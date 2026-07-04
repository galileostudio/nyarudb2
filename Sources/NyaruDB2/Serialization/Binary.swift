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
  /// - Parameters:
  ///   - data: The data buffer to read from.
  ///   - offset: The byte offset at which to start reading (0-indexed).
  /// - Returns: The decoded value, or `nil` if fewer than two bytes are
  ///   available from the offset.
  @inlinable
  static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= data.count else { return nil }
    let base = data.startIndex + offset
    let b0 = UInt16(data[base])
    let b1 = UInt16(data[base + 1])
    return b0 | (b1 << 8)
  }

  /// Reads a 32-bit unsigned integer in little-endian byte order from the
  /// given data at the specified offset.
  ///
  /// - Parameters:
  ///   - data: The data buffer to read from.
  ///   - offset: The byte offset at which to start reading (0-indexed).
  /// - Returns: The decoded value, or `nil` if fewer than four bytes are
  ///   available from the offset.
  @inlinable
  static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    let base = data.startIndex + offset
    var value: UInt32 = 0
    for i in 0..<4 {
      value |= UInt32(data[base + i]) << (8 * i)
    }
    return value
  }

  /// Reads a 64-bit unsigned integer in little-endian byte order from the
  /// given data at the specified offset.
  ///
  /// Internally this reads two 32-bit halves and combines them, which avoids
  /// a single 8-byte unaligned load that could trap on some architectures.
  ///
  /// - Parameters:
  ///   - data: The data buffer to read from.
  ///   - offset: The byte offset at which to start reading (0-indexed).
  /// - Returns: The decoded value, or `nil` if fewer than eight bytes are
  ///   available from the offset.
  @inlinable
  static func readUInt64(_ data: Data, at offset: Int) -> UInt64? {
    guard let low = readUInt32(data, at: offset),
      let high = readUInt32(data, at: offset + 4)
    else {
      return nil
    }
    return UInt64(low) | (UInt64(high) << 32)
  }
}
