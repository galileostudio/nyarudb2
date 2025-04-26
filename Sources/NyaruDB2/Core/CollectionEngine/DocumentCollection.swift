import Foundation


///  A structure representing metadata for a collection in the database.
///  
///  This metadata includes the collection's name, the indexes associated with it,
///  and the partition key used for organizing the data.
///  
///  - Properties:
///  - name: The name of the collection.
///  - indexes: An array of strings representing the indexes defined for the collection.
///  - partitionKey: The key used to partition the data within the collection.

public struct CollectionMetadata: Codable {
    public let name: String
    public let indexes: [String]
    public let partitionKey: String

    
    ///  Initializes a new instance of `DocumentCollection`.
    ///  
    ///  - Parameters:
    ///      - name: The name of the collection.
    ///      - indexes: An optional array of index names to be used in the collection. Defaults to an empty array.
    ///      - partitionKey: The key used to partition the collection.
    
    public init(name: String, indexes: [String] = [], partitionKey: String) {
        self.name = name
        self.indexes = indexes
        self.partitionKey = partitionKey
    }
}


///  A class representing a collection of documents within the database.
///  
///  The `DocumentCollection` class is responsible for managing the documents
///  in a specific collection, including their metadata, storage, and statistics.
///  
///  - Properties:
///  - `metadata`: Metadata associated with the collection, such as its name and configuration.
///  - `storage`: The storage engine responsible for persisting the documents in the collection.
///  - `statsEngine`: The statistics engine responsible for tracking and managing collection statistics.

public class DocumentCollection {
    public let metadata: CollectionMetadata
    private let storage: StorageEngine
    private let statsEngine: StatsEngine

    /// Initializes a new instance of `DocumentCollection`.
    ///
    /// - Parameters:
    ///   - storage: The storage engine responsible for handling data persistence.
    ///   - statsEngine: The statistics engine used for tracking collection metrics.
    ///   - name: The name of the collection.
    ///   - indexes: An optional array of index names to be created for the collection. Defaults to an empty array.
    ///   - partitionKey: The key used to partition the data within the collection.
    public init(storage: StorageEngine, statsEngine: StatsEngine, name: String, indexes: [String] = [], partitionKey: String) {
        self.storage = storage
        self.metadata = CollectionMetadata(name: name, indexes: indexes, partitionKey: partitionKey)
        self.statsEngine = statsEngine
    }

    /// Inserts a document into the collection asynchronously.
    /// 
    /// - Parameter document: The document to be inserted. It must conform to the `Codable` protocol.
    /// - Throws: An error if the insertion fails.
    /// - Note: The document is stored in the collection specified by the metadata, and the first index field
    ///   from the metadata's indexes is used for indexing.
    public func insert<T: Codable>(_ document: T) async throws {
        let indexField = metadata.indexes.first
        try await storage.insertDocument(document, collection: metadata.name, indexField: indexField)
    }

    /// Inserts multiple documents into the collection in bulk.
    /// 
    /// - Parameter documents: An array of documents conforming to the `Codable` protocol to be inserted.
    /// - Throws: An error if the insertion fails.
    /// - Note: This method uses the first index field from the collection's metadata for indexing.
    /// - Requires: The `documents` array must not be empty.
    public func bulkInsert<T: Codable>(_ documents: [T]) async throws {
        let indexField = metadata.indexes.first
        try await storage.bulkInsertDocuments(documents, collection: metadata.name, indexField: indexField)
    }

    /// Finds a single document in the collection that matches the specified query and shard key-value pair.
    ///
    /// - Parameters:
    ///   - query: An optional dictionary representing the query criteria. If `nil`, no filtering is applied.
    ///   - shardKey: The key used to identify the shard where the document is stored.
    ///   - shardValue: The value of the shard key to locate the specific shard.
    /// - Returns: An optional object of type `T` that conforms to `Codable`, representing the found document, or `nil` if no document matches the criteria.
    /// - Throws: An error if the operation fails.
    /// - Note: This method is asynchronous and must be called with `await`.
    public func findOne<T: Codable>(
        query: [String: Any]? = nil,
        shardKey: String,
        shardValue: String
    ) async throws -> T? {
        return try await _findOne(query: query, shardKey: shardKey, shardValue: shardValue)
    }

