import Foundation

/// A protocol that represents a key used for indexing in a database.
///
/// Types conforming to this protocol must be both `Hashable` and `Codable`,
/// ensuring that they can be used as unique keys in collections like dictionaries
/// and can be serialized/deserialized for persistence or transmission.
public protocol IndexKey: Hashable, Codable {}


/// Extends the `String` type to conform to the `IndexKey` protocol.
///
/// This allows `String` values to be used as keys in the indexing system
/// managed by the `IndexManager`. By conforming to `IndexKey`, `String`
/// gains compatibility with any functionality or constraints defined by
/// the `IndexKey` protocol.
extension String: IndexKey {}

/// A structure that represents metrics for an index, providing insights into its usage and value distribution.
///
/// - Properties:
///   - `accessCount`: The number of times the index has been accessed. Defaults to `0`.
///   - `lastAccess`: The date and time when the index was last accessed. Defaults to `.distantPast`.
///   - `valueDistribution`: A dictionary that tracks the distribution of values associated with the index,
///     where the keys are the values and the values are their respective counts. Defaults to an empty dictionary.
public struct IndexMetrics {
    public var accessCount: Int = 0
    public var lastAccess: Date = .distantPast
    public var valueDistribution: [AnyHashable: Int] = [:]
}


/// An actor responsible for managing indices in a database system.
///
/// `IndexManager` provides functionality to handle the creation, storage, and
/// metrics of indices for efficient data retrieval. It is generic over a `Key`
/// type that conforms to both `IndexKey` and `Comparable` protocols, ensuring
/// that the keys used in the indices are suitable for indexing and comparison.
///
/// - Note: This actor is designed to be thread-safe, leveraging Swift's actor
///   model to protect its internal state from concurrent access.
///
/// Properties:
/// - `indices`: A dictionary mapping index names (`String`) to their corresponding
///   `BTreeIndex` instances, which store the actual index data.
/// - `createdIndexes`: A set of index names (`String`) that have been created,
///   ensuring uniqueness and preventing duplication.
/// - `metrics`: A dictionary mapping index names (`String`) to their associated
///   `IndexMetrics`, which provide performance and usage statistics for each index.
public actor IndexManager<Key: IndexKey & Comparable> {
    private var indices: [String: BTreeIndex<Key>] = [:]
    private var createdIndexes: Set<String> = []
    private var metrics: [String: IndexMetrics] = [:]
    private let storageFormat: StorageFormat
    
    /// Initializes a new instance of the `IndexManager` class.
    ///
    /// This initializer sets up the `IndexManager` with default values.
    public init(storageFormat: StorageFormat = .json) {
        self.storageFormat = storageFormat
    }
    
    
    /// Creates an index for the specified field with a given minimum degree.
    ///
    /// - Parameters:
    ///   - field: The name of the field for which the index will be created.
    ///   - minimumDegree: The minimum degree of the B-tree used for the index. Defaults to 2.
    /// - Note: This function is asynchronous and may involve I/O operations.
    public func createIndex(for field: String, minimumDegree: Int = 2) async {
        if indices[field] == nil {
            let btree = BTreeIndex<Key>(minimumDegree: minimumDegree)
            indices[field] = btree
            createdIndexes.insert(field)
            metrics[field] = IndexMetrics()
        }
    }
    
    
    /// Inserts a new index entry into the index manager.
    ///
    /// - Parameters:
    ///   - field: The name of the index field to insert the entry into.
    ///   - key: The unique key associated with the index entry.
    ///   - data: The data to be stored in the index entry.
    /// - Note: This is an asynchronous operation.
    public func insert(index field: String, key: Key, data: Data) async {
        if var m = metrics[field] {
            m.accessCount += 1
            m.lastAccess = Date()
            m.valueDistribution[key, default: 0] += 1  // Increment the frequency for this key
            metrics[field] = m
        }
        
        guard let indexTree = indices[field] else {
            print(
                "Índice para o campo \(field) não foi criado. Utilize createIndex(for:) primeiro."
            )
            return
        }
        await indexTree.insert(key: key, data: data)
    }
    
    
    /// Searches for records in the database that match the specified field and value.
    ///
    /// - Parameters:
    ///   - field: The name of the field to search for.
    ///   - value: The value to match against the specified field.
    /// - Returns: An array of `Data` objects representing the matching records.
    /// - Note: This is an asynchronous function and should be awaited.
    public func search(_ field: String, value: Key) async -> [Data] {
        if var m = metrics[field] {
            m.accessCount += 1
            m.lastAccess = Date()
            metrics[field] = m
        }
        
        guard let indexTree = indices[field] else { return [] }
        return await indexTree.search(key: value) ?? []
    }
    
    /// Retrieves the metrics for all indexes managed by the `IndexManager`.
    ///
    /// - Returns: A dictionary where the keys are index names (as `String`) and the values are
    ///   `IndexMetrics` objects containing the metrics for each index.
    public func getMetrics() -> [String: IndexMetrics] {
        return metrics
    }
    
    /// Asynchronously retrieves the count of indices.
    ///
    /// - Returns: A dictionary where the keys are index names (as `String`) and the values are their respective counts (as `Int`).
    public func getIndexCounts() async -> [String: Int] {
        var counts = [String: Int]()
        for (field, btree) in indices {
            counts[field] = await btree.getTotalCount()
        }
        return counts
    }
    
    /// Lists all the indexes managed by the `IndexManager`.
    ///
    /// - Returns: An array of strings representing the names of all indexes.
    public func listIndexes() -> [String] {
        return Array(indices.keys)
    }
    
    /// Drops the index associated with the specified field.
    ///
    /// - Parameter field: The name of the field for which the index should be dropped.
    /// - Returns: A Boolean value indicating whether the index was successfully dropped.
    public func dropIndex(for field: String) -> Bool {
        guard indices[field] != nil else {
            return false
        }
        indices.removeValue(forKey: field)
        createdIndexes.remove(field)
        metrics.removeValue(forKey: field)
        return true
    }
    
    /// Inserts or updates an index for the specified field using the provided JSON data.
    ///
    /// - Parameters:
    ///   - field: The name of the field for which the index is being upserted.
    ///   - jsonData: The JSON data containing the index information.
    /// - Throws: An error if the operation fails.
    /// - Note: This method is asynchronous and must be called with `await`.
    public func upsertIndex(for field: String, jsonData: Data) async throws {
        await createIndex(for: field)
        
        let keyString = try DynamicDecoder.extractValue(
            from: jsonData,
            key: field,
            forIndex: true,
            storageFormat: self.storageFormat
        )
        
        guard let key = keyString as? Key else {
            print("Não foi possível converter a chave para o tipo Key.")
            return
        }
        
        await insert(index: field, key: key, data: jsonData)
    }
    
}
