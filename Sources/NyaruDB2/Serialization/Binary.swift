import Foundation

/// Little-endian binary encoding helpers.
///
/// All multi-byte integers in the NyaruDB file format are little-endian and
/// are assembled/disassembled byte by byte. This avoids unaligned-load traps
/// entirely (no `load(as:)` on arbitrary offsets) and is portable to any
/// architecture, including Android targets.
enum Binary {

  // MARK: - Append (encode)

  @inlinable
  static func append(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
  }

  @inlinable
  static func append(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
    data.append(UInt8(truncatingIfNeeded: value >> 16))
    data.append(UInt8(truncatingIfNeeded: value >> 24))
  }

  @inlinable
  static func append(_ value: UInt64, to data: inout Data) {
    // Otimização: Usa append(contentsOf:) para inserir os 8 bytes de uma vez,
    // reduzindo o overhead de múltiplas chamadas de função e realocações.
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

  @inlinable
  static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= data.count else { return nil }
    let base = data.startIndex + offset
    let b0 = UInt16(data[base])
    let b1 = UInt16(data[base + 1])
    return b0 | (b1 << 8)
  }

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
