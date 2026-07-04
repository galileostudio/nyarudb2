import Foundation

/// Configuration options for opening or creating a collection.
///
/// `CollectionOptions` lets you specify the document id field, an optional
/// partition key for shard routing, and additional fields to index for
/// query performance.
///
/// - Note: The `idField` and `partitionKey` are frozen at collection creation.
///   Changing them after data exists would make existing records unreadable.
///   `indexedFields` can be extended across opens.
public struct CollectionOptions: Sendable {
  /// The JSON field (dot paths allowed) that uniquely identifies a document.
  ///
  /// An index on this field is always maintained — `get`, `update`, `delete`,
  /// and `patch` are O(log n) point operations through it.
  ///
  /// Changing this after creation is not supported.
  ///
  /// Default: `"id"`.
  public var idField: String

  /// An optional JSON field used to route documents into shard files.
  ///
  /// When set, documents with the same partition key value are stored in the
  /// same physical shard file. This enables partition-scoped scans that only
  /// touch one shard instead of all shards. The partition key also affects the
  /// query planner: an equality predicate on the partition key triggers a
  /// partition scan instead of a full scan.
  ///
  /// Default: `nil` (all documents go into the `"default"` shard).
  public var partitionKey: String?

  /// Additional fields to index for query performance.
  ///
  /// Each field in this list gets an `OrderedIndex` that supports point
  /// lookups, range queries, `IN` queries, and sorting. The id field is
  /// always indexed automatically and does not need to be listed here.
  ///
  /// Fields can be added across opens — new indexes are populated by
  /// scanning all shards. Removing a field drops its index.
  ///
  /// Default: `[]`.
  public var indexedFields: [String]

  /// Creates collection options for opening or creating a collection.
  ///
  /// - Parameters:
  ///   - idField: Document id field name (default `"id"`).
  ///   - partitionKey: Optional partition key field for sharding.
  ///   - indexedFields: Additional indexed fields for queries.
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

/// A write buffer that accumulates document insertions for a batch commit.
///
/// Obtain one via `NyaruCollection.withTransaction(_:)`. All insertions are
/// synchronous — no `await` needed. Documents are not written to disk until
/// the `withTransaction` body completes without throwing.
public final class NyaruTransaction<T: Codable & Sendable>: @unchecked Sendable {
  fileprivate var buffer: [T] = []
  fileprivate init() {}

  /// Adds a single document to the transaction buffer.
  public func insert(_ document: T) { buffer.append(document) }

  /// Adds a collection of documents to the transaction buffer.
  public func insert(contentsOf documents: some Collection<T>) {
    buffer.append(contentsOf: documents)
  }
}

/// A typed, Sendable handle to one collection within a NyaruDB database.
///
/// `NyaruCollection` is a thin facade that encodes and decodes the generic
/// document type `T` and delegates all storage operations to a shared
/// `CollectionCore` actor. Handles are cheap value types — copy them freely.
///
/// **Writing documents.** Use `insert`, `update`, `upsert`, `patch`, and
/// `delete`:
///
/// ```swift
/// try await collection.insert(user)
/// try await collection.patch(id: userId, changes: ["name": "New Name"])
/// ```
///
/// **Reading documents.** Use `get(id:)` for point lookups, `all()` for
/// everything, `stream()` for bounded-memory iteration, and `find()` for
/// fluent queries with predicates, sorting, and pagination.
///
/// **Maintenance.** Call `compact()` opportunistically (e.g. on app
/// backgrounding) to reclaim space from tombstoned records.
public struct NyaruCollection<T: Codable & Sendable>: Sendable {
  /// The collection name as passed to `NyaruDB.collection(_:of:options:)`.
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

  /// Encodes a document to the storage format.
  ///
  /// - Parameter document: The document to encode.
  /// - Returns: Encoded data.
  /// - Throws: `NyaruError.encodingFailed` if encoding fails.
  private func encode(_ document: T) throws -> Data {
    do {
      return try Serializer.encode(document, format: format)
    } catch {
      throw NyaruError.encodingFailed(String(describing: error))
    }
  }

  /// Decodes a document from stored data.
  ///
  /// - Parameter data: The encoded data.
  /// - Returns: The decoded document.
  /// - Throws: `NyaruError.decodingFailed` if decoding fails.
  private func decode(_ data: Data) throws -> T {
    do {
      return try Serializer.decode(T.self, from: data, format: format)
    } catch {
      throw NyaruError.decodingFailed(String(describing: error))
    }
  }

