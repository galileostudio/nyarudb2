import Crypto
import Foundation

/// Persisted per-collection configuration.
struct CollectionManifest: Codable, Equatable, Sendable {
  var formatVersion: Int = 1
  var name: String
  var idField: String
  var partitionKey: String?
  var indexedFields: [String]
  var compression: CompressionMethod
  var fileProtection: FileProtection
  var format: SerializationFormat
  var isEncrypted: Bool

  /// True when everything except `indexedFields` matches. The base
  /// configuration is frozen at creation (changing it would reinterpret
  /// the on-disk layout); indexed fields may evolve between opens.
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

/// Snapshot statistics for a collection.
public struct CollectionStats: Sendable {
  public let name: String
  public let documentCount: Int
  public let shardCount: Int
  public let sizeInBytes: UInt64
  public let indexes: [String: Int]  // field -> entry count
}

/// The type-erased engine behind one collection.
///
/// Owns the collection directory, one `ShardActor` per shard file, and all
/// in-memory indexes. Everything above this layer (the typed
/// `NyaruCollection<T>` facade and the query builder) only encodes/decodes;
/// everything below (`ShardActor`/`SlottedFile`) only moves bytes.
actor CollectionCore {
  private(set) var manifest: CollectionManifest
  private let directory: URL
  private let format: SerializationFormat
  private let encryptionKey: SymmetricKey?
  private var shards: [String: ShardActor] = [:]
  private var shardURLs: [String: URL] = [:]  // Maps on-disk files without opening FileHandle
  /// field -> index. Always contains an index for `manifest.idField`.
  private var indexes: [String: OrderedIndex] = [:]
  private var isClosed = false

  var idField: String { manifest.idField }

  private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

  private var shardsDirectory: URL { directory.appendingPathComponent("shards", isDirectory: true) }
  private var indexesDirectory: URL {
    directory.appendingPathComponent("indexes", isDirectory: true)
  }
  private var allIndexedFields: [String] {
    var fields = manifest.indexedFields
    if !fields.contains(manifest.idField) { fields.append(manifest.idField) }
    return fields
  }

  // MARK: - Open

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

    // 1. Only list files on disk. Does NOT open FileHandle!
    let files =
      (try? fm.contentsOfDirectory(at: shardsDirectory, includingPropertiesForKeys: nil)) ?? []
    for url in files where url.pathExtension == "nyaru" {
      let shardID = url.deletingPathExtension().lastPathComponent
      shardURLs[shardID] = url
    }

    // 2. Rehydrate indexes. If indexes need rebuilding, open shards on demand.
    let indexSnapshotsLoaded = try loadIndexSnapshots()
    if !indexSnapshotsLoaded {
      try await rebuildAllIndexes()
    }
  }

  /// Returns false when any snapshot is missing/unreadable.
  private func loadIndexSnapshots() throws -> Bool {
    var loaded: [String: OrderedIndex] = [:]
    let fm = FileManager.default

    for field in allIndexedFields {
      let url = snapshotURL(for: field)
      guard fm.fileExists(atPath: url.path) else { return false }

      do {
        // Pass the encryption key to the index for decryption
        loaded[field] = try OrderedIndex.load(from: url, encryptionKey: encryptionKey)
      } catch {
        return false
      }
    }
    indexes = loaded
    return true
  }

  private func snapshotURL(for field: String) -> URL {
    indexesDirectory.appendingPathComponent("\(Self.sanitizeFileComponent(field)).idx")
  }

  private func rebuildAllIndexes() async throws {
    var fresh: [String: OrderedIndex] = [:]
    for field in allIndexedFields { fresh[field] = OrderedIndex() }

    // Iterate over mapped on-disk IDs, opening them on demand (Lazy Load)
    for shardID in shardURLs.keys {
      let shard = try shard(for: shardID)
      let records = try await shard.scanAll()
      for record in records {
        let pointer = RecordPointer(shardID: shardID, offset: record.offset)
        guard let dict = try? FieldExtractor.parse(record.data, using: format) else { continue }
        for field in allIndexedFields {
          if let key = FieldExtractor.value(in: dict, path: field) {
            fresh[field]?.insert(key: key, pointer: pointer)
          }
        }
      }
    }
    indexes = fresh
  }

