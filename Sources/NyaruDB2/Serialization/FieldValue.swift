import Foundation

/// A scalar value extracted from a document field (JSON or MessagePack).
///
/// Provides a *total ordering* so it can be used as an index key and in
/// range queries. Ordering is by type rank first (null < bool < number <
/// string), then by value within the same type. `.int` and `.double` share
/// the "number" rank and always compare *numerically* against each other,
/// exactly (no round-trip through Double), so `int(5) == double(5.0)` and
/// `int(2^60 + 1) != double(2^60)`.
public enum FieldValue: Codable, Sendable, CustomStringConvertible,
  ExpressibleByIntegerLiteral, ExpressibleByStringLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral,
  ExpressibleByNilLiteral
{
  case null
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case string(String)

  // MARK: - ExpressibleBy Literals

  public init(integerLiteral value: Int) { self = .int(Int64(value)) }
  public init(stringLiteral value: String) { self = .string(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(nilLiteral: ()) { self = .null }

  /// Returns the native Swift `Any` representation of this value.
  public var anyValue: Any {
    switch self {
    case .null: return NSNull()
    case .bool(let v): return v
    case .int(let v): return v
    case .double(let v): return v
    case .string(let v): return v
    }
  }

  /// Type rank for total ordering: null < bool < number < string.
  @inlinable
  internal var typeRank: Int {
    switch self {
    case .null: return 0
    case .bool: return 1
    case .int, .double: return 2
    case .string: return 3
    }
  }

  /// Canonicalizes a Double: integral values that fit Int64 exactly become `.int`.
  public static func number(_ d: Double) -> FieldValue {
    if let i = Int64(exactly: d) { return .int(i) }
    return .double(d)
  }

  // MARK: - Exact Numeric Comparison

  @inlinable
  internal static func compare(_ i: Int64, _ d: Double) -> Int {
    if d.isNaN { return -1 }
    if d >= 9_223_372_036_854_775_808.0 { return -1 }
    if d < -9_223_372_036_854_775_808.0 { return 1 }
    let floor = d.rounded(.down)
    let fi = Int64(floor)
    if i != fi { return i < fi ? -1 : 1 }
    return d > floor ? -1 : 0
  }

  @inlinable
  internal static func compareDoubles(_ a: Double, _ b: Double) -> Int {
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

  /// Total ordering across all FieldValue variants.
  @inlinable
  public static func compare(_ lhs: FieldValue, _ rhs: FieldValue) -> Int {
    if lhs.typeRank != rhs.typeRank {
      return lhs.typeRank < rhs.typeRank ? -1 : 1
    }
    switch (lhs, rhs) {
    case (.null, .null): return 0
    case (.bool(let a), .bool(let b)):
      let (x, y) = (a ? 1 : 0, b ? 1 : 0)
      return x == y ? 0 : (x < y ? -1 : 1)
    case (.int(let a), .int(let b)):
      return a == b ? 0 : (a < b ? -1 : 1)
    case (.int(let a), .double(let b)): return compare(a, b)
    case (.double(let a), .int(let b)): return -compare(b, a)
    case (.double(let a), .double(let b)): return compareDoubles(a, b)
    case (.string(let a), .string(let b)):
      return a == b ? 0 : (a < b ? -1 : 1)
    default: return 0
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

  /// Converts any value from a deserialized dictionary into a canonical FieldValue.
  public static func fromAny(_ value: Any?) -> FieldValue? {
    switch value {
    case nil, is NSNull:
      return .null
    case let v as Bool:
      return .bool(v)
    case let v as Int64:
      return .int(v)
    case let v as Int:
      return .int(Int64(v))
    case let v as Double:
      return .number(v)
    case let v as String:
      return .string(v)
    default:
      return nil
    }
  }
}

// MARK: - Comparable / Equatable / Hashable

extension FieldValue: Comparable {
  @inlinable public static func < (lhs: FieldValue, rhs: FieldValue) -> Bool {
    compare(lhs, rhs) < 0
  }
  @inlinable public static func == (lhs: FieldValue, rhs: FieldValue) -> Bool {
    compare(lhs, rhs) == 0
  }
}

extension FieldValue: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(typeRank)
    switch self {
    case .null: break
    case .bool(let b): hasher.combine(b)
    case .int(let i): hasher.combine(i)
    case .double(let d):
      if let i = Int64(exactly: d) { hasher.combine(i) } else { hasher.combine(d) }
    case .string(let s): hasher.combine(s)
    }
  }
}

// MARK: - FieldValueConvertible

public protocol FieldValueConvertible: Sendable {
  var fieldValue: FieldValue { get }
}

extension String: FieldValueConvertible { public var fieldValue: FieldValue { .string(self) } }
extension Int: FieldValueConvertible { public var fieldValue: FieldValue { .int(Int64(self)) } }
extension Int64: FieldValueConvertible { public var fieldValue: FieldValue { .int(self) } }
extension Double: FieldValueConvertible { public var fieldValue: FieldValue { .number(self) } }
extension Bool: FieldValueConvertible { public var fieldValue: FieldValue { .bool(self) } }
extension UUID: FieldValueConvertible { public var fieldValue: FieldValue { .string(uuidString) } }
extension Date: FieldValueConvertible {
  public var fieldValue: FieldValue { .number(timeIntervalSinceReferenceDate) }
}
extension FieldValue: FieldValueConvertible { public var fieldValue: FieldValue { self } }

extension Optional: FieldValueConvertible where Wrapped: FieldValueConvertible {
  public var fieldValue: FieldValue {
    switch self {
    case .some(let value): return value.fieldValue
    case .none: return .null
    }
  }
}

// MARK: - FieldExtractor

enum FieldExtractor {
  static func parse(_ data: Data, using format: SerializationFormat) throws -> [String: Any] {
    let obj = try Serializer.unpack(data, format: format)
    guard let dict = obj as? [String: Any] else {
      throw NyaruError.decodingFailed("Top-level value is not an object")
    }
    return dict
  }

  static func value(in dict: [String: Any], path: String) -> FieldValue? {
    var current: Any = dict
    var start = path.startIndex

    while start < path.endIndex {
      // Pula separadores (caso haja pontos múltiplos acidentais)
      while start < path.endIndex && path[start] == "." {
        start = path.index(after: start)
      }
      guard start < path.endIndex else { break }

      let end = path[start...].firstIndex(of: ".") ?? path.endIndex
      let key = String(path[start..<end])
      start = end

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
    return FieldValue.fromAny(current)
  }

  static func value(in data: Data, path: String, using format: SerializationFormat) throws
    -> FieldValue?
  {
    let dict = try parse(data, using: format)
    return value(in: dict, path: path)
  }
}
