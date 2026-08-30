import Foundation
import LocalOCRModelCore

public struct LocalModelQualificationReceipt: Codable, Sendable, Equatable {
    public static let currentPolicyVersion = 1
    public static let currentFixtureVersion = 1

    public let policyVersion: Int
    public let fixtureVersion: Int
    public let identity: LocalModelIdentity
    public let passedActions: Set<LocalIntelligenceAction>
    public let qualifiedAt: Date

    public init(
        policyVersion: Int,
        fixtureVersion: Int,
        identity: LocalModelIdentity,
        passedActions: Set<LocalIntelligenceAction>,
        qualifiedAt: Date
    ) {
        self.policyVersion = policyVersion
        self.fixtureVersion = fixtureVersion
        self.identity = identity
        self.passedActions = passedActions
        self.qualifiedAt = qualifiedAt
    }

    enum CodingKeys: String, CodingKey {
        case policyVersion = "policy_version"
        case fixtureVersion = "fixture_version"
        case identity
        case passedActions = "passed_actions"
        case qualifiedAt = "qualified_at"
    }
}

public enum LocalIntelligenceAction: String, Codable, Sendable, Hashable, CaseIterable {
    case summary
    case organization
    case extraction
}

public struct ExternalLocalModelAcknowledgment: Codable, Sendable, Equatable {
    public static let currentPolicyVersion = 1

    public let policyVersion: Int
    public let identity: LocalModelIdentity
    public let acceptedAt: Date

    public init(policyVersion: Int, identity: LocalModelIdentity, acceptedAt: Date) {
        self.policyVersion = policyVersion
        self.identity = identity
        self.acceptedAt = acceptedAt
    }

    enum CodingKeys: String, CodingKey {
        case policyVersion = "policy_version"
        case identity
        case acceptedAt = "accepted_at"
    }
}

public enum LocalIntelligenceSelection: Codable, Sendable, Equatable {
    case appleSystemDefault
    case external(
        identity: LocalModelIdentity,
        qualification: LocalModelQualificationReceipt,
        acknowledgment: ExternalLocalModelAcknowledgment
    )
}

public enum LocalIntelligenceSelectionReceipt: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let currentPolicyVersion = 1

    case none(resetAt: Date)
    case selected(LocalIntelligenceSelection)

    private enum State: String, Codable {
        case none
        case selected
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case policyVersion = "policy_version"
        case state
        case resetAt = "reset_at"
        case selection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion) == Self.currentSchemaVersion,
              try container.decode(Int.self, forKey: .policyVersion) == Self.currentPolicyVersion
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported selection receipt version"
            )
        }
        switch try container.decode(State.self, forKey: .state) {
        case .none:
            self = .none(resetAt: try container.decode(Date.self, forKey: .resetAt))
        case .selected:
            self = .selected(try container.decode(LocalIntelligenceSelection.self, forKey: .selection))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(Self.currentPolicyVersion, forKey: .policyVersion)
        switch self {
        case let .none(resetAt):
            try container.encode(State.none, forKey: .state)
            try container.encode(resetAt, forKey: .resetAt)
        case let .selected(selection):
            try container.encode(State.selected, forKey: .state)
            try container.encode(selection, forKey: .selection)
        }
    }
}

public enum LocalIntelligenceSelectionFailure: Codable, Sendable, Equatable {
    case corruptReceipt
    case providerUnavailable(LocalModelProviderID)
    case modelUnavailable(LocalModelIdentity)
    case localityUnverified(LocalModelIdentity)
    case localityBlocked(LocalModelIdentity)
    case qualificationRequired(LocalModelIdentity)
    case acknowledgmentRequired(LocalModelIdentity)
    case identityChanged(expected: LocalModelIdentity, actual: LocalModelIdentity?)
}

public enum LocalIntelligenceSelectionState: Sendable, Equatable {
    case none
    case reset(at: Date)
    case selected(LocalIntelligenceSelection)
    case invalid(LocalIntelligenceSelectionFailure)
}

public protocol LocalIntelligenceSelectionStoring: Sendable {
    func state() async -> LocalIntelligenceSelectionState
    func selectApple(at date: Date) async throws
    func selectExternal(
        _ identity: LocalModelIdentity,
        qualification: LocalModelQualificationReceipt,
        acknowledgment: ExternalLocalModelAcknowledgment
    ) async throws
    func reset(at date: Date) async throws
}
