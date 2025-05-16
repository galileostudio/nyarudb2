import Foundation

/// The `StorageEngine` actor is responsible for managing the core storage functionality of the database.
/// It handles the configuration, partitioning, and management of collections, shards, and indexes.
///
/// Properties:
/// - `baseURL`: The base URL where the storage engine operates.
/// - `compressionMethod`: The method used for compressing stored data.
/// - `fileProtectionType`: The type of file protection applied to stored data.
/// - `collectionPartitionKeys`: A dictionary mapping collection names to their partition keys.
/// - `activeShardManagers`: A dictionary of active shard managers, keyed by collection name.
/// - `indexManagers`: A dictionary of index managers, keyed by collection name.
/// - `statsEngine`: A lazily initialized instance of `StatsEngine` for gathering storage statistics.
public actor StorageEngine {

    private let baseURL: URL
    private let compressionMethod: CompressionMethod
    private let fileProtectionType: FileProtectionType
    public var collectionPartitionKeys: [String: String] = [:]
    public var activeShardManagers = [String: ShardManager]()
    public var indexManagers: [String: IndexManager<String>] = [:]
    private lazy var statsEngine: StatsEngine = StatsEngine(storage: self)

    /// An enumeration representing errors that can occur in the storage engine.
    ///
    /// This enum conforms to the `Error` protocol, allowing instances of `StorageError`
    /// to be thrown and handled as part of Swift's error-handling mechanism.
    public enum StorageError: Error {
        case invalidDocument
        case partitionKeyNotFound(String)
        case indexKeyNotFound(String)
        case shardManagerCreationFailed
        case updateDocumentNotFound
    }

    /// Initializes a new instance of the `StorageEngine` class.
    ///
    /// - Parameters:
    ///   - path: The file path where the storage engine will operate.
    ///   - compressionMethod: The method used for compressing data. Defaults to `.none`.
    ///   - fileProtectionType: The file protection level to apply. Defaults to `.none`.
    public init(
        path: String,
        compressionMethod: CompressionMethod = .none,
        fileProtectionType: FileProtectionType = .none

    ) throws {
        self.baseURL = URL(fileURLWithPath: path, isDirectory: true)
        self.compressionMethod = compressionMethod
        self.fileProtectionType = fileProtectionType

        try FileManager.default.createDirectory(
            at: baseURL,
            withIntermediateDirectories: true
        )
    }

    /// Inserts a document into the specified collection in the storage engine.
    ///
    /// - Parameters:
    ///   - document: The document to be inserted. Must conform to the `Codable` protocol.
    ///   - collection: The name of the collection where the document will be stored.
    ///   - indexField: An optional field to be used as an index for the document. Defaults to `nil`.
    /// - Throws: An error if the insertion fails.
    /// - Note: This method is asynchronous and must be called with `await`.
    public func insertDocument<T: Codable>(
        _ document: T,
        collection: String,
        indexField: String? = nil
    ) async throws {
        let jsonData = try JSONEncoder().encode(document)

        let partitionField = collectionPartitionKeys[collection]
        let partitionValue: String =
            partitionField != nil && !partitionField!.isEmpty
            ? try DynamicDecoder.extractValue(
                from: jsonData,
                key: partitionField!
            ) : "default"

        let shardManager = try await getOrCreateShardManager(for: collection)
        let shard = try await shardManager.getOrCreateShard(id: partitionValue)


        try await shard.appendDocument(document, jsonData: jsonData)

        let indexManager = indexManagers[collection] ?? IndexManager<String>()
        indexManagers[collection] = indexManager
        if let unwrappedIndexField = indexField {
            try await indexManager.upsertIndex(for: unwrappedIndexField, jsonData: jsonData)
        }

        try await self.statsEngine.updateCollectionMetadata(for: collection)

    }

    /// Fetches documents from the specified collection and decodes them into the specified type.
    ///
    /// This method retrieves all documents from the given collection and attempts to decode them
    /// into the specified `Codable` type `T`. The operation is asynchronous and may throw an error
    /// if the fetch or decoding process fails.
    ///
    /// - Parameter collection: The name of the collection to fetch documents from.
    /// - Returns: An array of decoded objects of type `T`.
    /// - Throws: An error if the fetch operation or decoding process fails.
    public func fetchDocuments<T: Codable>(from collection: String) async throws
        -> [T]
    {
        // Ensure shard manager exists and loads existing shards
        let shardManager = try await getOrCreateShardManager(for: collection)
        // Load documents from all shards sequentially
        var allDocs: [T] = []
        for shard in shardManager.allShards() {
            let docs: [T] = try await shard.loadDocuments()
            allDocs.append(contentsOf: docs)
        }
        return allDocs
    }

    /// Fetches records from the specified collection that match the given field and value.
    ///
    /// This method performs an asynchronous operation to retrieve records from the index
    /// of the specified collection. The records are decoded into the specified generic type `T`.
    ///
    /// - Parameters:
    ///   - collection: The name of the collection to fetch records from.
    ///   - field: The name of the field to match against.
    ///   - value: The value to match in the specified field.
    /// - Returns: An array of decoded objects of type `T` that match the specified criteria.
    /// - Throws: An error if the fetch operation fails or if decoding the records fails.
    public func fetchFromIndex<T: Codable>(
        collection: String,
        field: String,
        value: String
    ) async throws -> [T] {
        guard let indexManager = indexManagers[collection] else {
            return []
        }
        let dataArray = await indexManager.search(field, value: value)
        return try dataArray.map { try JSONDecoder().decode(T.self, from: $0) }
    }

    /// Fetches documents lazily from the specified collection.
    ///
    /// This method returns an `AsyncThrowingStream` that allows you to asynchronously
    /// iterate over the documents in the collection. Each document is decoded into
    /// the specified `Codable` type `T`.
    ///
    /// - Parameter collection: The name of the collection to fetch documents from.
    /// - Returns: An `AsyncThrowingStream` of type `T` that provides asynchronous access
    ///   to the documents in the collection.
    /// - Throws: An error if the operation fails during document retrieval or decoding.
    public func fetchDocumentsLazy<T: Codable>(from collection: String)
        -> AsyncThrowingStream<T, Error>
    {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await activeShardManagers[collection]?
                        .allShards()
                        .asyncForEach { shard in
                            try await shard.loadDocuments()
                                .forEach { continuation.yield($0) }
                        }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Deletes documents from the specified collection that satisfy the given predicate.
    ///
    /// - Parameters:
    ///   - predicate: A closure that takes an instance of type `T` and returns a Boolean value
    ///     indicating whether the document should be deleted.
    ///   - collection: The name of the collection from which documents will be deleted.
    /// - Throws: An error if the deletion process fails.
    /// - Note: This method is asynchronous and must be called with `await`.
    public func deleteDocuments<T: Codable>(
        where predicate: @escaping (T) -> Bool,
        from collection: String
    ) async throws {
        guard let shardManager = activeShardManagers[collection] else { return }

        try await shardManager.allShards()
            .asyncForEach { shard in
                let docs = try await shard.loadDocuments() as [T]
                let newDocs = docs.filter { !predicate($0) }
                if docs.count != newDocs.count {
                    try await shard.saveDocuments(newDocs)
                }
            }

        try await statsEngine.updateCollectionMetadata(for: collection)
    }

    /// Updates a document in the specified collection that matches the given predicate.
    ///
    /// - Parameters:
    ///   - document: The document of type `T` to update. Must conform to `Codable`.
    ///   - collection: The name of the collection where the document resides.
    ///   - predicate: A closure that takes a document of type `T` as its argument and
    ///     returns a Boolean value indicating whether the document matches the criteria.
    ///   - indexField: An optional field name to use as an index for optimizing the update operation.
    ///
    /// - Throws: An error if the update operation fails.
    ///
    /// - Note: This method is asynchronous and must be called with `await`.
    public func updateDocument<T: Codable>(
        _ document: T,
        in collection: String,
        matching predicate: (T) -> Bool,
        indexField: String? = nil
    ) async throws {

        let jsonData = try JSONEncoder().encode(document)

        let shardManager = try await getOrCreateShardManager(for: collection)
        let shard: Shard
        if let partitionField = collectionPartitionKeys[collection] {
            let partitionValue: String = try DynamicDecoder.extractValue(
                from: jsonData,
                key: partitionField
            )
            shard = try await shardManager.getOrCreateShard(id: partitionValue)
        } else {
            shard = try await shardManager.getOrCreateShard(id: "default")
        }

        var documents: [T] = try await shard.loadDocuments()

        guard let indexToUpdate = documents.firstIndex(where: predicate) else {
            throw StorageEngine.StorageError.updateDocumentNotFound
        }

        documents[indexToUpdate] = document

        try await shard.saveDocuments(documents)
        
        let indexManager = indexManagers[collection] ?? IndexManager<String>()
        indexManagers[collection] = indexManager  // salva no dicionário caso seja recém-criado
        if let unwrappedIndexField = indexField {
            try await indexManager.upsertIndex(for: unwrappedIndexField, jsonData: jsonData)
        }
    }

    /// Inserts multiple documents into the specified collection in bulk.
    ///
    /// - Parameters:
    ///   - documents: An array of documents conforming to the `Codable` protocol to be inserted.
    ///   - collection: The name of the collection where the documents will be inserted.
    ///   - indexField: An optional field name to be used as an index for the documents. Defaults to `nil`.
    /// - Throws: An error if the insertion fails.
    /// - Note: This method is asynchronous and must be called with `await`.
    public func bulkInsertDocuments<T: Codable>(
        _ documents: [T],
        collection: String,
        indexField: String? = nil
    ) async throws {

        guard !documents.isEmpty else { return }

        let shardManager = try await getOrCreateShardManager(for: collection)

        if let indexField = indexField, indexManagers[collection] == nil {
            let newManager = IndexManager<String>()
            await newManager.createIndex(for: indexField)
            indexManagers[collection] = newManager
        }

        let groups: [String: [(document: T, jsonData: Data)]] =
            try documents.reduce(into: [:]) { result, document in
                let jsonData = try JSONEncoder().encode(document)
                // Consulta a chave de partição configurada para a coleção.
                let partitionField = collectionPartitionKeys[collection]
                let partitionValue =
                    partitionField != nil
                    ? try DynamicDecoder.extractValue(
                        from: jsonData,
                        key: partitionField!
                    )
                    : "default"

                result[partitionValue, default: []].append((document, jsonData))
            }

        if let indexField = indexField {
            try await documents.asyncForEach { document in
                let jsonData = try JSONEncoder().encode(document)
                let indexKey = try DynamicDecoder.extractValue(
                    from: jsonData,
                    key: indexField,
                    forIndex: true
                )
                let indexManager: IndexManager<String>
                if let existing = indexManagers[collection] {
                    indexManager = existing
                } else {
                    let newManager = IndexManager<String>()
                    await newManager.createIndex(for: indexField)
                    indexManagers[collection] = newManager
                    indexManager = newManager
                }
                await indexManager.insert(
                    index: indexField,
                    key: indexKey,
                    data: jsonData
                )
            }
        }

        try await groups.forEachAsync { (shardId, groupDocuments) in
            let shard = try await shardManager.getOrCreateShard(id: shardId)
            let existingDocs: [T] = try await shard.loadDocuments()
            let newDocs = groupDocuments.map { $0.document }
            let updatedDocs = existingDocs + newDocs
            try await shard.saveDocuments(updatedDocs)
        }

        try await self.statsEngine.updateCollectionMetadata(for: collection)
    }

    /// Counts the number of documents in the specified collection.
    ///
    /// - Parameter collection: The name of the collection to count documents in.
    /// - Returns: The total number of documents in the specified collection.
    /// - Throws: An error if the operation fails.
    /// - Note: This is an asynchronous method and must be called with `await`.
    public func countDocuments(in collection: String) async throws -> Int {
        return activeShardManagers[collection]?.allShards()
            .map(\.metadata.documentCount)
            .reduce(0, +) ?? 0
    }

    /// Drops the specified collection from the storage engine.
    ///
    /// This method removes all data associated with the given collection name.
    ///
    /// - Parameter collection: The name of the collection to be dropped.
    /// - Throws: An error if the operation fails.
    /// - Note: This operation is asynchronous and must be awaited.
    public func dropCollection(_ collection: String) async throws {
        let collectionURL = baseURL.appendingPathComponent(
            collection,
            isDirectory: true
        )
        try FileManager.default.removeItem(at: collectionURL)

        activeShardManagers.removeValue(forKey: collection)
        indexManagers.removeValue(forKey: collection)
    }

    /// Lists all the collections available in the storage engine.
    ///
    /// - Returns: An array of strings representing the names of the collections.
    /// - Throws: An error if the operation fails.
    public func listCollections() throws -> [String] {
        let items = try FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: nil
        )

        let collections = items.filter { url in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            )
            return isDirectory.boolValue
        }

        return collections.map { $0.lastPathComponent }
    }

    /// Retrieves the shard managers associated with a specific collection.
    ///
    /// This asynchronous function fetches all the shards for the given collection name.
    ///
    /// - Parameter collection: The name of the collection for which shard managers are to be retrieved.
    /// - Returns: An array of `Shard` objects representing the shard managers for the specified collection.
    /// - Throws: An error if the operation fails, such as issues with accessing the storage or invalid collection name.
    public func getShardManagers(for collection: String) async throws -> [Shard]
    {
        guard let shardManager = activeShardManagers[collection] else {
            return []
        }
        return shardManager.allShards()
    }

    /// Retrieves the shard associated with a specific partition within a given collection.
    ///
    /// - Parameters:
    ///   - partition: The identifier of the partition for which the shard is being retrieved.
    ///   - collection: The name of the collection containing the partition.
    public func getShard(forPartition partition: String, in collection: String)
        async throws -> Shard?
    {
        let shards = try await getShardManagers(for: collection)
        return shards.first(where: { $0.id == partition })
    }

    /// Retrieves the shard manager for the specified collection, or creates a new one if it does not exist.
    ///
    /// - Parameter collection: The name of the collection for which the shard manager is required.
    /// - Returns: The shard manager associated with the specified collection.
    /// - Throws: An error if the shard manager cannot be retrieved or created.
    /// - Note: This is an asynchronous function and must be called with `await`.
    private func getOrCreateShardManager(for collection: String) async throws
        -> ShardManager
    {
        if let existing = activeShardManagers[collection] {
            return existing
        }

        let collectionURL = baseURL.appendingPathComponent(
            collection,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: collectionURL,
            withIntermediateDirectories: true
        )

        let newManager = ShardManager(
            baseURL: collectionURL,
            compressionMethod: compressionMethod
        )
        // Load existing shards from disk when creating a new shard manager
        newManager.loadShards()
        activeShardManagers[collection] = newManager
        return newManager
    }


    /// Performs a bulk update of indexes for a specified collection.
    ///
    /// - Parameters:
    ///   - collection: The name of the collection where the indexes will be updated.
    ///   - updates: An array of tuples containing the index field, index key, and associated data to update.
    ///     - indexField: The field name of the index to be updated.
    ///     - indexKey: The key of the index to be updated.
    ///     - data: The data associated with the index key to be updated.
    /// 
    /// This method is asynchronous and allows for batch processing of index updates.
    public func bulkUpdateIndexes(
        collection: String,
        updates: [(indexField: String, indexKey: String, data: Data)]
    ) async {
        guard let indexManager = self.indexManagers[collection] else { return }
        await withTaskGroup(of: Void.self) { group in
            for update in updates {
                group.addTask {
                    await indexManager.insert(
                        index: update.indexField,
                        key: update.indexKey,
                        data: update.data
                    )
                }
            }
        }
    }

    /// Sets the partition key for a specified collection.
    ///
    /// - Parameters:
    ///   - collection: The name of the collection for which the partition key is being set.
    ///   - key: The key to be used as the partition key for the collection.
    public func setPartitionKey(for collection: String, key: String) {
        collectionPartitionKeys[collection] = key
    }

    /// Returns the directory URL for the specified collection.
    ///
    /// This method asynchronously retrieves the directory URL where the data
    /// for the given collection is stored.
    ///
    /// - Parameter collection: The name of the collection for which the directory URL is required.
    /// - Returns: A `URL` pointing to the directory of the specified collection.
    /// - Throws: An error if the directory cannot be determined or accessed.
    public func collectionDirectory(for collection: String) async throws -> URL
    {
        let collectionURL = baseURL.appendingPathComponent(
            collection,
            isDirectory: true
        )
        return collectionURL
    }

    /// Repartitions a collection by changing its partition key.
    ///
    /// This method allows you to repartition an existing collection by specifying a new partition key.
    /// The operation is performed asynchronously and may throw an error if the operation fails.
    ///
    /// - Parameters:
    ///   - collection: The name of the collection to repartition.
    ///   - newPartitionKey: The new partition key to be used for the collection.
    ///   - type: The type of the objects stored in the collection, conforming to `Codable`.
    ///
    /// - Throws: An error if the repartitioning operation fails.
    public func repartitionCollection<T: Codable>(
        collection: String,
        newPartitionKey: String,
        as type: T.Type
    ) async throws {
        
        let allDocs: [T] = try await fetchDocuments(from: collection)
        let shardManager = try await getOrCreateShardManager(for: collection)
        try shardManager.removeAllShards()
        setPartitionKey(for: collection, key: newPartitionKey)
        let groups = try allDocs.reduce(into: [String: [T]]()) {
            result,
            document in
            let jsonData = try JSONEncoder().encode(document)
            let partitionValue = try DynamicDecoder.extractValue(
                from: jsonData,
                key: newPartitionKey
            )
            result[partitionValue, default: []].append(document)
        }

        for (partitionValue, docsGroup) in groups {
            let shard = try await shardManager.getOrCreateShard(
                id: partitionValue
            )
            try await shard.saveDocuments(docsGroup)
        }
        try await statsEngine.updateCollectionMetadata(for: collection)
    }

    public func cleanupEmptyShards(for collection: String) async throws {
        let shardManager = try await getOrCreateShardManager(for: collection)
        try await shardManager.cleanupEmptyShards()
    }

}

