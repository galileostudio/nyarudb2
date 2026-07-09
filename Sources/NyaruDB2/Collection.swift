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

/// A write buffer that accumulates mixed operations — insert, update,
/// upsert, delete — for a single all-or-nothing flush.
///
/// Obtain one via `NyaruCollection.writeBatch(_:)`. All calls are
/// synchronous — no `await` needed. Nothing touches the collection until the
/// `writeBatch` body completes without throwing.
///
/// At most one operation may target a given document id per batch.
///
/// - Note: Deliberately **not** `Sendable` — the buffer is unsynchronised and
///   must only be used from the `writeBatch` body that received it.
public final class NyaruWriteBatch<T: Codable & Sendable> {
  fileprivate enum Operation {
    case insert(T)
    case update(T)
    case upsert(T)
    case delete(FieldValue)
  }
  fileprivate var operations: [Operation] = []
  fileprivate init() {}

  /// Queues a document insertion. Fails the batch if the id already exists.
  public func insert(_ document: T) { operations.append(.insert(document)) }

  /// Queues a collection of document insertions.
  public func insert(contentsOf documents: some Collection<T>) {
    for document in documents { operations.append(.insert(document)) }
  }

  /// Queues a full-document replacement. Fails the batch if the id is absent.
  public func update(_ document: T) { operations.append(.update(document)) }

  /// Queues a replace-or-insert of the document.
  public func upsert(_ document: T) { operations.append(.upsert(document)) }

  /// Queues a deletion by id. Unknown ids are skipped, not errors.
  public func delete(id: FieldValueConvertible) {
    operations.append(.delete(id.fieldValue))
  }
}

/// The insert-only batch buffer was folded into `NyaruWriteBatch`, which
/// accepts the same `insert` calls plus updates, upserts, and deletes.
@available(*, deprecated, renamed: "NyaruWriteBatch")
public typealias NyaruInsertBatch<T: Codable & Sendable> = NyaruWriteBatch<T>

