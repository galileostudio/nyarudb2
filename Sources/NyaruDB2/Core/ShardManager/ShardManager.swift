import Foundation

/// An enumeration representing errors that can occur within the `ShardManager`.
/// 
/// This enum conforms to the `Error` protocol, allowing instances of it to be
/// thrown and caught as part of error handling in Swift.
public enum ShardManagerError: Error {
    case shardNotFound(shardID: String)
    case shardAlreadyExists(shardID: String)
    case failedToSaveShard(shardID: String)
    case unknown(Error)
}

/// The `ShardManager` class is responsible for managing a collection of `Shard` objects.
/// It provides functionality for storing, retrieving, and managing shards, as well as handling
/// file-related configurations and compression methods.
///
/// - Properties:
///   - `shards`: A dictionary mapping `String` keys to `Shard` objects, representing the managed shards.
///   - `baseURL`: The base URL where shard files are stored.
///   - `compressionMethod`: The method used for compressing shard data.
///   - `fileProtectionType`: The file protection type applied to shard files.
///   - `autoMergeTask`: An optional asynchronous task for automatically merging shards.
public class ShardManager {
    private var shards: [String: Shard] = [:]
    private let baseURL: URL
    private let compressionMethod: CompressionMethod
    public let fileProtectionType: FileProtectionType

    private var autoMergeTask: Task<Void, Never>?

    /// Initializes a new instance of `ShardManager`.
    ///
    /// - Parameters:
    ///   - baseURL: The base URL where the shard files will be stored.
    ///   - compressionMethod: The method used for compressing shard data. Defaults to `.none`.
    ///   - fileProtectionType: The file protection level applied to the shard files. Defaults to `.none`.
    public init(
        baseURL: URL,
        compressionMethod: CompressionMethod = .none,
        fileProtectionType: FileProtectionType = .none
    ) {
        self.baseURL = baseURL

        try? FileManager.default.createDirectory(
            at: baseURL,
            withIntermediateDirectories: true
        )
        self.compressionMethod = compressionMethod
        self.fileProtectionType = fileProtectionType

        startAutoMergeProcess()
    }

    /// Deinitializer for the `ShardManager` class.
    /// 
    /// This is called automatically when the `ShardManager` instance is deallocated.
    /// Use this to clean up resources or perform any necessary teardown operations.
    deinit {
        autoMergeTask?.cancel()
    }

    /// Creates a new shard with the specified identifier.
    ///
    /// - Parameter id: A unique identifier for the shard to be created.
    /// - Returns: The newly created `Shard` instance.
    /// - Throws: An error if the shard creation fails.
    /// - Note: This method is asynchronous and must be called with `await`.
    public func createShard(withID id: String) async throws -> Shard {
        guard shards[id] == nil else {
            throw ShardManagerError.shardAlreadyExists(shardID: id)
        }

        let shardURL = baseURL.appendingPathComponent("\(id).nyaru")

        let shard = Shard(
            id: id,
            url: shardURL,
            compressionMethod: compressionMethod,
            fileProtectionType: fileProtectionType
        )

        shards[id] = shard

        try await shard.saveDocuments([] as [String])

        return shard
    }

    /// Retrieves an existing shard with the specified identifier or creates a new one if it does not exist.
    ///
    /// - Parameter id: A unique identifier for the shard.
    /// - Returns: The shard associated with the given identifier.
    /// - Throws: An error if the shard cannot be retrieved or created.
    /// - Note: This method is asynchronous and must be awaited.
    public func getOrCreateShard(id: String) async throws -> Shard {
        if let shard = shards[id] {
            return shard
        }
        return try await createShard(withID: id)
    }

    /// Retrieves a shard by its unique identifier.
    ///
    /// - Parameter id: The unique identifier of the shard to retrieve.
    /// - Returns: The `Shard` instance corresponding to the provided identifier.
    /// - Throws: An error if the shard cannot be found or if there is an issue retrieving it.
    public func getShard(byID id: String) throws -> Shard {
        guard let shard = shards[id] else {
            throw ShardManagerError.shardNotFound(shardID: id)
        }
        return shard
    }

    /// Retrieves metadata information for all shards.
    ///
    /// - Returns: An array of `ShardMetadataInfo` objects containing metadata
    ///            details for all shards managed by the `ShardManager`.
    public func allShardInfo() -> [ShardMetadataInfo] {
        shards.values.map { shard in
            ShardMetadataInfo(
                id: shard.id,
                url: shard.url,
                metadata: shard.metadata
            )
        }
    }

