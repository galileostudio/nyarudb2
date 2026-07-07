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

/// A resolved index lookup produced by the query planner: the single
/// operation to run against one indexed field.
///
/// The query engine hands the core a probe instead of resolved
/// `RecordPointer`s so that pointer resolution and the reads that
/// dereference them happen inside one compaction-gated actor call.
enum IndexProbe: Sendable {
  case equal(FieldValue)
  case inSet([FieldValue])
  case range(
    lower: FieldValue?, lowerInclusive: Bool,
    upper: FieldValue?, upperInclusive: Bool)
}

/// One operation inside a `writeBatch`, with the document payload and
/// metadata already encoded by the typed facade.
enum BatchOperation: Sendable {
  case insert(data: Data, metadata: Serializer.DocumentMetadata)
  case update(data: Data, metadata: Serializer.DocumentMetadata)
  case upsert(data: Data, metadata: Serializer.DocumentMetadata)
  case delete(id: FieldValue)
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
  private let autoSync: DatabaseOptions.AutoSyncPolicy
  private var shards: [String: ShardActor] = [:]
  private var shardURLs: [String: URL] = [:]
  private var indexes: [String: OrderedIndex] = [:]
  private var isClosed = false

  // MARK: - Durability bookkeeping
  //
  // `totalWrites` is monotonic (never reset); auto-sync compares it against
  // `writesAtLastSync`, and sync() uses it as a generation stamp to detect
  // writes racing the off-actor snapshot persistence.
  private var totalWrites: UInt64 = 0
  private var writesAtLastSync: UInt64 = 0
  private var lastSyncDate = Date()
  private var autoSyncScheduled = false

  // MARK: - Compaction exclusion
  //
  // Compaction rewrites shard files (invalidating every stored offset) and
  // then remaps index pointers. The actor suspends at each `await` inside
  // `compact()`, so without a gate a concurrent pointer-based operation can
  // interleave in that window: a `get` would read a stale offset against the
  // rewritten file and evict a healthy index entry, and an `insert` would add
  // entries with new-file offsets that the remap would then drop as stale.
  // Pointer-based operations therefore wait while compaction is in flight,
  // and compaction drains in-flight operations before touching any file.
  // MARK: - Metrics counters (see CollectionMetrics)
  private var metricIndexLookups = 0
  private var metricCoveredQueries = 0
  private var metricFullScans = 0
  private var metricPartitionScans = 0
  private var metricCompactionCount = 0
  private var metricLastCompactionDuration: TimeInterval?

  private var isCompacting = false
  private var activePointerOps = 0
  private var compactionWaiters: [CheckedContinuation<Void, Never>] = []
  private var drainWaiter: CheckedContinuation<Void, Never>?

  /// Blocks new pointer-based operations while compaction runs, then marks
  /// one operation as in flight. Must be paired with `endPointerOp()`.
  private func beginPointerOp() async {
    while isCompacting {
      await withCheckedContinuation { compactionWaiters.append($0) }
    }
    activePointerOps += 1
  }

  /// Marks a pointer-based operation as finished, waking a draining
  /// compaction when the last one completes.
  private func endPointerOp() {
    activePointerOps -= 1
    if activePointerOps == 0, let waiter = drainWaiter {
      drainWaiter = nil
      waiter.resume()
    }
  }

  /// Closes the gate exclusively: waits for any other exclusive holder,
  /// then drains in-flight pointer operations. Pair with `openGate()`.
  private func closeGate() async {
    while isCompacting {
      await withCheckedContinuation { compactionWaiters.append($0) }
    }
    isCompacting = true
    while activePointerOps > 0 {
      await withCheckedContinuation { drainWaiter = $0 }
    }
  }

  /// Reopens the gate and wakes every operation that queued behind it.
  private func openGate() {
    isCompacting = false
    let waiters = compactionWaiters
    compactionWaiters = []
    for waiter in waiters { waiter.resume() }
  }

  /// The configured document id field name.
  var idField: String { manifest.idField }

