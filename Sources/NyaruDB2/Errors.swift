import Foundation

/// Represents all errors that can be thrown by NyaruDB operations.
///
/// `NyaruError` covers storage corruption, document validation failures,
/// collection lifecycle issues, compression errors, and cryptographic
/// failures. Each case carries contextual information to aid debugging.
///
/// Conforms to `CustomStringConvertible` to provide a human-readable
/// description of each error case.
public enum NyaruError: Error, Sendable, CustomStringConvertible {
  // Storage / file format

  /// The on-disk file header or layout is invalid or unrecognised.
  ///
  /// This can occur when a file is not a NyaruDB shard, the magic bytes
  /// are wrong, the version is unsupported, or the header is truncated.
  ///
  /// - Parameter String: A description of what was invalid.
  case invalidFileFormat(String)

  /// A record at a specific offset failed integrity checks.
  ///
  /// This is raised when a record's header is malformed, its CRC-32
  /// checksum does not match, or the payload is truncated. Corruption
  /// may be caused by hardware faults, torn writes, or bugs.
  ///
  /// - Parameters:
  ///   - offset: The byte offset of the corrupt record within the shard.
  ///   - reason: A human-readable description of the integrity failure.
  case corruptedRecord(offset: UInt64, reason: String)

  /// An underlying filesystem read, write, or open operation failed.
  ///
  /// This wraps `Foundation` I/O errors such as permission denied, disk
  /// full, or file-not-found during shard operations.
  ///
  /// - Parameter String: The underlying I/O error description.
  case ioError(String)

  // Documents

  /// A document does not contain the configured id field.
  ///
  /// Every document inserted into a collection must have the field
  /// specified by `CollectionOptions.idField`. The default is `"id"`.
  ///
  /// - Parameter field: The name of the missing id field.
  case idFieldMissing(field: String)

  /// A document does not contain the configured partition key field.
  ///
  /// If a partition key is configured, every document must include that
  /// field so the engine can determine which shard to route it to.
  ///
  /// - Parameter field: The name of the missing partition key field.
  case partitionKeyMissing(field: String)

  /// A document with the same id already exists in the collection.
  ///
  /// Raised by `insert` and `insert(contentsOf:)` when the id field
  /// value collides with an existing document. Batch inserts validate
  /// all ids before writing anything.
  ///
  /// - Parameter String: The duplicate id value.
  case duplicateID(String)

  /// No document exists with the given id.
  ///
  /// Raised by `get`, `update`, `delete`, and `patch` when the id is
  /// not found in the primary index.
  ///
  /// - Parameter id: The requested document id.
  case documentNotFound(id: String)

  /// Encoding a document to the storage format failed.
  ///
  /// Wraps errors from `JSONEncoder` or `MsgPackEncoder` (e.g. when
  /// a value is not encodable).
  ///
  /// - Parameter String: The underlying encoding error description.
  case encodingFailed(String)

  /// Decoding a stored payload back into a document failed.
  ///
  /// Wraps errors from `JSONDecoder` or `MsgPackDecoder` (e.g. when
  /// stored data is structurally invalid for the expected type).
  ///
  /// - Parameter String: The underlying decoding error description.
  case decodingFailed(String)

  // Collections

  /// The requested collection directory does not exist on disk.
  ///
  /// Raised by `drop` when the collection has not been opened and the
  /// directory is missing.
  ///
  /// - Parameter String: The collection name.
  case collectionNotFound(String)

  /// The collection was previously created with incompatible options.
  ///
  /// Raised when `collection(_:of:options:)` is called with options that
  /// conflict with the persisted manifest. The base configuration (id field,
  /// partition key, compression, encryption, format) is frozen at creation.
  ///
  /// - Parameter String: The collection name.
  case collectionTypeMismatch(String)

  // Compression

  /// Compressing a payload failed.
  ///
  /// Raised by the internal compression utilities when the underlying
  /// library returns an error status.
  case compressionFailed

  /// Decompressing a stored payload failed.
  ///
  /// Raised when a compressed record cannot be decompressed, possibly
  /// because the data is corrupt or was compressed with a different method.
  case decompressionFailed

  /// The requested compression method is not available on this platform.
  ///
  /// For example, LZFSE and LZ4 are only available on Apple platforms.
  /// gzip is always available.
  ///
  /// - Parameter String: The name of the unsupported method.
  case unsupportedCompression(String)

  // Crypto

  /// Decrypting an encrypted payload or manifest failed.
  ///
  /// Raised when AES-GCM decryption fails, typically because the key is
  /// wrong or the data has been tampered with.
  case decryptionFailed

  /// Encrypting a payload or manifest failed.
  ///
  /// Raised when AES-GCM encryption produces an unexpected result.
  case encryptionFailed

  /// The requested operation is not supported in the current configuration.
  ///
  /// For example, pagination without a sort field, or patching the document
  /// id field.
  ///
  /// - Parameter String: A description of the unsupported operation.
  case unsupportedOperation(String)

  // Lifecycle

  /// The database or collection has been closed and cannot accept operations.
  case databaseClosed

  /// Returns a human-readable description of this error.
  public var description: String {
    switch self {
    case .invalidFileFormat(let s): return "Invalid file format: \(s)"
    case .corruptedRecord(let offset, let reason):
      return "Corrupted record at offset \(offset): \(reason)"
    case .ioError(let s): return "I/O error: \(s)"
    case .idFieldMissing(let f): return "Document is missing id field '\(f)'"
    case .partitionKeyMissing(let f): return "Document is missing partition key '\(f)'"
    case .duplicateID(let id): return "A document with id '\(id)' already exists"
    case .documentNotFound(let id): return "No document with id '\(id)'"
    case .encodingFailed(let s): return "Encoding failed: \(s)"
    case .decodingFailed(let s): return "Decoding failed: \(s)"
    case .collectionNotFound(let n): return "Collection '\(n)' not found"
    case .collectionTypeMismatch(let n):
      return "Collection '\(n)' was opened with a different configuration"
    case .compressionFailed: return "Compression failed"
    case .decompressionFailed: return "Decompression failed"
    case .unsupportedCompression(let m):
      return "Compression method '\(m)' is not supported on this platform"
    case .decryptionFailed: return "Decryption failed"
    case .encryptionFailed: return "Encryption failed"
    case .unsupportedOperation(let s): return "Unsupported operation: \(s)"
    case .databaseClosed: return "Database has been closed"
    }
  }
}