    /// Finds and returns the first document that matches the specified query.
    ///
    /// - Parameters:
    ///   - query: An optional dictionary representing the query criteria. If `nil`, no filtering is applied.
    ///   - shardKey: An optional string representing the shard key to filter the query by. Defaults to `nil`.
    ///   - shardValue: An optional string representing the shard value to filter the query by. Defaults to `nil`.
    /// - Returns: The first document of type `T` that matches the query, or `nil` if no document is found.
    /// - Throws: An error if the fetch operation fails.
    /// - Note: This method is asynchronous and must be called with `await`.
    private func _findOne<T: Codable>(
        query: [String: Any]? = nil,
        shardKey: String? = nil,
        shardValue: String? = nil
    ) async throws -> T? {
        let results: [T] = try await fetch(query: query, shardKey: shardKey, shardValue: shardValue)
        return results.first
    }

    /// Updates a document in the collection that matches the given predicate.
    /// 
    /// - Parameters:
    ///   - document: The document of type `T` to update. Must conform to `Codable`.
    ///   - predicate: A closure that takes a document of type `T` as its argument and returns a Boolean value indicating whether the document matches the condition.
    /// 
    /// - Throws: An error if the update operation fails.
    /// 
    /// - Note: This method is asynchronous and must be called with `await`.
    public func update<T: Codable>(_ document: T, matching predicate: @escaping (T) -> Bool) async throws {
        try await storage.updateDocument(document, in: metadata.name, matching: predicate)
    }

    /// Fetches documents from the collection that match the specified query and optional shard parameters.
    ///
    /// - Parameters:
    ///   - query: An optional dictionary representing the query criteria. The keys are field names, and the values are the values to match. If `nil`, all documents are fetched.
    ///   - shardKey: An optional string representing the shard key to filter the documents. If `nil`, no shard key filtering is applied.
    ///   - shardValue: An optional string representing the shard value to filter the documents. If `nil`, no shard value filtering is applied.
    /// - Returns: An array of documents of type `T` that match the query and shard parameters.
    /// - Throws: An error if the fetch operation fails.
    /// - Note: The generic type `T` must conform to the `Codable` protocol.
    public func fetch<T: Codable>(
        query: [String: Any]? = nil,
        shardKey: String? = nil,
        shardValue: String? = nil
    ) async throws -> [T] {

        let results: [T] = try await storage.fetchDocuments(from: metadata.name)

        // Apply shard filtering if specified
        let resultsFilteredByShard: [T] = await {
            let currentFormat = await storage.storageFormat
            guard let shardKey = shardKey, let shardValue = shardValue else { return results }
            return results.filter { document in
                guard let data = try? StorageSerializer.encode(document, using: currentFormat),
                      let dict = try? StorageSerializer.decodeToDictionary(data: data, format: currentFormat),
                      let value = dict[shardKey] as? String
                else { return false }

                return value == shardValue
            }
        }()

        guard let query = query else { return resultsFilteredByShard }

        let currentFormat = await storage.storageFormat
        let finalResults = resultsFilteredByShard.filter { document in
            
            guard let data = try? StorageSerializer.encode(document, using: currentFormat),
                  let dict = try? StorageSerializer.decodeToDictionary(data: data, format: currentFormat)

            else { return false }
            for (key, value) in query {
                if let docValue = dict[key] as? String, let queryValue = value as? String {
                    if docValue != queryValue { return false }
                } else if let docValue = dict[key] as? Int, let queryValue = value as? Int {
                    if docValue != queryValue { return false }
                } else {
                    return false
                }
            }
            return true
        }
        return finalResults
    }

    /// Deletes documents from the collection that satisfy the given predicate.
    ///
    /// This method asynchronously deletes documents of type `T` from the collection
    /// where the provided predicate evaluates to `true`.
    ///
    /// - Parameter predicate: A closure that takes an instance of `T` as its argument
    ///   and returns a Boolean value indicating whether the document should be deleted.
    ///
    /// - Throws: An error if the deletion process fails.
    ///
    /// - Note: The `predicate` closure is executed asynchronously.
    public func delete<T: Codable>(where predicate: @escaping (T) -> Bool) async throws {
        try await storage.deleteDocuments(where: predicate, from: metadata.name)
    }

    /// Asynchronously creates a query for documents of the specified type.
    ///
    /// - Returns: A `Query` object that can be used to perform operations on documents of type `T`.
    /// - Throws: An error if the query cannot be created.
    /// - Note: The generic type `T` must conform to the `Codable` protocol.
    public func query<T: Codable>() async throws -> Query<T> {
    let indexStats = await statsEngine.getIndexStats()  // Using StatsEngine directly.
    let shardStats = try await statsEngine.getShardStats()
    return Query<T>(collection: metadata.name,
                    storage: storage,
                    indexStats: indexStats,
                    shardStats: shardStats)
}


}