  /// The full list of indexed fields (including the id field). Used by the
  /// query engine to pre-extract index keys for batched deletes.
  var indexedFieldList: [String] { allIndexedFields }

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
    encryptionKey: SymmetricKey?, autoSync: DatabaseOptions.AutoSyncPolicy = .off
  ) async throws {
    self.directory = directory
    self.manifest = manifest
    self.format = format
    self.encryptionKey = encryptionKey
    self.autoSync = autoSync
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
    indexes = try await buildIndexes(for: allIndexedFields)
  }

  /// Scans every shard once and builds fresh indexes for the given fields.
  ///
  /// Shards are scanned in a bounded window (`maxConcurrentShardScans`) —
  /// each task materialises its whole shard, so unbounded fan-out would peak
  /// at the sum of all shard sizes. Records are parsed across all cores
  /// within each shard, and every shard task returns its entries already
  /// grouped by field, so the final merge is a per-field array concatenation
  /// instead of a serial regrouping pass over all entries.
  private func buildIndexes(for fields: [String]) async throws -> [String: OrderedIndex] {
    if fields.isEmpty { return [:] }
    // All shards are already open (opened in init or by prior ops); snapshot
    // them into a plain array so the task closures can capture them without
    // actor hops.
    for shardID in shardURLs.keys { _ = try shard(for: shardID) }
    let allShards = Array(shards)
    let capturedFormat = format
    let capturedFields = fields

    typealias Entries = [(key: FieldValue, pointer: RecordPointer)]

    @Sendable func scanShard(_ shardID: String, _ shard: ShardActor) async throws
      -> [String: Entries]
    {
      let records = try await shard.readAllLive()
      typealias Entry = (field: String, key: FieldValue, pointer: RecordPointer)
      let perRecord = Parallel.map(records) { record -> [Entry] in
        let values = Serializer.extractFieldValues(
          from: record.data, fields: capturedFields, format: capturedFormat)
        let pointer = RecordPointer(shardID: shardID, offset: record.offset)
        var entries: [Entry] = []
        for field in capturedFields {
          if let key = values[field] {
            entries.append((field: field, key: key, pointer: pointer))
          }
        }
        return entries
      }
      var grouped: [String: Entries] = [:]
      grouped.reserveCapacity(capturedFields.count)
      for entries in perRecord {
        for entry in entries {
          grouped[entry.field, default: []].append((key: entry.key, pointer: entry.pointer))
        }
      }
      return grouped
    }

    var iterator = allShards.makeIterator()
    let byField: [String: Entries] = try await withThrowingTaskGroup(
      of: [String: Entries].self
    ) { group in
      for _ in 0..<min(Self.maxConcurrentShardScans, allShards.count) {
        if let (shardID, shard) = iterator.next() {
          group.addTask { try await scanShard(shardID, shard) }
        }
      }

      var merged: [String: Entries] = [:]
      for field in capturedFields { merged[field] = [] }
      while let chunk = try await group.next() {
        for (field, entries) in chunk {
          merged[field, default: []].append(contentsOf: entries)
        }
        if let (shardID, shard) = iterator.next() {
          group.addTask { try await scanShard(shardID, shard) }
        }
      }
      return merged
    }

    let built = Parallel.map(Array(byField), serialThreshold: 2) {
      field, entries -> (String, OrderedIndex) in
      let idx = OrderedIndex()
      idx.bulkLoad(entries)
      return (field, idx)
    }
    return Dictionary(uniqueKeysWithValues: built)
  }

  /// Persists all index snapshots and flushes all shard headers to disk.
  ///
  /// The expensive part — encode + gzip + seal of every index — runs OFF
  /// the actor over O(1) copy-on-write snapshots, so reads and writes keep
  /// flowing while it happens (concurrent mutations pay the CoW copy).
  ///
  /// **Snapshot/flag ordering.** An index snapshot is only trusted at open
  /// when the shards are clean, so the snapshots on disk must never be
  /// OLDER than the state the clean flags vouch for. The gate closes only
  /// for the final fsync barrier; if writes landed while the snapshots were
  /// being encoded, the capture is redone (bounded — the last attempt
  /// re-persists while holding the gate, trading a short write stall for
  /// correctness under sustained write pressure).
  func sync() async throws {
    try ensureOpen()
    var attempts = 0
    while true {
      let generation = totalWrites
      try await persistIndexSnapshots()
      attempts += 1

      await closeGate()
      defer { openGate() }

      if totalWrites == generation || attempts >= 3 {
        if totalWrites != generation {
          try await persistIndexSnapshots()
        }
        for shard in shards.values {
          try await shard.sync()
        }
        writesAtLastSync = totalWrites
        lastSyncDate = Date()
        return
      }
      // Writes raced the off-actor persist: loop and re-capture.
    }
  }

  /// Sync body without gate manipulation — the caller must already hold the
  /// gate exclusively (`compact()` does).
  private func syncHoldingGate() async throws {
    try await persistIndexSnapshots()
    for shard in shards.values {
      try await shard.sync()
    }
    writesAtLastSync = totalWrites
    lastSyncDate = Date()
  }

  /// Captures CoW snapshots of every index on the actor (O(1)), then
  /// encodes, compresses, seals, and atomically writes them off the actor,
  /// in parallel across indexes.
  private func persistIndexSnapshots() async throws {
    let work = indexes.map { (snapshot: $0.value.snapshot(), url: snapshotURL(for: $0.key)) }
    guard !work.isEmpty else { return }
    let key = encryptionKey
    try await Task.detached(priority: .utility) {
      _ = try Parallel.map(work, serialThreshold: 2) { item in
        try OrderedIndex.persist(item.snapshot, to: item.url, encryptionKey: key)
      }
    }.value
  }

  /// Registers `count` written documents and schedules an auto-sync when
  /// the policy says one is due. The sync runs as a follow-up task — never
  /// inside the write that triggered it, which still holds a pointer op —
  /// and is best-effort: its failure must not fail an already-applied write.
  private func noteWrites(_ count: Int) {
    totalWrites += UInt64(count)
    let due: Bool
    switch autoSync {
    case .off:
      due = false
    case .afterWrites(let threshold):
      due = totalWrites - writesAtLastSync >= UInt64(max(1, threshold))
    case .interval(let seconds):
      due = totalWrites > writesAtLastSync && Date().timeIntervalSince(lastSyncDate) >= seconds
    }
    guard due, !autoSyncScheduled else { return }
    autoSyncScheduled = true
    Task { await self.runScheduledAutoSync() }
  }

  private func runScheduledAutoSync() async {
    autoSyncScheduled = false
    try? await sync()
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
  private static let _hexChars: [UInt8] = Array("0123456789abcdef".utf8)

  static func hmacHex(_ hmacBytes: some ContiguousBytes) -> String {
    hmacBytes.withUnsafeBytes { ptr in
      var out = [UInt8](repeating: 0, count: ptr.count * 2)
      for (i, byte) in ptr.enumerated() {
        out[i * 2] = Self._hexChars[Int(byte >> 4)]
        out[i * 2 + 1] = Self._hexChars[Int(byte & 0x0F)]
      }
      return String(bytes: out, encoding: .ascii)!
    }
  }

  private static let _allowedASCII: [Bool] = {
    var table = [Bool](repeating: false, count: 128)
    for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-" {
      table[Int(c.asciiValue!)] = true
    }
    return table
  }()

  /// Pre-computed hex percent-encoding strings for bytes 0x00–0xFF.
  /// Avoids `String(format: "%%%02X", byte)` allocation per byte.
  private static let _percentHex: [String] = {
    let hex = Array("0123456789ABCDEF".utf8)
    return (0...255).map { i in
      let hi = hex[Int(i >> 4)]
      let lo = hex[Int(i & 0x0F)]
      return "%\(Unicode.Scalar(hi))\(Unicode.Scalar(lo))"
    }
  }()

  /// Appends the UTF-8 percent-encoding of a single Unicode scalar without
  /// allocating an intermediate String.
  @inline(__always)
  private static func _appendPercentEncoded(_ scalar: Unicode.Scalar, to out: inout String) {
    let val = scalar.value
    if val < 0x80 {
      out += Self._percentHex[Int(val)]
    } else if val < 0x800 {
      out += Self._percentHex[Int(0xC0 | (val >> 6))]
      out += Self._percentHex[Int(0x80 | (val & 0x3F))]
    } else if val < 0x10000 {
      out += Self._percentHex[Int(0xE0 | (val >> 12))]
      out += Self._percentHex[Int(0x80 | ((val >> 6) & 0x3F))]
      out += Self._percentHex[Int(0x80 | (val & 0x3F))]
    } else {
      out += Self._percentHex[Int(0xF0 | (val >> 18))]
      out += Self._percentHex[Int(0x80 | ((val >> 12) & 0x3F))]
      out += Self._percentHex[Int(0x80 | ((val >> 6) & 0x3F))]
      out += Self._percentHex[Int(0x80 | (val & 0x3F))]
    }
  }

  static func sanitizeFileComponent(_ raw: String) -> String {
    var out = ""
    for scalar in raw.unicodeScalars {
      let val = Int(scalar.value)
      if val < 128 && Self._allowedASCII[val] {
        out.unicodeScalars.append(scalar)
      } else {
        Self._appendPercentEncoded(scalar, to: &out)
      }
    }
    return out.isEmpty ? "_" : out
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

  /// Inserts a document using pre-extracted metadata, skipping the parse.
  func insert(data: Data, metadata: Serializer.DocumentMetadata) async throws {
    try ensureOpen()
    await beginPointerOp()
    defer { endPointerOp() }
    if indexes[manifest.idField]?.contains(metadata.id) == true {
      throw NyaruError.duplicateID(metadata.id.description)
    }
    try await performInsert(data: data, metadata: metadata)
    noteWrites(1)
  }

  /// Performs a bulk insert of multiple documents with optimized index loading.
  ///
  /// Bulk insert with pre-extracted metadata, skipping per-document parse.
  func insertMany(batch: [(Data, Serializer.DocumentMetadata)]) async throws {
    if batch.isEmpty { return }
    try ensureOpen()
    await beginPointerOp()
    defer { endPointerOp() }
    var seen = Set<FieldValue>()
    var groupedByShard: [String: [(data: Data, metadata: Serializer.DocumentMetadata)]] = [:]

    for (data, metadata) in batch {
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

    // One merge pass per index, in parallel — the indexes are independent
    // objects and each is touched by exactly one thread.
    let loads = indexUpdates.compactMap { field, entries in
      indexes[field].map { (index: $0, entries: entries) }
    }
    _ = Parallel.map(loads, serialThreshold: 2) { $0.index.bulkLoad($0.entries) }
    noteWrites(batch.count)
  }

  private func shardID(forPartitionValue value: FieldValue?) throws -> String {
    guard let partitionKey = manifest.partitionKey else { return "default" }
    guard let value = value else {
      throw NyaruError.partitionKeyMissing(field: partitionKey)
    }
    return physicalShardID(for: value)
  }

  /// Maps a partition value to its physical shard identifier. When encryption
  /// is enabled the value is HMAC-hashed so partition values never leak into
  /// filenames; otherwise it is sanitised for filesystem use.
  private func physicalShardID(for value: FieldValue) -> String {
    let rawID = value.description
    if let key = encryptionKey {
      let hmac = HMAC<SHA256>.authenticationCode(for: Data(rawID.utf8), using: key)
      return Self.hmacHex(hmac)
    }
    return Self.sanitizeFileComponent(rawID)
  }

  /// Performs the actual insert: routes to a shard, writes, and updates indexes.
  private func performInsert(data: Data, metadata: Serializer.DocumentMetadata) async throws {
    let shardID = try shardID(forPartitionValue: metadata.partitionValue)
    let shard = try shard(for: shardID)
    let pointer = try await shard.insert(data: data)
    for entry in metadata.indexEntries {
      indexes[entry.field]?.insert(key: entry.key, pointer: pointer)
    }
  }

  /// Point lookup by document id through the primary index.
  ///
  /// No identity re-verification is performed: the compaction gate guarantees
  /// pointer-based operations never interleave with offset rewrites, all
  /// index mutations are actor-serialised with their writes, and dirty opens
  /// rebuild indexes from disk — so a pointer always references the record it
  /// was created for. Payload corruption is still caught by the record CRC.
  func get(id: FieldValue) async throws -> Data? {
    try ensureOpen()
    await beginPointerOp()
    defer { endPointerOp() }
    guard let pointer = indexes[manifest.idField]?.search(id).first else { return nil }
    let shard = try existingShard(pointer.shardID)
    return try await shard.read(at: pointer.offset)
  }

  /// Point update with pre-extracted new-document metadata, skipping one parse.
  func update(data: Data, metadata: Serializer.DocumentMetadata, upsert: Bool) async throws {
    try ensureOpen()
    await beginPointerOp()
    defer { endPointerOp() }
    let id = metadata.id

    guard let oldPointer = indexes[manifest.idField]?.search(id).first else {
      if upsert {
        let shardID = try shardID(forPartitionValue: metadata.partitionValue)
        let shard = try shard(for: shardID)
        let pointer = try await shard.insert(data: data)
        for entry in metadata.indexEntries {
          indexes[entry.field]?.insert(key: entry.key, pointer: pointer)
        }
        noteWrites(1)
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
      noteWrites(1)
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

    let oldKeyByField = Dictionary(
      uniqueKeysWithValues: oldMetadata.indexEntries.map { ($0.field, $0.key) })
    let newKeyByField = Dictionary(
      uniqueKeysWithValues: metadata.indexEntries.map { ($0.field, $0.key) })

    for field in allIndexedFields {
      guard let index = indexes[field] else { continue }
      let oldKey = oldKeyByField[field]
      let newKey = newKeyByField[field]

      if oldKey == newKey, let key = oldKey {
        index.replace(key: key, old: oldPointer, new: newPointer)
      } else {
        if let oldKey { index.remove(key: oldKey, pointer: oldPointer) }
        if let newKey { index.insert(key: newKey, pointer: newPointer) }
      }
    }
    noteWrites(1)
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
    await beginPointerOp()
    defer { endPointerOp() }
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

    let newPartitionValue = manifest.partitionKey.flatMap {
      FieldExtractor.value(in: newDict, path: $0)
    }
    let newShardID = try shardID(forPartitionValue: newPartitionValue)
    let newPointer: RecordPointer
    if newShardID == oldShard.id {
      newPointer = try await oldShard.update(at: pointer.offset, data: newData)
    } else {
      let newShard = try shard(for: newShardID)
      newPointer = try await newShard.insert(data: newData)
      try await oldShard.delete(at: pointer.offset)
    }

    for field in allIndexedFields {
      guard let index = indexes[field] else { continue }
      let oldKey = FieldExtractor.value(in: oldDict, path: field)
      let newKey = FieldExtractor.value(in: newDict, path: field)

      if oldKey == newKey, let key = oldKey {
        index.replace(key: key, old: pointer, new: newPointer)
      } else {
        if let oldKey { index.remove(key: oldKey, pointer: pointer) }
        if let newKey { index.insert(key: newKey, pointer: newPointer) }
      }
    }
    noteWrites(1)
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
    await beginPointerOp()
    defer { endPointerOp() }
    guard let pointer = indexes[manifest.idField]?.search(id).first else { return false }
    let shard = try existingShard(pointer.shardID)
    guard let oldData = try await shard.read(at: pointer.offset) else {
      removeFromAllIndexes(pointer: pointer)
      return false
    }
    try await shard.delete(at: pointer.offset)

    if let oldDict = try? FieldExtractor.parse(oldData, using: format) {
      for field in allIndexedFields {
        if let key = FieldExtractor.value(in: oldDict, path: field) {
          indexes[field]?.remove(key: key, pointer: pointer)
        }
      }
    }
    noteWrites(1)
    return true
  }

  /// Deletes documents whose index keys were already extracted by the caller
  /// (the query engine parsed each document to match it, so the keys are
  /// free). Skips re-reading payloads entirely: one tombstone-only actor hop
  /// per shard and one bulk removal per index.
  ///
  /// - Parameter prepared: `(id, keysByField)` pairs; `keysByField` must map
  ///   every indexed field present in the document to its key.
  /// - Returns: The number of documents actually deleted.
  func deleteMany(prepared: [(id: FieldValue, keys: [String: FieldValue])]) async throws -> Int {
    if prepared.isEmpty { return 0 }
    try ensureOpen()
    await beginPointerOp()
    defer { endPointerOp() }
    guard let primary = indexes[manifest.idField] else { return 0 }

    var byShard: [String: [(entryIndex: Int, pointer: RecordPointer)]] = [:]
    for (i, entry) in prepared.enumerated() {
      guard let pointer = primary.search(entry.id).first else { continue }
      byShard[pointer.shardID, default: []].append((entryIndex: i, pointer: pointer))
    }

    var removed = 0
    var removalsByField: [String: [(key: FieldValue, pointer: RecordPointer)]] = [:]

    for (shardID, items) in byShard {
      let shard = try existingShard(shardID)
      let results = try await shard.tombstoneMany(offsets: items.map(\.pointer.offset))
      for (j, wasLive) in results.enumerated() {
        let item = items[j]
        if wasLive {
          removed += 1
          for (field, key) in prepared[item.entryIndex].keys {
            removalsByField[field, default: []].append((key, item.pointer))
          }
        } else {
          removeFromAllIndexes(pointer: item.pointer)
        }
      }
    }

    applyBulkRemovals(removalsByField)
    noteWrites(removed)
    return removed
  }

  /// Applies grouped index removals, one bulk sweep per index, in parallel —
  /// each `OrderedIndex` is an independent object touched by exactly one
  /// thread.
  private func applyBulkRemovals(
    _ removalsByField: [String: [(key: FieldValue, pointer: RecordPointer)]]
  ) {
    let work = removalsByField.compactMap { field, removals in
      indexes[field].map { (index: $0, removals: removals) }
    }
    _ = Parallel.map(work, serialThreshold: 2) { $0.index.bulkRemove($0.removals) }
  }

  /// Deletes multiple documents by id: one actor hop per shard for the
  /// tombstones (with parallel payload restore), one parse per document, and
  /// one bulk removal per index — instead of a full read/parse/remove cycle
  /// per document.
  ///
  /// - Parameter ids: The document ids to delete. Unknown ids are skipped.
  /// - Returns: The number of documents actually deleted.
  func deleteMany(ids: [FieldValue]) async throws -> Int {
    if ids.isEmpty { return 0 }
    try ensureOpen()
    await beginPointerOp()
    defer { endPointerOp() }
    guard let primary = indexes[manifest.idField] else { return 0 }

    var pointersByShard: [String: [RecordPointer]] = [:]
    for id in ids {
      guard let pointer = primary.search(id).first else { continue }
      pointersByShard[pointer.shardID, default: []].append(pointer)
    }

    let capturedFormat = format
    let fields = allIndexedFields
    var removed = 0
    var removalsByField: [String: [(key: FieldValue, pointer: RecordPointer)]] = [:]

    for (shardID, pointers) in pointersByShard {
      let shard = try existingShard(shardID)
      let oldDatas = try await shard.deleteMany(offsets: pointers.map(\.offset))

      typealias Removal = (field: String, key: FieldValue, pointer: RecordPointer)
      let perDoc = Parallel.map(Array(zip(pointers, oldDatas))) { pair -> [Removal] in
        guard let data = pair.1 else { return [] }
        let values = Serializer.extractFieldValues(
          from: data, fields: fields, format: capturedFormat)
        var out: [Removal] = []
        for field in fields {
          if let key = values[field] {
            out.append((field: field, key: key, pointer: pair.0))
          }
        }
        return out
      }

      for (i, data) in oldDatas.enumerated() {
        if data != nil {
          removed += 1
        } else {
          // The record was already dead — purge the stale pointer everywhere.
          removeFromAllIndexes(pointer: pointers[i])
        }
      }
      for removals in perDoc {
        for removal in removals {
          removalsByField[removal.field, default: []].append((removal.key, removal.pointer))
        }
      }
    }

    applyBulkRemovals(removalsByField)
    noteWrites(removed)
    return removed
  }

  // MARK: - Atomic write batches

  /// Applies a mixed batch of operations with error-atomicity.
  ///
  /// **Guarantee.** Every operation is validated before anything is written:
  /// duplicate ids, missing update targets, and conflicting in-batch
  /// operations throw with NO side effects. After validation, new document
  /// versions are appended first — never overwriting in place and never
  /// reusing free slots, so a failed append is rolled back by tombstoning
  /// what was written. Old versions are tombstoned next, and indexes are
  /// updated in memory last.
  ///
  /// **Limits.** An I/O failure during the tombstone phase triggers a
  /// best-effort per-operation resolution: operations whose old version was
  /// already superseded are committed (their new version is indexed —
  /// rolling it back would lose the document), everything else is rolled
  /// back by tombstoning its append. Nothing is ever left on disk outside
  /// the indexes, so a later rebuild cannot resurrect ghosts. Full
  /// crash-atomicity would require a write-ahead log, which NyaruDB
  /// deliberately does not have. The batch is also not isolated from
  /// concurrent writes to the same ids from other tasks, just as individual
  /// operations are not isolated from each other.
  ///
  /// At most one operation may target a given document id per batch.
  func applyBatch(_ operations: [BatchOperation]) async throws {
    if operations.isEmpty { return }
    try ensureOpen()
    await beginPointerOp()
    defer { endPointerOp() }

    let primary = indexes[manifest.idField]
    let fields = allIndexedFields
    let capturedFormat = format

    // ---- Phase 1: validate everything and resolve targets. Reads only —
    // any throw here leaves the collection untouched.
    struct PlannedAppend {
      let data: Data
      let metadata: Serializer.DocumentMetadata
      let shardID: String
      /// Index into `removals` of the old version this append supersedes
      /// (updates/upserts), or `nil` for plain inserts. Links the two so a
      /// phase-3 failure can decide per append whether to roll back or
      /// partially commit.
      let removalIndex: Int?
    }
    var appends: [PlannedAppend] = []
    // Live old versions to tombstone, with index keys extracted from the
    // payload read here so the index sweep needs no second read.
    var removals: [(pointer: RecordPointer, keys: [String: FieldValue])] = []
    // Pointers whose record was already dead — purged from every index.
    var stalePointers: [RecordPointer] = []

    var seenIDs = Set<FieldValue>()
    var insertIDs = Set<FieldValue>()

    func requireSingleOp(_ id: FieldValue, isInsert: Bool) throws {
      guard seenIDs.insert(id).inserted else {
        if isInsert && insertIDs.contains(id) {
          throw NyaruError.duplicateID(id.description)
        }
        throw NyaruError.unsupportedOperation(
          "Multiple operations on the same document id in one writeBatch "
            + "(id: \(id.description)). Combine them into a single upsert/delete.")
      }
      if isInsert { insertIDs.insert(id) }
    }

    // Resolves the current version of a document. Returns the index of the
    // removal added to `removals` when the record is live, or `nil` when it
    // does not exist (dead index entries go to `stalePointers`).
    func resolveExisting(_ id: FieldValue) async throws -> Int? {
      guard let pointer = primary?.search(id).first else { return nil }
      let shard = try existingShard(pointer.shardID)
      if let oldData = try await shard.read(at: pointer.offset) {
        let keys = Serializer.extractFieldValues(
          from: oldData, fields: fields, format: capturedFormat)
        removals.append((pointer: pointer, keys: keys))
        return removals.count - 1
      } else {
        stalePointers.append(pointer)
        return nil
      }
    }

    for operation in operations {
      switch operation {
      case .insert(let data, let metadata):
        try requireSingleOp(metadata.id, isInsert: true)
        if primary?.contains(metadata.id) == true {
          throw NyaruError.duplicateID(metadata.id.description)
        }
        appends.append(
          .init(
            data: data, metadata: metadata,
            shardID: try shardID(forPartitionValue: metadata.partitionValue),
            removalIndex: nil))

      case .update(let data, let metadata):
        try requireSingleOp(metadata.id, isInsert: false)
        guard primary?.contains(metadata.id) == true else {
          throw NyaruError.documentNotFound(id: metadata.id.description)
        }
        let removalIndex = try await resolveExisting(metadata.id)
        appends.append(
          .init(
            data: data, metadata: metadata,
            shardID: try shardID(forPartitionValue: metadata.partitionValue),
            removalIndex: removalIndex))

      case .upsert(let data, let metadata):
        try requireSingleOp(metadata.id, isInsert: false)
        let removalIndex = try await resolveExisting(metadata.id)
        appends.append(
          .init(
            data: data, metadata: metadata,
            shardID: try shardID(forPartitionValue: metadata.partitionValue),
            removalIndex: removalIndex))

      case .delete(let id):
        try requireSingleOp(id, isInsert: false)
        // Unknown ids are skipped, matching deleteMany.
        _ = try await resolveExisting(id)
      }
    }

    // ---- Phase 2: append all new versions, one batched write per shard.
    // insertMany routes through appendBatch, which never reuses free slots,
    // so old versions stay intact until phase 3 and a rollback only has to
    // tombstone what this batch wrote.
    var newPointers = [RecordPointer?](repeating: nil, count: appends.count)
    var appendedSoFar: [(shard: ShardActor, offsets: [UInt64])] = []
    do {
      var byShard: [String: [Int]] = [:]
      for (i, append) in appends.enumerated() {
        byShard[append.shardID, default: []].append(i)
      }
      for (shardID, indices) in byShard {
        let shard = try shard(for: shardID)
        let pointers = try await shard.insertMany(datas: indices.map { appends[$0].data })
        for (j, i) in indices.enumerated() { newPointers[i] = pointers[j] }
        appendedSoFar.append((shard: shard, offsets: pointers.map(\.offset)))
      }
    } catch {
      for (shard, offsets) in appendedSoFar {
        _ = try? await shard.tombstoneMany(offsets: offsets)
      }
      throw error
    }

    // ---- Phase 3: tombstone the old versions (updates, upserts, deletes).
    // `nil` = outcome unknown (the shard's tombstoneMany failed or never ran).
    var tombstonesByShard: [String: [Int]] = [:]
    for (i, removal) in removals.enumerated() {
      tombstonesByShard[removal.pointer.shardID, default: []].append(i)
    }
    var removedLive = [Bool?](repeating: nil, count: removals.count)
    do {
      for (shardID, indices) in tombstonesByShard {
        let shard = try existingShard(shardID)
        let results = try await shard.tombstoneMany(
          offsets: indices.map { removals[$0].pointer.offset })
        for (j, wasLive) in results.enumerated() { removedLive[indices[j]] = wasLive }
      }
    } catch {
      // Best-effort rollback so the failure leaves nothing invisible: an
      // append left on disk unindexed resurfaces as a ghost (or duplicate)
      // on the next dirty rebuild. Per operation:
      // - old version already tombstoned → the new version is the only
      //   copy; rolling it back would LOSE the document. Keep it and make
      //   it visible (partial commit of that operation).
      // - old version still live, or a plain insert → tombstone the append;
      //   the pre-batch state stays authoritative.
      // Probes and tombstones are best-effort (`try?`) — a tombstone
      // failure usually means the disk is dying, and the goal is to not
      // leave things worse than the original error.
      for (i, removal) in removals.enumerated() where removedLive[i] == nil {
        let stillLive =
          (try? await existingShard(removal.pointer.shardID).read(at: removal.pointer.offset))
          .flatMap { $0 } != nil
        // A failed probe counts as tombstoned: preferring the new version
        // risks a duplicate after rebuild, but assuming "live" would
        // tombstone the only surviving copy.
        removedLive[i] = !stillLive
      }

      var commitAdds: [String: [(key: FieldValue, pointer: RecordPointer)]] = [:]
      var commitRemovals: [String: [(key: FieldValue, pointer: RecordPointer)]] = [:]
      for (i, append) in appends.enumerated() {
        guard let pointer = newPointers[i] else { continue }
        let oldIsGone = append.removalIndex.map { removedLive[$0] == true } ?? false
        if oldIsGone, let removalIndex = append.removalIndex {
          let removal = removals[removalIndex]
          for (field, key) in removal.keys {
            commitRemovals[field, default: []].append((key, removal.pointer))
          }
          for entry in append.metadata.indexEntries {
            commitAdds[entry.field, default: []].append((entry.key, pointer))
          }
        } else {
          _ = try? await existingShard(pointer.shardID).delete(at: pointer.offset)
        }
      }
      // Deletes whose tombstone landed also commit their index removal.
      let supersededRemovals = Set(appends.compactMap(\.removalIndex))
      for (i, removal) in removals.enumerated()
      where removedLive[i] == true && !supersededRemovals.contains(i) {
        for (field, key) in removal.keys {
          commitRemovals[field, default: []].append((key, removal.pointer))
        }
      }
      applyBulkRemovals(commitRemovals)
      let commits = commitAdds.compactMap { field, entries in
        indexes[field].map { (index: $0, entries: entries) }
      }
      _ = Parallel.map(commits, serialThreshold: 2) { $0.index.bulkLoad($0.entries) }
      throw error
    }

    // ---- Phase 4: index updates — pure in-memory, cannot fail.
    var removalsByField: [String: [(key: FieldValue, pointer: RecordPointer)]] = [:]
    for (i, removal) in removals.enumerated() {
      if removedLive[i] == true {
        for (field, key) in removal.keys {
          removalsByField[field, default: []].append((key, removal.pointer))
        }
      } else {
        stalePointers.append(removal.pointer)
      }
    }
    applyBulkRemovals(removalsByField)
    for pointer in stalePointers { removeFromAllIndexes(pointer: pointer) }

    var indexUpdates: [String: [(key: FieldValue, pointer: RecordPointer)]] = [:]
    for (i, append) in appends.enumerated() {
      guard let pointer = newPointers[i] else { continue }
      for entry in append.metadata.indexEntries {
        indexUpdates[entry.field, default: []].append((entry.key, pointer))
      }
    }
    let loads = indexUpdates.compactMap { field, entries in
      indexes[field].map { (index: $0, entries: entries) }
    }
    _ = Parallel.map(loads, serialThreshold: 2) { $0.index.bulkLoad($0.entries) }
    noteWrites(operations.count)
  }

  /// Removes a pointer from every index. Used when a record disappears
  /// (corrupt, stale pointer, or phantom).
  private func removeFromAllIndexes(pointer: RecordPointer) {
    for index in indexes.values {
      index.removeAll(pointer: pointer)
    }
  }

  /// Returns the total number of live documents (from the primary index).
  func count() throws -> Int {
    try ensureOpen()
    return indexes[manifest.idField]?.entryCount ?? 0
  }

  // MARK: - Index evolution

  /// Adds or removes indexed fields, rebuilding indexes for new fields by
  /// scanning all shards.
  ///
  /// - Parameter fields: The new set of indexed fields.
  /// - Throws: I/O errors from manifest writes.
  func setIndexedFields(_ fields: [String]) async throws {
    try ensureOpen()
    // Rebuilding reads live offsets from shards and installs them in fresh
    // indexes — a pointer-based operation like any other. Without the gate,
    // a rebuild racing a compact() indexes offsets that the subsequent
    // remap silently drops as "did not survive compaction".
    await beginPointerOp()
    defer { endPointerOp() }
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
      let built = try await buildIndexes(for: Array(missing))
      for (field, idx) in built { indexes[field] = idx }
    }

    manifest.indexedFields = sorted
    try ManifestIO.write(manifest, to: manifestURL, encryptionKey: encryptionKey)
  }

  // MARK: - Reads for queries / scans

  /// Performs a full scan of all shards, returning every live document's
  /// encoded data.
  ///
  /// At most `maxConcurrentShardScans` shards are read at a time: each task
  /// materialises its whole shard, so an unbounded fan-out would peak at the
  /// sum of all shard sizes in memory instead of a small window.
  func scanAll() async throws -> [Data] {
    try ensureOpen()
    metricFullScans += 1
    for shardID in shardURLs.keys {
      _ = try shard(for: shardID)
    }

    let allShards = Array(shards.values)
    var iterator = allShards.makeIterator()
    return try await withThrowingTaskGroup(of: [Data].self) { group in
      for _ in 0..<min(Self.maxConcurrentShardScans, allShards.count) {
        if let shard = iterator.next() {
          group.addTask { try await shard.readAllLive().map(\.data) }
        }
      }
      var out: [Data] = []
      while let chunk = try await group.next() {
        out.append(contentsOf: chunk)
        if let shard = iterator.next() {
          group.addTask { try await shard.readAllLive().map(\.data) }
        }
      }
      return out
    }
  }

  /// The window size for concurrent whole-shard operations (scans, index
  /// builds, compaction) — enough to overlap I/O with parsing without
  /// letting memory grow with the shard count.
  static let maxConcurrentShardScans = 3

  /// Scans a single partition shard identified by the partition key value.
  ///
  /// - Parameter value: The partition key value.
  /// - Returns: All live document data from the matching shard.
  func scanPartition(value: FieldValue) async throws -> [Data] {
    try ensureOpen()
    metricPartitionScans += 1
    guard let shard = try? shard(for: physicalShardID(for: value)) else { return [] }
    return try await shard.readAllLive().map(\.data)
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

  /// Single actor hop for bulk index-existence checks in the query planner.
  func indexedFieldSet(of fields: Set<String>) -> Set<String> {
    Set(fields.filter { indexes[$0] != nil })
  }

  /// Resolves an index probe to record pointers.
  ///
  /// - Parameter maxCount: For range probes, stop after collecting this many
  ///   pointers (in ascending key order). Ignored by point/set probes.
  private func resolvePointers(field: String, probe: IndexProbe, maxCount: Int?)
    -> [RecordPointer]
  {
    guard let index = indexes[field] else { return [] }
    switch probe {
    case .equal(let key):
      return index.search(key)
    case .inSet(let keys):
      // search() returns the posting array by reference (CoW), so gathering
      // the lists first costs nothing and sizes the output exactly.
      let lists = keys.map { index.search($0) }
      var out: [RecordPointer] = []
      out.reserveCapacity(lists.reduce(0) { $0 + $1.count })
      for list in lists { out.append(contentsOf: list) }
      return out
    case .range(let lower, let lowerInclusive, let upper, let upperInclusive):
      return index.range(
        lower: lower, lowerInclusive: lowerInclusive,
        upper: upper, upperInclusive: upperInclusive,
        maxCount: maxCount)
    }
  }

  /// Resolves an index probe and reads the matching documents inside one
  /// gated section.
  ///
  /// Resolving pointers and dereferencing them MUST be atomic with respect
  /// to compaction: a pointer held across an `await` goes stale when a
  /// `compact()` rewrites the shard files in between, and the read then
  /// lands on a tombstone or a different record. Callers therefore never
  /// hold raw `RecordPointer`s — they describe the lookup and receive data.
  ///
  /// - Parameters:
  ///   - field: The indexed field to probe.
  ///   - probe: The lookup operation the planner selected.
  ///   - slice: Optional pagination pushdown `(offset, limit)`. Pass it only
  ///     when the query is fully covered by the index — residual predicates
  ///     need every match.
  func fetch(field: String, probe: IndexProbe, slice: (offset: Int, limit: Int?)?)
    async throws -> [Data]
  {
    try ensureOpen()
    metricIndexLookups += 1
    if slice != nil { metricCoveredQueries += 1 }
    await beginPointerOp()
    defer { endPointerOp() }

    // Range scans can stop as soon as offset+limit pointers are collected —
    // no need to materialise every match just to slice the head.
    let needed = slice.flatMap { s in s.limit.map { s.offset + $0 } }
    var pointers = resolvePointers(field: field, probe: probe, maxCount: needed)
    if let slice {
      let start = min(slice.offset, pointers.count)
      let end = min(start + (slice.limit ?? (pointers.count - start)), pointers.count)
      pointers = Array(pointers[start..<end])
    }
    return try await readPointers(pointers)
  }

  /// Counts the matches of a fully covered query from the index alone —
  /// zero disk I/O. No gate is needed: nothing dereferences the pointers.
  func coveredCount(field: String, probe: IndexProbe, slice: (offset: Int, limit: Int?)) -> Int {
    metricIndexLookups += 1
    metricCoveredQueries += 1
    let needed = slice.limit.map { slice.offset + $0 }
    let pointers = resolvePointers(field: field, probe: probe, maxCount: needed)
    let start = min(slice.offset, pointers.count)
    let end = min(start + (slice.limit ?? (pointers.count - start)), pointers.count)
    return end - start
  }

  /// Reads the payloads for already-resolved pointers. The caller must hold
  /// the compaction gate.
  ///
  /// Multi-shard reads run in parallel — each `ShardActor` is independent,
  /// so latency is the slowest shard's read rather than the sum of all of
  /// them. Output order is not defined (it never was: shards were visited
  /// in dictionary order); queries that need an order sort in memory.
  private func readPointers(_ pointers: [RecordPointer]) async throws -> [Data] {
    if pointers.isEmpty { return [] }

    var grouped: [String: [UInt64]] = [:]
    for pointer in pointers {
      grouped[pointer.shardID, default: []].append(pointer.offset)
    }

    // Offsets are sorted to turn random disk seeks into sequential reads;
    // one actor hop per shard reads all of its records.
    if grouped.count == 1, let (shardID, offsets) = grouped.first {
      let shard = try existingShard(shardID)
      return try await shard.readBatch(offsets: offsets.sorted())
    }

    // Resolve the actors before the task group — existingShard is
    // actor-isolated and cannot be called from inside the child tasks.
    var work: [(shard: ShardActor, offsets: [UInt64])] = []
    work.reserveCapacity(grouped.count)
    for (shardID, offsets) in grouped {
      work.append((shard: try existingShard(shardID), offsets: offsets.sorted()))
    }

    return try await withThrowingTaskGroup(of: [Data].self) { group in
      for item in work {
        group.addTask { try await item.shard.readBatch(offsets: item.offsets) }
      }
      var out: [Data] = []
      out.reserveCapacity(pointers.count)
      for try await batch in group { out.append(contentsOf: batch) }
      return out
    }
  }

  // MARK: - Maintenance

  /// Rewrites every shard without tombstones (or padding waste), then remaps
  /// index pointers using the offset maps returned by each shard.
  ///
  /// This is the manual replacement for the old engine's 60-second background
  /// auto-merge task, which was removed by design: background timers in a
  /// mobile embedded database burn battery and raced with concurrent writes.
  ///
  /// Shards are compacted concurrently (up to 3 at a time) to minimise
  /// latency on multi-shard collections. Because each shard reports its
  /// old-offset → new-offset map, indexes are updated by rewriting pointers
  /// in place — no document is re-read or re-parsed.
  func compact() async throws {
    try ensureOpen()
    let compactionStart = Date()
    defer {
      metricCompactionCount += 1
      metricLastCompactionDuration = Date().timeIntervalSince(compactionStart)
    }

    // Close the gate: new pointer-based operations suspend until compaction
    // finishes, and compaction waits for in-flight ones to drain so no stale
    // offset is ever read against a rewritten file.
    await closeGate()
    defer { openGate() }

    let allShardIDs = Array(shardURLs.keys)

    let maxConcurrent = Self.maxConcurrentShardScans
    var iterator = allShardIDs.makeIterator()

    var mappings: [String: [UInt64: UInt64]] = [:]
    try await withThrowingTaskGroup(of: (String, [UInt64: UInt64]).self) { group in
      for _ in 0..<min(maxConcurrent, allShardIDs.count) {
        if let shardID = iterator.next() {
          group.addTask {
            let shard = try await self.shard(for: shardID)
            return (shardID, try await shard.compact())
          }
        }
      }

      while let (shardID, mapping) = try await group.next() {
        mappings[shardID] = mapping
        if let nextID = iterator.next() {
          group.addTask {
            let shard = try await self.shard(for: nextID)
            return (nextID, try await shard.compact())
          }
        }
      }
    }

    let allIndexes = Array(indexes.values)
    _ = Parallel.map(allIndexes, serialThreshold: 2) { $0.compactRemap(mappings) }
    // The public sync() closes the gate itself — this one already holds it.
    try await syncHoldingGate()
  }

  /// Whether any shard's tombstone ratio exceeds the configured
  /// `maxFragmentation` threshold, indicating that `compact()` would
  /// reclaim meaningful space.
  func needsCompaction() async throws -> Bool {
    try ensureOpen()
    for shardID in shardURLs.keys {
      guard let shard = try? shard(for: shardID) else { continue }
      if await shard.needsCompaction { return true }
    }
    return false
  }

  /// Returns a snapshot of the collection's internal counters.
  ///
  /// I/O counters cover the shards opened so far (shards open lazily on
  /// first touch).
  func metrics() async throws -> CollectionMetrics {
    try ensureOpen()
    var bytesRead: UInt64 = 0
    var bytesWritten: UInt64 = 0
    var recovered = 0
    for shard in shards.values {
      let io = await shard.ioBytes
      bytesRead += io.read
      bytesWritten += io.written
      if shard.recoveredFromDirtyAtOpen { recovered += 1 }
    }
    return CollectionMetrics(
      indexLookups: metricIndexLookups,
      coveredQueries: metricCoveredQueries,
      fullScans: metricFullScans,
      partitionScans: metricPartitionScans,
      bytesRead: bytesRead,
      bytesWritten: bytesWritten,
      compactionCount: metricCompactionCount,
      lastCompactionDuration: metricLastCompactionDuration,
      shardsRecoveredFromDirty: recovered
    )
  }

  /// Returns a snapshot of collection statistics.
  func stats() async throws -> CollectionStats {
    try ensureOpen()
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
      documentCount: indexes[manifest.idField]?.entryCount ?? 0,
      shardCount: shardURLs.count,
      sizeInBytes: size,
      indexes: indexCounts,
      fragmentationRatio: fragRatio
    )
  }

  #if DEBUG
    /// Test-only access to a shard actor, for fault injection.
    func shardForTesting(_ id: String) -> ShardActor? { shards[id] }
  #endif

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
}
