import Foundation
import SwiftMsgpack

/// Specifies the wire format used to serialize and deserialize documents.
///
/// NyaruDB supports two formats:
/// - `.json`: Standard JSON, produced and consumed by `JSONEncoder`/`JSONDecoder`.
/// - `.msgpack`: MessagePack, a compact binary format, produced and consumed by
///   `MsgPackEncoder`/`MsgPackDecoder` from the SwiftMsgpack package.
///
/// The format is stored in the collection manifest and is immutable after
/// collection creation — changing it would make existing records unreadable.
public enum SerializationFormat: String, CaseIterable, Codable, Sendable {
  /// JavaScript Object Notation (JSON).
  case json
  /// MessagePack binary format.
  case msgpack
}

/// Provides centralized encoding, decoding, and unpacking of documents
/// regardless of the serialization format in use.
///
/// Every document that flows through NyaruDB's public API is encoded or decoded
/// here. The type dispatches to the appropriate backend (`JSONEncoder` or
/// `MsgPackEncoder`) based on the `SerializationFormat` value stored in the
/// collection manifest.
///
/// - Note: The `unpack(_:format:)` method is used internally by `FieldExtractor`
///   for predicate evaluation, patch, and partial reads. It decodes into a
///   generic `[String: Any]` dictionary.
enum Serializer {

  private static let jsonEncoder = JSONEncoder()
  private static let jsonDecoder = JSONDecoder()
  private static let msgPackEncoder = MsgPackEncoder()
  private static let msgPackDecoder = MsgPackDecoder()

  /// Encodes a Swift value to `Data` using the specified serialization format.
  ///
  /// - Parameters:
  ///   - value: The value to encode (must conform to `Encodable`).
  ///   - format: The target serialization format (`.json` or `.msgpack`).
  /// - Returns: The encoded data.
  /// - Throws: Encoding errors from the underlying encoder.
  @inlinable
  static func encode<T: Encodable>(_ value: T, format: SerializationFormat) throws -> Data {
    switch format {
    case .json:
      return try jsonEncoder.encode(value)
    case .msgpack:
      return try msgPackEncoder.encode(value)
    }
  }

  /// Decodes a Swift value from `Data` using the specified serialization format.
  ///
  /// - Parameters:
  ///   - type: The expected Swift type.
  ///   - data: The encoded data.
  ///   - format: The serialization format used to produce the data.
  /// - Returns: The decoded value.
  /// - Throws: `NyaruError.decodingFailed` if decoding fails.
  @inlinable
  static func decode<T: Decodable>(_ type: T.Type, from data: Data, format: SerializationFormat)
    throws -> T
  {
    switch format {
    case .json:
      return try jsonDecoder.decode(type, from: data)
    case .msgpack:
      return try msgPackDecoder.decode(type, from: data)
    }
  }

  /// Decodes many payloads in parallel across all cores, preserving order.
  ///
  /// Fresh decoder instances are created inside the parallel region — the
  /// shared decoders above must not be used from multiple threads
  /// (`MsgPackDecoder` is documented non-Sendable).
  ///
  /// - Parameters:
  ///   - type: The expected Swift type.
  ///   - datas: The encoded payloads.
  ///   - format: The serialization format of the payloads.
  /// - Returns: The decoded values, in input order.
  /// - Throws: Decoding errors from the underlying decoder.
  static func decodeBatch<T: Decodable>(
    _ type: T.Type, from datas: [Data], format: SerializationFormat
  ) throws -> [T] {
    switch format {
    case .json:
      return try Parallel.map(datas) { try JSONDecoder().decode(type, from: $0) }
    case .msgpack:
      // lazyScan materialises containers on demand instead of building the
      // whole MsgPackValue tree upfront — measurably faster for flat
      // documents where only leaf values are consumed.
      return try Parallel.map(datas) {
        try MsgPackDecoder(options: .lazyScan).decode(type, from: $0)
      }
    }
  }

  /// Decodes a single payload with a freshly-created decoder — safe to call
  /// from a concurrent context (the shared `Serializer` decoders are not
  /// thread-safe). Mirrors the per-element decode of `decodeBatch`.
  @inline(__always)
  static func decodeConcurrent<T: Decodable>(
    _ type: T.Type, from data: Data, format: SerializationFormat
  ) throws -> T {
    switch format {
    case .json:
      return try JSONDecoder().decode(type, from: data)
    case .msgpack:
      return try MsgPackDecoder(options: .lazyScan).decode(type, from: data)
    }
  }

  /// Converts encoded document data into a generic `[String: Any]` dictionary
  /// for field extraction and predicate evaluation.
  ///
  /// JSON uses `JSONSerialization` (C-level, far faster than `JSONDecoder`
  /// for raw dictionaries); MsgPack uses the native `MsgPackExtractor`.
  /// `FieldValue.fromAny` handles the NSNumber bool/number disambiguation
  /// downstream, so type information survives for query comparisons.
  ///
  /// - Parameters:
  ///   - data: The encoded document data.
  ///   - format: The serialization format of the data.
  /// - Returns: The root decoded value (expected to be a dictionary).
  /// - Throws: Decoding errors from the underlying decoder.
  static func unpack(_ data: Data, format: SerializationFormat) throws -> Any {
    switch format {
    case .json:
      return try JSONSerialization.jsonObject(with: data, options: [])
    case .msgpack:
      return try MsgPackExtractor.extractDictionary(from: data)
    }
  }

  public struct DocumentMetadata {
    public let id: FieldValue
    public let partitionValue: FieldValue?
    public let indexEntries: [(field: String, key: FieldValue)]
  }

