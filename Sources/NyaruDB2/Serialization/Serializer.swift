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
      return try Parallel.map(datas) { try MsgPackDecoder().decode(type, from: $0) }
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

  /// Extracts a single field value without building the full document dictionary.
  static func fieldValue(in data: Data, path: String, format: SerializationFormat) -> FieldValue? {
    switch format {
    case .json:

      guard let dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
      else {
        return nil
      }
      return FieldExtractor.value(in: dict, path: path)
    case .msgpack:
      return MsgPackExtractor.fieldValue(in: data, path: path)
    }
  }

  public struct DocumentMetadata {
    public let id: FieldValue
    public let partitionValue: FieldValue?
    public let indexEntries: [(field: String, key: FieldValue)]
  }

  /// Extracts the id, partition value, and index keys from an encoded
  /// document in a single parse, avoiding repeated per-field parses.
  static func extractMetadata(
    from data: Data, idField: String, partitionKey: String?, indexedFields: [String],
    format: SerializationFormat
  ) throws -> DocumentMetadata {
    let dict: [String: Any]
    switch format {
    case .json:
      dict = (try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]) ?? [:]
    case .msgpack:
      dict = try MsgPackExtractor.extractDictionary(from: data)
    }

    guard let id = FieldExtractor.value(in: dict, path: idField) else {
      throw NyaruError.idFieldMissing(field: idField)
    }

    let partitionValue = partitionKey.flatMap { FieldExtractor.value(in: dict, path: $0) }

    var entries: [(field: String, key: FieldValue)] = []
    entries.reserveCapacity(indexedFields.count + 1)
    for field in indexedFields {
      if let key = FieldExtractor.value(in: dict, path: field) {
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
