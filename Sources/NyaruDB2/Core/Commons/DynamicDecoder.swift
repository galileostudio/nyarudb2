import Foundation
import MessagePack

/// An enumeration that provides functionality for dynamic decoding of data.
/// This can be used to decode data whose structure is not known at compile time.
public enum DynamicDecoder {

    /// Extracts a value from the given data for a specified key.
    ///
    /// - Parameters:
    ///   - data: The `Data` object containing the encoded information.
    ///   - key: The key whose associated value needs to be extracted.
    ///   - forIndex: A Boolean value indicating whether the extraction is for indexing purposes. Defaults to `false`.
    ///   - storageFormat: The storage format used for decoding. Defaults to `.json`.
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

    /// An enumeration that provides functionality to extract dynamic values.
    /// This is used internally to handle dynamic decoding of values.
    private enum DynamicValueExtractor {

        /// An enumeration representing different types of values that can be decoded.
        enum ValueType: Decodable {
            case string(String)
            case number(NSNumber)
            case bool(Bool)
            case null

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

        /// Extracts a value associated with a given key from the provided data.
        static func extractValue(
            from data: Data,
            key: String,
            storageFormat: StorageFormat = .json
        ) throws -> String {
            switch storageFormat {
            case .json:
                let dict = try JSONDecoder().decode([String: ValueType].self, from: data)
                guard let value = dict[key] else {
                    throw DecodingError.keyNotFound(
                        DynamicCodingKey(stringValue: key)!,
                        DecodingError.Context(
                            codingPath: [],
                            debugDescription: "Key \(key) not found"
                        )
                    )
                }
                return try mapToString(value)

            case .messagePack:
                let (value, _) = try unpack(data)
                guard case .map(let map) = value else {
                    throw StorageFormatError.unsupportedFormat("Expected MessagePack Map, but found something else.")
                }
                guard let extracted = map[.string(key)] else {
                    throw DecodingError.keyNotFound(
                        DynamicCodingKey(stringValue: key)!,
                        DecodingError.Context(
                            codingPath: [],
                            debugDescription: "Key \(key) not found"
                        )
                    )
                }
                return try mapToString(extracted)

            }
        }

        /// Converts a `ValueType` or `MessagePackValue` to `String`.
        private static func mapToString(_ value: Any) throws -> String {
            switch value {
            case let value as ValueType:
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
            case let value as MessagePackValue:
                switch value {
                case .string(let str):
                    return str
                case .int(let int):
                    return String(int)
                case .uint(let uint):
                    return String(uint)
                case .bool(let bool):
                    return bool ? "true" : "false"
                case .float(let float):
                    return String(float)
                case .double(let double):
                    return String(double)
                case .nil:
                    return "null"
                default:
                    throw StorageFormatError.unsupportedFormat("Unsupported MessagePack value type for key extraction.")
                }
            default:
                throw StorageFormatError.unsupportedFormat("Unsupported value type for key extraction.")
            }
        }
    }

    /// A private struct that conforms to the `CodingKey` protocol.
    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { return nil }

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