  /// Extracts the values of the given fields, using a MsgPack skip-scan when
  /// every requested path is top-level — unwanted fields (e.g. large content
  /// strings) are skipped via length prefixes instead of being decoded. JSON
  /// and dot paths fall back to a full parse.
  ///
  /// - Returns: The scalar values found; absent or non-scalar fields are
  ///   omitted. Malformed input yields an empty dictionary.
  static func extractFieldValues(
    from data: Data, fields: [String], format: SerializationFormat
  ) -> [String: FieldValue] {
    extractFieldValues(from: data, plan: FieldPlan(fields: fields), format: format)
  }

  /// The per-query preparation for repeated field extraction: UTF-8 key
  /// bytes and the dot-path check are computed once here instead of once
  /// per document inside hot loops.
  struct FieldPlan: Sendable {
    let fields: [String]
    let keyBytes: [[UInt8]]
    let hasDotPath: Bool

    init(fields: [String]) {
      self.fields = fields
      self.keyBytes = fields.map { Array($0.utf8) }
      self.hasDotPath = fields.contains { $0.contains(".") }
    }
  }

  /// Extracts field values using a pre-built `FieldPlan` — the hot-loop
  /// variant of `extractFieldValues(from:fields:format:)`.
  static func extractFieldValues(
    from data: Data, plan: FieldPlan, format: SerializationFormat
  ) -> [String: FieldValue] {
    if format == .msgpack, !plan.hasDotPath,
      let found = MsgPackExtractor.extractTopLevelFields(
        from: data, fields: plan.fields, keyBytes: plan.keyBytes)
    {
      return found
    }

    guard let dict = try? FieldExtractor.parse(data, using: format) else { return [:] }
    var out: [String: FieldValue] = [:]
    out.reserveCapacity(plan.fields.count)
    for field in plan.fields {
      if let value = FieldExtractor.value(in: dict, path: field) {
        out[field] = value
      }
    }
    return out
  }

  /// Extracts the id, partition value, and index keys from an encoded
  /// document in a single pass, avoiding repeated per-field parses (and,
  /// for MsgPack, avoiding materialising the document at all).
  static func extractMetadata(
    from data: Data, idField: String, partitionKey: String?, indexedFields: [String],
    format: SerializationFormat
  ) throws -> DocumentMetadata {
    var fields = indexedFields
    if !fields.contains(idField) { fields.append(idField) }
    if let pk = partitionKey, !fields.contains(pk) { fields.append(pk) }

    let values = extractFieldValues(from: data, fields: fields, format: format)

    guard let id = values[idField] else {
      throw NyaruError.idFieldMissing(field: idField)
    }
    let partitionValue = partitionKey.flatMap { values[$0] }

    var entries: [(field: String, key: FieldValue)] = []
    entries.reserveCapacity(indexedFields.count)
    for field in indexedFields {
      if let key = values[field] {
        entries.append((field, key))
      }
    }

    return DocumentMetadata(id: id, partitionValue: partitionValue, indexEntries: entries)
  }
}

// MARK: - AnyEncodable

/// Encodes a dynamic `[String: Any]` dictionary using Swift's native encoder,
/// supporting `Bool`, `Int`, `Int64`, `Double`, `String`, `[Any]`, and
/// `[String: Any]` values.
///
/// Used during patch (partial update) to re-encode the merged document
/// dictionary without going through `Codable` conformance on the document type.
///
/// - Note: Unsupported value types cause a hard `EncodingError` rather than
///   silent data loss by encoding them as `nil`.
struct AnyEncodable: Encodable {
  /// The value to encode.
  let value: Any

  init(value: Any) {
    self.value = value
  }

  func encode(to encoder: Encoder) throws {
    try encodeAny(value, to: encoder)
  }

  private func encodeAny(_ value: Any, to encoder: Encoder) throws {
    switch value {
    case let dict as [String: Any]:
      var container = encoder.container(keyedBy: AnyCodingKey.self)
      for (key, val) in dict {
        try encodeAny(val, to: container.superEncoder(forKey: AnyCodingKey(stringValue: key)))
      }

    case let arr as [Any]:
      var container = encoder.unkeyedContainer()
      for val in arr {
        try encodeAny(val, to: container.superEncoder())
      }

    default:
      var container = encoder.singleValueContainer()
      switch value {
      case is NSNull:
        try container.encodeNil()
      case let n as NSNumber:
        // Must check CFTypeID before `as? Bool` — NSNumber(1) incorrectly matches Bool in Swift.
        if CFGetTypeID(n) == CFBooleanGetTypeID() {
          try container.encode(n.boolValue)
        } else if CFNumberIsFloatType(n) {
          try container.encode(n.doubleValue)
        } else {
          try container.encode(n.int64Value)
        }
      case let v as Bool:
        try container.encode(v)
      case let v as Int:
        try container.encode(v)
      case let v as Int64:
        try container.encode(v)
      case let v as Double:
        try container.encode(v)
      case let v as String:
        try container.encode(v)
      default:
        let context = EncodingError.Context(
          codingPath: encoder.codingPath,
          debugDescription: "Unsupported type for AnyEncodable: \(type(of: value))"
        )
        throw EncodingError.invalidValue(value, context)
      }
    }
  }
}

// MARK: - AnyCodingKey

/// A simple `CodingKey` implementation that supports both string and integer
/// keys, used by `AnyEncodable` to encode dictionary keys.
///
/// Both initialisers are non-failable, so callers never need to force-unwrap.
struct AnyCodingKey: CodingKey {
  /// The string representation of the key.
  let stringValue: String
  /// The optional integer representation of the key.
  let intValue: Int?

  init(stringValue: String) {
    self.stringValue = stringValue
    self.intValue = nil
  }

  init(intValue: Int) {
    self.stringValue = String(intValue)
    self.intValue = intValue
  }
}
