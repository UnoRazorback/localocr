import Foundation
import LocalOCRModelCore

public enum ModelBridgeLimits {
    public static let maximumMessageBytes = 1_048_576
    public static let maximumPromptBytes = 1_000_000
    public static let maximumFieldCount = 64
    public static let timeoutMilliseconds = 1_000...120_000
}

public enum ModelBridgeAction: String, Codable, Sendable, Equatable {
    case discover
    case generate
    case status
}

public enum ModelBridgeOperation: String, Codable, Sendable, Equatable {
    case summarize
    case organize
    case extract
}

public struct ModelBridgeRequest: Codable, Sendable, Equatable {
    public static let protocolVersion = 1

    public let version: Int
    public let id: UInt64
    public let action: ModelBridgeAction
    public let provider: LocalModelProviderID
    public let model: String?
    public let expectedIdentity: LocalModelIdentity?
    public let operation: ModelBridgeOperation?
    public let prompt: String?
    public let fields: [String]
    public let timeoutMilliseconds: Int

    public init(
        version: Int = protocolVersion,
        id: UInt64,
        action: ModelBridgeAction,
        provider: LocalModelProviderID,
        model: String? = nil,
        expectedIdentity: LocalModelIdentity? = nil,
        operation: ModelBridgeOperation? = nil,
        prompt: String? = nil,
        fields: [String] = [],
        timeoutMilliseconds: Int = 10_000
    ) {
        self.version = version
        self.id = id
        self.action = action
        self.provider = provider
        self.model = model
        self.expectedIdentity = expectedIdentity
        self.operation = operation
        self.prompt = prompt
        self.fields = fields
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    public static func discover(
        id: UInt64,
        provider: LocalModelProviderID,
        timeoutMilliseconds: Int = 10_000
    ) -> ModelBridgeRequest {
        ModelBridgeRequest(
            id: id,
            action: .discover,
            provider: provider,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    public static func status(
        id: UInt64,
        provider: LocalModelProviderID,
        model: String? = nil,
        timeoutMilliseconds: Int = 10_000
    ) -> ModelBridgeRequest {
        ModelBridgeRequest(
            id: id,
            action: .status,
            provider: provider,
            model: model,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    public static func generate(
        id: UInt64,
        expectedIdentity: LocalModelIdentity,
        operation: ModelBridgeOperation,
        prompt: String,
        fields: [String] = [],
        timeoutMilliseconds: Int = 30_000
    ) -> ModelBridgeRequest {
        ModelBridgeRequest(
            id: id,
            action: .generate,
            provider: expectedIdentity.provider,
            model: expectedIdentity.model,
            expectedIdentity: expectedIdentity,
            operation: operation,
            prompt: prompt,
            fields: fields,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, id, action, provider, model, expectedIdentity, operation, prompt, fields, timeoutMilliseconds
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)

        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(UInt64.self, forKey: .id)
        action = try container.decode(ModelBridgeAction.self, forKey: .action)
        provider = try container.decode(LocalModelProviderID.self, forKey: .provider)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        if container.contains(.expectedIdentity), try !container.decodeNil(forKey: .expectedIdentity) {
            expectedIdentity = try decodeStrictIdentity(
                from: container.superDecoder(forKey: .expectedIdentity)
            )
        } else {
            expectedIdentity = nil
        }
        operation = try container.decodeIfPresent(ModelBridgeOperation.self, forKey: .operation)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        fields = try container.decode([String].self, forKey: .fields)
        timeoutMilliseconds = try container.decode(Int.self, forKey: .timeoutMilliseconds)

        guard version == Self.protocolVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported model bridge protocol version.")
        }
        guard provider == .ollama || provider == .lmStudio else {
            throw DecodingError.dataCorruptedError(forKey: .provider, in: container, debugDescription: "Provider is not supported by the model bridge.")
        }
        if let model, model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DecodingError.dataCorruptedError(forKey: .model, in: container, debugDescription: "Model identifier must not be empty.")
        }
        guard fields.count <= ModelBridgeLimits.maximumFieldCount else {
            throw DecodingError.dataCorruptedError(forKey: .fields, in: container, debugDescription: "Too many requested fields.")
        }
        if let prompt, prompt.utf8.count > ModelBridgeLimits.maximumPromptBytes {
            throw DecodingError.dataCorruptedError(forKey: .prompt, in: container, debugDescription: "Prompt exceeds the bounded limit.")
        }
        guard ModelBridgeLimits.timeoutMilliseconds.contains(timeoutMilliseconds) else {
            throw DecodingError.dataCorruptedError(forKey: .timeoutMilliseconds, in: container, debugDescription: "Timeout is outside the supported range.")
        }
        switch action {
        case .discover:
            guard model == nil, expectedIdentity == nil,
                  operation == nil, prompt == nil, fields.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .action, in: container, debugDescription: "Discovery requests accept provider metadata only.")
            }
        case .status:
            guard expectedIdentity == nil, operation == nil, prompt == nil, fields.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .action, in: container, debugDescription: "Status requests cannot contain generation content.")
            }
        case .generate:
            guard let model,
                  let expectedIdentity,
                  expectedIdentity.provider == provider,
                  expectedIdentity.model == model,
                  !(expectedIdentity.fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                  !(expectedIdentity.harnessVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                  operation != nil,
                  let prompt,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .action, in: container, debugDescription: "Generate requests require one exact immutable identity, operation, and prompt.")
            }
        }
    }
}

