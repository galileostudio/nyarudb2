import Foundation

/// A singleton class responsible for managing and providing access to document collections.
/// The `CollectionCatalog` class maintains a registry of collections, allowing for centralized
/// management and retrieval of `DocumentCollection` instances. It is designed as a singleton
/// to ensure a single, globally accessible instance throughout the application.

public class CollectionCatalog {

    public static let shared = CollectionCatalog()

    private var collections: [String: DocumentCollection] = [:]

    private init() {}

    /// Creates a new collection with the specified parameters.
    ///
    /// - Parameters:
    ///  - name: The name of the collection to be created.
    ///  - options: Additional options or configurations for the collection.
    /// - Throws: An error if the collection cannot be created, such as if a collection
    ///  with the same name already exists or if there is an issue with the provided options.
    /// - Returns: A reference to the newly created collection.

    public func createCollection(
        storage: StorageEngine,
        statsEngine: StatsEngine,
        name: String,
        indexes: [String] = [],
        partitionKey: String
    ) -> DocumentCollection {
        let newCollection = DocumentCollection(
            storage: storage,
            statsEngine: statsEngine,
            name: name,
            indexes: indexes,
            partitionKey: partitionKey
        )
        collections[name] = newCollection
        return newCollection
    }

    /// Retrieves a `DocumentCollection` with the specified name.
    ///
    /// - Parameter name: The name of the collection to retrieve.
    /// - Returns: The `DocumentCollection` associated with the given name, or `nil` if no such collection exists.
    public func getCollection(named name: String) -> DocumentCollection? {
        return collections[name]
    }

    /// Removes a collection with the specified name from the storage engine.
    ///
    /// - Parameters:
    ///   - name: The name of the collection to be removed.
    ///   - storage: The storage engine instance where the collection resides.
    /// - Throws: An error if the operation fails.
    /// - Note: This is an asynchronous function and must be called with `await`.
    public func removeCollection(named name: String, storage: StorageEngine)
        async throws
    {
        try await storage.dropCollection(name)
        collections.removeValue(forKey: name)
    }

    /// Updates the configuration of a collection with the specified name.
    ///
    /// - Parameters:
    ///   - name: The name of the collection to update.
    ///   - storage: The storage engine to be used for the collection.
    ///   - partitionKey: The partition key to be used for the collection.
    /// - Throws: An error if the update operation fails.
    /// - Note: This is an asynchronous operation.
    public func updateCollectionConfiguration(
        named name: String,
        storage: StorageEngine,
        partitionKey: String
    ) async throws {

        guard collections[name] != nil else {
            throw NSError(
                domain: "CollectionEngine",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Collection not found"]
            )
        }

        await storage.setPartitionKey(
            for: name,
            key: partitionKey
        )
    }

    /// Retrieves a list of all document collections.
    ///
    /// - Returns: An array containing all `DocumentCollection` instances
    ///   currently stored in the catalog.
    public func listCollections() -> [DocumentCollection] {
        return Array(collections.values)
    }

}
