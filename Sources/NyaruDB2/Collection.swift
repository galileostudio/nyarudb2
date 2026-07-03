import Foundation

/// Configuration for opening a collection.
public struct CollectionOptions: Sendable {
  /// JSON field (dot paths allowed) that uniquely identifies a document.
  /// An index on this field is always maintained; `get`/`update`/`delete`
  /// are O(log n) point operations through it.
  public var idField: String
  /// Optional JSON field used to route documents into shard files.
  public var partitionKey: String?
  /// Additional fields to index for queries.
  public var indexedFields: [String]

  public init(
    idField: String = "id",
    partitionKey: String? = nil,
    indexedFields: [String] = []
  ) {
    self.idField = idField
    self.partitionKey = partitionKey
    self.indexedFields = indexedFields
  }
}

/// A typed handle to one collection.
///
/// This is a thin facade: it encodes/decodes `T` and delegates everything
/// else to the collection's engine actor. Handles are cheap value types —
/// copy them freely, hold them anywhere.
public struct NyaruCollection<T: Codable & Sendable>: Sendable {
  public let name: String
  let core: CollectionCore
  private let partitionKey: String?
  private let format: SerializationFormat

  init(name: String, core: CollectionCore, partitionKey: String?, format: SerializationFormat) {
    self.name = name
    self.core = core
    self.partitionKey = partitionKey
    self.format = format
  }

  private func encode(_ document: T) throws -> Data {
    do {
      return try Serializer.encode(document, format: format)
    } catch {
      throw NyaruError.encodingFailed(String(describing: error))
    }
  }

  private func decode(_ data: Data) throws -> T {
    do {
      return try Serializer.decode(T.self, from: data, format: format)
    } catch {
      throw NyaruError.decodingFailed(String(describing: error))
    }
  }

  // MARK: - Writes

  /// Inserts a new document. Throws `NyaruError.duplicateID` if a document
  /// with the same id already exists (use `upsert` to overwrite).

  public func insert(_ document: T) async throws {
    try await core.insert(data: encode(document))
  }

  /// Inserts a batch. Validates every id (including duplicates inside the
  /// batch) before writing anything.

  public func insert(contentsOf documents: [T]) async throws {
    try await core.insertMany(datas: documents.map(encode))
  }

  /// Replaces the document with the same id. Throws
  /// `NyaruError.documentNotFound` if it does not exist.

  public func update(_ document: T) async throws {
    try await core.update(data: encode(document), upsert: false)
  }

  /// Replaces the document with the same id, inserting it if absent.

  public func upsert(_ document: T) async throws {
    try await core.update(data: encode(document), upsert: true)
  }

  /// Deletes by id. Returns true if a document was removed.

  @discardableResult
  public func delete(id: FieldValueConvertible) async throws -> Bool {
    try await core.delete(id: id.fieldValue)
  }

  // MARK: - Partial Update

  /// Partially updates a document without needing to decode the full struct.
  /// Example: `users.patch(id: 1, changes: ["isActive": false, "age": 31])`
  public func patch(id: FieldValueConvertible, changes: [String: FieldValue]) async throws {
    let format = self.format
    // The validator runs inside the core, BEFORE anything is written. If the
    // merged document no longer decodes as T, the patch is rejected and the
    // stored document is untouched — no poisoned records.
    _ = try await core.patch(id: id.fieldValue, changes: changes) { data in
      do {
        _ = try Serializer.decode(T.self, from: data, format: format)
      } catch {
        throw NyaruError.decodingFailed(
          "Patch rejected: result no longer decodes as \(T.self): \(error)")
      }
    }
  }

  // MARK: - Reads

  /// Point lookup by id through the primary index.

  public func get(id: FieldValueConvertible) async throws -> T? {
    guard let data = try await core.get(id: id.fieldValue) else { return nil }
    return try decode(data)
  }

  public func count() async -> Int {
    await core.count()
  }

  /// All documents, decoded. For large collections prefer `stream()`.
  public func all() async throws -> [T] {
    try await core.scanAll().map(decode)
  }

  /// Streams all documents without materializing the full array of `T`.
  public func stream(batchSize: Int = 64) -> NyaruDocumentStream<T> {
    NyaruDocumentStream(core: core, format: format, batchSize: batchSize)
  }

  /// Starts a fluent query.

  public func find() -> QueryBuilder<T> {
    QueryBuilder(core: core, partitionKey: partitionKey, format: format)
  }

  // MARK: - Maintenance

  /// Rewrites shard files without tombstones and rebuilds indexes.
  /// Call opportunistically (e.g. on app background) — there is no
  /// background timer doing this behind your back.
  public func compact() async throws {
    try await core.compact()
  }

  public func stats() async -> CollectionStats {
    await core.stats()
  }

  public func needsCompaction() async -> Bool {
    return await core.checkNeedsCompaction()
  }
}

// MARK: - Pull-based document stream

/// AsyncSequence whose iterator drives the reads: each `next()` serves from
/// an in-memory batch and only touches the collection actor when the batch
/// runs out. Memory is bounded by one batch; a suspended consumer suspends
/// the producer for free, because there is no producer task at all.
public struct NyaruDocumentStream<T: Codable & Sendable>: AsyncSequence, Sendable {
  public typealias Element = T
  let core: CollectionCore
  let format: SerializationFormat
  let batchSize: Int

  public func makeAsyncIterator() -> Iterator {
    Iterator(core: core, format: format, batchSize: Swift.max(1, batchSize))
  }

  public struct Iterator: AsyncIteratorProtocol {
    let core: CollectionCore
    let format: SerializationFormat
    let batchSize: Int
    private var shardIDs: [String]?
    private var shardIndex = 0
    private var cursor: UInt64?
    private var buffer: [Data] = []
    private var bufferIndex = 0

    init(core: CollectionCore, format: SerializationFormat, batchSize: Int) {
      self.core = core
      self.format = format
      self.batchSize = batchSize
    }

    public mutating func next() async throws -> T? {
      while true {
        if bufferIndex < buffer.count {
          let data = buffer[bufferIndex]
          bufferIndex += 1
          do {
            return try Serializer.decode(T.self, from: data, format: format)
          } catch {
            throw NyaruError.decodingFailed(String(describing: error))
          }
        }
        try Task.checkCancellation()
        if shardIDs == nil {
          shardIDs = await core.shardIDList()
        }
        guard let ids = shardIDs, shardIndex < ids.count else { return nil }
        let (items, nextPos) = try await core.readBatch(
          shardID: ids[shardIndex], from: cursor, maxCount: batchSize)
        buffer = items
        bufferIndex = 0
        if let nextPos {
          cursor = nextPos
        } else {
          shardIndex += 1
          cursor = nil
        }
        // Loop: either serve from the fresh buffer or advance to next shard.
      }
    }
  }
}
