import Foundation

/// Database-wide configuration.
public struct DatabaseOptions: Sendable {
  /// Compression applied to document payloads. `gzip` is portable to
  /// every platform; `lzfse`/`lz4` are Apple-only and tie the data files
  /// to Apple devices.
  public var compression: CompressionMethod
  /// iOS data-protection class for shard files (no-op on other platforms).
  public var fileProtection: FileProtection

  public init(
    compression: CompressionMethod = .none,
    fileProtection: FileProtection = .none
  ) {
    self.compression = compression
    self.fileProtection = fileProtection
  }
}

/// An embedded document database.
///
/// ```swift
/// struct User: Codable, Sendable {
///     let id: Int
///     let name: String
///     let country: String
/// }
///
/// let db = try await NyaruDB(path: url)
/// let users = try await db.collection(
///     "users", of: User.self,
///     options: .init(partitionKey: "country", indexedFields: ["name"])
/// )
/// try await users.insert(User(id: 1, name: "Alice", country: "BR"))
/// let alice = try await users.get(id: 1)
/// let brazilians = try await users.find()
///     .where("country", isEqualTo: "BR")
///     .sort(by: "name")
///     .execute()
/// ```
public actor NyaruDB {
  private let baseURL: URL
  private let options: DatabaseOptions
  private var cores: [String: CollectionCore] = [:]
  private var isClosed = false

  /// Opens (or creates) a database rooted at `path`.
  public init(path: URL, options: DatabaseOptions = DatabaseOptions()) async throws {
    self.baseURL = path
    self.options = options
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
  }

  /// Convenience: relative or absolute string path.
  public init(path: String, options: DatabaseOptions = DatabaseOptions()) async throws {
    try await self.init(
      path: URL(fileURLWithPath: path, isDirectory: true),
      options: options
    )
  }

  private func ensureOpen() throws {
    if isClosed { throw NyaruError.databaseClosed }
  }

  // MARK: - Collections

  /// Opens (or creates) a typed collection.
  ///
  /// On first creation the configuration is persisted in the collection's
  /// manifest. Reopening with a *different* configuration throws
  /// `NyaruError.collectionTypeMismatch` — silently reinterpreting the
  /// on-disk layout is how databases corrupt themselves.
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
      partitionKey: await core.manifest.partitionKey
    )
  }

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
      fileProtection: options.fileProtection
    )

    // The base configuration (id field, partition key, compression,
    // protection) is frozen at creation — reopening with a different one
    // would silently reinterpret the on-disk layout. Indexed fields may
    // evolve freely: missing indexes are built, dropped ones discarded.
    if let existing = cores[name] {
      guard await existing.manifest.sameBase(as: requested) else {
        throw NyaruError.collectionTypeMismatch(name)
      }
      try await existing.setIndexedFields(requested.indexedFields)
      return existing
    }

    let manifest: CollectionManifest
    if let data = try? Data(contentsOf: manifestURL) {
      let persisted = try JSONDecoder().decode(CollectionManifest.self, from: data)
      guard persisted.sameBase(as: requested) else {
        throw NyaruError.collectionTypeMismatch(name)
      }
      manifest = persisted
    } else {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(requested)
      try data.write(to: manifestURL, options: .atomic)
      manifest = requested
    }

    let core = try await CollectionCore(directory: directory, manifest: manifest)
    try await core.setIndexedFields(requested.indexedFields)
    cores[name] = core
    return core
  }

  /// Lists collections present on disk.
  public func listCollections() throws -> [String] {
    try ensureOpen()
    let fm = FileManager.default
    let items = (try? fm.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)) ?? []
    var names: [String] = []
    for url in items {
      let manifestURL = url.appendingPathComponent("manifest.json")
      if let data = try? Data(contentsOf: manifestURL),
        let manifest = try? JSONDecoder().decode(CollectionManifest.self, from: data)
      {
        names.append(manifest.name)
      }
    }
    return names.sorted()
  }

  /// Permanently deletes a collection and its files.
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

  /// Flushes index snapshots and shard headers to disk. After `sync()`
  /// returns, a crash will reopen without any recovery work.
  public func sync() async throws {
    try ensureOpen()
    for core in cores.values {
      try await core.sync()
    }
  }

  /// Syncs and closes every collection. The instance cannot be used
  /// afterwards.
  public func close() async throws {
    guard !isClosed else { return }
    for core in cores.values {
      try await core.close()
    }
    cores = [:]
    isClosed = true
  }
}
