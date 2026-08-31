import Foundation

/// The JSON-RPC error values emitted by the local stdio server.
public enum MCPError: Error, Hashable, Codable, Sendable {
    case parseError(String?)
    case invalidRequest(String?)
    case methodNotFound(String?)
    case invalidParams(String?)
    case internalError(String?)
    case serverError(code: Int, message: String)

    public var code: Int {
        switch self {
        case .parseError: -32700
        case .invalidRequest: -32600
        case .methodNotFound: -32601
        case .invalidParams: -32602
        case .internalError: -32603
        case let .serverError(code, _): code
        }
    }

    public var message: String {
        switch self {
        case let .parseError(detail): "Parse error: Invalid JSON" + detailSuffix(detail)
        case let .invalidRequest(detail): "Invalid Request" + detailSuffix(detail)
        case let .methodNotFound(detail): "Method not found" + detailSuffix(detail)
        case let .invalidParams(detail): "Invalid params" + detailSuffix(detail)
        case let .internalError(detail): "Internal error" + detailSuffix(detail)
        case let .serverError(_, message): "Server error: \(message)"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        if let detail {
            try container.encode(["detail": detail], forKey: .data)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(Int.self, forKey: .code)
        let message = try container.decode(String.self, forKey: .message)
        let data = try container.decodeIfPresent([String: Value].self, forKey: .data)
        let detail = data?["detail"]?.stringValue ?? message
        switch code {
        case -32700: self = .parseError(detail)
        case -32600: self = .invalidRequest(detail)
        case -32601: self = .methodNotFound(detail)
        case -32602: self = .invalidParams(detail)
        case -32603: self = .internalError(detail)
        default: self = .serverError(code: code, message: message)
        }
    }

    private enum CodingKeys: String, CodingKey { case code, message, data }

    private var detail: String? {
        switch self {
        case let .parseError(detail), let .invalidRequest(detail), let .methodNotFound(detail), let .invalidParams(detail), let .internalError(detail): detail
        case .serverError: nil
        }
    }

    private func detailSuffix(_ detail: String?) -> String { detail.map { ": \($0)" } ?? "" }
}
