import Foundation

private let jsonrpcVersion = "2.0"

public protocol NotRequired { init() }

public struct Empty: NotRequired, Hashable, Codable, Sendable { public init() {} }
extension Value: NotRequired { public init() { self = .null } }

public protocol Method: Sendable {
    associatedtype Parameters: Codable & Hashable & Sendable = Empty
    associatedtype Result: Codable & Hashable & Sendable = Empty
    static var name: String { get }
}

extension Method {
    public static func request(id: ID = .random, _ parameters: Parameters) -> Request<Self> {
        Request(id: id, method: name, params: parameters)
    }

    public static func response(id: ID, result: Result) -> Response<Self> {
        Response(id: id, result: .success(result))
    }

    public static func response(id: ID, error: MCPError) -> Response<Self> {
        Response(id: id, result: .failure(error))
    }
}

extension Method where Parameters == Empty {
    public static func request(id: ID = .random) -> Request<Self> { request(id: id, Empty()) }
}

public struct Request<M: Method>: Hashable, Identifiable, Codable, Sendable {
    public let id: ID
    public let method: String
    public let params: M.Parameters

    public init(id: ID = .random, method: String = M.name, params: M.Parameters) {
        self.id = id
        self.method = method
        self.params = params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .jsonrpc) == jsonrpcVersion else {
            throw DecodingError.dataCorruptedError(forKey: .jsonrpc, in: container, debugDescription: "Invalid JSON-RPC version")
        }
        id = try container.decode(ID.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        if M.Parameters.self is NotRequired.Type {
            params = try container.decodeIfPresent(M.Parameters.self, forKey: .params) ?? (M.Parameters.self as! any NotRequired.Type).init() as! M.Parameters
        } else {
            params = try container.decode(M.Parameters.self, forKey: .params)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpcVersion, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encode(params, forKey: .params)
    }

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params }
}

public struct Response<M: Method>: Hashable, Identifiable, Codable, Sendable {
    public let id: ID
    public let result: Result<M.Result, MCPError>

    public init(id: ID, result: Result<M.Result, MCPError>) {
        self.id = id
        self.result = result
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .jsonrpc) == jsonrpcVersion else {
            throw DecodingError.dataCorruptedError(forKey: .jsonrpc, in: container, debugDescription: "Invalid JSON-RPC version")
        }
        id = try container.decode(ID.self, forKey: .id)
        if container.contains(.result) {
            result = .success(try container.decode(M.Result.self, forKey: .result))
        } else {
            result = .failure(try container.decode(MCPError.self, forKey: .error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpcVersion, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        switch result {
        case let .success(value): try container.encode(value, forKey: .result)
        case let .failure(error): try container.encode(error, forKey: .error)
        }
    }

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }
}

public protocol Notification: Hashable, Codable, Sendable {
    associatedtype Parameters: Codable & Hashable & Sendable = Empty
    static var name: String { get }
}

public struct Message<N: Notification>: Hashable, Codable, Sendable {
    public let method: String
    public let params: N.Parameters

    public init(method: String = N.name, params: N.Parameters) {
        self.method = method
        self.params = params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .jsonrpc) == jsonrpcVersion else {
            throw DecodingError.dataCorruptedError(forKey: .jsonrpc, in: container, debugDescription: "Invalid JSON-RPC version")
        }
        method = try container.decode(String.self, forKey: .method)
        if N.Parameters.self is NotRequired.Type {
            params = try container.decodeIfPresent(N.Parameters.self, forKey: .params) ?? (N.Parameters.self as! any NotRequired.Type).init() as! N.Parameters
        } else {
            params = try container.decode(N.Parameters.self, forKey: .params)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpcVersion, forKey: .jsonrpc)
        try container.encode(method, forKey: .method)
        if N.Parameters.self != Empty.self { try container.encode(params, forKey: .params) }
    }

    private enum CodingKeys: String, CodingKey { case jsonrpc, method, params }
}
