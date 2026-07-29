import Foundation

public enum ResponseEncoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func encode<Response: Encodable>(_ response: Response) -> Data {
        do {
            return try encoder.encode(response)
        } catch {
            preconditionFailure("LocalOCR responses must always be JSON encodable: \(error)")
        }
    }
}
