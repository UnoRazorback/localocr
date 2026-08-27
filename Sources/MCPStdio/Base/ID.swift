import Foundation

/// A JSON-RPC request identifier.
public enum ID: Hashable, Codable, Sendable {
    case null
    case string(String)
    case int(Int)

    public static var random: ID {
        .string(UUID().uuidString)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "ID must be null, a string, or an integer")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .string(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        }
    }
}

extension ID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension ID: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}
