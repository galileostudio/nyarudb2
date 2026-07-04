import Foundation

/// High-performance native MessagePack parser.
/// Reads bytes directly via UnsafeRawBufferPointer to avoid Codable overhead.
enum MsgPackExtractor {

  @inlinable
  static func extractDictionary(from data: Data) throws -> [String: Any] {
    return try data.withUnsafeBytes { buffer -> [String: Any] in
      guard buffer.baseAddress != nil else { return [:] }
      var offset = 0
      guard
        let dict = readValue(buffer: buffer, offset: &offset, length: data.count) as? [String: Any]
      else {
        throw NyaruError.decodingFailed("MsgPack top-level is not a map")
      }
      return dict
    }
  }

  @inlinable
  static func fieldValue(in data: Data, path: String) -> FieldValue? {
    return data.withUnsafeBytes { buffer -> FieldValue? in
      guard buffer.baseAddress != nil else { return nil }
      var offset = 0
      guard
        let root = readValue(buffer: buffer, offset: &offset, length: data.count) as? [String: Any]
      else {
        return nil
      }
      return FieldExtractor.value(in: root, path: path)
    }
  }

  @inline(__always)
  private static func readValue(buffer: UnsafeRawBufferPointer, offset: inout Int, length: Int)
    -> Any?
  {
    guard offset < length else { return nil }
    let byte = buffer[offset]
    offset += 1

    // --- FixInts ---
    if byte <= 0x7f { return Int64(byte) }
    if byte >= 0xe0 { return Int64(Int8(bitPattern: byte)) }

    // --- FixMap (0x80 - 0x8f) ---
    if byte >= 0x80 && byte <= 0x8f {
      return readMap(buffer: buffer, offset: &offset, length: length, count: Int(byte & 0x0f))
    }

    // --- FixArray (0x90 - 0x9f) ---
    if byte >= 0x90 && byte <= 0x9f {
      return readArray(buffer: buffer, offset: &offset, length: length, count: Int(byte & 0x0f))
    }

    // --- FixStr (0xa0 - 0xbf) ---
    if byte >= 0xa0 && byte <= 0xbf {
      return readString(buffer: buffer, offset: &offset, length: length, count: Int(byte & 0x1f))
    }

    // --- Type switches ---
    switch byte {
    case 0xc0: return NSNull()
    case 0xc2: return false
    case 0xc3: return true

    case 0xcc:  // UInt8
      guard offset + 1 <= length else { return nil }
      let val = buffer[offset]
      offset += 1
      return Int64(val)

    case 0xcd:  // UInt16
      guard offset + 2 <= length else { return nil }
      let val = UInt16(buffer[offset]) << 8 | UInt16(buffer[offset + 1])
      offset += 2
      return Int64(val)

    case 0xce:  // UInt32
      guard offset + 4 <= length else { return nil }
      let val =
        UInt32(buffer[offset]) << 24 | UInt32(buffer[offset + 1]) << 16 | UInt32(buffer[offset + 2])
        << 8 | UInt32(buffer[offset + 3])
      offset += 4
      return Int64(val)

    case 0xcf:  // UInt64
      guard offset + 8 <= length else { return nil }
      let val =
        UInt64(buffer[offset]) << 56 | UInt64(buffer[offset + 1]) << 48 | UInt64(buffer[offset + 2])
        << 40 | UInt64(buffer[offset + 3]) << 32 | UInt64(buffer[offset + 4]) << 24 | UInt64(
          buffer[offset + 5]) << 16 | UInt64(buffer[offset + 6]) << 8 | UInt64(buffer[offset + 7])
      offset += 8
      return Int64(val)

    case 0xd0:  // Int8
      guard offset + 1 <= length else { return nil }
      let val = Int8(bitPattern: buffer[offset])
      offset += 1
      return Int64(val)

    case 0xd1:  // Int16
      guard offset + 2 <= length else { return nil }
      let val = Int16(buffer[offset]) << 8 | Int16(buffer[offset + 1])
      offset += 2
      return Int64(val)

    case 0xd2:  // Int32
      guard offset + 4 <= length else { return nil }
      let val =
        Int32(buffer[offset]) << 24 | Int32(buffer[offset + 1]) << 16 | Int32(buffer[offset + 2])
        << 8 | Int32(buffer[offset + 3])
      offset += 4
      return Int64(val)

    case 0xd3:  // Int64
      guard offset + 8 <= length else { return nil }
      let val =
        Int64(buffer[offset]) << 56 | Int64(buffer[offset + 1]) << 48 | Int64(buffer[offset + 2])
        << 40 | Int64(buffer[offset + 3]) << 32 | Int64(buffer[offset + 4]) << 24 | Int64(
          buffer[offset + 5]) << 16 | Int64(buffer[offset + 6]) << 8 | Int64(buffer[offset + 7])
      offset += 8
      return val

    case 0xca:  // Float32
      guard offset + 4 <= length else { return nil }
      let val = Float(
        bitPattern: UInt32(buffer[offset]) << 24 | UInt32(buffer[offset + 1]) << 16 | UInt32(
          buffer[offset + 2]) << 8 | UInt32(buffer[offset + 3]))
      offset += 4
      return Double(val)

    case 0xcb:  // Float64
      guard offset + 8 <= length else { return nil }
      let val = Double(
        bitPattern: UInt64(buffer[offset]) << 56 | UInt64(buffer[offset + 1]) << 48 | UInt64(
          buffer[offset + 2]) << 40 | UInt64(buffer[offset + 3]) << 32 | UInt64(buffer[offset + 4])
          << 24 | UInt64(buffer[offset + 5]) << 16 | UInt64(buffer[offset + 6]) << 8
          | UInt64(buffer[offset + 7]))
      offset += 8
      return val

    case 0xd9:  // Str8
      guard offset + 1 <= length else { return nil }
      let count = Int(buffer[offset])
      offset += 1
      return readString(buffer: buffer, offset: &offset, length: length, count: count)

    case 0xda:  // Str16
      guard offset + 2 <= length else { return nil }
      let count = Int(UInt16(buffer[offset]) << 8 | UInt16(buffer[offset + 1]))
      offset += 2
      return readString(buffer: buffer, offset: &offset, length: length, count: count)

    case 0xdb:  // Str32
      guard offset + 4 <= length else { return nil }
      let count = Int(
        UInt32(buffer[offset]) << 24 | UInt32(buffer[offset + 1]) << 16 | UInt32(buffer[offset + 2])
          << 8 | UInt32(buffer[offset + 3]))
      offset += 4
      return readString(buffer: buffer, offset: &offset, length: length, count: count)

    case 0xdc:  // Array16
      guard offset + 2 <= length else { return nil }
      let count = Int(UInt16(buffer[offset]) << 8 | UInt16(buffer[offset + 1]))
      offset += 2
      return readArray(buffer: buffer, offset: &offset, length: length, count: count)

    case 0xdd:  // Array32
      guard offset + 4 <= length else { return nil }
      let count = Int(
        UInt32(buffer[offset]) << 24 | UInt32(buffer[offset + 1]) << 16 | UInt32(buffer[offset + 2])
          << 8 | UInt32(buffer[offset + 3]))
      offset += 4
      return readArray(buffer: buffer, offset: &offset, length: length, count: count)

    case 0xde:  // Map16
      guard offset + 2 <= length else { return nil }
      let count = Int(UInt16(buffer[offset]) << 8 | UInt16(buffer[offset + 1]))
      offset += 2
      return readMap(buffer: buffer, offset: &offset, length: length, count: count)

    case 0xdf:  // Map32
      guard offset + 4 <= length else { return nil }
      let count = Int(
        UInt32(buffer[offset]) << 24 | UInt32(buffer[offset + 1]) << 16 | UInt32(buffer[offset + 2])
          << 8 | UInt32(buffer[offset + 3]))
      offset += 4
      return readMap(buffer: buffer, offset: &offset, length: length, count: count)

    default:
      return nil
    }
  }

