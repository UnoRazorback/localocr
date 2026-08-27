import Foundation

public struct ExternalDataConsentReceipt: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let currentPolicyVersion = 1

    public let schemaVersion: Int
    public let policyVersion: Int
    public let acceptedAt: Date
    public let externalProviderRiskAccepted: Bool
    public let documentToolAccessAccepted: Bool

    public init(
        schemaVersion: Int,
        policyVersion: Int,
        acceptedAt: Date,
        externalProviderRiskAccepted: Bool,
        documentToolAccessAccepted: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.policyVersion = policyVersion
        self.acceptedAt = acceptedAt
        self.externalProviderRiskAccepted = externalProviderRiskAccepted
        self.documentToolAccessAccepted = documentToolAccessAccepted
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case policyVersion = "policy_version"
        case acceptedAt = "accepted_at"
        case externalProviderRiskAccepted = "external_provider_risk_accepted"
        case documentToolAccessAccepted = "document_tool_access_accepted"
    }
}

public enum ExternalDataConsentStatus: Sendable, Equatable {
    case current(ExternalDataConsentReceipt)
    case required
}

public protocol ExternalDataConsentStoring: Sendable {
    func status() async -> ExternalDataConsentStatus
    func acceptBothStatements(at date: Date) async throws
    func revoke() async throws
}
