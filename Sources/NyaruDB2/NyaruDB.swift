import Crypto
import Foundation

/// Configuration shared by every collection opened from a single `NyaruDB`
/// instance.
///
/// `DatabaseOptions` controls compression, encryption, serialization format,
/// file protection, and the fragmentation threshold that drives compaction
/// hints. These options are applied to all collections within the database
/// and are persisted in each collection's manifest at creation time.
///
/// Changing options after collections exist has no effect on existing
/// collections — the manifest is frozen at creation. Only `encryptionKey`
/// is omitted from the manifest (it is provided at open time) so the key
/// can be rotated or supplied from the Keychain without touching on-disk data.
public struct DatabaseOptions: Sendable {
  /// The compression method applied to record payloads in every shard file.
  ///
  /// Default: `.none`. Consider `.gzip` for portable compression that works
  /// on all platforms.
  public var compression: CompressionMethod

  /// The iOS file protection level applied to every shard file (no-op on
  /// non-Apple platforms).
  ///
  /// Default: `.none`. Set to `.completeUnlessOpen` for data-in-rest
  /// protection on iOS devices.
  public var fileProtection: FileProtection

  /// The serialization format used for encoding and decoding documents.
  ///
  /// Default: `.json`. Set to `.msgpack` for more compact storage.
  public var format: SerializationFormat

  /// An optional AES-256-GCM symmetric key. When set, all shard payloads and
  /// collection manifests are encrypted before being written to disk and
  /// decrypted on read.
  ///
  /// Default: `nil` (no encryption).
  ///
  /// - Important: The encryption key itself is never persisted. It must be
  ///   provided every time the database is opened. Store the key in the
  ///   system Keychain and use `NyaruCrypto.generateRandomKey()` to create it.
  public var encryptionKey: SymmetricKey?

  /// The ratio of tombstoned records to total records above which
  /// `needsCompaction()` returns `true` for a collection.
  ///
  /// Default: `0.2` (20%).
  public var maxFragmentation: Double

  /// Creates database options with sensible defaults.
  ///
  /// - Parameters:
  ///   - compression: Payload compression for all collections.
  ///   - fileProtection: iOS file protection for shard files.
  ///   - format: Document serialization format (`.json` or `.msgpack`).
  ///   - encryptionKey: Optional AES-256-GCM key for encrypting data at rest.
  ///   - maxFragmentation: Tombstone ratio that triggers compaction hints.
  public init(
    compression: CompressionMethod = .none,
    fileProtection: FileProtection = .none,
    format: SerializationFormat = .json,
    encryptionKey: SymmetricKey? = nil,
    maxFragmentation: Double = 0.2
  ) {
    self.compression = compression
    self.fileProtection = fileProtection
    self.format = format
    self.encryptionKey = encryptionKey
    self.maxFragmentation = maxFragmentation
  }
}

