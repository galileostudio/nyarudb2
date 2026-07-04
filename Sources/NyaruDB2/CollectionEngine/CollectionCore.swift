import Crypto
import Foundation

// MARK: - Manifest I/O (single source of truth)

/// Provides safe, centralised read and write operations for collection
/// manifests, ensuring encryption is always applied consistently.
///
/// **Why this exists.** A previous bug class occurred because `openCore`
/// encrypted the manifest when writing it, but `setIndexedFields` rewrote
/// it as plaintext JSON. On the next open, the engine tried to AES-decrypt
/// plain JSON and the collection became permanently unopenable.
///
/// All manifest I/O in the codebase MUST go through `ManifestIO.read` and
/// `ManifestIO.write` to guarantee that encryption (when configured) is
/// applied in exactly one place.
enum ManifestIO {
  /// Reads and optionally decrypts a collection manifest from disk.
  ///
  /// - Parameters:
  ///   - url: The file URL of the manifest (`manifest.json`).
  ///   - encryptionKey: Optional AES-256-GCM key for decryption.
  /// - Returns: The decoded `CollectionManifest`.
  /// - Throws: `NyaruError.decryptionFailed` if decryption fails.
  static func read(at url: URL, encryptionKey: SymmetricKey?) throws -> CollectionManifest {
    let raw = try Data(contentsOf: url)
    let plaintext: Data
    if let key = encryptionKey {
      do {
        let sealedBox = try AES.GCM.SealedBox(combined: raw)
        plaintext = try AES.GCM.open(sealedBox, using: key)
      } catch {
        throw NyaruError.decryptionFailed
      }
    } else {
      plaintext = raw
    }
    return try JSONDecoder().decode(CollectionManifest.self, from: plaintext)
  }

  /// Writes and optionally encrypts a collection manifest to disk.
  ///
  /// - Parameters:
  ///   - manifest: The manifest to persist.
  ///   - url: The destination file URL.
  ///   - encryptionKey: Optional AES-256-GCM key for encryption.
  /// - Throws: `NyaruError.encryptionFailed` if encryption fails.
  static func write(_ manifest: CollectionManifest, to url: URL, encryptionKey: SymmetricKey?)
    throws
  {
    let plaintext = try JSONEncoder().encode(manifest)
    let payload: Data
    if let key = encryptionKey {
      do {
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else { throw NyaruError.encryptionFailed }
        payload = combined
      } catch let error as NyaruError {
        throw error
      } catch {
        throw NyaruError.encryptionFailed
      }
    } else {
      payload = plaintext
    }
    try payload.write(to: url, options: .atomic)
  }
}

/// Persisted per-collection configuration stored in `manifest.json` within
/// the collection's directory.
///
/// The manifest is created once when the collection is first opened and is
/// immutable thereafter — changing the base configuration would reinterpret
/// the on-disk layout and corrupt data. Only `indexedFields` may evolve
/// across opens.
struct CollectionManifest: Codable, Equatable, Sendable {
  /// File format version for forward-compatibility.
  var formatVersion: Int = 1
  /// The human-readable collection name.
  var name: String
  /// The document field used as the unique identifier.
  var idField: String
  /// Optional field used to partition documents into shards.
  var partitionKey: String?
  /// Additional fields with maintained indexes, sorted alphabetically.
  var indexedFields: [String]
  /// The compression method applied to new records.
  var compression: CompressionMethod
  /// File protection level for shard files.
  var fileProtection: FileProtection
  /// Serialisation format (JSON or MsgPack).
  var format: SerializationFormat
  /// Whether the collection uses encryption.
  var isEncrypted: Bool
  /// Fragmentation threshold for compaction hints.
  var maxFragmentation: Double

  /// Checks whether the base (immutable) configuration matches another
  /// manifest, ignoring differences in `indexedFields`.
  ///
  /// The base configuration — id field, partition key, compression,
  /// protection, format, encryption — is frozen at collection creation.
  /// Indexed fields may be added later.
  func sameBase(as other: CollectionManifest) -> Bool {
    formatVersion == other.formatVersion
      && name == other.name
      && idField == other.idField
      && partitionKey == other.partitionKey
      && compression == other.compression
      && fileProtection == other.fileProtection
      && format == other.format
      && isEncrypted == other.isEncrypted
  }
}

/// A snapshot of collection statistics returned by `NyaruCollection.stats()`.
public struct CollectionStats: Sendable {
  /// The collection name.
  public let name: String
  /// The number of live (non-tombstoned) documents.
  public let documentCount: Int
  /// The number of shard files on disk.
  public let shardCount: Int
  /// The total on-disk size of all shard files, in bytes.
  public let sizeInBytes: UInt64
  /// Index statistics mapping field name to entry count.
  public let indexes: [String: Int]
  /// The ratio of dead (tombstoned) bytes to total file size.
  public let fragmentationRatio: Double
}