public struct BridgeModelCandidate: Codable, Sendable, Equatable {
    public let identity: LocalModelIdentity
    public let displayName: String
    public let locality: LocalModelLocality
    public let localityReason: String

    public init(identity: LocalModelIdentity, displayName: String, locality: LocalModelLocality, localityReason: String) {
        self.identity = identity
        self.displayName = displayName
        self.locality = locality
        self.localityReason = localityReason
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case identity, displayName, locality, localityReason
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identity = try decodeStrictIdentity(from: container.superDecoder(forKey: .identity))
        displayName = try container.decode(String.self, forKey: .displayName)
        locality = try container.decode(LocalModelLocality.self, forKey: .locality)
        localityReason = try container.decode(String.self, forKey: .localityReason)
    }
}

public struct ModelBridgeResponse: Codable, Sendable, Equatable {
    public let version: Int
    public let id: UInt64
    public let candidates: [BridgeModelCandidate]
    public let payloadJSON: String?
    public let identity: LocalModelIdentity?
    public let error: ModelBridgeWireError?

    public init(
        version: Int = ModelBridgeRequest.protocolVersion,
        id: UInt64,
        candidates: [BridgeModelCandidate] = [],
        payloadJSON: String? = nil,
        identity: LocalModelIdentity? = nil,
        error: ModelBridgeWireError? = nil
    ) {
        self.version = version
        self.id = id
        self.candidates = candidates
        self.payloadJSON = payloadJSON
        self.identity = identity
        self.error = error
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, id, candidates, payloadJSON, identity, error
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(UInt64.self, forKey: .id)
        candidates = try container.decode([BridgeModelCandidate].self, forKey: .candidates)
        payloadJSON = try container.decodeIfPresent(String.self, forKey: .payloadJSON)
        if container.contains(.identity), try !container.decodeNil(forKey: .identity) {
            identity = try decodeStrictIdentity(from: container.superDecoder(forKey: .identity))
        } else {
            identity = nil
        }
        error = try container.decodeIfPresent(ModelBridgeWireError.self, forKey: .error)

        guard version == ModelBridgeRequest.protocolVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported model bridge protocol version.")
        }
        if let payloadJSON, payloadJSON.utf8.count > ModelBridgeLimits.maximumPromptBytes {
            throw DecodingError.dataCorruptedError(forKey: .payloadJSON, in: container, debugDescription: "Payload exceeds the bounded limit.")
        }
        if let payloadJSON,
           (try? JSONSerialization.jsonObject(
               with: Data(payloadJSON.utf8),
               options: [.fragmentsAllowed]
           )) == nil {
            throw DecodingError.dataCorruptedError(forKey: .payloadJSON, in: container, debugDescription: "Payload is not valid JSON.")
        }
        if error != nil,
           (!candidates.isEmpty || payloadJSON != nil || identity != nil) {
            throw DecodingError.dataCorruptedError(forKey: .error, in: container, debugDescription: "Error responses cannot contain success fields.")
        }
    }
}

public enum ModelBridgeWireErrorCode: String, Codable, Sendable, Equatable {
    case invalidRequest = "invalid_request"
    case messageTooLarge = "message_too_large"
    case unsupportedVersion = "unsupported_version"
    case providerNotImplemented = "provider_not_implemented"
    case providerUnavailable = "provider_unavailable"
    case providerResponseInvalid = "provider_response_invalid"
    case modelUnavailable = "model_unavailable"
    case modelIdentityChanged = "model_identity_changed"
    case localityUnverified = "locality_unverified"
    case localityBlocked = "locality_blocked"
    case generationTimedOut = "generation_timed_out"
    case generationFailed = "generation_failed"
    case contextOverflow = "context_overflow"
    case schemaFailure = "schema_failure"
    case groundingFailure = "grounding_failure"
    case cancelled
}

public struct ModelBridgeWireError: Codable, Sendable, Equatable {
    public let code: ModelBridgeWireErrorCode
    public let message: String

    public init(code: ModelBridgeWireErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case code, message
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(ModelBridgeWireErrorCode.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
    }
}

public protocol ModelBridgeHandling: Sendable {
    func handle(_ request: ModelBridgeRequest) async -> ModelBridgeResponse
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownKeys(in decoder: any Decoder, allowed: [String]) throws {
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    let allowedKeys = Set(allowed)
    if let unknownKey = container.allKeys.first(where: { !allowedKeys.contains($0.stringValue) }) {
        throw DecodingError.dataCorruptedError(forKey: unknownKey, in: container, debugDescription: "Unknown key in model bridge message.")
    }
}

private enum IdentityCodingKeys: String, CodingKey, CaseIterable {
    case provider, model, fingerprint, harnessVersion
}

private func decodeStrictIdentity(from decoder: any Decoder) throws -> LocalModelIdentity {
    try rejectUnknownKeys(in: decoder, allowed: IdentityCodingKeys.allCases.map(\.rawValue))
    let container = try decoder.container(keyedBy: IdentityCodingKeys.self)
    return try LocalModelIdentity(
        provider: container.decode(LocalModelProviderID.self, forKey: .provider),
        model: container.decode(String.self, forKey: .model),
        fingerprint: container.decodeIfPresent(String.self, forKey: .fingerprint),
        harnessVersion: container.decodeIfPresent(String.self, forKey: .harnessVersion)
    )
}
