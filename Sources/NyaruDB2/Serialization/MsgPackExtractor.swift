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

  /// Extracts the values of specific top-level fields without materialising
  /// the document: unwanted values (e.g. large content strings, nested
  /// objects) are skipped using MsgPack's length prefixes instead of being
  /// decoded into Swift objects.
  ///
  /// - Parameters:
  ///   - data: The encoded MsgPack document (top-level map).
  ///   - fields: The top-level field names to extract. Dot paths are NOT
  ///     supported here — callers must fall back to a full parse for those.
  /// - Returns: The scalar values found (fields that are absent or hold
  ///   non-scalar values are omitted), or `nil` if the input is malformed —
  ///   the caller should fall back to a full parse.
  static func extractTopLevelFields(from data: Data, fields: [String]) -> [String: FieldValue]? {
    extractTopLevelFields(from: data, fields: fields, keyBytes: fields.map { Array($0.utf8) })
  }

  /// Hot-loop variant of `extractTopLevelFields` taking pre-computed UTF-8
  /// key bytes (build them once per query, not once per document). Map keys
  /// are matched by comparing raw bytes in place — no `String` is ever
  /// allocated for a key, wanted or not.
  ///
  /// Limited to 64 fields (a bitmask tracks which are still wanted); more
  /// returns `nil` and the caller falls back to the full parse.
  static func extractTopLevelFields(
    from data: Data, fields: [String], keyBytes: [[UInt8]]
  ) -> [String: FieldValue]? {
    guard fields.count <= 64 else { return nil }
    return data.withUnsafeBytes { buffer -> [String: FieldValue]? in
      guard buffer.baseAddress != nil, !data.isEmpty else { return nil }
      var offset = 0
      let length = data.count
      guard let pairCount = readMapHeader(buffer: buffer, offset: &offset, length: length) else {
        return nil
      }

      var wantedMask: UInt64 = fields.count == 64 ? .max : (1 << fields.count) - 1
      var found: [String: FieldValue] = [:]
      found.reserveCapacity(fields.count)

      for _ in 0..<pairCount {
        guard let key = readStringBytes(buffer: buffer, offset: &offset, length: length) else {
          return nil
        }
        var matched = -1
        var candidates = wantedMask
        while candidates != 0 {
          let i = candidates.trailingZeroBitCount
          candidates &= candidates - 1
          let candidate = keyBytes[i]
          if candidate.count == key.count,
            candidate.withUnsafeBufferPointer({ ptr in
              memcmp(ptr.baseAddress!, buffer.baseAddress! + key.lowerBound, key.count) == 0
            })
          {
            matched = i
            break
          }
        }

        if matched >= 0 {
          guard let value = readFieldValue(buffer: buffer, offset: &offset, length: length) else {
            return nil
          }
          if let value { found[fields[matched]] = value }
          wantedMask &= ~(UInt64(1) << matched)
          if wantedMask == 0 { break }
        } else {
          guard skipValue(buffer: buffer, offset: &offset, length: length) else { return nil }
        }
      }
      return found
    }
  }

  /// Reads a MsgPack string header and returns the byte range of its UTF-8
  /// payload, advancing past it. Returns `nil` for non-string values (map
  /// keys are expected to be strings) or truncated input.
  @inline(__always)
  private static func readStringBytes(
    buffer: UnsafeRawBufferPointer, offset: inout Int, length: Int
  ) -> Range<Int>? {
    guard offset < length else { return nil }
    let byte = buffer[offset]
    let payloadLength: Int
    switch byte {
    case 0xa0...0xbf:
      payloadLength = Int(byte & 0x1f)
      offset += 1
    case 0xd9:
      guard offset + 2 <= length else { return nil }
      payloadLength = Int(buffer[offset + 1])
      offset += 2
    case 0xda:
      guard offset + 3 <= length else { return nil }
      payloadLength = Int(UInt16(buffer[offset + 1]) << 8 | UInt16(buffer[offset + 2]))
      offset += 3
    case 0xdb:
      guard offset + 5 <= length else { return nil }
      payloadLength = Int(
        UInt32(buffer[offset + 1]) << 24 | UInt32(buffer[offset + 2]) << 16
          | UInt32(buffer[offset + 3]) << 8 | UInt32(buffer[offset + 4]))
      offset += 5
    default:
      return nil
    }
    guard offset + payloadLength <= length else { return nil }
    defer { offset += payloadLength }
    return offset..<(offset + payloadLength)
  }

  /// Reads the top-level map header, returning the number of key/value pairs.
  @inline(__always)
  private static func readMapHeader(
    buffer: UnsafeRawBufferPointer, offset: inout Int, length: Int
  ) -> Int? {
    guard offset < length else { return nil }
    let byte = buffer[offset]
    if byte >= 0x80 && byte <= 0x8f {
      offset += 1
      return Int(byte & 0x0f)
    }
    if byte == 0xde {
      guard offset + 3 <= length else { return nil }
      let count = Int(UInt16(buffer[offset + 1]) << 8 | UInt16(buffer[offset + 2]))
      offset += 3
      return count
    }
    if byte == 0xdf {
      guard offset + 5 <= length else { return nil }
      let count = Int(
        UInt32(buffer[offset + 1]) << 24 | UInt32(buffer[offset + 2]) << 16
          | UInt32(buffer[offset + 3]) << 8 | UInt32(buffer[offset + 4]))
      offset += 5
      return count
    }
    return nil
  }

  /// Reads a scalar value as a `FieldValue`, or skips a container value.
  ///
  /// - Returns: `.some(value)` for scalars, `.some(nil)` for containers
  ///   (skipped, matching `FieldValue.fromAny` returning `nil` for them),
  ///   or `nil` when the input is malformed.
  @inline(__always)
  private static func readFieldValue(
    buffer: UnsafeRawBufferPointer, offset: inout Int, length: Int
  ) -> FieldValue?? {
    guard offset < length else { return nil }
    let byte = buffer[offset]
    let isContainer =
      (byte >= 0x80 && byte <= 0x9f)  // fixmap / fixarray
      || (byte >= 0xc4 && byte <= 0xc9)  // bin / ext
      || (byte >= 0xd4 && byte <= 0xd8)  // fixext
      || (byte >= 0xdc && byte <= 0xdf)  // array / map 16/32
    if isContainer {
      return skipValue(buffer: buffer, offset: &offset, length: length)
        ? FieldValue??.some(nil) : nil
    }
    guard let any = readValue(buffer: buffer, offset: &offset, length: length) else { return nil }
    return .some(FieldValue.fromAny(any))
  }

  /// Advances `offset` past one MsgPack value without materialising it.
  /// Containers are traversed recursively; scalars advance by their
  /// length-prefixed size.
  ///
  /// - Returns: `false` if the input is truncated or malformed.
  private static func skipValue(
    buffer: UnsafeRawBufferPointer, offset: inout Int, length: Int
  ) -> Bool {
    guard offset < length else { return false }
    let byte = buffer[offset]
    offset += 1

    @inline(__always)
    func advance(_ n: Int) -> Bool {
      guard offset + n <= length else { return false }
      offset += n
      return true
    }
    @inline(__always)
    func skipElements(_ count: Int) -> Bool {
      for _ in 0..<count {
        guard skipValue(buffer: buffer, offset: &offset, length: length) else { return false }
      }
      return true
    }
    @inline(__always)
    func readLength(_ bytes: Int) -> Int? {
      guard offset + bytes <= length else { return nil }
      var value = 0
      for i in 0..<bytes { value = value << 8 | Int(buffer[offset + i]) }
      offset += bytes
      return value
    }

    switch byte {
    case 0x00...0x7f, 0xe0...0xff, 0xc0, 0xc2, 0xc3:
      return true  // fixint / nil / bool: no payload
    case 0x80...0x8f: return skipElements(Int(byte & 0x0f) * 2)  // fixmap
    case 0x90...0x9f: return skipElements(Int(byte & 0x0f))  // fixarray
    case 0xa0...0xbf: return advance(Int(byte & 0x1f))  // fixstr
    case 0xcc, 0xd0: return advance(1)
    case 0xcd, 0xd1: return advance(2)
    case 0xce, 0xd2, 0xca: return advance(4)
    case 0xcf, 0xd3, 0xcb: return advance(8)
    case 0xd9, 0xc4:  // str8 / bin8
      guard let n = readLength(1) else { return false }
      return advance(n)
    case 0xda, 0xc5:  // str16 / bin16
      guard let n = readLength(2) else { return false }
      return advance(n)
    case 0xdb, 0xc6:  // str32 / bin32
      guard let n = readLength(4) else { return false }
      return advance(n)
    case 0xd4: return advance(2)  // fixext1: type + 1
    case 0xd5: return advance(3)
    case 0xd6: return advance(5)
    case 0xd7: return advance(9)
    case 0xd8: return advance(17)
    case 0xc7:  // ext8
      guard let n = readLength(1) else { return false }
      return advance(n + 1)
    case 0xc8:  // ext16
      guard let n = readLength(2) else { return false }
      return advance(n + 1)
    case 0xc9:  // ext32
      guard let n = readLength(4) else { return false }
      return advance(n + 1)
    case 0xdc:  // array16
      guard let n = readLength(2) else { return false }
      return skipElements(n)
    case 0xdd:  // array32
      guard let n = readLength(4) else { return false }
      return skipElements(n)
    case 0xde:  // map16
      guard let n = readLength(2) else { return false }
      return skipElements(n * 2)
    case 0xdf:  // map32
      guard let n = readLength(4) else { return false }
      return skipElements(n * 2)
    default:
      return false  // 0xc1 (never used) or unknown
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
