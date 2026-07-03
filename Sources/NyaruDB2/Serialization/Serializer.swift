import Foundation
import SwiftMsgpack

/// Document serialization format.
public enum SerializationFormat: String, CaseIterable, Codable, Sendable {
  case json
  case msgpack
}

enum Serializer {
  static func encode<T: Encodable>(_ value: T, format: SerializationFormat) throws -> Data {
    switch format {
    case .json:
      return try JSONEncoder().encode(value)
    case .msgpack:
      return try MsgPackEncoder().encode(value)
    }
  }

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

  /// Converts Data to a generic [String: Any] dictionary for FieldExtractor to read.
  static func unpack(_ data: Data, format: SerializationFormat) throws -> Any {
    switch format {
    case .json:
      // Uses native JSONDecoder instead of JSONSerialization to avoid NSNumber bridging issues.
      let anyDecodable = try JSONDecoder().decode(AnyDecodable.self, from: data)
      return anyDecodable.value
    case .msgpack:
      let anyDecodable = try MsgPackDecoder().decode(AnyDecodable.self, from: data)
      return anyDecodable.value
    }
  }
}

// MARK: - AnyDecodable Bridge
// Native Swift trick to decode anything into `Any` using the Codable API.
// This ensures we only get pure Swift types (Int64, Bool, String), bypassing Objective-C's NSNumber.

struct AnyDecodable: Decodable {
  let value: Any

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self.value = NSNull()
    } else if let v = try? container.decode(Bool.self) {
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

// MARK: - AnyEncodable Bridge
// Allows encoding a [String: Any] dictionary using Swift's native Encoder (JSON or MsgPack).

struct AnyEncodable: Encodable {
  let value: Any

  init(value: Any) { self.value = value }

  func encode(to encoder: Encoder) throws {
    try encodeAny(value, to: encoder)
  }

  private func encodeAny(_ value: Any, to encoder: Encoder) throws {
    if let dict = value as? [String: Any] {
      var container = encoder.container(keyedBy: AnyCodingKey.self)
      for (key, val) in dict {
        try encodeAny(val, to: container.superEncoder(forKey: AnyCodingKey(stringValue: key)!))
      }
      return
    }
    if let arr = value as? [Any] {
      var container = encoder.unkeyedContainer()
      for val in arr {
        try encodeAny(val, to: container.superEncoder())
      }
      return
    }

    var container = encoder.singleValueContainer()
    if value is NSNull {
      try container.encodeNil()
    } else if let v = value as? Bool {
      try container.encode(v)
    } else if let v = value as? Int64 {
      try container.encode(v)
    } else if let v = value as? Int {
      try container.encode(v)
    } else if let v = value as? Double {
      try container.encode(v)
    } else if let v = value as? String {
      try container.encode(v)
    } else {
      try container.encodeNil()
    }
  }
}

struct AnyCodingKey: CodingKey {
  var stringValue: String
  var intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
  }

  init?(intValue: Int) {
    self.stringValue = String(intValue)
    self.intValue = intValue
  }
}
