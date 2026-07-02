import Foundation

/// Little-endian binary encoding helpers.
///
/// All multi-byte integers in the NyaruDB file format are little-endian and
/// are assembled/disassembled byte by byte. This avoids unaligned-load traps
/// entirely (no `load(as:)` on arbitrary offsets) and is portable to any
/// architecture, including Android targets.
enum Binary {
  // MARK: - Append (encode)

  static func append(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
  }

  static func append(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
    data.append(UInt8(truncatingIfNeeded: value >> 16))
    data.append(UInt8(truncatingIfNeeded: value >> 24))
  }

  static func append(_ value: UInt64, to data: inout Data) {
    append(UInt32(truncatingIfNeeded: value), to: &data)
    append(UInt32(truncatingIfNeeded: value >> 32), to: &data)
  }

  // MARK: - Read (decode)

  /// Reads a UInt16 at `offset` relative to the start of `data`.
  /// Returns nil if out of bounds.
  static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= data.count else { return nil }
    let base = data.startIndex + offset
    let b0 = UInt16(data[base])
    let b1 = UInt16(data[base + 1])
    return b0 | (b1 << 8)
  }

  static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    let base = data.startIndex + offset
    var value: UInt32 = 0
    for i in 0..<4 {
      value |= UInt32(data[base + i]) << (8 * i)
    }
    return value
  }

  static func readUInt64(_ data: Data, at offset: Int) -> UInt64? {
    guard offset >= 0, offset + 8 <= data.count else { return nil }
    let base = data.startIndex + offset
    var value: UInt64 = 0
    for i in 0..<8 {
      value |= UInt64(data[base + i]) << (8 * i)
    }
    return value
  }
}
