import Foundation
import MessagePack

/// An enumeration that provides functionality for dynamic decoding of data.
/// This can be used to decode data whose structure is not known at compile time.
public enum DynamicDecoder {
    
    /// Extracts a value from the given data for a specified key.
    ///
    /// - Parameters:
    ///   - data: The `Data` object containing the serialized information.
    ///   - key: The key whose associated value needs to be extracted.
    ///   - forIndex: A Boolean indicating whether the extraction is for indexing purposes. Defaults to `false`.
    ///   - storageFormat: The format in which the data is stored. Defaults to `.json`.
    /// - Returns: A `String` representing the extracted value.
    /// - Throws: An error if the extraction process fails.
    public static func extractValue(
        from data: Data,
        key: String,
        forIndex: Bool = false,
        storageFormat: StorageFormat = .json
    ) throws -> String {
        do {
            return try DynamicValueExtractor.extractValue(from: data, key: key, storageFormat: storageFormat)
        } catch _ as DecodingError {
            if forIndex {
                throw StorageEngine.StorageError.indexKeyNotFound(key)
            } else {
                throw StorageEngine.StorageError.partitionKeyNotFound(key)
            }
        } catch {
            throw error
        }
    }
    
    /// An enumeration that provides functionality for extracting dynamic values.
    /// This is used internally to handle dynamic decoding of values in a flexible manner.
    private enum DynamicValueExtractor {
        
        /// An enumeration representing different types of values that can be dynamically decoded.
        ///
        /// - Cases:
        ///   - `string(String)`: Represents a string value.
        ///   - `number(NSNumber)`: Represents a numeric value.
        ///   - `bool(Bool)`: Represents a boolean value.
        ///   - `null`: Represents a null value.
        enum ValueType: Decodable {
            case string(String)
            case number(NSNumber)
            case bool(Bool)
            case null
            
            /// Initializes a new instance of the conforming type by decoding from the given decoder.
            /// 
            /// - Parameter decoder: The decoder to read data from.
            /// - Throws: An error if decoding fails, such as if the data is corrupted or does not match the expected format.
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let str = try? container.decode(String.self) {
                    self = .string(str)
                } else if let num = try? container.decode(Double.self) {
                    self = .number(NSNumber(value: num))
                } else if let bool = try? container.decode(Bool.self) {
                    self = .bool(bool)
                } else if container.decodeNil() {
                    self = .null
                } else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Unsupported value type"
                    )
                }
            }
        }
        
        /// Extracts a value associated with a given key from the provided data using the specified storage format.
        ///
        /// - Parameters:
        ///   - data: The data from which the value will be extracted.
        ///   - key: The key whose associated value is to be extracted.
        ///   - storageFormat: The format in which the data is stored. Defaults to `.json`.
        /// - Returns: The value associated with the specified key as a `String`.
        /// - Throws: An error if the extraction process fails, such as if the data is malformed or the key is not found.
        static func extractValue(from data: Data, key: String, storageFormat: StorageFormat = .json) throws -> String {
            let dict: [String: ValueType]
            switch storageFormat {
            case .json:
                dict = try JSONDecoder().decode([String: ValueType].self, from: data)
            case .messagePack:
                let (value, _) = try unpack(data)
                guard case .map(let map) = value else {
                    throw StorageFormatError.unsupportedFormat("Expected MessagePack Map, but found something else.")
                }
                var tempDict: [String: ValueType] = [:]
                for (keyValue, val) in map {
                    if case let .string(keyStr) = keyValue {
                        tempDict[keyStr] = try decodeValueType(from: val)
                    }
                }
                dict = tempDict
            }
            
            guard let value = dict[key] else {
                throw DecodingError.keyNotFound(
                    DynamicCodingKey(stringValue: key)!,
                    DecodingError.Context(codingPath: [], debugDescription: "Key \(key) not found")
                )
            }
            
            switch value {
            case .string(let str):
                return str
            case .number(let num):
                return num.stringValue
            case .bool(let bool):
                return bool ? "true" : "false"
            case .null:
                return "null"
            }
        }
        
        /// Decodes a `ValueType` from the given `MessagePackValue`.
        ///
        /// This method attempts to interpret the provided `MessagePackValue` and convert it
        /// into the corresponding `ValueType`. If the conversion fails, an error is thrown.
        ///
        /// - Parameter value: The `MessagePackValue` to decode.
        /// - Throws: An error if the decoding process fails.
        /// - Returns: The decoded `ValueType` corresponding to the provided `MessagePackValue`.
        private static func decodeValueType(from value: MessagePackValue) throws -> ValueType {
            switch value {
            case .string(let str):
                return .string(str)
            case .int(let num):
                return .number(NSNumber(value: num))
            case .uint(let num):
                return .number(NSNumber(value: num))
            case .bool(let bool):
                return .bool(bool)
            case .float(let float):
                return .number(NSNumber(value: float))
            case .double(let double):
                return .number(NSNumber(value: double))
            case .nil:
                return .null
            default:
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: [], debugDescription: "Unsupported MessagePack value type: \(value)")
                )
            }
        }
    }
    
    /// A private struct that conforms to the `CodingKey` protocol.
    /// This is used to dynamically create coding keys at runtime,
    /// enabling flexible decoding of data structures where the keys
    /// are not known at compile time.
    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { return nil }
        
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