  /// Persist index snapshots, then clear shard dirty flags — in that
  /// order. If we crash in between, shards remain dirty and the next open
  /// rebuilds the indexes, so a stale snapshot can never be trusted.
  func sync() async throws {
    try ensureOpen()

    for (field, index) in indexes {
      // Pass the encryption key to the index for encryption
      try index.persist(to: snapshotURL(for: field), encryptionKey: encryptionKey)
    }

    for shard in shards.values {
      try await shard.sync()
    }
  }

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

  private func shardID(forDocument dict: [String: Any]) throws -> String {
    guard let partitionKey = manifest.partitionKey else { return "default" }
    guard let value = FieldExtractor.value(in: dict, path: partitionKey) else {
      throw NyaruError.partitionKeyMissing(field: partitionKey)
    }
    let rawID = value.description

    // If encryption is enabled, use HMAC to avoid leaking partition values in filenames
    if let key = encryptionKey {
      let hmac = HMAC<SHA256>.authenticationCode(for: Data(rawID.utf8), using: key)
      return Data(hmac).map { String(format: "%02x", $0) }.joined()
    } else {
      return Self.sanitizeFileComponent(rawID)
    }
  }

  private func shard(for id: String) throws -> ShardActor {
    // If already open in memory, use it
    if let existing = shards[id] { return existing }

    // If it exists on disk but is not open, OPEN IT NOW (Lazy Load)
    if let url = shardURLs[id] {
      let shard = try ShardActor(
        id: id, url: url,
        compression: manifest.compression,
        fileProtection: manifest.fileProtection,
        encryptionKey: encryptionKey
      )
      shards[id] = shard
      return shard
    }

    // If it doesn't exist on disk, create a new file
    let url = shardsDirectory.appendingPathComponent("\(id).nyaru")
    let shard = try ShardActor(
      id: id, url: url,
      compression: manifest.compression,
      fileProtection: manifest.fileProtection,
      encryptionKey: encryptionKey
    )
    shards[id] = shard
    shardURLs[id] = url
    return shard
  }

  private func existingShard(_ id: String) throws -> ShardActor {
    // Try to get from memory or disk (Lazy Load)
    return try shard(for: id)
  }

  // MARK: - Field helpers

  private func extractID(from dict: [String: Any]) throws -> FieldValue {
    guard let id = FieldExtractor.value(in: dict, path: manifest.idField) else {
      throw NyaruError.idFieldMissing(field: manifest.idField)
    }
    return id
  }

  private func indexEntries(for dict: [String: Any]) -> [(field: String, key: FieldValue)] {
    allIndexedFields.compactMap { field in
      FieldExtractor.value(in: dict, path: field).map { (field, $0) }
    }
  }

  // MARK: - CRUD

  func insert(data: Data) async throws {
    try ensureOpen()
    let dict = try FieldExtractor.parse(data, using: format)
    let id = try extractID(from: dict)
    if indexes[manifest.idField]?.contains(id) == true {
      throw NyaruError.duplicateID(id.description)
    }
    try await performInsert(data: data, dict: dict)
  }

  /// Bulk insert: validates all ids first (against the index and against
  /// duplicates inside the batch) before writing anything. Shard headers
  /// are only synced once per `sync()`/`close()`, not per document.
  func insertMany(datas: [Data]) async throws {
    try ensureOpen()
    var parsed: [(data: Data, dict: [String: Any], id: FieldValue)] = []
    parsed.reserveCapacity(datas.count)
    var seen = Set<FieldValue>()
    for data in datas {
      let dict = try FieldExtractor.parse(data, using: format)
      let id = try extractID(from: dict)
      if indexes[manifest.idField]?.contains(id) == true || !seen.insert(id).inserted {
        throw NyaruError.duplicateID(id.description)
      }
      parsed.append((data, dict, id))
    }
    for item in parsed {
      try await performInsert(data: item.data, dict: item.dict)
    }
  }

  private func performInsert(data: Data, dict: [String: Any]) async throws {
    let shardID = try shardID(forDocument: dict)
    let shard = try shard(for: shardID)
    let pointer = try await shard.insert(data: data)
    for entry in indexEntries(for: dict) {
      indexes[entry.field]?.insert(key: entry.key, pointer: pointer)
    }
  }

  func get(id: FieldValue) async throws -> Data? {
    try ensureOpen()
    guard let pointer = indexes[manifest.idField]?.search(id).first else { return nil }
    let shard = try existingShard(pointer.shardID)
    return try await shard.read(at: pointer.offset)
  }

