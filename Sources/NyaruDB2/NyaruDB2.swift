import Foundation

/// A class representing the NyaruDB2 database system.
///
/// This class provides the core functionality for managing collections,
/// storage, indexing, and statistics within the database.
///
/// - Properties:
///   - `storage`: The storage engine responsible for handling data persistence.
///   - `indexManager`: The index manager responsible for managing indexes for efficient data retrieval.
///   - `statsEngine`: A private engine for tracking and managing database statistics.
///   - `collections`: A private dictionary mapping collection names to their respective document collections.
public class NyaruDB2 {
    public let storage: StorageEngine
    public let indexManager: IndexManager<String>
    private let statsEngine: StatsEngine
    private var collections: [String: DocumentCollection] = [:]
    private let storageFormat: StorageFormat

    
    /// Initializes a new instance of `NyaruDB2`.
    ///
    /// - Parameters:
    ///   - path: The file path where the database will be stored. Defaults to `"NyaruDB2"`.
    ///   - compressionMethod: The method used for compressing the database. Defaults to `.none`.
    ///   - fileProtectionType: The file protection level for the database. Defaults to `.none`.
    ///   - storageFormat: The format used for storing data. Defaults to `.json`.
    /// - Throws: An error if the initialization fails.
    public init(
        path: String = "NyaruDB2",
        compressionMethod: CompressionMethod = .none,
        fileProtectionType: FileProtectionType = .none,
        storageFormat: StorageFormat = .json
    ) throws {
        self.storage = try StorageEngine(
            path: path,
            compressionMethod: compressionMethod,
            fileProtectionType: fileProtectionType,
            storageFormat: storageFormat
        )
        self.indexManager = IndexManager()
        self.statsEngine = StatsEngine(storage: storage)
        self.storageFormat = storageFormat
    }
    
    /// Retrieves a `DocumentCollection` with the specified name.
    ///
    /// - Parameter name: The name of the collection to retrieve.
    /// - Returns: A `DocumentCollection` instance if a collection with the specified name exists, otherwise `nil`.
    public func getCollection(named name: String) -> DocumentCollection? {
        return collections[name]
    }

    /// Creates a new collection in the database.
    ///
    /// - Parameters:
    ///   - name: The name of the collection to be created.
    ///   - indexes: An optional array of field names to create indexes on. Defaults to an empty array.
    ///   - partitionKey: The field name to be used as the partition key for the collection.
    /// - Returns: A `DocumentCollection` representing the newly created collection.
    /// - Throws: An error if the collection cannot be created.
    public func createCollection(name: String, indexes: [String] = [], partitionKey: String) async throws -> DocumentCollection {
        await storage.setPartitionKey(for: name, key: partitionKey)
        
        let collection = DocumentCollection(storage: storage,
                                       statsEngine: statsEngine,
                                       name: name,
                                       indexes: indexes,
                                       partitionKey: partitionKey
                                       )
        collections[name] = collection
        return collection
    }
    



    /// Inserts a document into the specified collection in the database.
    ///
    /// - Parameters:
    ///   - document: The document to be inserted. Must conform to the `Codable` protocol.
    ///   - collection: The name of the collection where the document will be inserted.
    ///   - indexField: An optional field to be used as an index for the document. Defaults to `nil`.
    /// - Throws: An error if the insertion fails.
    /// - Note: This is an asynchronous operation.
    public func insert<T: Codable>(
        _ document: T,
        into collection: String,
        indexField: String? = nil
    ) async throws {
        try await storage.insertDocument(document, collection: collection, indexField: indexField)
    }
    
    
    /// Inserts multiple documents into the specified collection in bulk.
    ///
    /// - Parameters:
    ///   - documents: An array of documents conforming to the `Codable` protocol to be inserted.
    ///   - collection: The name of the collection where the documents will be inserted.
    ///   - indexField: An optional field name to be used as an index for the documents. Defaults to `nil`.
    /// - Throws: An error if the insertion fails.
    /// - Note: This method is asynchronous and should be called with `await`.
    public func bulkInsert<T: Codable>(
        _ documents: [T],
        into collection: String,
        indexField: String? = nil
    ) async throws {
        try await storage.bulkInsertDocuments(documents, collection: collection, indexField: indexField)
    }
    
    
    /// Updates a document in the specified collection that matches the given predicate.
    ///
    /// - Parameters:
    ///   - document: The document of type `T` to update. Must conform to `Codable`.
    ///   - collection: The name of the collection where the document resides.
    ///   - predicate: A closure that takes a document of type `T` as its argument and returns a Boolean value
    ///                indicating whether the document matches the criteria for updating.
    ///   - indexField: An optional field name to use as an index for optimizing the update operation. Defaults to `nil`.
    ///
    /// - Throws: An error if the update operation fails.
    ///
    /// - Note: This method is asynchronous and must be called with `await`.
    public func update<T: Codable>(
        _ document: T,
        in collection: String,
        matching predicate: @escaping (T) -> Bool,
        indexField: String? = nil
    ) async throws {
        try await storage.updateDocument(document, in: collection, matching: predicate, indexField: indexField)
    }
    
    
    /// Deletes objects of type `T` from the specified collection that satisfy the given predicate.
    ///
    /// - Parameters:
    ///   - predicate: A closure that takes an object of type `T` as its argument and returns a Boolean value
    ///     indicating whether the object should be deleted.
    ///   - collection: The name of the collection from which the objects should be deleted.
    /// - Throws: An error if the deletion process fails.
    /// - Note: This is an asynchronous operation.
    public func delete<T: Codable>(
        where predicate: @escaping (T) -> Bool,
        from collection: String
    ) async throws {
        try await storage.deleteDocuments(where: predicate, from: collection)
    }
    
    
    /// Fetches all documents from the specified collection and decodes them into an array of the specified `Codable` type.
    ///
    /// - Parameter collection: The name of the collection to fetch documents from.
    /// - Returns: An array of decoded objects of type `T`.
    /// - Throws: An error if the fetch operation fails or if decoding the documents fails.
    public func fetch<T: Codable>(from collection: String) async throws -> [T] {
        return try await storage.fetchDocuments(from: collection)
    }
    