  @inline(__always)
  private static func readMap(
    buffer: UnsafeRawBufferPointer, offset: inout Int, length: Int, count: Int
  ) -> [String: Any]? {
    var dict = [String: Any]()
    dict.reserveCapacity(count)
    for _ in 0..<count {
      guard let key = readValue(buffer: buffer, offset: &offset, length: length) as? String else {
        return nil
      }
      guard let val = readValue(buffer: buffer, offset: &offset, length: length) else { return nil }
      dict[key] = val
    }
    return dict
  }

  @inline(__always)
  private static func readArray(
    buffer: UnsafeRawBufferPointer, offset: inout Int, length: Int, count: Int
  ) -> [Any]? {
    var arr = [Any]()
    arr.reserveCapacity(count)
    for _ in 0..<count {
      guard let val = readValue(buffer: buffer, offset: &offset, length: length) else { return nil }
      arr.append(val)
    }
    return arr
  }

  @inline(__always)
  private static func readString(
    buffer: UnsafeRawBufferPointer, offset: inout Int, length: Int, count: Int
  ) -> String? {
    guard offset + count <= length else { return nil }
    let bytes = UnsafeRawBufferPointer(rebasing: buffer[offset..<offset + count])
    let val = String(bytes: bytes, encoding: .utf8)
    offset += count
    return val
  }
}
