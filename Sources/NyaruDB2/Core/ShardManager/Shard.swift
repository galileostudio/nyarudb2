import Foundation

/// A structure that represents metadata for a shard in the database.
///
/// `ShardMetadata` contains information about the shard, such as the number of documents it holds,
/// and timestamps for when it was created and last updated.
///
/// - Properties:
///   - documentCount: The total number of documents stored in the shard.
///   - createdAt: The date and time when the shard was created.
///   - updatedAt: The date and time when the shard was last updated.
public struct ShardMetadata: Codable {
    public var documentCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    /// Initializes a new instance of the `Shard` class.
    ///
    /// - Parameters:
    ///   - documentCount: The number of documents in the shard. Defaults to `0`.
    ///   - createdAt: The date and time when the shard was created. Defaults to the current date and time.
    ///   - updatedAt: The date and time when the shard was last updated. Defaults to the current date and time.
    public init(
        documentCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.documentCount = documentCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Represents a shard in the database, which is a unit of data storage and management.
///
/// A `Shard` contains metadata, a unique identifier, and configuration details such as
/// compression and file protection settings. It also includes a cache for storing documents.
///
/// - Properties:
///   - `id`: A unique identifier for the shard.
///   - `url`: The file URL where the shard is stored.
///   - `metadata`: Metadata associated with the shard, such as its state and configuration.
///   - `compressionMethod`: The method used to compress data within the shard.
///   - `fileProtectionType`: The file protection level applied to the shard's storage.
///   - `documentCache`: An in-memory cache for storing documents, keyed by their identifiers.
public class Shard {
    public let id: String
    public let url: URL
    public private(set) var metadata: ShardMetadata
    public let compressionMethod: CompressionMethod
    public let fileProtectionType: FileProtectionType
    private var documentCache: NSCache<NSString, NSArray> = NSCache()

    /// Initializes a new instance of `Shard`.
    ///
    /// - Parameters:
    ///   - id: A unique identifier for the shard.
    ///   - url: The file URL where the shard is stored.
    ///   - metadata: Metadata associated with the shard. Defaults to an empty `ShardMetadata` instance.
    ///   - compressionMethod: The compression method used for the shard. Defaults to `.none`.
    ///   - fileProtectionType: The file protection type for the shard. Defaults to `.none`.
    public init(
        id: String,
        url: URL,
        metadata: ShardMetadata = .init(),
        compressionMethod: CompressionMethod = .none,
        fileProtectionType: FileProtectionType = .none
    ) {
        self.id = id
        self.url = url
        self.metadata = metadata
        self.compressionMethod = compressionMethod
        self.fileProtectionType = fileProtectionType
    }

    /// Updates the metadata of the shard with the given document count and update timestamp.
    ///
    /// - Parameters:
    ///   - documentCount: The number of documents in the shard.
    ///   - updatedAt: The date and time when the shard was last updated.
    public func updateMetadata(documentCount: Int, updatedAt: Date) {
        self.metadata.documentCount = documentCount
        self.metadata.updatedAt = updatedAt
    }

    /// Loads and decodes documents of the specified type from the shard.
    ///
    /// This method asynchronously retrieves and decodes documents stored in the shard
    /// into an array of the specified `Codable` type.
    ///
    /// - Returns: An array of decoded documents of type `T`.
    /// - Throws: An error if the documents cannot be loaded or decoded.
    /// - Note: Ensure that the type `T` conforms to the `Codable` protocol.
    public func loadDocuments<T: Codable>() async throws -> [T] {
        let key = cacheKey(for: T.self)
        if let cached = documentCache.object(forKey: key) as? [T] {
            return cached
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let compressedData = try Data(contentsOf: url)
        let data = try decompressData(compressedData, method: compressionMethod)
        let docs = try JSONDecoder().decode([T].self, from: data)
        documentCache.setObject(docs as NSArray, forKey: key)
        return docs
    }

    /// Saves an array of documents to the shard.
    ///
    /// - Parameter documents: An array of documents conforming to the `Codable` protocol to be saved.
    /// - Throws: An error if the save operation fails.
    /// - Note: This is an asynchronous function and should be called with `await`.
    public func saveDocuments<T: Codable>(_ documents: [T]) async throws {
        let data = try JSONEncoder().encode(documents)
        let compressedData = try compressData(data, method: compressionMethod)
        try compressedData.write(to: url, options: .atomic)

        // `FileProtectionType` é um conceito de iOS. Em macOS, definir o atributo
        // de proteção pode falhar; como `.none` significa "sem proteção", pular a
        // chamada nesse caso é equivalente e mantém a portabilidade (inclusive no CI macOS).
        if fileProtectionType != .none {
            try FileManager.default.setAttributes(
                [.protectionKey: fileProtectionType],
                ofItemAtPath: url.path
            )
        }

        metadata.documentCount = documents.count
        metadata.updatedAt = Date()
        try persistMetadata()

        let key = cacheKey(for: T.self)
        documentCache.setObject(documents as NSArray, forKey: key)
    }

    /// Persiste o metadado do shard em um arquivo sidecar `<id>.nyaru.meta.json`.
    ///
    /// Sem isto, `ShardManager.loadShards()` recria cada shard com metadados padrão
    /// (`documentCount = 0`) ao reabrir o banco, o que quebra `countDocuments(in:)`
    /// e o filtro de shards do query planner (`metadata.documentCount > 0`).
    private func persistMetadata() throws {
        let metaURL = url.appendingPathExtension("meta.json")
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metaURL, options: .atomic)
    }

    /// Appends a document to the shard.
    ///
    /// - Parameters:
    ///   - document: The document to append, conforming to the `Codable` protocol.
    ///   - jsonData: The JSON-encoded data representation of the document.
    public func appendDocument<T: Codable>(_ document: T, jsonData: Data)
        async throws
    {
        // `loadDocuments()` já retorna [] quando o arquivo ainda não existe.
        // Qualquer OUTRA falha (corrupção, erro de decode) precisa ser propagada:
        // o código antigo usava `try?`, então uma leitura que falhava virava []
        // e o `saveDocuments` abaixo sobrescrevia o shard com apenas o novo
        // documento — destruindo silenciosamente os dados já existentes.
        var documents: [T] = try await loadDocuments()
        documents.append(document)
        try await saveDocuments(documents)
    }

    /// Loads documents lazily as an asynchronous throwing stream.
    ///
    /// This method returns an `AsyncThrowingStream` that allows you to iterate over
    /// documents of the specified type `T` conforming to `Codable`. The documents
    /// are loaded lazily, meaning they are fetched and decoded on demand as you
    /// iterate through the stream.
    ///
    /// - Returns: An `AsyncThrowingStream` of type `T` that provides access to the
    ///   documents. The stream may throw an error during iteration if an issue
    ///   occurs while loading or decoding the documents.
    ///
    /// - Throws: An error if the stream encounters an issue while loading or decoding
    ///   the documents.
    public func loadDocumentsLazy<T: Codable>() -> AsyncThrowingStream<T, Error>
    {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let docs: [T] = try await self.loadDocuments()
                    for doc in docs {
                        continuation.yield(doc)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Generates a cache key for a given Codable type.
    ///
    /// - Parameter type: The type conforming to `Codable` for which the cache key is generated.
    /// - Returns: An `NSString` representing the cache key for the specified type.
    private func cacheKey<T: Codable>(for type: T.Type) -> NSString {
        return "\(String(describing: type))_docs" as NSString
    }

}
