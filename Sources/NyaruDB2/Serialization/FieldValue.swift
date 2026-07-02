import Foundation

/// A scalar value extracted from a JSON document field.
///
/// Provides a *total ordering* so it can be used as an index key and in
/// range queries. Ordering is by type rank first (null < bool < number <
/// string), then by value within the same type. `.int` and `.double` share
/// the "number" rank and always compare *numerically* against each other,
/// exactly (no round-trip through Double), so `int(5) == double(5.0)` and
/// `int(2^60 + 1) != double(2^60)`.
///
/// Canonical form: any numeric value exactly representable as `Int64` is
/// stored as `.int`. `from(jsonObject:)` and every `FieldValueConvertible`
/// conformance produce canonical values, and `==`/`hash(into:)` are defined
/// numerically as a safety net for hand-constructed non-canonical values
/// (e.g. `.double(5.0)`).
///
/// Why `.int` exists at all: 64-bit integer IDs (snowflakes, database
/// sequence values) exceed 2^53 and silently corrupt if squeezed through
/// Double. Since those integers are *primary keys* in practice, exactness
/// here is non-negotiable.
public enum FieldValue: Codable, Sendable, CustomStringConvertible {
  case null
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case string(String)

  /// null < bool < number < string. `.int` and `.double` share a rank.
  private var typeRank: Int {
    switch self {
    case .null: return 0
    case .bool: return 1
    case .int, .double: return 2
    case .string: return 3
    }
  }

  /// Canonicalizes a Double: integral values that fit Int64 exactly become
  /// `.int`; everything else (fractions, ±inf, NaN, huge magnitudes) stays
  /// `.double`. `Int64(exactly:)` also collapses `-0.0` to `.int(0)`.
  public static func number(_ d: Double) -> FieldValue {
    if let i = Int64(exactly: d) { return .int(i) }
    return .double(d)
  }

  // MARK: - Exact mixed numeric comparison

  /// -1 / 0 / +1 comparing an Int64 against a Double without losing
  /// precision. NaN is treated as greater than every number so ordering
  /// stays total even for hand-built values (JSON cannot produce NaN).
  private static func compare(_ i: Int64, _ d: Double) -> Int {
    if d.isNaN { return -1 }
    // 2^63 and -2^63 are exactly representable Doubles.
    if d >= 9_223_372_036_854_775_808.0 { return -1 }  // d > Int64.max
    if d < -9_223_372_036_854_775_808.0 { return 1 }  // d < Int64.min
    let floor = d.rounded(.down)  // fits in Int64 now
    let fi = Int64(floor)
    if i != fi { return i < fi ? -1 : 1 }
    return d > floor ? -1 : 0  // fraction decides
  }

  private static func compareDoubles(_ a: Double, _ b: Double) -> Int {
    // Total order with NaN sorted last; canonical values never carry
    // -0.0 (collapsed to .int(0)), so a simple < is enough otherwise.
    switch (a.isNaN, b.isNaN) {
    case (true, true): return 0
    case (true, false): return 1
    case (false, true): return -1
    case (false, false):
      if a < b { return -1 }
      if a > b { return 1 }
      return 0
    }
  }

  /// -1 / 0 / +1 across the full domain. Basis for `<`, `==`, and range
  /// scans, so all three are guaranteed mutually consistent.
  static func compare(_ lhs: FieldValue, _ rhs: FieldValue) -> Int {
    if lhs.typeRank != rhs.typeRank {
      return lhs.typeRank < rhs.typeRank ? -1 : 1
    }
    switch (lhs, rhs) {
    case (.null, .null):
      return 0
    case (.bool(let a), .bool(let b)):
      let (x, y) = (a ? 1 : 0, b ? 1 : 0)
      return x == y ? 0 : (x < y ? -1 : 1)
    case (.int(let a), .int(let b)):
      return a == b ? 0 : (a < b ? -1 : 1)
    case (.int(let a), .double(let b)):
      return compare(a, b)
    case (.double(let a), .int(let b)):
      return -compare(b, a)
    case (.double(let a), .double(let b)):
      return compareDoubles(a, b)
    case (.string(let a), .string(let b)):
      return a == b ? 0 : (a < b ? -1 : 1)
    default:
      return 0  // unreachable: ranks matched above
    }
  }

  public var description: String {
    switch self {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .int(let i): return String(i)
    case .double(let d): return String(d)
    case .string(let s): return s
    }
  }

