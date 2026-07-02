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
  public func stream() -> AsyncThrowingStream<T, Error> {
    let core = self.core
    let format = self.format
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let data = try await core.scanAll()
          for docData in data {
            try Task.checkCancellation()
            continuation.yield(try Serializer.decode(T.self, from: docData, format: format))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
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
}
