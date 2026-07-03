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
  var maxFragmentation: Double

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
  public let fragmentationRatio: Double
}

/// The type-erased engine behind one collection.
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
    /// Checks if any shard is dirty without fully opening them
    var anyShardDirty = false
    for (_, url) in shardURLs {
      if SlottedFile.peekDirty(url: url) {
        anyShardDirty = true
        break
      }
    }

    // 2. Rehydrate indexes. If indexes need rebuilding, open shards on demand.
    let indexSnapshotsLoaded = try loadIndexSnapshots()
    if anyShardDirty || !indexSnapshotsLoaded {
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

  /// Persist index snapshots, then clear shard dirty flags — in that
  /// order. If we crash in between, shards remain dirty and the next open
  /// rebuilds the indexes, so a stale snapshot can never be trusted.
  func sync() async throws {
    try ensureOpen()

    for (field, index) in indexes {
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

    if let key = encryptionKey {
      let hmac = HMAC<SHA256>.authenticationCode(for: Data(rawID.utf8), using: key)
      return Data(hmac).map { String(format: "%02x", $0) }.joined()
    } else {
      return Self.sanitizeFileComponent(rawID)
    }
  }

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

  private func existingShard(_ id: String) throws -> ShardActor {
    if let existing = shards[id] { return existing }
    if shardURLs[id] != nil {
      return try shard(for: id)
    }
    throw NyaruError.corruptedRecord(offset: 0, reason: "pointer references unknown shard '\(id)'")
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
      guard var index = indexes[entry.field] else { continue }
      index.insert(key: entry.key, pointer: pointer)
      indexes[entry.field] = index
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
      let newShard = try shard(for: newShardID)
      newPointer = try await newShard.insert(data: data)
      try await oldShard.delete(at: oldPointer.offset)
    }

    for field in allIndexedFields {
      guard var index = indexes[field] else { continue }
      let oldKey = FieldExtractor.value(in: oldDict, path: field)
      let newKey = FieldExtractor.value(in: dict, path: field)
      if let oldKey { index.remove(key: oldKey, pointer: oldPointer) }
      if let newKey { index.insert(key: newKey, pointer: newPointer) }
      indexes[field] = index
    }
  }

  // MARK: - Partial Update (Patch)

  /// Partially updates a document by merging `changes` into the existing document.
  /// - Parameters:
  ///   - id: The document's primary key.
  ///   - changes: A dictionary of field names to new values.
  /// - Returns: The re-serialized document data.
  /// - Throws: `NyaruError.documentNotFound` if the document doesn't exist.
  ///           `NyaruError.unsupportedOperation` if nested paths are attempted or if the ID field is being changed.
  func patch(id: FieldValue, changes: [String: FieldValue]) async throws -> Data {
    try ensureOpen()

    // Early return: no changes to apply
    guard !changes.isEmpty else {
      guard let pointer = indexes[manifest.idField]?.search(id).first else {
        throw NyaruError.documentNotFound(id: id.description)
      }
      let shard = try existingShard(pointer.shardID)
      guard let oldData = try await shard.read(at: pointer.offset) else {
        removeFromAllIndexes(pointer: pointer)
        throw NyaruError.documentNotFound(id: id.description)
      }
      return oldData
    }

    // Validate that we are not trying to change the ID field
    if changes.keys.contains(manifest.idField) {
      throw NyaruError.unsupportedOperation("Changing the document ID is not allowed via patch.")
    }

    // Reject nested paths to avoid ambiguity
    for key in changes.keys where key.contains(".") {
      throw NyaruError.unsupportedOperation(
        "Nested paths (e.g., 'address.city') are not supported in patch. Update the full document instead."
      )
    }

    guard let pointer = indexes[manifest.idField]?.search(id).first else {
      throw NyaruError.documentNotFound(id: id.description)
    }

    let oldShard = try existingShard(pointer.shardID)
    guard let oldData = try await oldShard.read(at: pointer.offset) else {
      removeFromAllIndexes(pointer: pointer)
      throw NyaruError.documentNotFound(id: id.description)
    }

    // 1. Deserialize the current document into a mutable dictionary
    let oldDict = try FieldExtractor.parse(oldData, using: format)
    var newDict = oldDict

    // 2. Apply changes (merge)
    for (key, value) in changes {
      newDict[key] = value.anyValue
    }

    // 3. Re-serialize to the database format using AnyEncodable
    let newData = try Serializer.encode(AnyEncodable(value: newDict), format: format)

    // 4. Determine the new shard (partition may have changed)
    let newShardID = try shardID(forDocument: newDict)
    let newPointer: RecordPointer

    if newShardID == oldShard.id {
      newPointer = try await oldShard.update(at: pointer.offset, data: newData)
    } else {
      let newShard = try shard(for: newShardID)
      newPointer = try await newShard.insert(data: newData)
      try await oldShard.delete(at: pointer.offset)
    }

    // 5. Reconcile all indexes (remove old keys, add new keys)
    for field in allIndexedFields {
      guard var index = indexes[field] else { continue }
      let oldKey = FieldExtractor.value(in: oldDict, path: field)
      let newKey = FieldExtractor.value(in: newDict, path: field)
      if let oldKey { index.remove(key: oldKey, pointer: pointer) }
      if let newKey { index.insert(key: newKey, pointer: newPointer) }
      indexes[field] = index
    }

    return newData
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
      guard var index = indexes[field] else { continue }
      if let key = FieldExtractor.value(in: oldDict, path: field) {
        index.remove(key: key, pointer: pointer)
      }
      indexes[field] = index
    }
    return true
  }

  private func removeFromAllIndexes(pointer: RecordPointer) {
    for field in allIndexedFields {
      guard var index = indexes[field] else { continue }
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
    let data = try JSONEncoder().encode(manifest)
    try data.write(to: manifestURL, options: .atomic)
  }

  // MARK: - Reads for queries / scans

  /// Full scan of all shards (parallel across shards).
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

    guard let shard = try? shard(for: id) else { return [] }
    var out: [Data] = []
    try await shard.forEachLive { _, data in
      out.append(data)
    }
    return out
  }

  /// REAL STREAMING: Iterates over shards without loading everything into RAM.
  nonisolated func scanLazy() -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      Task {
        do {
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
    let allShardIDs = Array(shardURLs.keys)

    // Concurrency limit to avoid exhausting CPU/FileHandles on the device
    let maxConcurrent = 3
    var iterator = allShardIDs.makeIterator()

    try await withThrowingTaskGroup(of: Void.self) { group in
      // 1. Starts the initial tasks (up to the limit of 3)
      for _ in 0..<min(maxConcurrent, allShardIDs.count) {
        if let shardID = iterator.next() {
          group.addTask {
            let shard = try await self.shard(for: shardID)
            try await shard.compact()
          }
        }
      }

      // 2. As one task finishes, adds the next one from the queue
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

  func stats() async -> CollectionStats {
    var size: UInt64 = 0
    var totalDeadBytes: UInt64 = 0

    // Calculates total on-disk size directly from FileManager (includes shards not opened via Lazy Load)
    for (_, url) in shardURLs {
      if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
        let fileSize = attrs[.size] as? UInt64
      {
        size += fileSize
      }
    }

    // Sums garbage (deadBytes) only from shards that are open in memory.
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
    for shard in shards.values {
      if await shard.needsCompaction {
        return true
      }
    }
    return false
  }
}