  /// Builds a canonical FieldValue from an object produced by
  /// JSONSerialization. Returns nil for non-scalar values (arrays, dicts).
  static func from(jsonObject value: Any?) -> FieldValue? {
    switch value {
    case nil:
      return nil
    case is NSNull:
      return .null
    case let number as NSNumber:
      // NSNumber wraps booleans too; distinguish via CFBoolean.
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return .bool(number.boolValue)
      }
      switch String(cString: number.objCType) {
      case "f", "d":
        return .number(number.doubleValue)
      case "Q":
        let u = number.uint64Value
        return u <= UInt64(Int64.max)
          ? .int(Int64(u))
          : .double(Double(u))  // > Int64.max: lossy, unavoidable
      default:
        return .int(number.int64Value)
      }
    case let string as String:
      return .string(string)
    default:
      return nil
    }
  }
}

// MARK: - Comparable / Equatable / Hashable (numerically consistent)

extension FieldValue: Comparable {
  public static func < (lhs: FieldValue, rhs: FieldValue) -> Bool {
    compare(lhs, rhs) < 0
  }

  public static func == (lhs: FieldValue, rhs: FieldValue) -> Bool {
    compare(lhs, rhs) == 0
  }
}

extension FieldValue: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(typeRank)
    switch self {
    case .null:
      break
    case .bool(let b):
      hasher.combine(b)
    case .int(let i):
      hasher.combine(i)
    case .double(let d):
      // Non-canonical .double(5.0) must hash like .int(5).
      if let i = Int64(exactly: d) {
        hasher.combine(i)
      } else {
        hasher.combine(d)
      }
    case .string(let s):
      hasher.combine(s)
    }
  }
}

// MARK: - FieldValueConvertible

/// Types that can be used directly as lookup keys (`get(id:)`, query values).
public protocol FieldValueConvertible: Sendable {
  var fieldValue: FieldValue { get }
}

extension String: FieldValueConvertible {
  public var fieldValue: FieldValue { .string(self) }
}
extension Int: FieldValueConvertible {
  public var fieldValue: FieldValue { .int(Int64(self)) }
}
extension Int64: FieldValueConvertible {
  public var fieldValue: FieldValue { .int(self) }
}
extension Double: FieldValueConvertible {
  public var fieldValue: FieldValue { .number(self) }
}
extension Bool: FieldValueConvertible {
  public var fieldValue: FieldValue { .bool(self) }
}
extension UUID: FieldValueConvertible {
  /// Matches `JSONEncoder`'s representation of UUID (its `uuidString`).
  public var fieldValue: FieldValue { .string(uuidString) }
}
extension Date: FieldValueConvertible {
  /// Matches `JSONEncoder`'s *default* date strategy (seconds since the
  /// reference date). NyaruDB always encodes documents with a default
  /// `JSONEncoder`, so stored dates and query values line up — both sides
  /// pass through the same `.number` canonicalization.
  public var fieldValue: FieldValue { .number(timeIntervalSinceReferenceDate) }
}
extension FieldValue: FieldValueConvertible {
  public var fieldValue: FieldValue { self }
}

/// Permite passar `nil` diretamente na query: `where("deletedAt", isEqualTo: nil)`
extension Optional: FieldValueConvertible where Wrapped: FieldValueConvertible {
  public var fieldValue: FieldValue {
    switch self {
    case .some(let value): return value.fieldValue
    case .none: return .null
    }
  }
}

// MARK: - FieldExtractor

/// Extracts scalar field values from encoded JSON documents.
///
/// Unlike the old `DynamicDecoder` (which decoded the document as a flat
/// `[String: Scalar]` and therefore *failed on any document containing a
/// nested object or array*), this extractor works on the full object
/// graph and supports dot-separated key paths ("address.city") e índices de array ("tags.0").
enum FieldExtractor {
  /// Parses the document once into a dictionary for repeated field access.
  /// Agora usa o Serializer injetado, suportando tanto JSON quanto MessagePack.
  static func parse(_ data: Data, using format: SerializationFormat) throws -> [String: Any] {
      let obj = try Serializer.unpack(data, format: format)
    guard let dict = obj as? [String: Any] else {
      throw NyaruError.decodingFailed("Top-level value is not an object")
    }
    return dict
  }

  /// Resolves a dot-separated key path within a parsed document.
  /// Returns nil when the path does not exist; returns `.null` for explicit
  /// nulls; returns nil for non-scalar leaf values.
  /// Supports array indexing: "items.1.name"
  static func value(in dict: [String: Any], path: String) -> FieldValue? {
    var current: Any = dict
    for component in path.split(separator: ".") {
      let key = String(component)

      if let currentDict = current as? [String: Any] {
        guard let next = currentDict[key] else { return nil }
        current = next
      } else if let currentArray = current as? [Any], let index = Int(key) {
        guard currentArray.indices.contains(index) else { return nil }
        current = currentArray[index]
      } else {
        return nil
      }
    }
    return FieldValue.from(jsonObject: current)
  }

  /// One-shot convenience: parse + resolve.
  static func value(in data: Data, path: String, using format: SerializationFormat) throws
    -> FieldValue?
  {
    let dict = try parse(data, using: format)
    return value(in: dict, path: path)
  }
}