    /// Fetches documents lazily from the specified collection as an asynchronous throwing stream.
    /// 
    /// This method allows you to retrieve documents from a collection in a lazy manner, 
    /// meaning that documents are fetched and processed one at a time, reducing memory usage 
    /// for large datasets. The returned stream can throw errors during iteration if any issues 
    /// occur while fetching the documents.
    /// 
    /// - Parameter collection: The name of the collection to fetch documents from.
    /// - Returns: An `AsyncThrowingStream` of type `T` containing the fetched documents.
    /// - Throws: An error if the fetching process encounters an issue.
    /// 
    /// - Note: The generic type `T` must conform to the `Codable` protocol.
    public func fetchLazy<T: Codable>(from collection: String) async -> AsyncThrowingStream<T, Error> {
        await storage.fetchDocumentsLazy(from: collection)
    }

    /// Executes a query on the specified collection and returns a `Query` object.
    ///
    /// - Parameter collection: The name of the collection to query.
    /// - Returns: A `Query` object of the specified generic type `T` conforming to `Codable`.
    /// - Throws: An error if retrieving index or shard statistics fails.
    /// - Note: This function is asynchronous and must be called with `await`.
    public func query<T: Codable>(from collection: String) async throws -> Query<T> {
        return Query<T>(
            collection: collection,
            storage: self.storage,
            indexStats: try await self.getIndexStats(),
            shardStats: try await self.getShardStats()
        )
    }
    
    
    /// Counts the number of documents in the specified collection.
    ///
    /// - Parameter collection: The name of the collection to count documents in.
    /// - Returns: The total number of documents in the specified collection.
    /// - Throws: An error if the operation fails.
    /// - Note: This is an asynchronous method and must be called with `await`.
    public func countDocuments(in collection: String) async throws -> Int {
        return try await storage.countDocuments(in: collection)
    }
    
    
    /// Lists all the collections available in the database.
    ///
    /// - Returns: An array of strings representing the names of the collections.
    /// - Throws: An error if the operation to list collections fails.
    /// - Note: This is an asynchronous function and must be called with `await`.
    public func listCollections() async throws -> [String] {
        return try await storage.listCollections()
    }
    
    /// Drops the specified collection from the database.
    ///
    /// - Parameter collection: The name of the collection to be dropped.
    /// - Throws: An error if the operation fails.
    /// - Note: This operation is asynchronous and may involve I/O operations.
    public func dropCollection(_ collection: String) async throws {
        try await storage.dropCollection(collection)
    }
    
    
    /// Retrieves the statistics for a specified collection.
    ///
    /// - Parameter collection: The name of the collection for which to retrieve statistics.
    /// - Returns: A `CollectionStats` object containing the statistics of the specified collection.
    /// - Throws: An error if the statistics could not be retrieved.
    /// - Note: This function is asynchronous and must be awaited.
    public func getCollectionStats(for collection: String) async throws -> CollectionStats {
        return try await statsEngine.getCollectionStats(collection)
    }
    
    /// Retrieves the global statistics of the database.
    ///
    /// This asynchronous function fetches and returns the global statistics
    /// by utilizing the `statsEngine`. The returned `GlobalStats` object
    /// contains aggregated information about the database's state.
    ///
    /// - Returns: A `GlobalStats` object containing the global statistics.
    /// - Throws: An error if the statistics retrieval fails.
    public func getGlobalStats() async throws -> GlobalStats {
        return try await statsEngine.getGlobalStats()
    }

    /// Retrieves statistics for all indexes in the database.
    ///
    /// This asynchronous function fetches index statistics using the `statsEngine`.
    ///
    /// - Returns: A dictionary where the keys are index names (`String`) and the values are `IndexStat` objects containing the statistics for each index.
    /// - Throws: An error if the operation to fetch index statistics fails.
    public func getIndexStats() async throws -> [String: IndexStat] {
        return await statsEngine.getIndexStats()
    }
    
    /// Retrieves statistics for all shards.
    ///
    /// This asynchronous function fetches and returns an array of `ShardStat` objects,
    /// which contain statistical information about the shards managed by the database.
    ///
    /// - Returns: An array of `ShardStat` objects representing the statistics of each shard.
    /// - Throws: An error if the statistics could not be retrieved.
    public func getShardStats() async throws -> [ShardStat] {
        return try await statsEngine.getShardStats()
    }
}
