import Foundation

/// Represents a scalar value extracted from a document field, providing a total
/// ordering for use as an index key and in range queries.
///
/// `FieldValue` bridges the gap between dynamically-typed document data (JSON
/// or MessagePack) and the statically-typed index and query systems. Every
/// value stored in an index is a `FieldValue`, and every predicate comparison
/// operates on `FieldValue` instances.
///
/// **Total ordering.** `FieldValue` guarantees a total order across all
/// variants, which is essential for binary-search-based indexes and correct
/// range-scan semantics. The ordering is defined first by *type rank*:
///
/// ```
/// null < bool < number < string
/// ```
///
/// Within the same type, values are ordered naturally. The `int` and `double`
/// cases share the "number" rank and compare *numerically* against each other
/// without lossy conversion through `Double`:
/// - `int(5) == double(5.0)` — exact integer equality
/// - `int(2^60 + 1) != double(2^60)` — no silent rounding
///
/// **ExpressibleBy literals.** `FieldValue` conforms to `ExpressibleByIntegerLiteral`,
/// `ExpressibleByStringLiteral`, `ExpressibleByBooleanLiteral`,
/// `ExpressibleByFloatLiteral`, and `ExpressibleByNilLiteral`, allowing
/// natural Swift syntax: `let v: FieldValue = "hello"`.
public enum FieldValue: Codable, Sendable, CustomStringConvertible,
  ExpressibleByIntegerLiteral, ExpressibleByStringLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral,
  ExpressibleByNilLiteral
{
  /// Represents the absence of a value (`null` / `NSNull`).
  case null
  /// A boolean value (`true` or `false`).
  case bool(Bool)
  /// A 64-bit signed integer.
  case int(Int64)
  /// A 64-bit floating-point number. Only used when the value cannot be
  /// represented exactly as `Int64` — see `number(_:)`.
  case double(Double)
  /// A Unicode string value.
  case string(String)

  // MARK: - ExpressibleBy Literals

  public init(integerLiteral value: Int) { self = .int(Int64(value)) }
  public init(stringLiteral value: String) { self = .string(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(nilLiteral: ()) { self = .null }

  /// Converts this field value back to a native Swift `Any` value suitable
  /// for use in `[String: Any]` dictionaries during patch operations.
  ///
  /// `.null` is represented as `NSNull()` to match Foundation convention.
  public var anyValue: Any {
    switch self {
    case .null: return NSNull()
    case .bool(let v): return v
    case .int(let v): return v
    case .double(let v): return v
    case .string(let v): return v
    }
  }

  /// Returns the type rank used for total ordering.
  ///
  /// Ranking: `null = 0`, `bool = 1`, `number = 2`, `string = 3`.
  @inlinable
  internal var typeRank: Int {
    switch self {
    case .null: return 0
    case .bool: return 1
    case .int, .double: return 2
    case .string: return 3
    }
  }

  /// Canonicalises a double-precision value: if it can be represented exactly
  /// as an `Int64`, stores it as `.int`; otherwise stores it as `.double`.
  ///
  /// This ensures that whole-number doubles (e.g. `42.0`) are indexed as
  /// integers and compare equal to their integer counterparts.
  ///
  /// - Parameter d: The double value to canonicalise.
  /// - Returns: `.int` if the value fits exactly in `Int64`, otherwise `.double`.
  public static func number(_ d: Double) -> FieldValue {
    if let i = Int64(exactly: d) { return .int(i) }
    return .double(d)
  }

  // MARK: - Exact Numeric Comparison

  /// Compares an `Int64` with a `Double` without lossy conversion.
  ///
  /// The comparison avoids converting the `Int64` through `Double` (which
  /// can lose precision for values above 2^53). Instead it rounds the double
  /// down, compares the rounded integer part, and uses the fractional part
  /// as a tiebreaker.
  ///
  /// - Parameters:
  ///   - i: The integer value.
  ///   - d: The double value.
  /// - Returns: -1, 0, or 1 following the same semantics as `Comparable`.
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

  /// Compares two `Double` values, treating NaN as greater than any number.
  ///
  /// This ensures a consistent (if arbitrary) ordering for NaN values so the
  /// total order invariant is maintained.
  ///
  /// - Parameters:
  ///   - a: The first double.
  ///   - b: The second double.
  /// - Returns: -1, 0, or 1.
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

  /// Compares two `FieldValue` instances, providing a total order conforming
  /// to `Comparable` semantics.
  ///
  /// The comparison first orders by type rank, then by value within the same
  /// type. Cross-type comparisons between `.int` and `.double` use the exact
  /// numeric comparison to avoid precision loss.
  ///
  /// - Parameters:
  ///   - lhs: The left-hand value.
  ///   - rhs: The right-hand value.
  /// - Returns: -1 if `lhs < rhs`, 0 if equal, 1 if `lhs > rhs`.
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

  /// A human-readable description of the value.
  public var description: String {
    switch self {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .int(let i): return String(i)
    case .double(let d): return String(d)
    case .string(let s): return s
    }
  }

  /// Converts an arbitrary value from a deserialized dictionary into a
  /// canonical `FieldValue`.
  ///
  /// Supports `nil`/`NSNull`, `Bool`, `Int`, `Int64`, `Double`, and `String`.
  /// Returns `nil` for unrecognized types (arrays, nested dictionaries).
  ///
  /// - Parameter value: The value to convert (may be `nil`).
  /// - Returns: A `FieldValue`, or `nil` if the type is not supported.
  public static func fromAny(_ value: Any?) -> FieldValue? {
    switch value {
    case nil, is NSNull:
      return .null
    case let n as NSNumber:
      // JSONSerialization returns NSNumber for all JSON numbers and booleans.
      // Swift's `as? Bool` incorrectly matches any non-zero NSNumber as `true`,
      // so we must check the CoreFoundation type ID first to distinguish
      // __NSCFBoolean (JSON true/false) from __NSCFNumber (JSON integers/floats).
      if CFGetTypeID(n) == CFBooleanGetTypeID() {
        return .bool(n.boolValue)
      } else if CFNumberIsFloatType(n) {
        return .number(n.doubleValue)
      } else {
        return .int(n.int64Value)
      }
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

/// A protocol for types that can be converted to a `FieldValue` for use in
/// queries and index operations.
///
/// Conforming types include `String`, `Int`, `Int64`, `Double`, `Bool`,
/// `UUID`, `Date`, and `Optional` wrappers. This allows the public API to
/// accept a wide range of value types without forcing callers to construct
/// `FieldValue` directly.
public protocol FieldValueConvertible: Sendable {
  /// Converts this value to its canonical `FieldValue` representation.
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

/// Internal utility for extracting field values from serialised document data
/// and from parsed `[String: Any]` dictionaries.
///
/// `FieldExtractor` is used throughout the query engine, the patch system, and
/// index maintenance. It supports dot-separated paths for nested field access
/// (e.g. `"address.city"`) and array index access (e.g. `"items.0.name"`).
enum FieldExtractor {
  /// Parses serialised document data into a generic string-keyed dictionary.
  ///
  /// - Parameters:
  ///   - data: The encoded document data.
  ///   - format: The serialization format of the data.
  /// - Returns: A `[String: Any]` dictionary representing the document.
  /// - Throws: `NyaruError.decodingFailed` if the data is not a valid object.
  static func parse(_ data: Data, using format: SerializationFormat) throws -> [String: Any] {
    let obj = try Serializer.unpack(data, format: format)
    guard let dict = obj as? [String: Any] else {
      throw NyaruError.decodingFailed("Top-level value is not an object")
    }
    return dict
  }

  /// Walks a dot-separated path in a parsed dictionary and returns the
  /// canonical `FieldValue` at that path.
  ///
  /// Supports nested dictionaries (`"address.city"`) and array index access
  /// (`"items.0.name"`). Returns `nil` if any segment of the path does not
  /// exist.
  ///
  /// - Parameters:
  ///   - dict: The parsed document dictionary.
  ///   - path: A dot-separated field path.
  /// - Returns: The `FieldValue` at the path, or `nil` if not found.
  static func value(in dict: [String: Any], path: String) -> FieldValue? {
    if path.firstIndex(of: ".") == nil {
      guard let raw = dict[path] else { return nil }
      return FieldValue.fromAny(raw)
    }
    var current: Any = dict
    var start = path.startIndex

    while start < path.endIndex {
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

  /// Parses encoded document data and extracts a `FieldValue` at the given
  /// dot-separated path.
  ///
  /// Convenience wrapper that combines `parse(_:using:)` and `value(in:path:)`.
  ///
  /// - Parameters:
  ///   - data: The encoded document data.
  ///   - path: A dot-separated field path.
  ///   - format: The serialization format of the data.
  /// - Returns: The `FieldValue` at the path, or `nil` if not found.
  /// - Throws: `NyaruError.decodingFailed` if the data is not a valid object.
  static func value(in data: Data, path: String, using format: SerializationFormat) throws
    -> FieldValue?
  {
    let dict = try parse(data, using: format)
    return value(in: dict, path: path)
  }
}