/// Remembers whether Mirror-based metadata extraction has been validated
/// against the encoded payload for one collection handle's document type.
///
/// `nil` means "not yet validated"; `true` means Mirror and payload agree and
/// the fast path can be trusted; `false` means they diverge (custom
/// `CodingKeys`, property wrappers, …) and the parse path must always be used.
private final class MirrorPathCache: @unchecked Sendable {
  private let lock = NSLock()
  private var _trusted: Bool?
  var trusted: Bool? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _trusted
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      _trusted = newValue
    }
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
  private let idField: String
  private let indexedFields: [String]
  private let mirrorCache = MirrorPathCache()

  init(
    name: String, core: CollectionCore, partitionKey: String?, format: SerializationFormat,
    idField: String, indexedFields: [String]
  ) {
    self.name = name
    self.core = core
    self.partitionKey = partitionKey
    self.format = format
    self.idField = idField
    self.indexedFields = indexedFields
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

  /// Encodes a document AND extracts its metadata directly from the struct
  /// via Mirror when possible, falling back to a post-encode parse for
  /// dot-path fields or documents Mirror cannot represent faithfully.
  ///
  /// **Why the Mirror path must be validated.** Mirror sees Swift property
  /// labels and values; the index must reflect the *encoded payload*. The two
  /// diverge for custom `CodingKeys`, property wrappers, and any value type
  /// `FieldValue.fromAny` cannot convert (enums, `Date`, `UUID`, …). Trusting
  /// Mirror blindly silently drops index entries that a payload-driven rebuild
  /// would create, making query results depend on which path indexed the
  /// document. Two guards close that hole:
  ///
  /// 1. **Per-document:** `mirrorMetadata` returns `nil` whenever a relevant
  ///    field holds a present-but-unconvertible value, forcing the parse path
  ///    for that document.
  /// 2. **Once per handle:** the first document that succeeds through Mirror
  ///    is *also* extracted via parse and both results compared. On mismatch
  ///    (e.g. renamed coding keys) the handle permanently switches to parse.
  ///
  /// The id field is always included in the `indexEntries` alongside the
  /// user's `indexedFields` because `CollectionCore` manages all indexed
  /// fields (including id) uniformly through `allIndexedFields`.
  private func encodeWithMetadata(_ document: T) throws
    -> (Data, Serializer.DocumentMetadata)
  {
    let data = try encode(document)

    let allFields = indexedFields.contains(idField)
      ? indexedFields : [idField] + indexedFields

    // Mirror can only extract top-level fields; dot-path fields ("a.b") always
    // require parsing the encoded payload.
    let hasDotPath =
      idField.contains(".") || (partitionKey?.contains(".") ?? false)
      || allFields.contains { $0.contains(".") }

    if !hasDotPath, mirrorCache.trusted != false,
      let mirrored = mirrorMetadata(for: document, allFields: allFields)
    {
      if mirrorCache.trusted == true {
        return (data, mirrored)
      }
      // First successful Mirror extraction for this handle: cross-check
      // against the payload before trusting it for the lifetime of the handle.
      let parsed = try Serializer.extractMetadata(
        from: data, idField: idField, partitionKey: partitionKey,
        indexedFields: allFields, format: format)
      if metadataMatches(mirrored, parsed) {
        mirrorCache.trusted = true
        return (data, mirrored)
      }
      mirrorCache.trusted = false
      return (data, parsed)
    }

    let metadata = try Serializer.extractMetadata(
      from: data, idField: idField, partitionKey: partitionKey,
      indexedFields: allFields, format: format)
    return (data, metadata)
  }

  /// Extracts document metadata via Mirror, or returns `nil` when any relevant
  /// field carries a value that Mirror cannot faithfully convert — a present
  /// (non-nil) value that `FieldValue.fromAny` rejects, such as an enum,
  /// `Date`, or `UUID`. Nil optionals are skipped, matching the encoder's
  /// behaviour of omitting them from the payload.
  private func mirrorMetadata(for document: T, allFields: [String])
    -> Serializer.DocumentMetadata?
  {
    let mirror = Mirror(reflecting: document)
    var dict: [String: Any] = [:]
    for child in mirror.children {
      guard let label = child.label else { continue }
      dict[label] = child.value
    }

    guard let rawID = dict[idField], let id = FieldValue.fromAny(rawID) else { return nil }

    var partitionValue: FieldValue?
    if let pk = partitionKey, let raw = dict[pk] {
      if let value = FieldValue.fromAny(raw) {
        partitionValue = value
      } else if !Self.isNilOptional(raw) {
        return nil
      }
    }

    var entries: [(field: String, key: FieldValue)] = []
    entries.reserveCapacity(allFields.count)
    for field in allFields {
      guard let raw = dict[field] else { continue }
      if let key = FieldValue.fromAny(raw) {
        entries.append((field, key))
      } else if !Self.isNilOptional(raw) {
        return nil
      }
    }

    return Serializer.DocumentMetadata(
      id: id, partitionValue: partitionValue, indexEntries: entries)
  }

  /// Whether the boxed value is an optional containing `nil`.
  private static func isNilOptional(_ value: Any) -> Bool {
    let mirror = Mirror(reflecting: value)
    return mirror.displayStyle == .optional && mirror.children.isEmpty
  }

  /// Compares two metadata extractions field by field (order-insensitive).
  private func metadataMatches(
    _ a: Serializer.DocumentMetadata, _ b: Serializer.DocumentMetadata
  ) -> Bool {
    guard a.id == b.id, a.partitionValue == b.partitionValue,
      a.indexEntries.count == b.indexEntries.count
    else { return false }
    let aByField = Dictionary(uniqueKeysWithValues: a.indexEntries.map { ($0.field, $0.key) })
    for entry in b.indexEntries {
      guard aByField[entry.field] == entry.key else { return false }
    }
    return true
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
    let (data, metadata) = try encodeWithMetadata(document)
    try await core.insert(data: data, metadata: metadata)
  }

  /// Inserts a batch of documents atomically (against errors).
  ///
  /// All ids are validated before anything is written — if any id already
  /// exists in the collection or is duplicated within the batch, **no**
  /// documents are inserted and `duplicateID` is thrown. Documents are
  /// encoded in parallel and merged into each index in a single pass.
  ///
  /// This is the right call when you already hold the documents in an array.
  /// To accumulate documents from multiple sources first, or to mix inserts
  /// with updates and deletes, use `writeBatch(_:)` — insert-only batches
  /// take exactly this code path, so there is no performance difference.
  ///
  /// - Parameter documents: An array of documents to insert.
  /// - Throws: `NyaruError.duplicateID` if any id conflicts.
  public func insert(contentsOf documents: [T]) async throws {
    // Encoding and metadata extraction are independent per document — run
    // them across all cores for large batches.
    let batch = try Parallel.map(documents) { try encodeWithMetadata($0) }
    try await core.insertMany(batch: batch)
  }

  /// Accumulates mixed operations — insert, update, upsert, delete — and
  /// applies them as one all-or-nothing batch when the body completes.
  ///
  /// Queuing inside the body is synchronous — no `await` — so operations can
  /// be gathered from loops or multiple sources before anything is written:
  ///
  /// ```swift
  /// try await collection.writeBatch { batch in
  ///   batch.insert(newUser)
  ///   batch.update(changedUser)
  ///   batch.delete(id: retiredUserID)
  /// }
  /// ```
  ///
  /// A batch containing only inserts takes the same fast path as
  /// `insert(contentsOf:)` — identical validation and performance.
  ///
  /// **Atomicity against errors, not crashes.** Every operation is validated
  /// before anything is written: a duplicate id, a missing update target, a
  /// thrown body, or two operations on the same id abort the batch with no
  /// side effects, and a failed write is rolled back. A process crash in the
  /// middle of the flush is NOT covered — per-record CRC + dirty-flag
  /// recovery still guarantees integrity, but some operations of the batch
  /// may be durable while others are not.
  ///
  /// The batch is not isolated from concurrent writes to the same ids from
  /// other tasks, just as individual operations are not isolated from each
  /// other.
  ///
  /// - Parameter body: Closure receiving a `NyaruWriteBatch` that queues
  ///   operations via its synchronous methods.
  /// - Throws: `NyaruError.duplicateID`, `NyaruError.documentNotFound`,
  ///   `NyaruError.unsupportedOperation` for conflicting operations, or
  ///   rethrows from `body`.
  public func writeBatch(
    _ body: (NyaruWriteBatch<T>) async throws -> Void
  ) async throws {
    let batch = NyaruWriteBatch<T>()
    try await body(batch)
    guard !batch.operations.isEmpty else { return }

    // Pure-insert batches take the bulk-insert fast path: same validation
    // semantics, one index merge pass.
    let allInserts = batch.operations.allSatisfy {
      if case .insert = $0 { return true } else { return false }
    }
    if allInserts {
      let documents: [T] = batch.operations.compactMap {
        if case .insert(let document) = $0 { return document } else { return nil }
      }
      try await insert(contentsOf: documents)
      return
    }

    // Encoding and metadata extraction are independent per operation.
    let operations: [BatchOperation] = try Parallel.map(batch.operations) { operation in
      switch operation {
      case .insert(let document):
        let (data, metadata) = try encodeWithMetadata(document)
        return .insert(data: data, metadata: metadata)
      case .update(let document):
        let (data, metadata) = try encodeWithMetadata(document)
        return .update(data: data, metadata: metadata)
      case .upsert(let document):
        let (data, metadata) = try encodeWithMetadata(document)
        return .upsert(data: data, metadata: metadata)
      case .delete(let id):
        return .delete(id: id)
      }
    }
    try await core.applyBatch(operations)
  }

  /// Deprecated alias of `writeBatch(_:)`. The buffer's `insert` methods are
  /// unchanged, so existing call sites compile as-is.
  @available(*, deprecated, renamed: "writeBatch")
  public func insertBatch(
    _ body: (NyaruWriteBatch<T>) async throws -> Void
  ) async throws {
    try await writeBatch(body)
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
    let (data, metadata) = try encodeWithMetadata(document)
    try await core.update(data: data, metadata: metadata, upsert: false)
  }

  /// Replaces the document with the same id, or inserts it if absent.
  ///
  /// Unlike `update`, this never throws `documentNotFound` — if no document
  /// exists for the id, the document is inserted.
  ///
  /// - Parameter document: The document to upsert.
  public func upsert(_ document: T) async throws {
    let (data, metadata) = try encodeWithMetadata(document)
    try await core.update(data: data, metadata: metadata, upsert: true)
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

  /// Deletes multiple documents by id in a single batched pass: one storage
  /// hop per shard and one index sweep per field, instead of a full
  /// read/remove cycle per document.
  ///
  /// Unknown ids are skipped (they do not count toward the result and do not
  /// throw).
  ///
  /// - Parameter ids: The document ids to delete.
  /// - Returns: The number of documents actually deleted.
  @discardableResult
  public func delete(ids: [FieldValueConvertible]) async throws -> Int {
    try await core.deleteMany(ids: ids.map(\.fieldValue))
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
  /// - Throws: `NyaruError.databaseClosed` if the database was closed.
  public func count() async throws -> Int {
    try await core.count()
  }

  /// Returns every document in the collection.
  ///
  /// For large collections this materialises the entire dataset in memory.
  /// Consider using `stream()` for bounded-memory iteration.
  ///
  /// - Returns: An array of all decoded documents.
  /// - Throws: `NyaruError.decodingFailed` if any document fails to decode.
  public func all() async throws -> [T] {
    let raw = try await core.scanAll()
    do {
      return try Serializer.decodeBatch(T.self, from: raw, format: format)
    } catch {
      throw NyaruError.decodingFailed(String(describing: error))
    }
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

  /// Persists this collection's index snapshots, flushes shard data, and
  /// clears the dirty flags — after it returns, a crash costs no recovery
  /// work for this collection on the next open.
  ///
  /// The expensive part (encoding and compressing the index snapshots) runs
  /// off the collection's actor, so concurrent reads and writes keep
  /// flowing; only the final fsync barrier briefly excludes writers.
  ///
  /// Call it at meaningful moments — app backgrounding, after an import —
  /// or let `DatabaseOptions.autoSync` schedule it. `NyaruDB.sync()` syncs
  /// every open collection.
  ///
  /// - Throws: `NyaruError.databaseClosed` or the first I/O error.
  public func sync() async throws {
    try await core.sync()
  }

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

  /// Whether any shard's tombstone ratio exceeds the configured
  /// `DatabaseOptions.maxFragmentation` threshold.
  ///
  /// Use this to decide when to call `compact()` — for example, on app
  /// backgrounding:
  /// ```swift
  /// if try await collection.needsCompaction() {
  ///   try await collection.compact()
  /// }
  /// ```
  ///
  /// - Returns: `true` if compaction would reclaim meaningful space.
  /// - Throws: `NyaruError.databaseClosed` if the database was closed.
  public func needsCompaction() async throws -> Bool {
    try await core.needsCompaction()
  }

  /// Returns a snapshot of collection statistics.
  ///
  /// The returned `CollectionStats` includes the document count, shard count,
  /// total on-disk size, index entry counts, and the fragmentation ratio.
  ///
  /// - Returns: Current collection statistics.
  /// - Throws: `NyaruError.databaseClosed` if the database was closed.
  public func stats() async throws -> CollectionStats {
    try await core.stats()
  }

  /// Returns a snapshot of the collection's internal counters — which access
  /// paths queries took, cumulative shard I/O, compaction activity, and
  /// whether any shard needed crash recovery at open.
  ///
  /// Counters accumulate from open and are not persisted. Use them to verify
  /// that the queries you expect to be index-served actually are, or to
  /// size compaction policies from real workloads.
  ///
  /// - Returns: Current metrics snapshot.
  /// - Throws: `NyaruError.databaseClosed` if the database was closed.
  public func metrics() async throws -> CollectionMetrics {
    try await core.metrics()
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
