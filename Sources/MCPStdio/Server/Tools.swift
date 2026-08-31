/// An MCP tool definition.
public struct Tool: Hashable, Codable, Sendable {
    public let name: String
    public let title: String?
    public let description: String?
    public let inputSchema: Value
    public let outputSchema: Value?
    public let annotations: Annotations
    public let _meta: Metadata?

    public struct Annotations: Hashable, Codable, Sendable, ExpressibleByNilLiteral {
        public let title: String?
        public let destructiveHint: Bool?
        public let idempotentHint: Bool?
        public let openWorldHint: Bool?
        public let readOnlyHint: Bool?

        public init(title: String? = nil, readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil, idempotentHint: Bool? = nil, openWorldHint: Bool? = nil) {
            self.title = title
            self.readOnlyHint = readOnlyHint
            self.destructiveHint = destructiveHint
            self.idempotentHint = idempotentHint
            self.openWorldHint = openWorldHint
        }

        public init(nilLiteral: ()) { self.init() }

        public var isEmpty: Bool {
            title == nil && readOnlyHint == nil && destructiveHint == nil && idempotentHint == nil && openWorldHint == nil
        }
    }

    public init(name: String, title: String? = nil, description: String?, inputSchema: Value, annotations: Annotations = nil, outputSchema: Value? = nil, _meta: Metadata? = nil) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
        self._meta = _meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        inputSchema = try container.decode(Value.self, forKey: .inputSchema)
        outputSchema = try container.decodeIfPresent(Value.self, forKey: .outputSchema)
        annotations = try container.decodeIfPresent(Annotations.self, forKey: .annotations) ?? .init()
        _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
    }

    public enum Content: Hashable, Codable, Sendable {
        /// LocalOCR emits only textual tool content; resources and media are not part of this server surface.
        case text(text: String, annotations: Value?, _meta: Metadata?)

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard try container.decode(String.self, forKey: .type) == "text" else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported tool content type")
            }
            self = .text(
                text: try container.decode(String.self, forKey: .text),
                annotations: try container.decodeIfPresent(Value.self, forKey: .annotations),
                _meta: try container.decodeIfPresent(Metadata.self, forKey: ._meta)
            )
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            let (text, annotations, meta): (String, Value?, Metadata?)
            switch self { case let .text(value, annotation, valueMeta): (text, annotations, meta) = (value, annotation, valueMeta) }
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(annotations, forKey: .annotations)
            try container.encodeIfPresent(meta, forKey: ._meta)
        }

        private enum CodingKeys: String, CodingKey { case type, text, annotations, _meta }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(inputSchema, forKey: .inputSchema)
        try container.encodeIfPresent(outputSchema, forKey: .outputSchema)
        if !annotations.isEmpty { try container.encode(annotations, forKey: .annotations) }
        try container.encodeIfPresent(_meta, forKey: ._meta)
    }

    private enum CodingKeys: String, CodingKey { case name, title, description, inputSchema, outputSchema, annotations, _meta }
}

public enum ListTools: Method {
    public static let name = "tools/list"

    public struct Parameters: NotRequired, Hashable, Codable, Sendable {
        public let cursor: String?
        public init() { cursor = nil }
        public init(cursor: String) { self.cursor = cursor }
    }

    public struct Result: Hashable, Codable, Sendable {
        public let tools: [Tool]
        public let nextCursor: String?
        public let _meta: Metadata?
        public init(tools: [Tool], nextCursor: String? = nil, _meta: Metadata? = nil) {
            self.tools = tools
            self.nextCursor = nextCursor
            self._meta = _meta
        }
    }
}

public enum CallTool: Method {
    public static let name = "tools/call"

    public struct Parameters: Hashable, Codable, Sendable {
        public let _meta: Metadata?
        public let name: String
        public let arguments: [String: Value]?

        public init(name: String, arguments: [String: Value]? = nil, meta: Metadata? = nil) {
            self._meta = meta
            self.name = name
            self.arguments = arguments
        }
    }

    public struct Result: Hashable, Codable, Sendable {
        public let content: [Tool.Content]
        public let structuredContent: Value?
        public let isError: Bool?
        public let _meta: Metadata?

        public init(content: [Tool.Content] = [], structuredContent: Value? = nil, isError: Bool? = nil, _meta: Metadata? = nil) {
            self.content = content
            self.structuredContent = structuredContent
            self.isError = isError
            self._meta = _meta
        }

        public init<Output: Codable>(content: [Tool.Content] = [], structuredContent: Output, isError: Bool? = nil, _meta: Metadata? = nil) throws {
            let value = try Value(structuredContent)
            self.init(
                content: content,
                structuredContent: Optional<Value>.some(value),
                isError: isError,
                _meta: _meta
            )
        }
    }
}
