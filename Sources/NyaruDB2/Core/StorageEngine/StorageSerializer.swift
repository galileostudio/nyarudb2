import Foundation
import MessagePack


extension Dictionary where Key == String, Value == MessagePackValue {
    func toDictionary() -> [String: Any] {
        var result = [String: Any]()
        for (key, value) in self {
            result[key] = value.toNative()
        }
        return result
    }
}

extension Dictionary where Key == MessagePackValue, Value == MessagePackValue {
    func toDictionary() -> [String: Any] {
        var result = [String: Any]()
        for (key, value) in self {
            if case let .string(stringKey) = key {
                result[stringKey] = value.toNative()
            }
        }
        return result
    }
}


extension MessagePackValue {
    func toNative() -> Any {
        switch self {
        case .string(let str):
            return str
        case .int(let num):
            return Int(num)
        case .bool(let bool):
            return bool
        case .nil:
            return NSNull()
        case .float(let float):
            return Float(float)
        case .double(let double):
            return double
        case .binary(let data):
            return data
        case .array(let arr):
            return arr.map { $0.toNative() }
        case .map(let dict):
            return dict.toDictionary()
        default:
            return NSNull() // outros tipos não suportados diretamente
        }
    }
}

public struct StorageSerializer {
    
    public static func decodeToDictionary(data: Data, format: StorageFormat) throws -> [String: Any] {
        switch format {
        case .json:
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "DecodeError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON structure"])
            }
            return dict
        case .messagePack:
            let (value, _) = try unpack(data)
            if case .map(let map) = value {
                return map.toDictionary()
            } else {
                throw StorageFormatError.unsupportedFormat("Expected MessagePack Map, but found something else.")
            }
        }
    }
    
    public static func encode<T: Encodable>(_ value: T, using format: StorageFormat) throws -> Data {
        switch format {
        case .json:
            return try JSONEncoder().encode(value)
        case .messagePack:
            let msgpackValue = try value.toMessagePackValue()
            return pack(msgpackValue)
        }
    }
    
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, using format: StorageFormat) throws -> T {
        switch format {
        case .json:
            return try JSONDecoder().decode(T.self, from: data)
        case .messagePack:
            let (value, _) = try unpack(data)
            return try T(from: MessagePackDecoder(value: value))
        }
    }
}

extension Encodable {
    func toMessagePackValue() throws -> MessagePackValue {
        let data = try JSONEncoder().encode(self)
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) else {
            throw NSError(domain: "toMessagePackValue", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize JSON"])
        }
        return MessagePackValue.from(jsonObject: jsonObject)
    }
}

extension MessagePackValue {
    static func from(jsonObject: Any) -> MessagePackValue {
        switch jsonObject {
        case let dict as [String: Any]:
            var map: [MessagePackValue: MessagePackValue] = [:]
            for (key, value) in dict {
                map[.string(key)] = from(jsonObject: value)
            }
            return .map(map)
        case let array as [Any]:
            return .array(array.map(from))
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if number.isBool {
                return .bool(number.boolValue)
            } else {
                return .double(number.doubleValue)
            }
        case _ as NSNull:
            return .nil
        default:
            return .nil
        }
    }
}

private extension NSNumber {
    var isBool: Bool { CFGetTypeID(self) == CFBooleanGetTypeID() }
}

struct MessagePackDecoder: Decoder {
    let value: MessagePackValue
    
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]
    
    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .map(let map) = value else {
            throw DecodingError.typeMismatch([String: MessagePackValue].self, DecodingError.Context(codingPath: codingPath, debugDescription: "Expected a map"))
        }
        let container = MessagePackKeyedContainer<Key>(codingPath: codingPath, map: map)
        return KeyedDecodingContainer(container)
    }
    
    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case .array(let array) = value else {
            throw DecodingError.typeMismatch([MessagePackValue].self, DecodingError.Context(codingPath: codingPath, debugDescription: "Expected an array"))
        }
        return MessagePackUnkeyedContainer(codingPath: codingPath, array: array)
    }
    
    func singleValueContainer() throws -> SingleValueDecodingContainer {
        return MessagePackSingleValueContainer(value: value, codingPath: codingPath)
    }
}

struct MessagePackKeyedContainer<K: CodingKey>: KeyedDecodingContainerProtocol {
    var codingPath: [CodingKey]
    let map: [MessagePackValue: MessagePackValue]
    
    var allKeys: [K] {
        map.keys.compactMap {
            if case let .string(str) = $0 { return K(stringValue: str) }
            return nil
        }
    }
    
    func contains(_ key: K) -> Bool {
        map.keys.contains { if case .string(let k) = $0 { return k == key.stringValue } else { return false } }
    }
    
    func decodeNil(forKey key: K) throws -> Bool {
        guard let value = map[.string(key.stringValue)] else { return true }
        if case .nil = value { return true }
        return false
    }
    
    func decode<T: Decodable>(_ type: T.Type, forKey key: K) throws -> T {
        guard let value = map[.string(key.stringValue)] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: codingPath, debugDescription: "Key not found"))
        }
        return try T(from: MessagePackDecoder(value: value))
    }
    
    func nestedContainer<NK: CodingKey>(keyedBy type: NK.Type, forKey key: K) throws -> KeyedDecodingContainer<NK> {
        throw DecodingError.typeMismatch([String: Any].self, DecodingError.Context(codingPath: codingPath, debugDescription: "nestedContainer not supported"))
    }
    
    func nestedUnkeyedContainer(forKey key: K) throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch([Any].self, DecodingError.Context(codingPath: codingPath, debugDescription: "nestedUnkeyedContainer not supported"))
    }
    
    func superDecoder() throws -> Decoder { throw DecodingError.dataCorrupted(DecodingError.Context(
        codingPath: codingPath,
        debugDescription: "superDecoder not supported in MessagePackKeyedContainer"
    )) }
    
    func superDecoder(forKey key: K) throws -> Decoder {
        throw DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "superDecoder(forKey:) not supported in MessagePackKeyedContainer"
        ))
    }
}

struct MessagePackUnkeyedContainer: UnkeyedDecodingContainer {
    var codingPath: [CodingKey]
    let array: [MessagePackValue]
    var currentIndex = 0
    
    var count: Int? { array.count }
    var isAtEnd: Bool { currentIndex >= array.count }
    
    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { throw DecodingError.valueNotFound(Any?.self, DecodingError.Context(codingPath: codingPath, debugDescription: "No more elements")) }
        if case .nil = array[currentIndex] {
            currentIndex += 1
            return true
        }
        return false
    }
    
    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard !isAtEnd else { throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: codingPath, debugDescription: "No more elements")) }
        defer { currentIndex += 1 }
        return try T(from: MessagePackDecoder(value: array[currentIndex]))
    }
    
    mutating func nestedContainer<NK: CodingKey>(keyedBy type: NK.Type) throws -> KeyedDecodingContainer<NK> {
        throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: codingPath, debugDescription: "Nested containers not supported"))
    }
    
    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: codingPath, debugDescription: "Nested unkeyed containers not supported"))
    }
    mutating func superDecoder() throws -> Decoder {
        throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: codingPath, debugDescription: "superDecoder not supported in unkeyed containers"))
    }
}

struct MessagePackSingleValueContainer: SingleValueDecodingContainer {
    let value: MessagePackValue
    var codingPath: [CodingKey]
    
    func decodeNil() -> Bool {
        if case .nil = value { return true }
        return false
    }
    
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try T(from: MessagePackDecoder(value: value))
    }
}
