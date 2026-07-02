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

    // Open every existing shard. SlottedFile performs crash recovery
    // internally when it finds the dirty flag set.
    var anyShardRecovered = false
    let files =
      (try? fm.contentsOfDirectory(at: shardsDirectory, includingPropertiesForKeys: nil)) ?? []
    for url in files where url.pathExtension == "nyaru" {
      let shardID = url.deletingPathExtension().lastPathComponent
      let shard = try ShardActor(
        id: shardID, url: url,
        compression: manifest.compression,
        fileProtection: manifest.fileProtection,
        encryptionKey: encryptionKey
      )
      if await shard.recoveredFromDirty { anyShardRecovered = true }
      shards[shardID] = shard
    }

    // Rehydrate indexes. If any shard needed crash recovery, the
    // persisted snapshots may be stale — rebuild everything from data.
    // (The old engine simply never reloaded indexes on reopen, so every
    // restart silently lost all indexes.)
    let indexSnapshotsLoaded = try loadIndexSnapshots()
    if anyShardRecovered || !indexSnapshotsLoaded {
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
        loaded[field] = try OrderedIndex.load(from: url)
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
    for (shardID, shard) in shards {
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
      try index.persist(to: snapshotURL(for: field))
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
    return Self.sanitizeFileComponent(value.description)
  }

  private func shard(for id: String) throws -> ShardActor {
    if let existing = shards[id] { return existing }
    let url = shardsDirectory.appendingPathComponent("\(id).nyaru")
    let shard = try ShardActor(
      id: id, url: url,
      compression: manifest.compression,
      fileProtection: manifest.fileProtection,
      encryptionKey: encryptionKey
    )
    shards[id] = shard
    return shard
  }

  private func existingShard(_ id: String) throws -> ShardActor {
    guard let shard = shards[id] else {
      throw NyaruError.corruptedRecord(
        offset: 0, reason: "pointer references unknown shard '\(id)'")
    }
    return shard
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
      for (shardID, shard) in shards {
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
    // O manifesto de config pode continuar sendo JSON, é um arquivo minúsculo.
    let data = try JSONEncoder().encode(manifest)
    try data.write(to: manifestURL, options: .atomic)
  }

  // MARK: - Reads for queries / scans

  /// Full scan of all shards (parallel across shards).
  func scanAll() async throws -> [Data] {
    try ensureOpen()
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
    let id = Self.sanitizeFileComponent(value.description)
    guard let shard = shards[id] else { return [] }
    return try await shard.scanAll().map(\.data)
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
    var rebuilt: [String: ShardActor] = [:]
    for (shardID, shard) in shards {
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

      // Reopen on the final path.
      rebuilt[shardID] = try ShardActor(
        id: shardID, url: finalURL,
        compression: manifest.compression,
        fileProtection: manifest.fileProtection,
        encryptionKey: encryptionKey
      )
    }
    shards = rebuilt
    try await rebuildAllIndexes()
    try await sync()
  }

  func stats() async -> CollectionStats {
    var size: UInt64 = 0
    for shard in shards.values {
      size += await shard.sizeInBytes()
    }
    var indexCounts: [String: Int] = [:]
    for (field, index) in indexes {
      indexCounts[field] = index.entryCount
    }
    return CollectionStats(
      name: manifest.name,
      documentCount: count(),
      shardCount: shards.count,
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
    indexes = [:]
    isClosed = true
    try FileManager.default.removeItem(at: directory)
  }

  func checkNeedsCompaction() async -> Bool {
    for shard in shards.values {
      if await shard.needsCompaction {
        return true
      }
    }
    return false
  }
}
