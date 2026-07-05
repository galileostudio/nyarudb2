import Foundation

/// A utility namespace providing little-endian binary encoding and decoding
/// primitives used throughout the NyaruDB file format.
///
/// All multi-byte integers in NyaruDB's on-disk format are stored in
/// little-endian byte order. This type assembles and disassembles them byte
/// by byte, which avoids unaligned-load traps entirely — there is no use of
/// `load(as:)` on arbitrary offsets. The approach is fully portable to every
/// architecture NyaruDB targets, including ARM64 and Android.
///
/// - Note: Every integer encoding or decoding operation in the storage engine
///   routes through this type, making it a single point of verification for
///   endianness correctness.
enum Binary {

  // MARK: - Append (encode)

  /// Encodes a 16-bit unsigned integer in little-endian byte order and appends
  /// the two bytes to the given data buffer.
  ///
  /// - Parameters:
  ///   - value: The value to encode.
  ///   - data: The target data buffer that receives the encoded bytes.
  @inlinable
  static func append(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
  }

  /// Encodes a 32-bit unsigned integer in little-endian byte order and appends
  /// the four bytes to the given data buffer.
  ///
  /// - Parameters:
  ///   - value: The value to encode.
  ///   - data: The target data buffer that receives the encoded bytes.
  @inlinable
  static func append(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
    data.append(UInt8(truncatingIfNeeded: value >> 16))
    data.append(UInt8(truncatingIfNeeded: value >> 24))
  }

  /// Encodes a 64-bit unsigned integer in little-endian byte order and appends
  /// the eight bytes to the given data buffer.
  ///
  /// This overload uses `append(contentsOf:)` with a literal array so the
  /// entire 8-byte sequence is inserted in a single call, reducing function-call
  /// overhead and memory reallocations compared to eight individual appends.
  ///
  /// - Parameters:
  ///   - value: The value to encode.
  ///   - data: The target data buffer that receives the encoded bytes.
  @inlinable
  static func append(_ value: UInt64, to data: inout Data) {
    data.append(contentsOf: [
      UInt8(truncatingIfNeeded: value),
      UInt8(truncatingIfNeeded: value >> 8),
      UInt8(truncatingIfNeeded: value >> 16),
      UInt8(truncatingIfNeeded: value >> 24),
      UInt8(truncatingIfNeeded: value >> 32),
      UInt8(truncatingIfNeeded: value >> 40),
      UInt8(truncatingIfNeeded: value >> 48),
      UInt8(truncatingIfNeeded: value >> 56),
    ])
  }

  // MARK: - Read (decode)

  /// Reads a 16-bit unsigned integer in little-endian byte order from the
  /// given data at the specified offset.
  ///
  /// Uses `withUnsafeBytes` + `loadUnaligned` to read both bytes in one
  /// instruction and avoid Swift's per-access bounds checking on `Data`.
  ///
  /// - Parameters:
  ///   - data: The data buffer to read from.
  ///   - offset: The byte offset at which to start reading (0-indexed).
  /// - Returns: The decoded value, or `nil` if fewer than two bytes are
  ///   available from the offset.
  @inlinable
  static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= data.count else { return nil }
    return data.withUnsafeBytes { ptr in
      UInt16(littleEndian: ptr.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }
  }

  /// Reads a 32-bit unsigned integer in little-endian byte order from the
  /// given data at the specified offset.
  ///
  /// Uses `withUnsafeBytes` + `loadUnaligned` to read all four bytes in one
  /// instruction, eliminating 4 bounds-checked `Data` subscript reads and
  /// the manual byte-assembly shift/or loop.
  ///
  /// - Parameters:
  ///   - data: The data buffer to read from.
  ///   - offset: The byte offset at which to start reading (0-indexed).
  /// - Returns: The decoded value, or `nil` if fewer than four bytes are
  ///   available from the offset.
  @inlinable
  static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return data.withUnsafeBytes { ptr in
      UInt32(littleEndian: ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
  }

  /// Reads a 64-bit unsigned integer in little-endian byte order from the
  /// given data at the specified offset.
  ///
  /// Uses `withUnsafeBytes` + `loadUnaligned` to read all eight bytes in one
  /// instruction. Unlike the previous implementation (which read two 32-bit
  /// halves), modern ARM64 and x86-64 handle unaligned 8-byte loads natively,
  /// so the split is no longer necessary for correctness.
  ///
  /// - Parameters:
  ///   - data: The data buffer to read from.
  ///   - offset: The byte offset at which to start reading (0-indexed).
  /// - Returns: The decoded value, or `nil` if fewer than eight bytes are
  ///   available from the offset.
  @inlinable
  static func readUInt64(_ data: Data, at offset: Int) -> UInt64? {
    guard offset >= 0, offset + 8 <= data.count else { return nil }
    return data.withUnsafeBytes { ptr in
      UInt64(littleEndian: ptr.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
  }
}
