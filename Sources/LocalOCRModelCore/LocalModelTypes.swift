import Foundation

public enum LocalModelProviderID: String, Codable, Sendable, Hashable {
    case appleFoundationModels = "apple_foundation_models"
    case ollama
    case lmStudio = "lm_studio"
    case llamaCpp = "llama_cpp"
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

public struct LocalModelFileAttestation: Codable, Sendable, Hashable {
    public let executablePath: String
    public let executableSHA256: String
    public let modelPath: String
    public let modelSize: Int64
    public let modelModifiedNanoseconds: Int64
    public let executableSize: Int64
    public let executableModifiedNanoseconds: Int64
    public let processID: Int32

    public init(executablePath: String, executableSHA256: String, modelPath: String, modelSize: Int64, modelModifiedNanoseconds: Int64, executableSize: Int64, executableModifiedNanoseconds: Int64, processID: Int32) {
        self.executablePath = executablePath
        self.executableSHA256 = executableSHA256
        self.modelPath = modelPath
        self.modelSize = modelSize
        self.modelModifiedNanoseconds = modelModifiedNanoseconds
        self.executableSize = executableSize
        self.executableModifiedNanoseconds = executableModifiedNanoseconds
        self.processID = processID
    }
}

public struct LocalModelIdentity: Codable, Sendable, Hashable {
    public let provider: LocalModelProviderID
    public let model: String
    public let fingerprint: String?
    public let harnessVersion: String?
    public let fileAttestation: LocalModelFileAttestation?

    public init(
        provider: LocalModelProviderID,
        model: String,
        fingerprint: String?,
        harnessVersion: String?,
        fileAttestation: LocalModelFileAttestation? = nil
    ) {
        self.provider = provider
        self.model = model
        self.fingerprint = fingerprint
        self.harnessVersion = harnessVersion
        self.fileAttestation = fileAttestation
    }

    /// llama.cpp receipts must bind the attested executable and local model file.
    public var hasValidProviderAttestation: Bool {
        guard provider == .llamaCpp else { return fileAttestation == nil }
        guard let files = fileAttestation else { return false }
        func validPath(_ path: String) -> Bool {
            path.hasPrefix("/") && path.utf8.count <= 1024
                && path == URL(fileURLWithPath: path).standardizedFileURL.path
                && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        func digest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        return validPath(files.modelPath) && validPath(files.executablePath)
            && files.modelPath.hasSuffix(".gguf") && digest(files.executableSHA256)
            && fingerprint.map(digest) == true && files.modelSize > 0 && files.executableSize > 0
            && files.modelModifiedNanoseconds >= 0 && files.executableModifiedNanoseconds >= 0
            && files.processID > 0
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
    public let harnessVersion: String?

    public init(
        provider: LocalModelProviderID,
        providerDisplayName: String,
        model: String,
        processing: LocalModelProcessing,
        fingerprint: String?,
        qualifiedAt: Date?,
        harnessVersion: String? = nil
    ) {
        self.provider = provider
        self.providerDisplayName = providerDisplayName
        self.model = model
        self.processing = processing
        self.fingerprint = fingerprint
        self.qualifiedAt = qualifiedAt
        self.harnessVersion = harnessVersion
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
