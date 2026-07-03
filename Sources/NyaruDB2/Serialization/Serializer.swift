import Foundation
import SwiftMsgpack

/// Document serialization format.
public enum SerializationFormat: String, CaseIterable, Codable, Sendable {
  case json
  case msgpack
}

/// Centralized serialization/deserialization for JSON and MessagePack.
enum Serializer {

  @inlinable
  static func encode<T: Encodable>(_ value: T, format: SerializationFormat) throws -> Data {
    switch format {
    case .json:
      return try JSONEncoder().encode(value)
    case .msgpack:
      return try MsgPackEncoder().encode(value)
    }
  }

  @inlinable
  static func decode<T: Decodable>(_ type: T.Type, from data: Data, format: SerializationFormat)
    throws -> T
  {
    switch format {
    case .json:
      return try JSONDecoder().decode(type, from: data)
    case .msgpack:
      return try MsgPackDecoder().decode(type, from: data)
    }
  }

  /// Converts Data to a generic `[String: Any]` dictionary for FieldExtractor.
  /// Uses `AnyDecodable` to avoid `NSNumber` bridging issues.
  static func unpack(_ data: Data, format: SerializationFormat) throws -> Any {
    switch format {
    case .json:
      let anyDecodable = try JSONDecoder().decode(AnyDecodable.self, from: data)
      return anyDecodable.value
    case .msgpack:
      let anyDecodable = try MsgPackDecoder().decode(AnyDecodable.self, from: data)
      return anyDecodable.value
    }
  }
}

// MARK: - AnyDecodable

/// Decodes any JSON/MsgPack value into Swift native types (Int64, Bool, Double, String, etc.)
/// avoiding `NSNumber` and preserving type information.
struct AnyDecodable: Decodable {
  let value: Any

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    if container.decodeNil() {
      self.value = NSNull()
      return
    }

    // Ordered to prevent Int64 from swallowing Bools or vice-versa
    if let v = try? container.decode(Bool.self) {
      self.value = v
    } else if let v = try? container.decode(Int64.self) {
      self.value = v
    } else if let v = try? container.decode(Double.self) {
      self.value = v
    } else if let v = try? container.decode(String.self) {
      self.value = v
    } else if let v = try? container.decode([AnyDecodable].self) {
      self.value = v.map { $0.value }
    } else if let v = try? container.decode([String: AnyDecodable].self) {
      self.value = v.mapValues { $0.value }
    } else {
      self.value = NSNull()
    }
  }
}

// MARK: - AnyEncodable

/// Encodes a dynamic `[String: Any]` dictionary using Swift's native Encoder.
/// Supports: Bool, Int, Int64, Double, String, [Any], and [String: Any].
struct AnyEncodable: Encodable {
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
        // AnyCodingKey init is non-failable, so no force unwrapping needed
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
        // Fail fast: do not silently encode unsupported types as nil
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

/// Simple CodingKey implementation supporting both string and integer keys.
/// Non-failable to avoid force-unwrapping in `AnyEncodable`.
struct AnyCodingKey: CodingKey {
  let stringValue: String
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