    /// Loads all shards into memory.
    ///
    /// This method is responsible for initializing and loading the shards
    /// that are managed by the `ShardManager`. It ensures that the shards
    /// are properly prepared for use within the database system.
    public func loadShards() {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: baseURL,
                includingPropertiesForKeys: nil
            )
        else {
            print(
                "[ShardManager] Failed to read directory contents at \(baseURL)"
            )
            return
        }

        let loadedShards =
            files
            // Consider shard files with ".nyaru" extension
            .filter { $0.pathExtension == "nyaru" }
            .compactMap { url -> (String, Shard)? in
                let id = url.deletingPathExtension().lastPathComponent
                do {
                    let metadata = try loadMetadata(from: url)
                    print("[ShardManager] Successfully loaded shard \(id)")
                    return (id, Shard(id: id, url: url, metadata: metadata))
                } catch {
                    print(
                        "[ShardManager] Error loading metadata for shard \(id): \(error.localizedDescription)"
                    )
                    print(
                        "[ShardManager] Creating shard \(id) with default metadata"
                    )
                    return (
                        id, Shard(id: id, url: url, metadata: ShardMetadata())
                    )
                }
            }

        shards = Dictionary(uniqueKeysWithValues: loadedShards)
        print("[ShardManager] Loaded \(shards.count) shards")
    }

    /// Starts the automatic merge process for managing shards.
    ///
    /// This method initiates a background process that periodically checks
    /// and merges smaller shards into larger ones to optimize storage and
    /// improve query performance. The exact behavior and frequency of the
    /// merge process depend on the implementation details and configuration
    /// of the shard manager.
    private func startAutoMergeProcess() {
        autoMergeTask = Task<Void, Never> { () async -> Void in
            while !Task.isCancelled {
                do {
                    // Check and merge small shards (this is a placeholder for the actual merge logic)
                    try await mergeSmallShards()
                } catch {
                    print("Auto-merge error: \(error)")
                }
                // Sleep for 60 seconds before checking again.
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    /// Merges small shards into larger ones to optimize storage and performance.
    ///
    /// This asynchronous function identifies shards that are below a certain size
    /// threshold and combines them into larger shards. This process helps to reduce
    /// fragmentation and improve the efficiency of shard management.
    ///
    /// - Throws: An error if the merging process encounters an issue.
    private func mergeSmallShards() async throws {
        let threshold = 100

        let candidateShards = shards.values
            .filter { $0.metadata.documentCount < threshold }
            .sorted { $0.metadata.createdAt < $1.metadata.createdAt }

        guard candidateShards.count > 1 else { return }

        let primaryShard = candidateShards.first!

        let accumulatedDocs = try await candidateShards.dropFirst()
            .asyncCompactMap { try await processAndRemoveShard($0) }
            .flatMap { $0 }

        let primaryDocs = try await loadShardDocuments(primaryShard)
        let mergedDocs = primaryDocs + accumulatedDocs

        try saveMergedDocuments(mergedDocs, to: primaryShard)

        primaryShard.updateMetadata(
            documentCount: mergedDocs.count,
            updatedAt: Date()
        )

        print(
            "Merged \(accumulatedDocs.count) documents from \(candidateShards.count - 1) small shards into shard \(primaryShard.id)"
        )
    }



    /// Processes the given shard and removes it from the system.
    ///
    /// This asynchronous function performs necessary operations on the provided shard
    /// and then removes it. The exact processing logic depends on the implementation.
    ///
    /// - Parameter shard: The `Shard` instance to be processed and removed.
    /// - Returns: An optional array of `Any` containing the results of the processing, 
    ///   or `nil` if no results are produced.
    /// - Throws: An error if the processing or removal fails.
    private func processAndRemoveShard(_ shard: Shard) async throws -> [Any]? {
        do {
            let docs = try await loadShardDocuments(shard)
            try removeShardFiles(shard)
            removeShardFromMemory(shard)
            return docs.isEmpty ? nil : docs
        } catch {
            print("Warning: Failed to process shard \(shard.id): \(error)")
            return nil
        }
    }

    /// Loads the documents from the specified shard asynchronously.
    ///
    /// - Parameter shard: The shard from which to load the documents.
    /// - Returns: An array of documents loaded from the shard.
    /// - Throws: An error if the documents cannot be loaded.
    private func loadShardDocuments(_ shard: Shard) async throws -> [Any] {
        let data = try Data(contentsOf: shard.url)
        let decompressed = try decompressData(
            data,
            method: shard.compressionMethod
        )
        let json = try JSONSerialization.jsonObject(
            with: decompressed,
            options: []
        )
        return (json as? [Any]) ?? []
    }

    /// Saves the merged documents to the specified shard.
    ///
    /// - Parameters:
    ///   - documents: An array of documents to be saved. The type of elements in the array is `Any`.
    ///   - shard: The shard where the documents will be saved.
    /// - Throws: An error if the save operation fails.
    private func saveMergedDocuments(_ documents: [Any], to shard: Shard) throws
    {
        let jsonData = try JSONSerialization.data(
            withJSONObject: documents,
            options: []
        )
        let compressedData = try compressData(
            jsonData,
            method: shard.compressionMethod
        )
        try compressedData.write(to: shard.url, options: .atomic)
    }

    /// Removes the files associated with the specified shard from the file system.
    ///
    /// - Parameter shard: The shard whose files are to be removed.
    /// - Throws: An error if the file removal process fails.
    private func removeShardFiles(_ shard: Shard) throws {
        try FileManager.default.removeItem(at: shard.url)
        let metaURL = shard.url.appendingPathExtension("meta.json")
        try? FileManager.default.removeItem(at: metaURL)
    }

    /// Removes the specified shard from memory.
    ///
    /// - Parameter shard: The `Shard` instance to be removed from memory.
    private func removeShardFromMemory(_ shard: Shard) {
        if let key = shards.first(where: { $0.value === shard })?.key {
            shards.removeValue(forKey: key)
        }
    }

    /// Loads the metadata for a shard from the specified URL.
    ///
    /// - Parameter shardURL: The URL of the shard from which to load metadata.
    /// - Returns: A `ShardMetadata` object containing the metadata of the shard.
    /// - Throws: An error if the metadata cannot be loaded or parsed.
    private func loadMetadata(from shardURL: URL) throws -> ShardMetadata {
        let metaURL = shardURL.appendingPathExtension("meta.json")
        let data = try Data(contentsOf: metaURL)
        return try JSONDecoder().decode(ShardMetadata.self, from: data)
    }

    /// Retrieves all shards managed by the `ShardManager`.
    ///
    /// - Returns: An array of `Shard` objects representing all the shards.
    public func allShards() -> [Shard] {
        return Array(shards.values)
    }

    /// Cleans up and removes any empty shards from the database.
    ///
    /// This method asynchronously iterates through the shards managed by the
    /// `ShardManager` and deletes any shards that are determined to be empty.
    ///
    /// - Throws: An error if the cleanup process encounters any issues.
    public func cleanupEmptyShards() async throws {
        try shards
            .filter { $0.value.metadata.documentCount == 0 }
            .forEach { key, shard in
                try FileManager.default.removeItem(at: shard.url)
                try? FileManager.default.removeItem(
                    at: shard.url.appendingPathExtension("meta.json")
                )
                shards.removeValue(forKey: key)
            }
    }

    /// Removes all shards managed by the `ShardManager`.
    ///
    /// This method deletes all shard files or data associated with the `ShardManager`.
    /// Use this method with caution as it will result in the loss of all stored data.
    ///
    /// - Throws: An error if the operation fails, such as due to file system issues or
    ///           insufficient permissions.
    public func removeAllShards() throws {
        for (_, shard) in shards {
            try FileManager.default.removeItem(at: shard.url)
            let metaURL = shard.url.appendingPathExtension("meta.json")
            try? FileManager.default.removeItem(at: metaURL)
        }
        shards.removeAll()
    }


}

/// An extension to the `Sequence` protocol that provides additional functionality
/// for sequences. This extension can be used to add custom methods or computed
/// properties that operate on any type conforming to `Sequence`.
extension Sequence {
    /// Asynchronously transforms each element of the collection using the given closure
    /// and returns an array containing the non-nil results.
    ///
    /// This method applies the `transform` closure to each element of the collection
    /// concurrently. If the closure returns a non-nil value, that value is included
    /// in the resulting array. If the closure returns `nil`, the element is skipped.
    ///
    /// - Parameter transform: An asynchronous closure that takes an element of the
    ///   collection as its parameter and returns an optional transformed value.
    /// - Returns: An array of the non-nil results of calling the `transform` closure
    ///   on each element of the collection.
    /// - Throws: Rethrows any error thrown by the `transform` closure.
    func asyncCompactMap<T>(
        _ transform: (Element) async throws -> T?
    ) async rethrows -> [T] {
        var results = [T]()
        for element in self {
            if let transformed = try await transform(element) {
                results.append(transformed)
            }
        }
        return results
    }
}