/// The type-erased engine behind one collection. This actor owns the shard
/// files, indexes, and manifest for a single collection.
///
/// `CollectionCore` is the workhorse of NyaruDB. It:
/// - Routes documents to shards based on the partition key.
/// - Maintains in-memory `OrderedIndex` instances for every indexed field.
/// - Provides CRUD operations with index consistency.
/// - Handles crash recovery by comparing dirty-flag state with index
///   snapshot recency.
/// - Supports partial updates (patch) with a validate-then-write protocol
///   that prevents type-poisoned documents.
/// - Provides parallel full-scan, partition-scoped scan, and index-based
///   point/range lookups for the query engine.
/// - Performs compaction to reclaim space from tombstoned records.
///
/// All file I/O is serialised through Swift actor concurrency, and index
/// accesses are guarded by actor isolation.
actor CollectionCore {
  private(set) var manifest: CollectionManifest
  private let directory: URL
  private let format: SerializationFormat
  private let encryptionKey: SymmetricKey?
  private var shards: [String: ShardActor] = [:]
  private var shardURLs: [String: URL] = [:]
  private var indexes: [String: OrderedIndex] = [:]
  private var isClosed = false

  /// The configured document id field name.
  var idField: String { manifest.idField }

  private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
  private var shardsDirectory: URL { directory.appendingPathComponent("shards", isDirectory: true) }
  private var indexesDirectory: URL {
    directory.appendingPathComponent("indexes", isDirectory: true)
  }

  /// Returns all fields that should have indexes: the explicit `indexedFields`
  /// plus the always-indexed `idField`.
  private var allIndexedFields: [String] {
    var fields = manifest.indexedFields
    if !fields.contains(manifest.idField) { fields.append(manifest.idField) }
    return fields
  }

  // MARK: - Open

  /// Opens or initialises a collection engine from its directory.
  ///
  /// On open, the engine:
  /// 1. Discovers existing shard files.
  /// 2. Checks the dirty flag on all shards.
  /// 3. Attempts to load index snapshots from disk.
  /// 4. If any shard was dirty OR index snapshots are missing/invalid,
  ///    rebuilds all indexes by scanning every shard.
  ///
  /// - Parameters:
  ///   - directory: The collection's directory URL.
  ///   - manifest: The persisted manifest.
  ///   - format: The serialisation format.
  ///   - encryptionKey: Optional AES-256-GCM key.
  init(
    directory: URL, manifest: CollectionManifest, format: SerializationFormat,
    encryptionKey: SymmetricKey?
  ) async throws {
    self.directory = directory
    self.manifest = manifest
    self.format = format
    self.encryptionKey = encryptionKey
    let fm = FileManager.default
    try fm.createDirectory(at: shardsDirectory, withIntermediateDirectories: true)
    try fm.createDirectory(at: indexesDirectory, withIntermediateDirectories: true)

    let files =
      (try? fm.contentsOfDirectory(at: shardsDirectory, includingPropertiesForKeys: nil)) ?? []
    for url in files where url.pathExtension == "nyaru" {
      let shardID = url.deletingPathExtension().lastPathComponent
      shardURLs[shardID] = url
    }

    var anyShardDirty = false
    for (_, url) in shardURLs {
      if SlottedFile.peekDirty(url: url) {
        anyShardDirty = true
        break
      }
    }

    let indexSnapshotsLoaded = try loadIndexSnapshots()
    if anyShardDirty || !indexSnapshotsLoaded {
      try await rebuildAllIndexes()
    }
  }

  /// Loads index snapshots from disk for all indexed fields.
  ///
  /// - Returns: `true` if all snapshots were loaded successfully, `false` if
  ///   any snapshot file is missing or corrupt.
  private func loadIndexSnapshots() throws -> Bool {
    var loaded: [String: OrderedIndex] = [:]
    let fm = FileManager.default

    for field in allIndexedFields {
      let url = snapshotURL(for: field)
      guard fm.fileExists(atPath: url.path) else { return false }
      do {
        loaded[field] = try OrderedIndex.load(from: url, encryptionKey: encryptionKey)
      } catch {
        return false
      }
    }
    indexes = loaded
    return true
  }

  /// Returns the file URL for the index snapshot of a given field.
  private func snapshotURL(for field: String) -> URL {
    indexesDirectory.appendingPathComponent("\(Self.sanitizeFileComponent(field)).idx")
  }

  /// Rebuilds every index by scanning all live records in every shard.
  ///
  /// This is called when:
  /// - A shard was dirty (crash recovery needed).
  /// - Index snapshots are missing or failed to load.
  /// - Indexed fields have been added since the last open.
  private func rebuildAllIndexes() async throws {
    var fresh: [String: OrderedIndex] = [:]
    for field in allIndexedFields { fresh[field] = OrderedIndex() }

    for shardID in shardURLs.keys {
      let shard = try shard(for: shardID)
      try await shard.forEachLive { offset, data in
        let pointer = RecordPointer(shardID: shardID, offset: offset)
        guard let dict = try? FieldExtractor.parse(data, using: format) else { return }
        for field in allIndexedFields {
          if let key = FieldExtractor.value(in: dict, path: field) {
            fresh[field]?.insert(key: key, pointer: pointer)
          }
        }
      }
    }
    indexes = fresh
  }

  /// Persists all index snapshots and flushes all shard headers to disk.
  func sync() async throws {
    try ensureOpen()
    for (field, index) in indexes {
      try index.persist(to: snapshotURL(for: field), encryptionKey: encryptionKey)
    }
    for shard in shards.values {
      try await shard.sync()
    }
  }

  /// Syncs and shuts down the core.
  func close() async throws {
    guard !isClosed else { return }
    try await sync()
    for shard in shards.values {
      try await shard.close()
    }
    isClosed = true
  }

  private func ensureOpen() throws {
    if isClosed { throw NyaruError.databaseClosed }
  }

  // MARK: - Shard routing

  /// Sanitises a string for use as a filesystem component by percent-encoding
  /// non-ASCII and special characters. Alphanumerics, underscores, and hyphens
  /// are preserved as-is.
  ///
  /// - Parameter raw: The raw string (e.g. a collection or shard name).
  /// - Returns: A filesystem-safe string.
  static func sanitizeFileComponent(_ raw: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    var out = ""
    for scalar in raw.unicodeScalars {
      if allowed.contains(scalar) && scalar.isASCII {
        out.unicodeScalars.append(scalar)
      } else {
        for byte in String(scalar).utf8 {
          out += String(format: "%%%02X", byte)
        }
      }
    }
    return out.isEmpty ? "_" : out
  }

  /// Determines the target shard ID for a document based on its partition key
  /// value and the encryption configuration.
  ///
  /// When encryption is enabled, the shard ID is an HMAC-SHA256 of the
  /// partition value to prevent leaking the partition distribution.
  /// Otherwise, the partition value is sanitised for filesystem use.
  ///
  /// - Parameter dict: The parsed document dictionary.
  /// - Returns: The shard ID string.
  /// - Throws: `NyaruError.partitionKeyMissing` if the partition key is
  ///   configured but absent from the document.
  private func shardID(forDocument dict: [String: Any]) throws -> String {
    guard let partitionKey = manifest.partitionKey else { return "default" }
    guard let value = FieldExtractor.value(in: dict, path: partitionKey) else {
      throw NyaruError.partitionKeyMissing(field: partitionKey)
    }
    let rawID = value.description

    if let key = encryptionKey {
      let hmac = HMAC<SHA256>.authenticationCode(for: Data(rawID.utf8), using: key)
      return Data(hmac).map { String(format: "%02x", $0) }.joined()
    } else {
      return Self.sanitizeFileComponent(rawID)
    }
  }

  /// Returns the `ShardActor` for a given shard ID, creating it lazily if
  /// it has not been opened yet.
  ///
  /// - Parameter id: The shard ID.
  /// - Returns: The shard actor.
  /// - Throws: I/O errors from shard initialisation.
  private func shard(for id: String) throws -> ShardActor {
    if let existing = shards[id] { return existing }

    let url = shardURLs[id] ?? shardsDirectory.appendingPathComponent("\(id).nyaru")
    let shard = try ShardActor(
      id: id, url: url,
      compression: manifest.compression,
      fileProtection: manifest.fileProtection,
      encryptionKey: encryptionKey,
      maxFragmentation: manifest.maxFragmentation
    )
    shards[id] = shard
    shardURLs[id] = url
    return shard
  }

  /// Returns an existing shard actor for the given ID, throwing if the
  /// shard is unknown (i.e. no shard file exists and no in-memory reference).
  ///
  /// - Parameter id: The shard ID.
  /// - Returns: The shard actor.
  /// - Throws: `NyaruError.corruptedRecord` if the shard is not found.
  private func existingShard(_ id: String) throws -> ShardActor {
    if let existing = shards[id] { return existing }
    if shardURLs[id] != nil {
      return try shard(for: id)
    }
    throw NyaruError.corruptedRecord(offset: 0, reason: "pointer references unknown shard '\(id)'")
  }

  // MARK: - Field helpers

  /// Extracts the document ID from a parsed dictionary.
  ///
  /// - Parameter dict: The parsed document.
  /// - Returns: The document's id as a `FieldValue`.
  /// - Throws: `NyaruError.idFieldMissing` if the id field is absent.
  private func extractID(from dict: [String: Any]) throws -> FieldValue {
    guard let id = FieldExtractor.value(in: dict, path: manifest.idField) else {
      throw NyaruError.idFieldMissing(field: manifest.idField)
    }
    return id
  }

  /// Returns all indexed field/key pairs extracted from a document.
  ///
  /// - Parameter dict: The parsed document dictionary.
  /// - Returns: An array of `(field, key)` tuples for every indexed field
  ///   present in the document.
  private func indexEntries(for dict: [String: Any]) -> [(field: String, key: FieldValue)] {
    allIndexedFields.compactMap { field in
      FieldExtractor.value(in: dict, path: field).map { (field, $0) }
    }
  }

  /// Reads a record through an index pointer and verifies that the document's
  /// id matches what the index claimed.
  ///
  /// **Why verify?** A stale pointer (e.g. the shard was compacted and offsets
  /// shifted) can land on a DIFFERENT valid record whose CRC passes. Blindly
  /// returning it would be silent wrong-document corruption — and on write
  /// paths, tombstoning through it would delete an innocent record. On
  /// mismatch, the stale entry is evicted from the index (self-healing) so
  /// the caller sees "not there".
  ///
  /// **Performance note:** This costs one `FieldExtractor.parse()` per pointer
  /// read, which is cheap relative to the I/O of reading the shard data. The
  /// correctness guarantee is worth the extra parse.
  ///
  /// - Parameters:
  ///   - pointer: The index pointer to read through.
  ///   - id: The expected document ID.
  /// - Returns: The record data and parsed dictionary, or `nil` if the
  ///   document was not found or the pointer was stale.
  private func verifiedRead(pointer: RecordPointer, expecting id: FieldValue) async throws
    -> (data: Data, dict: [String: Any])?
  {
    let shard = try existingShard(pointer.shardID)
    guard let data = try await shard.read(at: pointer.offset) else { return nil }
    let dict = try FieldExtractor.parse(data, using: format)
    guard let actualID = FieldExtractor.value(in: dict, path: manifest.idField), actualID == id
    else {
      indexes[manifest.idField]?.remove(key: id, pointer: pointer)
      return nil
    }
    return (data, dict)
  }

  // MARK: - CRUD

  /// Inserts a document after validating that its id is unique.
  ///
  /// - Parameter data: The encoded document data.
  /// - Throws: `NyaruError.duplicateID` if the id already exists.
  func insert(data: Data) async throws {
    try ensureOpen()
    let dict = try FieldExtractor.parse(data, using: format)
    let id = try extractID(from: dict)
    if indexes[manifest.idField]?.contains(id) == true {
      throw NyaruError.duplicateID(id.description)
    }
    try await performInsert(data: data, dict: dict)
  }

  /// Performs a bulk insert of multiple documents with optimized index loading.
  ///
  /// This method optimizes batch inserts by:
  ///   1. Validating all documents before touching disk (all-or-nothing)
  ///   2. Grouping documents by shard for minimal I/O
  ///   3. Writing each shard's batch in a single disk operation
  ///   4. Collecting index entries during the write phase
  ///   5. Loading all indexes in bulk using an O(N log N) merge algorithm
  ///
  /// The index loading is the key optimization: instead of inserting entries
  /// one by one (O(N²) due to array shifting), entries are collected and
  /// loaded in bulk using `OrderedIndex.bulkLoad(_:)`.
  ///
  /// - Parameter datas: An array of serialized document `Data` payloads.
  /// - Throws: `NyaruError.duplicateID` if any document ID conflicts with an
  ///   existing document or appears multiple times in the batch.
  ///   `NyaruError.partitionKeyMissing` if the partition key is missing in a
  ///   document when partitioning is configured.
  ///
  /// - Complexity: O(N log N) for sorting entries during bulk load, where N
  ///   is the total number of documents being inserted.
  ///
  /// - Note: The entire batch is treated as an atomic operation: if any
  ///   validation fails, no documents are written to disk.
  ///
  /// - SeeAlso: `insert(data:)` for single-document insertion,
  ///   `OrderedIndex.bulkLoad(_:)` for the index loading implementation.
  func insertMany(datas: [Data]) async throws {
    try ensureOpen()
    var seen = Set<FieldValue>()
    var groupedByShard: [String: [(data: Data, metadata: Serializer.DocumentMetadata)]] = [:]

    for data in datas {
      // ROADMAP 2: Usa extractMetadata (evita construir o dict completo separadamente)
      let metadata = try Serializer.extractMetadata(
        from: data, idField: manifest.idField, partitionKey: manifest.partitionKey,
        indexedFields: allIndexedFields, format: format)

      if indexes[manifest.idField]?.contains(metadata.id) == true
        || !seen.insert(metadata.id).inserted
      {
        throw NyaruError.duplicateID(metadata.id.description)
      }

      let shardID = try shardID(forPartitionValue: metadata.partitionValue)
      groupedByShard[shardID, default: []].append((data, metadata))
    }

    var indexUpdates: [String: [(key: FieldValue, pointer: RecordPointer)]] = [:]
    for field in allIndexedFields { indexUpdates[field] = [] }

    for (shardID, items) in groupedByShard {
      let shard = try shard(for: shardID)
      let datas = items.map { $0.data }
      let pointers = try await shard.insertMany(datas: datas)

      for (i, item) in items.enumerated() {
        let pointer = pointers[i]
        for entry in item.metadata.indexEntries {
          indexUpdates[entry.field, default: []].append((key: entry.key, pointer: pointer))
        }
      }
    }

    for (field, entries) in indexUpdates {
      indexes[field]?.bulkLoad(entries)
    }
  }

  private func shardID(forPartitionValue value: FieldValue?) throws -> String {
    guard let partitionKey = manifest.partitionKey else { return "default" }
    guard let value = value else {
      throw NyaruError.partitionKeyMissing(field: partitionKey)
    }
    let rawID = value.description
    if let key = encryptionKey {
      let hmac = HMAC<SHA256>.authenticationCode(for: Data(rawID.utf8), using: key)
      return Data(hmac).map { String(format: "%02x", $0) }.joined()
    } else {
      return Self.sanitizeFileComponent(rawID)
    }
  }

  /// Performs the actual insert: routes to a shard, writes, and updates indexes.
  private func performInsert(data: Data, dict: [String: Any]) async throws {
    let shardID = try shardID(forDocument: dict)
    let shard = try shard(for: shardID)
    let pointer = try await shard.insert(data: data)
    for entry in indexEntries(for: dict) {
      indexes[entry.field]?.insert(key: entry.key, pointer: pointer)
    }
  }

  /// Point lookup by document id through the primary index.
  ///
  /// - Parameter id: The document id.
  /// - Returns: The encoded document data, or `nil` if not found.
  func get(id: FieldValue) async throws -> Data? {
    try ensureOpen()
    guard let pointer = indexes[manifest.idField]?.search(id).first else { return nil }
    let shard = try existingShard(pointer.shardID)
    guard let data = try await shard.read(at: pointer.offset) else { return nil }

    if let actualID = Serializer.fieldValue(in: data, path: manifest.idField, format: format),
      actualID != id
    {
      indexes[manifest.idField]?.remove(key: id, pointer: pointer)
      return nil
    }
    return data
  }

  /// Point update by id. Handles three layouts:
  /// 1. **In-place** — new payload fits the existing slot capacity.
  /// 2. **Same-shard relocation** — doesn't fit; tombstone + append in same shard.
  /// 3. **Cross-shard relocation** — partition value changed; insert in new
  ///    shard, delete from old.
  ///
  /// - Parameters:
  ///   - data: The new encoded document.
  ///   - upsert: If `true`, insert when the id is not found.
  /// - Throws: `NyaruError.documentNotFound` if not found and `upsert` is false.
  func update(data: Data, upsert: Bool) async throws {
    try ensureOpen()
    // ROADMAP 2: Usa extractMetadata
    let metadata = try Serializer.extractMetadata(
      from: data, idField: manifest.idField, partitionKey: manifest.partitionKey,
      indexedFields: allIndexedFields, format: format)
    let id = metadata.id

    guard let oldPointer = indexes[manifest.idField]?.search(id).first else {
      if upsert {
        // Inserção isolada se não existir
        let shardID = try shardID(forPartitionValue: metadata.partitionValue)
        let shard = try shard(for: shardID)
        let pointer = try await shard.insert(data: data)
        for entry in metadata.indexEntries {
          indexes[entry.field]?.insert(key: entry.key, pointer: pointer)
        }
        return
      }
      throw NyaruError.documentNotFound(id: id.description)
    }

    let oldShard = try existingShard(oldPointer.shardID)
    guard let oldData = try await oldShard.read(at: oldPointer.offset) else {
      removeFromAllIndexes(pointer: oldPointer)
      let shardID = try shardID(forPartitionValue: metadata.partitionValue)
      let shard = try shard(for: shardID)
      let pointer = try await shard.insert(data: data)
      for entry in metadata.indexEntries {
        indexes[entry.field]?.insert(key: entry.key, pointer: pointer)
      }
      return
    }

    let oldMetadata = try Serializer.extractMetadata(
      from: oldData, idField: manifest.idField, partitionKey: manifest.partitionKey,
      indexedFields: allIndexedFields, format: format)
    let newShardID = try shardID(forPartitionValue: metadata.partitionValue)

    let newPointer: RecordPointer
    if newShardID == oldPointer.shardID {
      newPointer = try await oldShard.update(at: oldPointer.offset, data: data)
    } else {
      let newShard = try shard(for: newShardID)
      newPointer = try await newShard.insert(data: data)
      try await oldShard.delete(at: oldPointer.offset)
    }

    for field in allIndexedFields {
      guard let index = indexes[field] else { continue }
      let oldKey = oldMetadata.indexEntries.first(where: { $0.field == field })?.key
      let newKey = metadata.indexEntries.first(where: { $0.field == field })?.key

      if oldKey == newKey, let key = oldKey {

        index.replace(key: key, old: oldPointer, new: newPointer)
      } else {
        if let oldKey { index.remove(key: oldKey, pointer: oldPointer) }
        if let newKey { index.insert(key: newKey, pointer: newPointer) }
      }
    }
  }

  // MARK: - Partial Update (Patch)

  /// Partially updates a document by applying top-level field changes.
  ///
  /// **Two-phase protocol.** The merged document is built and passed to the
  /// `validate` closure BEFORE anything touches disk or indexes. The previous
  /// version validated in the facade after the write, so a type-poisoned
  /// document (e.g. patching "age" to a string) was already persisted when
  /// the error surfaced — every future read of that doc failed forever.
  /// Here, the validator runs inside this single actor call, so
  /// validate-then-write is atomic with respect to every other operation.
  ///
  /// - Parameters:
  ///   - id: The document id.
  ///   - changes: A dictionary of top-level field changes.
  ///   - validate: A closure that validates the merged data before writing.
  /// - Returns: The new encoded document data.
  /// - Throws: `NyaruError.documentNotFound` if not found,
  ///   `NyaruError.unsupportedOperation` for id changes or nested paths.
  func patch(
    id: FieldValue, changes: [String: FieldValue], validate: @Sendable (Data) throws -> Void
  ) async throws -> Data {
    try ensureOpen()
    guard !changes.isEmpty else {
      guard let pointer = indexes[manifest.idField]?.search(id).first,
        let current = try await verifiedRead(pointer: pointer, expecting: id)
      else { throw NyaruError.documentNotFound(id: id.description) }
      return current.data
    }
    if changes.keys.contains(manifest.idField) {
      throw NyaruError.unsupportedOperation("Changing the document ID is not allowed via patch.")
    }
    for key in changes.keys where key.contains(".") {
      throw NyaruError.unsupportedOperation("Nested paths are not supported in patch.")
    }
    guard let pointer = indexes[manifest.idField]?.search(id).first else {
      throw NyaruError.documentNotFound(id: id.description)
    }
    guard let old = try await verifiedRead(pointer: pointer, expecting: id) else {
      removeFromAllIndexes(pointer: pointer)
      throw NyaruError.documentNotFound(id: id.description)
    }
    let oldShard = try existingShard(pointer.shardID)

    let oldDict = old.dict
    var newDict = oldDict
    for (key, value) in changes { newDict[key] = value.anyValue }
    let newData = try Serializer.encode(AnyEncodable(value: newDict), format: format)
    try validate(newData)

    let newMetadata = try Serializer.extractMetadata(
      from: newData, idField: manifest.idField, partitionKey: manifest.partitionKey,
      indexedFields: allIndexedFields, format: format)

    let newShardID = try shardID(forPartitionValue: newMetadata.partitionValue)
    let newPointer: RecordPointer
    if newShardID == oldShard.id {
      newPointer = try await oldShard.update(at: pointer.offset, data: newData)
    } else {
      let newShard = try shard(for: newShardID)
      newPointer = try await newShard.insert(data: newData)
      try await oldShard.delete(at: pointer.offset)
    }

    let oldMetadata = try Serializer.extractMetadata(
      from: old.data, idField: manifest.idField, partitionKey: manifest.partitionKey,
      indexedFields: allIndexedFields, format: format)

    for field in allIndexedFields {
      guard let index = indexes[field] else { continue }
      let oldKey = oldMetadata.indexEntries.first(where: { $0.field == field })?.key
      let newKey = newMetadata.indexEntries.first(where: { $0.field == field })?.key

      if oldKey == newKey, let key = oldKey {

        index.replace(key: key, old: pointer, new: newPointer)
      } else {
        if let oldKey { index.remove(key: oldKey, pointer: pointer) }
        if let newKey { index.insert(key: newKey, pointer: newPointer) }
      }
    }
    return newData
  }

  /// Deletes a document by id, removing it from indexes and tombstoning
  /// it in its shard.
  ///
  /// - Parameter id: The document id.
  /// - Returns: `true` if a document was found and deleted.
  @discardableResult
  func delete(id: FieldValue) async throws -> Bool {
    try ensureOpen()
    guard let pointer = indexes[manifest.idField]?.search(id).first else { return false }
    let shard = try existingShard(pointer.shardID)
    guard let oldData = try await shard.read(at: pointer.offset) else {
      removeFromAllIndexes(pointer: pointer)
      return false
    }
    try await shard.delete(at: pointer.offset)

    for field in allIndexedFields {
      if let key = Serializer.fieldValue(in: oldData, path: field, format: format) {
        indexes[field]?.remove(key: key, pointer: pointer)
      }
    }
    return true
  }

  /// Removes a pointer from every index. Used when a record disappears
  /// (corrupt, stale pointer, or phantom).
  private func removeFromAllIndexes(pointer: RecordPointer) {
    for field in allIndexedFields {
      guard let index = indexes[field] else { continue }
      for key in index.keys {
        index.remove(key: key, pointer: pointer)
      }
    }
  }

  /// Returns the total number of live documents (from the primary index).
  func count() -> Int {
    indexes[manifest.idField]?.entryCount ?? 0
  }

  // MARK: - Index evolution

  /// Adds or removes indexed fields, rebuilding indexes for new fields by
  /// scanning all shards.
  ///
  /// - Parameter fields: The new set of indexed fields.
  /// - Throws: I/O errors from manifest writes.
  func setIndexedFields(_ fields: [String]) async throws {
    try ensureOpen()
    let sorted = Array(Set(fields)).sorted()
    guard sorted != manifest.indexedFields else { return }

    var wanted = Set(sorted)
    wanted.insert(manifest.idField)

    for field in indexes.keys where !wanted.contains(field) {
      indexes.removeValue(forKey: field)
      try? FileManager.default.removeItem(at: snapshotURL(for: field))
    }

    let missing = wanted.filter { indexes[$0] == nil }
    if !missing.isEmpty {
      var fresh: [String: OrderedIndex] = [:]
      for field in missing { fresh[field] = OrderedIndex() }

      for shardID in shardURLs.keys {
        let shard = try shard(for: shardID)
        try await shard.forEachLive { offset, data in
          let pointer = RecordPointer(shardID: shardID, offset: offset)
          guard let dict = try? FieldExtractor.parse(data, using: format) else { return }
          for field in missing {
            if let key = FieldExtractor.value(in: dict, path: field) {
              fresh[field]?.insert(key: key, pointer: pointer)
            }
          }
        }
      }
      for (field, index) in fresh { indexes[field] = index }
    }

    manifest.indexedFields = sorted
    try ManifestIO.write(manifest, to: manifestURL, encryptionKey: encryptionKey)
  }

  // MARK: - Reads for queries / scans

  /// Performs a full scan of all shards in parallel, returning every live
  /// document's encoded data.
  func scanAll() async throws -> [Data] {
    try ensureOpen()
    for shardID in shardURLs.keys {
      _ = try shard(for: shardID)
    }

    let allShards = Array(shards.values)
    return try await withThrowingTaskGroup(of: [Data].self) { group in
      for shard in allShards {
        group.addTask {
          var out: [Data] = []
          try await shard.forEachLive { _, data in
            out.append(data)
          }
          return out
        }
      }
      var out: [Data] = []
      for try await chunk in group { out.append(contentsOf: chunk) }
      return out
    }
  }

  /// Scans a single partition shard identified by the partition key value.
  ///
  /// - Parameter value: The partition key value.
  /// - Returns: All live document data from the matching shard.
  func scanPartition(value: FieldValue) async throws -> [Data] {
    try ensureOpen()
    let rawID = value.description
    let id: String
    if let key = encryptionKey {
      let hmac = HMAC<SHA256>.authenticationCode(for: Data(rawID.utf8), using: key)
      id = Data(hmac).map { String(format: "%02x", $0) }.joined()
    } else {
      id = Self.sanitizeFileComponent(rawID)
    }

    guard let shard = try? shard(for: id) else { return [] }
    var out: [Data] = []
    try await shard.forEachLive { _, data in
      out.append(data)
    }
    return out
  }

  /// Returns all known shard IDs, sorted.
  ///
  /// Used by the pull-based streaming iterator to discover shards.
  func shardIDList() -> [String] {
    shardURLs.keys.sorted()
  }

  /// Reads a batch of records from a shard, starting at the given position.
  ///
  /// - Parameters:
  ///   - shardID: The shard to read from.
  ///   - pos: The byte position to resume from, or `nil` to start at the
  ///     beginning.
  ///   - maxCount: Maximum number of records to return.
  /// - Returns: A tuple of encoded data items and the next position cursor.
  func readBatch(shardID: String, from pos: UInt64?, maxCount: Int) async throws
    -> (items: [Data], nextPos: UInt64?)
  {
    try ensureOpen()
    guard shardURLs[shardID] != nil else { return ([], nil) }
    let shard = try shard(for: shardID)
    let batch = try await shard.readLiveBatch(from: pos, maxCount: max(1, maxCount))
    return (batch.items.map(\.data), batch.nextPos)
  }

  /// Returns whether the given field has an active in-memory index.
  func isIndexed(field: String) -> Bool {
    indexes[field] != nil
  }

  /// Searches an index for all pointers matching the given key.
  func indexSearch(field: String, key: FieldValue) -> [RecordPointer] {
    indexes[field]?.search(key) ?? []
  }

  /// Performs a range lookup on an indexed field.
  func indexRange(
    field: String,
    lower: FieldValue?, lowerInclusive: Bool,
    upper: FieldValue?, upperInclusive: Bool
  ) -> [RecordPointer] {
    indexes[field]?.range(
      lower: lower, lowerInclusive: lowerInclusive,
      upper: upper, upperInclusive: upperInclusive
    ) ?? []
  }

  /// Fetches the encoded data for a list of pointers.
  func fetch(pointers: [RecordPointer]) async throws -> [Data] {
    try ensureOpen()
    if pointers.isEmpty { return [] }

    var grouped: [String: [UInt64]] = [:]
    for pointer in pointers {
      grouped[pointer.shardID, default: []].append(pointer.offset)
    }

    var out: [Data] = []
    out.reserveCapacity(pointers.count)

    for (shardID, offsets) in grouped {
      let shard = try existingShard(shardID)
      // Sort offsets to turn random disk seeks into sequential reads
      let sortedOffsets = offsets.sorted()
      // Single actor hop per shard to read multiple records
      let batch = try await shard.readBatch(offsets: sortedOffsets)
      out.append(contentsOf: batch)
    }

    return out
  }

  // MARK: - Maintenance

  /// Rewrites every shard without tombstones (or padding waste), then
  /// rebuilds all indexes.
  ///
  /// This is the manual replacement for the old engine's 60-second background
  /// auto-merge task, which was removed by design: background timers in a
  /// mobile embedded database burn battery and raced with concurrent writes.
  ///
  /// Shards are compacted concurrently (up to 3 at a time) to minimise
  /// latency on multi-shard collections.
  func compact() async throws {
    try ensureOpen()
    let allShardIDs = Array(shardURLs.keys)

    let maxConcurrent = 3
    var iterator = allShardIDs.makeIterator()

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<min(maxConcurrent, allShardIDs.count) {
        if let shardID = iterator.next() {
          group.addTask {
            let shard = try await self.shard(for: shardID)
            try await shard.compact()
          }
        }
      }

      while try await group.next() != nil {
        if let shardID = iterator.next() {
          group.addTask {
            let shard = try await self.shard(for: shardID)
            try await shard.compact()
          }
        }
      }
    }

    try await rebuildAllIndexes()
    try await sync()
  }

  /// Returns a snapshot of collection statistics.
  func stats() async -> CollectionStats {
    var size: UInt64 = 0
    var totalDeadBytes: UInt64 = 0

    for (_, url) in shardURLs {
      if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
        let fileSize = attrs[.size] as? UInt64
      {
        size += fileSize
      }
    }

    for shard in shards.values {
      totalDeadBytes += await shard.deadBytes
    }

    let fragRatio = size > 0 ? Double(totalDeadBytes) / Double(size) : 0.0

    var indexCounts: [String: Int] = [:]
    for (field, index) in indexes {
      indexCounts[field] = index.entryCount
    }

    return CollectionStats(
      name: manifest.name,
      documentCount: count(),
      shardCount: shardURLs.count,
      sizeInBytes: size,
      indexes: indexCounts,
      fragmentationRatio: fragRatio
    )
  }

  /// Deletes the entire collection directory from disk.
  ///
  /// The core must not be used after this is called.
  func destroy() async throws {
    for shard in shards.values {
      try? await shard.close()
    }
    shards = [:]
    shardURLs = [:]
    indexes = [:]
    isClosed = true
    try FileManager.default.removeItem(at: directory)
  }

  /// Checks whether any shard exceeds the fragmentation threshold.
  func checkNeedsCompaction() async -> Bool {
    for shard in shards.values {
      if await shard.needsCompaction {
        return true
      }
    }
    return false
  }
}