  /// Point update by id. Handles all three layouts:
  /// in-place (fits slot), same-shard relocation (doesn't fit), and
  /// cross-shard relocation (partition value changed — the case that
  /// corrupted data in the old engine).
  func update(data: Data, upsert: Bool) async throws {
    try ensureOpen()
    let dict = try FieldExtractor.parse(data, using: format)
    let id = try extractID(from: dict)
    guard let oldPointer = indexes[manifest.idField]?.search(id).first else {
      if upsert {
        try await performInsert(data: data, dict: dict)
        return
      }
      throw NyaruError.documentNotFound(id: id.description)
    }

    let oldShard = try existingShard(oldPointer.shardID)
    guard let oldData = try await oldShard.read(at: oldPointer.offset) else {
      // Index said it exists but the record is a tombstone: the index
      // is out of sync. Repair by treating this as an insert.
      removeFromAllIndexes(pointer: oldPointer)
      try await performInsert(data: data, dict: dict)
      return
    }
    let oldDict = try FieldExtractor.parse(oldData, using: format)

    let newShardID = try shardID(forDocument: dict)
    let newPointer: RecordPointer
    if newShardID == oldPointer.shardID {
      newPointer = try await oldShard.update(at: oldPointer.offset, data: data)
    } else {
      // Partition changed: write to the new shard first, then remove
      // the old record.
      let newShard = try shard(for: newShardID)
      newPointer = try await newShard.insert(data: data)
      try await oldShard.delete(at: oldPointer.offset)
    }

    // Reconcile every index: old entries out, new entries in.
    for field in allIndexedFields {
      let oldKey = FieldExtractor.value(in: oldDict, path: field)
      let newKey = FieldExtractor.value(in: dict, path: field)
      if let oldKey { indexes[field]?.remove(key: oldKey, pointer: oldPointer) }
      if let newKey { indexes[field]?.insert(key: newKey, pointer: newPointer) }
    }
  }

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
    let oldDict = try FieldExtractor.parse(oldData, using: format)
    for field in allIndexedFields {
      if let key = FieldExtractor.value(in: oldDict, path: field) {
        indexes[field]?.remove(key: key, pointer: pointer)
      }
    }
    return true
  }

  private func removeFromAllIndexes(pointer: RecordPointer) {
    for field in allIndexedFields {
      var index = indexes[field] ?? OrderedIndex()
      // Brute-force removal is acceptable here: this only runs on the
      // self-repair path for an inconsistent index entry.
      for key in index.keys {
        index.remove(key: key, pointer: pointer)
      }
      indexes[field] = index
    }
  }

  func count() -> Int {
    indexes[manifest.idField]?.entryCount ?? 0
  }

  // MARK: - Index evolution

  /// Reconciles the set of indexed fields with `fields`.
  ///
  /// Missing indexes are built with a single scan over all shards; indexes
  /// on dropped fields are discarded along with their snapshots. The
  /// manifest is rewritten atomically afterwards, so a crash mid-build
  /// leaves the old manifest in place and the next open simply retries.
  /// The id-field index is always kept.
  func setIndexedFields(_ fields: [String]) async throws {
    try ensureOpen()
    let sorted = Array(Set(fields)).sorted()
    guard sorted != manifest.indexedFields else { return }

    var wanted = Set(sorted)
    wanted.insert(manifest.idField)

    // Drop indexes that are no longer wanted.
    for field in indexes.keys where !wanted.contains(field) {
      indexes.removeValue(forKey: field)
      try? FileManager.default.removeItem(at: snapshotURL(for: field))
    }

    // Build the missing ones in one pass over the data.
    let missing = wanted.filter { indexes[$0] == nil }
    if !missing.isEmpty {
      var fresh: [String: OrderedIndex] = [:]
      for field in missing { fresh[field] = OrderedIndex() }

      // Iterate over all shards on disk (Lazy Load)
      for shardID in shardURLs.keys {
        let shard = try shard(for: shardID)
        let records = try await shard.scanAll()
        for record in records {
          let pointer = RecordPointer(shardID: shardID, offset: record.offset)
          guard let dict = try? FieldExtractor.parse(record.data, using: format) else { continue }
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
    let data = try JSONEncoder().encode(manifest)
    try data.write(to: manifestURL, options: .atomic)
  }

  // MARK: - Reads for queries / scans

  /// Full scan of all shards (parallel across shards).
  func scanAll() async throws -> [Data] {
    try ensureOpen()
    // Ensure all shards mapped on disk are open
    for shardID in shardURLs.keys {
      _ = try shard(for: shardID)
    }

    let allShards = Array(shards.values)
    return try await withThrowingTaskGroup(of: [Data].self) { group in
      for shard in allShards {
        group.addTask {
          try await shard.scanAll().map(\.data)
        }
      }
      var out: [Data] = []
      for try await chunk in group { out.append(contentsOf: chunk) }
      return out
    }
  }

  /// Restricts a full scan to a single partition when possible.
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

    // Use the Lazy Load router
    guard let shard = try? shard(for: id) else { return [] }
    return try await shard.scanAll().map(\.data)
  }

  /// REAL STREAMING: Iterates over shards without loading everything into RAM.
  nonisolated func scanLazy() -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      Task {
        do {
          // Pega os shards de forma assíncrona respeitando o isolamento do Actor
          let shardActors = try await self.getShardsForStreaming()
          for shard in shardActors {
            for try await record in shard.scanLazy() {
              continuation.yield(record.data)
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  /// Helper isolado para retornar os actors de forma segura para o stream
  private func getShardsForStreaming() async throws -> [ShardActor] {
    try ensureOpen()
    var actors: [ShardActor] = []
    for shardID in shardURLs.keys {
      actors.append(try shard(for: shardID))
    }
    return actors
  }

  func isIndexed(field: String) -> Bool {
    indexes[field] != nil
  }

  func indexSearch(field: String, key: FieldValue) -> [RecordPointer] {
    indexes[field]?.search(key) ?? []
  }

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

  func fetch(pointers: [RecordPointer]) async throws -> [Data] {
    try ensureOpen()
    var out: [Data] = []
    out.reserveCapacity(pointers.count)
    for pointer in pointers {
      let shard = try existingShard(pointer.shardID)
      if let data = try await shard.read(at: pointer.offset) {
        out.append(data)
      }
    }
    return out
  }

  // MARK: - Maintenance

  /// Rewrites every shard without tombstones/padding waste, then rebuilds
  /// indexes. This is the manual replacement for the old engine's
  /// 60-second background auto-merge task (removed by design: background
  /// timers in a mobile embedded DB burn battery and raced with writes).
  func compact() async throws {
    try ensureOpen()
    let fm = FileManager.default

    let allShardIDs = Array(shardURLs.keys)

    for shardID in allShardIDs {
      let shard = try shard(for: shardID)
      let records = try await shard.scanAll()
      try await shard.close()

      let finalURL = shardsDirectory.appendingPathComponent("\(shardID).nyaru")
      let tempURL = shardsDirectory.appendingPathComponent("\(shardID).nyaru.compact")
      try? fm.removeItem(at: tempURL)

      let fresh = try ShardActor(
        id: shardID, url: tempURL,
        compression: manifest.compression,
        fileProtection: manifest.fileProtection,
        encryptionKey: encryptionKey
      )
      for record in records {
        _ = try await fresh.insert(data: record.data)
      }
      try await fresh.close()
      _ = try fm.replaceItemAt(finalURL, withItemAt: tempURL)

      // Reopen on the final path
      shards[shardID] = try ShardActor(
        id: shardID, url: finalURL,
        compression: manifest.compression,
        fileProtection: manifest.fileProtection,
        encryptionKey: encryptionKey
      )
    }
    try await rebuildAllIndexes()
    try await sync()
  }

  func stats() async -> CollectionStats {
    var size: UInt64 = 0
    // Calculate size directly from disk to avoid forcing shard opens (Lazy Load)
    for (_, url) in shardURLs {
      if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
        let fileSize = attrs[.size] as? UInt64
      {
        size += fileSize
      }
    }
    var indexCounts: [String: Int] = [:]
    for (field, index) in indexes {
      indexCounts[field] = index.entryCount
    }
    return CollectionStats(
      name: manifest.name,
      documentCount: count(),
      shardCount: shardURLs.count,
      sizeInBytes: size,
      indexes: indexCounts
    )
  }

  /// Deletes the whole collection directory. The core must not be used
  /// afterwards.
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

  func checkNeedsCompaction() async -> Bool {
    // Iterate over open shards. If any need compaction, return true.
    // Shards not yet opened (Lazy) don't have tombstoneCount yet, but if they aren't open,
    // they aren't being actively updated.
    for shard in shards.values {
      if await shard.needsCompaction {
        return true
      }
    }
    return false
  }
}