/// The root entry point for the NyaruDB embedded document database.
///
/// `NyaruDB` is an actor that serialises all file I/O through Swift's
/// concurrency model. It manages the lifecycle of collections, handles
/// manifest I/O, and coordinates durability across all open collections.
///
/// **Opening a database.** Provide a directory URL or filesystem path:
///
/// ```swift
/// let db = try await NyaruDB(path: "path/to/database")
/// ```
///
/// **Opening collections.** Use `collection(_:of:options:)` to open or create
/// a typed collection:
///
/// ```swift
/// let users = try await db.collection("users", of: User.self)
/// ```
///
/// **Lifecycle.** Call `sync()` to flush pending index and shard I/O, and
/// `close()` to shut down cleanly. After `close()`, the instance cannot be
/// used again.
///
/// - Note: A single `NyaruDB` instance corresponds to one directory on disk.
///   Opening multiple instances pointing at the same directory is not supported.
public actor NyaruDB {
  private let baseURL: URL
  private let options: DatabaseOptions
  private var cores: [String: CollectionCore] = [:]
  private var isClosed = false

  /// Opens or creates a database at the given directory URL.
  ///
  /// If the directory does not exist, it is created (with intermediate
  /// directories). All collection data is stored as subdirectories within
  /// this directory.
  ///
  /// - Parameters:
  ///   - path: The directory URL for the database.
  ///   - options: Database-wide configuration applied to all collections.
  /// - Throws: `NyaruError.ioError` if the directory cannot be created.
  public init(path: URL, options: DatabaseOptions = DatabaseOptions()) throws {
    self.baseURL = path
    self.options = options
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
  }

  /// Opens or creates a database at the given filesystem path string.
  ///
  /// Convenience initialiser that converts the string to a directory URL and
  /// delegates to `init(path:options:)`.
  ///
  /// - Parameters:
  ///   - path: The filesystem path to the database directory.
  ///   - options: Database-wide configuration.
  /// - Throws: `NyaruError.ioError` if the directory cannot be created.
  public init(path: String, options: DatabaseOptions = DatabaseOptions()) throws {
    try self.init(
      path: URL(fileURLWithPath: path, isDirectory: true),
      options: options
    )
  }

  /// Ensures the database has not been closed.
  ///
  /// All public methods that interact with storage must call this first.
  ///
  /// - Throws: `NyaruError.databaseClosed` if `close()` was already called.
  private func ensureOpen() throws {
    if isClosed { throw NyaruError.databaseClosed }
  }

  // MARK: - Collections

  /// Opens an existing collection or creates a new one with the given name
  /// and document type.
  ///
  /// When opening an existing collection, the provided options are validated
  /// against the persisted manifest. If the base configuration (id field,
  /// partition key, compression, encryption, format) does not match,
  /// `collectionTypeMismatch` is thrown.
  ///
  /// Indexed fields **can** be added across opens — new fields are populated
  /// by scanning all shards on first open. The id field is always indexed
  /// automatically.
  ///
  /// - Parameters:
  ///   - name: The collection name.
  ///   - type: The document type, which must conform to `Codable & Sendable`.
  ///   - collectionOptions: Per-collection options (id field, partition key,
  ///     indexed fields).
  /// - Returns: A typed `NyaruCollection<T>` handle.
  /// - Throws: `NyaruError.collectionTypeMismatch` if options conflict with the
  ///   persisted manifest, `NyaruError.databaseClosed` if closed.
  public func collection<T: Codable & Sendable>(
    _ name: String,
    of type: T.Type,
    options collectionOptions: CollectionOptions = CollectionOptions()
  ) async throws -> NyaruCollection<T> {
    try ensureOpen()
    let core = try await openCore(name: name, options: collectionOptions)

    return NyaruCollection(
      name: name,
      core: core,
      partitionKey: await core.manifest.partitionKey,
      format: options.format,
      idField: collectionOptions.idField,
      indexedFields: collectionOptions.indexedFields
    )
  }

  /// Internal: opens or reuses the `CollectionCore` for a given name.
  ///
  /// If the core is already in memory, it validates the manifest. Otherwise
  /// it reads or creates the manifest on disk and initialises a new core.
  private func openCore(name: String, options collectionOptions: CollectionOptions) async throws
    -> CollectionCore
  {
    let directory = baseURL.appendingPathComponent(
      CollectionCore.sanitizeFileComponent(name), isDirectory: true
    )
    let manifestURL = directory.appendingPathComponent("manifest.json")

    let requested = CollectionManifest(
      name: name,
      idField: collectionOptions.idField,
      partitionKey: collectionOptions.partitionKey,
      indexedFields: collectionOptions.indexedFields.sorted(),
      compression: options.compression,
      fileProtection: options.fileProtection,
      format: options.format,
      isEncrypted: options.encryptionKey != nil,
      maxFragmentation: options.maxFragmentation
    )

    if let existing = cores[name] {
      guard await existing.manifest.sameBase(as: requested) else {
        throw NyaruError.collectionTypeMismatch(name)
      }
      try await existing.setIndexedFields(requested.indexedFields)
      return existing
    }

    let manifest: CollectionManifest
    if FileManager.default.fileExists(atPath: manifestURL.path) {
      let persisted = try ManifestIO.read(at: manifestURL, encryptionKey: options.encryptionKey)
      guard persisted.sameBase(as: requested) else {
        throw NyaruError.collectionTypeMismatch(name)
      }
      manifest = persisted
    } else {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try ManifestIO.write(requested, to: manifestURL, encryptionKey: options.encryptionKey)
      manifest = requested
    }

    let core = try await CollectionCore(
      directory: directory,
      manifest: manifest,
      format: options.format,
      encryptionKey: options.encryptionKey
    )
    try await core.setIndexedFields(requested.indexedFields)
    cores[name] = core
    return core
  }

  /// Returns the names of all collections present on disk.
  ///
  /// Scans the database directory for subdirectories containing a
  /// `manifest.json` file and reads each manifest to extract the collection
  /// name. Handles encrypted manifests transparently.
  ///
  /// - Returns: A sorted list of collection names.
  /// - Throws: `NyaruError.databaseClosed` if closed, or
  ///   `NyaruError.decryptionFailed` if a manifest cannot be decrypted.
  public func listCollections() throws -> [String] {
    try ensureOpen()
    let fm = FileManager.default
    let items = (try? fm.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)) ?? []
    var names: [String] = []
    for url in items {
      let manifestURL = url.appendingPathComponent("manifest.json")
      guard fm.fileExists(atPath: manifestURL.path) else { continue }

      let manifest = try ManifestIO.read(at: manifestURL, encryptionKey: options.encryptionKey)
      names.append(manifest.name)
    }
    return names.sorted()
  }

  /// Permanently deletes a collection and all of its files from disk.
  ///
  /// If the collection is currently open, it is destroyed through the core
  /// (which shuts down shards cleanly). Otherwise the directory is removed
  /// directly.
  ///
  /// - Parameter name: The name of the collection to drop.
  /// - Throws: `NyaruError.collectionNotFound` if the collection directory
  ///   does not exist, `NyaruError.databaseClosed` if closed.
  public func drop(_ name: String) async throws {
    try ensureOpen()
    if let core = cores.removeValue(forKey: name) {
      try await core.destroy()
      return
    }
    let directory = baseURL.appendingPathComponent(
      CollectionCore.sanitizeFileComponent(name), isDirectory: true
    )
    guard FileManager.default.fileExists(atPath: directory.path) else {
      throw NyaruError.collectionNotFound(name)
    }
    try FileManager.default.removeItem(at: directory)
  }

  // MARK: - Durability / lifecycle

  /// Flushes all index snapshots and shard headers to disk.
  ///
  /// After `sync()` returns successfully, a crash on any clean shard requires
  /// no recovery work — the index snapshots are current and the dirty flag
  /// is cleared. This is a no-op if no mutations have occurred since the last
  /// sync.
  ///
  /// - Throws: `NyaruError.databaseClosed` if closed, or the first I/O error
  ///   encountered across all collections.
  public func sync() async throws {
    try ensureOpen()
    var firstError: Error? = nil

    for core in cores.values {
      do {
        try await core.sync()
      } catch {
        if firstError == nil { firstError = error }
      }
    }

    if let error = firstError { throw error }
  }

  /// Syncs and then closes every open collection.
  ///
  /// After `close()` returns, the instance is permanently closed. Calling any
  /// method other than `close()` (which is idempotent) will throw
  /// `NyaruError.databaseClosed`.
  ///
  /// - Throws: The first I/O error encountered from any collection's sync or
  ///   close operations.
  public func close() async throws {
    guard !isClosed else { return }
    var firstError: Error? = nil

    for core in cores.values {
      do {
        try await core.close()
      } catch {
        if firstError == nil { firstError = error }
      }
    }

    cores = [:]
    isClosed = true

    if let error = firstError { throw error }
  }
}