/// An extension to the `Sequence` protocol that provides additional functionality
/// for sequences. This extension can be used to add custom methods or computed
/// properties to all types conforming to `Sequence`.
extension Sequence {
    /// Asynchronously performs the given operation on each element of the collection.
    ///
    /// This method allows you to iterate over the elements of the collection and
    /// execute an asynchronous operation for each element. The operation can throw
    /// errors, which will be propagated to the caller.
    ///
    /// - Parameter operation: An asynchronous closure that takes an element of the
    ///   collection as its parameter and performs an operation.
    /// - Throws: Rethrows any error thrown by the `operation` closure.
    /// - Note: The order in which the `operation` is applied to the elements is not
    ///   guaranteed to be sequential.
    func asyncForEach(
        _ operation: (Element) async throws -> Void
    ) async rethrows {
        for element in self {
            try await operation(element)
        }
    }
    /// Applies the given asynchronous transformation to each element of the collection concurrently and returns an array of the transformed elements.
    /// 
    /// - Parameter transform: An asynchronous closure that takes an element of the collection as its argument and returns a transformed value.
    /// - Returns: An array containing the transformed elements.
    /// - Throws: Rethrows any error thrown by the `transform` closure.
    func concurrentMap<T>(_ transform: @escaping (Element) async throws -> T)
        async rethrows -> [T]
    {
        try await withThrowingTaskGroup(of: T.self) { group in
            forEach { element in
                group.addTask { try await transform(element) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
    }
}

/// An extension to the `Dictionary` type that provides additional functionality
/// specific to the `StorageEngine` implementation in the NyaruDB2 project.
extension Dictionary {
    /// Asynchronously iterates over each key-value pair in the storage engine.
    ///
    /// - Parameter body: A closure that takes a key and a value as its parameters.
    ///   The closure is executed asynchronously for each key-value pair in the storage.
    ///   It can throw an error, which will propagate out of this method.
    /// - Throws: Rethrows any error thrown by the `body` closure.
    /// - Note: The iteration order is not guaranteed.
    func forEachAsync(_ body: (Key, Value) async throws -> Void) async rethrows
    {
        for (key, value) in self {
            try await body(key, value)
        }
    }
}
