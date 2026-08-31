/// Lifecycle messages for an MCP server. This is data-only; the stdio server
/// implementation owns dispatch and does not include an MCP client.
public enum Initialize: Method {
    public static let name = "initialize"

    public struct ClientInfo: Hashable, Codable, Sendable {
        public let name: String
        public let version: String
        public let title: String?

        public init(name: String, version: String, title: String? = nil) {
            self.name = name
            self.version = version
            self.title = title
        }
    }

    public struct ServerInfo: Hashable, Codable, Sendable {
        public let name: String
        public let version: String
        public let title: String?

        public init(name: String, version: String, title: String? = nil) {
            self.name = name
            self.version = version
            self.title = title
        }
    }

    /// Capability objects are open for forwards-compatible MCP fields.
    public struct ClientCapabilities: Hashable, Codable, Sendable {
        public let fields: [String: Value]
        public init(_ fields: [String: Value] = [:]) { self.fields = fields }
        public init(from decoder: Decoder) throws { fields = try decoder.singleValueContainer().decode([String: Value].self) }
        public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(fields) }
    }

    public struct ServerCapabilities: Hashable, Codable, Sendable {
        public let fields: [String: Value]
        public init(_ fields: [String: Value] = [:]) { self.fields = fields }
        public init(from decoder: Decoder) throws { fields = try decoder.singleValueContainer().decode([String: Value].self) }
        public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(fields) }
    }

    public struct Parameters: Hashable, Codable, Sendable {
        public let protocolVersion: String
        public let capabilities: ClientCapabilities
        public let clientInfo: ClientInfo

        public init(protocolVersion: String = Version.latest, capabilities: ClientCapabilities, clientInfo: ClientInfo) {
            self.protocolVersion = protocolVersion
            self.capabilities = capabilities
            self.clientInfo = clientInfo
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            protocolVersion = try container.decodeIfPresent(String.self, forKey: .protocolVersion) ?? Version.latest
            capabilities = try container.decodeIfPresent(ClientCapabilities.self, forKey: .capabilities) ?? .init()
            clientInfo = try container.decodeIfPresent(ClientInfo.self, forKey: .clientInfo) ?? .init(name: "unknown", version: "0.0.0")
        }
    }

    public struct Result: Hashable, Codable, Sendable {
        public let protocolVersion: String
        public let capabilities: ServerCapabilities
        public let serverInfo: ServerInfo
        public let instructions: String?
        public let _meta: Metadata?

        public init(protocolVersion: String, capabilities: ServerCapabilities, serverInfo: ServerInfo, instructions: String? = nil, _meta: Metadata? = nil) {
            self.protocolVersion = protocolVersion
            self.capabilities = capabilities
            self.serverInfo = serverInfo
            self.instructions = instructions
            self._meta = _meta
        }
    }
}

public struct InitializedNotification: Notification {
    public static let name = "notifications/initialized"
    public init() {}
}
