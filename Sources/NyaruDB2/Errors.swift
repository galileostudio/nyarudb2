import Foundation

/// All errors thrown by NyaruDB.
public enum NyaruError: Error, Sendable, CustomStringConvertible {
  // Storage / file format
  case invalidFileFormat(String)
  case corruptedRecord(offset: UInt64, reason: String)
  case ioError(String)

  // Documents
  case idFieldMissing(field: String)
  case partitionKeyMissing(field: String)
  case duplicateID(String)
  case documentNotFound(id: String)
  case encodingFailed(String)
  case decodingFailed(String)

  // Collections
  case collectionNotFound(String)
  case collectionTypeMismatch(String)

  // Compression
  case compressionFailed
  case decompressionFailed
  case unsupportedCompression(String)

  //crypto
  case decryptionFailed
  case encryptionFailed

  case unsupportedOperation(String)

  // Lifecycle
  case databaseClosed

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
    case .unsupportedOperation: return "Unsupported operation"
    case .databaseClosed: return "Database has been closed"
    }
  }
}
