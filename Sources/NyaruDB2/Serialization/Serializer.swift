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

  /// Converte o Data para um dicionário genérico [String: Any] para o FieldExtractor ler.
  static func unpack(_ data: Data, format: SerializationFormat) throws -> Any {
    switch format {
    case .json:
      return try JSONSerialization.jsonObject(with: data)
    case .msgpack:
      // O MsgPackDecoder é Codable, não suporta `Any` nativo.
      // Usamos o AnyDecodable abaixo para converter o binário em [String: Any].
      let anyDecodable = try MsgPackDecoder().decode(AnyDecodable.self, from: data)
      return anyDecodable.value
    }
  }
}

// MARK: - AnyDecodable Bridge
// Truque nativo do Swift para decodificar qualquer coisa para `Any` usando a API Codable.

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
