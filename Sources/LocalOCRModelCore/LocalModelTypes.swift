import Foundation

public enum LocalModelProviderID: String, Codable, Sendable, Hashable {
    case appleFoundationModels = "apple_foundation_models"
    case ollama
    case lmStudio = "lm_studio"
}

public enum LocalModelProcessing: String, Codable, Sendable, Equatable {
    case onDevice = "on_device"
    case onDeviceLoopback = "on_device_loopback"
}

public enum LocalModelLocality: String, Codable, Sendable, Equatable {
    case verifiedLocal = "verified_local"
    case unverified
    case blocked
}

public struct LocalModelIdentity: Codable, Sendable, Hashable {
    public let provider: LocalModelProviderID
    public let model: String
    public let fingerprint: String?
    public let harnessVersion: String?

    public init(
        provider: LocalModelProviderID,
        model: String,
        fingerprint: String?,
        harnessVersion: String?
    ) {
        self.provider = provider
        self.model = model
        self.fingerprint = fingerprint
        self.harnessVersion = harnessVersion
    }

    public static let appleSystemDefault = LocalModelIdentity(
        provider: .appleFoundationModels,
        model: "SystemLanguageModel.default",
        fingerprint: nil,
        harnessVersion: nil
    )
}

public struct LocalModelProvenance: Codable, Sendable, Equatable {
    public let provider: LocalModelProviderID
    public let providerDisplayName: String
    public let model: String
    public let processing: LocalModelProcessing
    public let fingerprint: String?
    public let qualifiedAt: Date?

    public init(
        provider: LocalModelProviderID,
        providerDisplayName: String,
        model: String,
        processing: LocalModelProcessing,
        fingerprint: String?,
        qualifiedAt: Date?
    ) {
        self.provider = provider
        self.providerDisplayName = providerDisplayName
        self.model = model
        self.processing = processing
        self.fingerprint = fingerprint
        self.qualifiedAt = qualifiedAt
    }

    public static let appleSystemDefault = LocalModelProvenance(
        provider: .appleFoundationModels,
        providerDisplayName: "Apple Foundation Models",
        model: "SystemLanguageModel.default",
        processing: .onDevice,
        fingerprint: nil,
        qualifiedAt: nil
    )
}
