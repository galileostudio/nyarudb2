/// An enumeration that defines the storage format used by the storage engine.
/// This can be used to specify or identify the format in which data is stored.
public enum StorageFormat: String {
    case json
    case messagePack
}

public enum StorageFormatError: Error {
    case unsupportedFormat(String)
}

extension StorageFormat {
    public static func from(_ string: String) throws -> StorageFormat {
        if let format = StorageFormat(rawValue: string) {
            return format
        } else {
            throw StorageFormatError.unsupportedFormat(string)
        }
    }
}
