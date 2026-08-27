import Foundation

/// A JSON value used in MCP request parameters and results.
public enum Value: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case data(mimeType: String? = nil, Data)
    case array([Value])
    case object([String: Value])

    public init<T: Codable>(_ value: T) throws {
        if let value = value as? Value {
            self = value
        } else {
            self = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
        }
    }

    public var isNull: Bool { self == .null }
    public var boolValue: Bool? { guard case let .bool(value) = self else { return nil }; return value }
    public var intValue: Int? { guard case let .int(value) = self else { return nil }; return value }
    public var doubleValue: Double? { guard case let .double(value) = self else { return nil }; return value }
    public var stringValue: String? { guard case let .string(value) = self else { return nil }; return value }
    public var dataValue: (mimeType: String?, data: Data)? { guard case let .data(mimeType, data) = self else { return nil }; return (mimeType, data) }
    public var arrayValue: [Value]? { guard case let .array(value) = self else { return nil }; return value }
    public var objectValue: [String: Value]? { guard case let .object(value) = self else { return nil }; return value }
}

extension Value: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = Self.decodeString(value)
        } else if let value = try? container.decode([Value].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: Value].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Value type not found")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .data(mimeType, data): try container.encode(Self.dataURL(mimeType: mimeType, data: data))
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    private static func decodeString(_ value: String) -> Value {
        guard value.hasPrefix("data:"),
              let separator = value.range(of: ","),
              value[..<separator.lowerBound].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(value[separator.upperBound...]))
        else { return .string(value) }

        let header = String(value[value.index(value.startIndex, offsetBy: 5)..<separator.lowerBound])
        let mimeType = String(header.dropLast(";base64".count))
        return .data(mimeType: mimeType.isEmpty ? nil : mimeType, data)
    }

    private static func dataURL(mimeType: String?, data: Data) -> String {
        "data:\(mimeType ?? "application/octet-stream");base64,\(data.base64EncodedString())"
    }
}

extension Value: ExpressibleByNilLiteral { public init(nilLiteral: ()) { self = .null } }
extension Value: ExpressibleByBooleanLiteral { public init(booleanLiteral value: Bool) { self = .bool(value) } }
extension Value: ExpressibleByIntegerLiteral { public init(integerLiteral value: Int) { self = .int(value) } }
extension Value: ExpressibleByFloatLiteral { public init(floatLiteral value: Double) { self = .double(value) } }
extension Value: ExpressibleByStringLiteral { public init(stringLiteral value: String) { self = .string(value) } }
extension Value: ExpressibleByArrayLiteral { public init(arrayLiteral elements: Value...) { self = .array(elements) } }
extension Value: ExpressibleByDictionaryLiteral { public init(dictionaryLiteral elements: (String, Value)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) } }

/// Open MCP metadata fields, encoded as the `_meta` object.
public typealias Metadata = [String: Value]
