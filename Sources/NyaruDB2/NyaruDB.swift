import Crypto
import Foundation

/// Database-wide configuration.
public struct DatabaseOptions: Sendable {
  public var compression: CompressionMethod
  public var fileProtection: FileProtection
  public var format: SerializationFormat
  public var encryptionKey: SymmetricKey?
  public var maxFragmentation: Double

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

/// An embedded document database.
public actor NyaruDB {
  private let baseURL: URL
  private let options: DatabaseOptions
  private var cores: [String: CollectionCore] = [:]
  private var isClosed = false

  public init(path: URL, options: DatabaseOptions = DatabaseOptions()) async throws {
    self.baseURL = path
    self.options = options
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
  }

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
      format: options.format
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

    // All manifest I/O goes through ManifestIO so encryption is applied (or
    // not) in exactly one place — see the regression note on ManifestIO.
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

  /// Lists collections present on disk.
  public func listCollections() throws -> [String] {
    try ensureOpen()
    let fm = FileManager.default
    let items = (try? fm.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)) ?? []
    var names: [String] = []
    for url in items {
      let manifestURL = url.appendingPathComponent("manifest.json")
      guard fm.fileExists(atPath: manifestURL.path) else { continue }

      // Delegates decryption and decoding to ManifestIO
      let manifest = try ManifestIO.read(at: manifestURL, encryptionKey: options.encryptionKey)
      names.append(manifest.name)
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

  /// Syncs and closes every collection. The instance cannot be used
  /// afterwards.
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
