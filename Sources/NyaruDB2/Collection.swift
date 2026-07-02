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

  init(name: String, core: CollectionCore, partitionKey: String?) {
    self.name = name
    self.core = core
    self.partitionKey = partitionKey
  }

  private func encode(_ document: T) throws -> Data {
    do {
      return try JSONEncoder().encode(document)
    } catch {
      throw NyaruError.encodingFailed(String(describing: error))
    }
  }

  private func decode(_ json: Data) throws -> T {
    do {
      return try JSONDecoder().decode(T.self, from: json)
    } catch {
      throw NyaruError.decodingFailed(String(describing: error))
    }
  }

  // MARK: - Writes

  /// Inserts a new document. Throws `NyaruError.duplicateID` if a document
  /// with the same id already exists (use `upsert` to overwrite).
  public func insert(_ document: T) async throws {
    try await core.insert(json: encode(document))
  }

  /// Inserts a batch. Validates every id (including duplicates inside the
  /// batch) before writing anything.
  public func insert(contentsOf documents: [T]) async throws {
    try await core.insertMany(jsons: documents.map(encode))
  }

  /// Replaces the document with the same id. Throws
  /// `NyaruError.documentNotFound` if it does not exist.
  public func update(_ document: T) async throws {
    try await core.update(json: encode(document), upsert: false)
  }

  /// Replaces the document with the same id, inserting it if absent.
  public func upsert(_ document: T) async throws {
    try await core.update(json: encode(document), upsert: true)
  }

  /// Deletes by id. Returns true if a document was removed.
  @discardableResult
  public func delete(id: FieldValueConvertible) async throws -> Bool {
    try await core.delete(id: id.fieldValue)
  }

  // MARK: - Reads

  /// Point lookup by id through the primary index.
  public func get(id: FieldValueConvertible) async throws -> T? {
    guard let json = try await core.get(id: id.fieldValue) else { return nil }
    return try decode(json)
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
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let jsons = try await core.scanAll()
          for json in jsons {
            try Task.checkCancellation()
            continuation.yield(try JSONDecoder().decode(T.self, from: json))
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
    QueryBuilder(core: core, partitionKey: partitionKey)
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