  // MARK: - Writes

  /// Inserts a new document into the collection.
  ///
  /// The document must contain the configured `idField`. If another document
  /// with the same id already exists, a `duplicateID` error is thrown.
  ///
  /// - Parameter document: The document to insert.
  /// - Throws: `NyaruError.duplicateID` if the id already exists,
  ///   `NyaruError.encodingFailed` if encoding fails.
  public func insert(_ document: T) async throws {
    try await core.insert(data: encode(document))
  }

  /// Inserts a batch of documents atomically.
  ///
  /// All ids are validated before anything is written — if any id already
  /// exists in the collection or is duplicated within the batch, **no**
  /// documents are inserted and `duplicateID` is thrown.
  ///
  /// - Parameter documents: An array of documents to insert.
  /// - Throws: `NyaruError.duplicateID` if any id conflicts.
  public func insert(contentsOf documents: [T]) async throws {
    try await core.insertMany(datas: documents.map(encode))
  }

  /// Accumulates insert operations in memory and flushes them as a single
  /// batch when the body completes, producing one index merge pass instead of
  /// one per call.
  ///
  /// Insertions inside the body are synchronous — no `await` required:
  /// ```swift
  /// try await collection.withTransaction { tx in
  ///   for chunk in incomingChunks { tx.insert(contentsOf: chunk) }
  /// }
  /// ```
  /// If the body throws, nothing is written to disk. Other write operations
  /// (update, delete, patch) are not buffered — call them after committing.
  ///
  /// - Parameter body: Closure receiving a `NyaruTransaction` that accumulates
  ///   documents via its synchronous `insert` methods.
  /// - Throws: Rethrows from `body` or from the final batch write.
  public func withTransaction(
    _ body: (NyaruTransaction<T>) async throws -> Void
  ) async throws {
    let tx = NyaruTransaction<T>()
    try await body(tx)
    guard !tx.buffer.isEmpty else { return }
    try await insert(contentsOf: tx.buffer)
  }

  /// Replaces the document with the same id.
  ///
  /// The full document is replaced (not merged). If no document with the given
  /// id exists, `documentNotFound` is thrown. To insert-or-replace, use
  /// `upsert` instead.
  ///
  /// - Parameter document: The updated document.
  /// - Throws: `NyaruError.documentNotFound` if the id does not exist.
  public func update(_ document: T) async throws {
    try await core.update(data: encode(document), upsert: false)
  }

  /// Replaces the document with the same id, or inserts it if absent.
  ///
  /// Unlike `update`, this never throws `documentNotFound` — if no document
  /// exists for the id, the document is inserted.
  ///
  /// - Parameter document: The document to upsert.
  public func upsert(_ document: T) async throws {
    try await core.update(data: encode(document), upsert: true)
  }

  /// Deletes a document by its id.
  ///
  /// The record is tombstoned in the shard file (space is reclaimed during
  /// compaction). The index entries are also removed.
  ///
  /// - Parameter id: The document id (any `FieldValueConvertible` type).
  /// - Returns: `true` if a document was removed, `false` if no document
  ///   with that id existed.
  @discardableResult
  public func delete(id: FieldValueConvertible) async throws -> Bool {
    try await core.delete(id: id.fieldValue)
  }

  // MARK: - Partial Update

  /// Partially updates a document by applying top-level field changes without
  /// decoding the full document type.
  ///
  /// This is useful when you want to change a few fields without fetching,
  /// decoding, modifying, re-encoding, and re-inserting the entire document.
  /// The merged document is validated against the type `T` before anything
  /// is written to disk.
  ///
  /// **Restrictions:**
  /// - Only top-level fields can be patched (nested paths like `"address.city"`
  ///   are rejected).
  /// - The document id field cannot be changed through patch.
  /// - The merged result must still decode as `T`, otherwise the patch is
  ///   rejected and no data is written.
  ///
  /// - Parameters:
  ///   - id: The document id.
  ///   - changes: A dictionary of field names to new `FieldValue`s.
  /// - Throws: `NyaruError.documentNotFound` if the id does not exist,
  ///   `NyaruError.decodingFailed` if the merged document no longer decodes
  ///   as `T`, `NyaruError.unsupportedOperation` for nested paths or id changes.
  public func patch(id: FieldValueConvertible, changes: [String: FieldValue]) async throws {
    let format = self.format
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

  /// Performs a point lookup by document id through the primary index.
  ///
  /// - Parameter id: The document id.
  /// - Returns: The decoded document, or `nil` if no document with that id
  ///   exists.
  public func get(id: FieldValueConvertible) async throws -> T? {
    guard let data = try await core.get(id: id.fieldValue) else { return nil }
    return try decode(data)
  }

  /// Returns the total number of live documents in the collection.
  ///
  /// - Returns: The live document count (excludes tombstoned records).
  public func count() async -> Int {
    await core.count()
  }

  /// Returns every document in the collection.
  ///
  /// For large collections this materialises the entire dataset in memory.
  /// Consider using `stream()` for bounded-memory iteration.
  ///
  /// - Returns: An array of all decoded documents.
  /// - Throws: `NyaruError.decodingFailed` if any document fails to decode.
  public func all() async throws -> [T] {
    try await core.scanAll().map(decode)
  }

  /// Returns a pull-based async sequence over all documents.
  ///
  /// Each `next()` call serves from an in-memory batch and only touches the
  /// collection actor when the batch is exhausted. Memory is bounded by one
  /// batch (`batchSize` elements), making this suitable for iterating large
  /// collections without materialising everything at once.
  ///
  /// - Parameter batchSize: Maximum documents fetched per storage read
  ///   (default 64).
  /// - Returns: A `NyaruDocumentStream<T>` (conforms to `AsyncSequence`).
  public func stream(batchSize: Int = 64) -> NyaruDocumentStream<T> {
    NyaruDocumentStream(core: core, format: format, batchSize: batchSize)
  }

  /// Returns a fluent query builder for this collection.
  ///
  /// ```swift
  /// let results = try await collection.find()
  ///     .where("age", isGreaterThan: 18)
  ///     .sort(by: "name")
  ///     .limit(10)
  ///     .execute()
  /// ```
  ///
  /// - Returns: An immutable `QueryBuilder<T>`.
  public func find() -> QueryBuilder<T> {
    QueryBuilder(core: core, partitionKey: partitionKey, format: format)
  }

  // MARK: - Maintenance

  /// Rewrites every shard file to remove tombstoned records and rebuilds all
  /// indexes.
  ///
  /// Call this opportunistically, such as when the app transitions to the
  /// background or after a significant number of deletions. There is no
  /// automatic background timer — compaction is always explicit.
  ///
  /// - Throws: I/O errors from shard or index operations.
  public func compact() async throws {
    try await core.compact()
  }

  /// Returns a snapshot of collection statistics.
  ///
  /// The returned `CollectionStats` includes the document count, shard count,
  /// total on-disk size, index entry counts, and the fragmentation ratio.
  ///
  /// - Returns: Current collection statistics.
  public func stats() async -> CollectionStats {
    await core.stats()
  }

  /// Returns whether any shard in the collection exceeds the configured
  /// fragmentation threshold (`maxFragmentation`).
  ///
  /// - Returns: `true` if compaction is recommended.
  public func needsCompaction() async -> Bool {
    return await core.checkNeedsCompaction()
  }
}

// MARK: - Pull-based document stream

/// A pull-based `AsyncSequence` that yields documents one by one without
/// materialising the entire collection in memory.
///
/// The iterator fetches documents in bounded batches from the storage engine.
/// Each batch is decoded lazily as the consumer calls `next()`. When the
/// batch is exhausted, the next batch is fetched from the collection actor.
///
/// Memory usage is bounded by one batch (`batchSize` documents).
///
/// - Note: This replaces the earlier `AsyncThrowingStream`-based approach
///   whose unbounded buffer allowed a fast producer to materialise the whole
///   collection behind a slow consumer, defeating the purpose of streaming.
public struct NyaruDocumentStream<T: Codable & Sendable>: AsyncSequence, Sendable {
  public typealias Element = T
  let core: CollectionCore
  let format: SerializationFormat
  let batchSize: Int

  /// Creates the iterator for this stream.
  ///
  /// - Returns: An `Iterator` ready to yield documents.
  public func makeAsyncIterator() -> Iterator {
    Iterator(core: core, format: format, batchSize: Swift.max(1, batchSize))
  }

  /// The pull-based iterator that fetches documents in bounded batches.
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

    /// Advances to the next document and returns it.
    ///
    /// When the current batch is exhausted, the next batch is fetched from
    /// the storage engine. When all shards are exhausted, returns `nil`.
    ///
    /// - Returns: The next decoded document, or `nil` at the end of the
    ///   collection.
    /// - Throws: `NyaruError.decodingFailed` if a stored document cannot
    ///   be decoded as `T`.
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
      }
    }
  }
}
