import Darwin
import Foundation

public enum ExternalDataConsentStoreError: Error, Sendable {
    case invalidReceiptPath
    case missingPath
    case insecureFilesystemState
    case filesystemOperationFailed(Int32)
    case invalidReceiptEncoding
}
struct ExternalDataConsentStoreHooks: Sendable {
    typealias OperationHook = @Sendable () throws -> Void
    typealias DescriptorSync = @Sendable (Int32) -> Int32

    let beforeAcceptReproof: OperationHook
    let beforeAcceptFinalMutation: OperationHook
    let beforeRevokeReproof: OperationHook
    let beforeRevokeFinalMutation: OperationHook
    let beforeTemporaryCleanupFinalMutation: OperationHook
    let afterQuarantineVerification: OperationHook
    let synchronizeDescriptor: DescriptorSync

    init(
        beforeAcceptReproof: @escaping OperationHook = {},
        beforeAcceptFinalMutation: @escaping OperationHook = {},
        beforeRevokeReproof: @escaping OperationHook = {},
        beforeRevokeFinalMutation: @escaping OperationHook = {},
        beforeTemporaryCleanupFinalMutation: @escaping OperationHook = {},
        afterQuarantineVerification: @escaping OperationHook = {},
        synchronizeDescriptor: @escaping DescriptorSync = { fsync($0) }
    ) {
        self.beforeAcceptReproof = beforeAcceptReproof
        self.beforeAcceptFinalMutation = beforeAcceptFinalMutation
        self.beforeRevokeReproof = beforeRevokeReproof
        self.beforeRevokeFinalMutation = beforeRevokeFinalMutation
        self.beforeTemporaryCleanupFinalMutation = beforeTemporaryCleanupFinalMutation
        self.afterQuarantineVerification = afterQuarantineVerification
        self.synchronizeDescriptor = synchronizeDescriptor
    }

    var secureStoreHooks: SecureJSONReceiptStoreHooks {
        SecureJSONReceiptStoreHooks(
            beforeAcceptReproof: beforeAcceptReproof,
            beforeAcceptFinalMutation: beforeAcceptFinalMutation,
            beforeRevokeReproof: beforeRevokeReproof,
            beforeRevokeFinalMutation: beforeRevokeFinalMutation,
            beforeTemporaryCleanupFinalMutation: beforeTemporaryCleanupFinalMutation,
            afterQuarantineVerification: afterQuarantineVerification,
            synchronizeDescriptor: synchronizeDescriptor
        )
    }
}

public actor ExternalDataConsentStore: ExternalDataConsentStoring {
    public static var defaultReceiptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(
                path: "Library/Application Support/com.rayconsulting.localocr",
                directoryHint: .isDirectory
            )
            .appending(path: "mcp-consent.json", directoryHint: .notDirectory)
    }

    public nonisolated let receiptURL: URL

    private let receiptStore: SecureJSONReceiptStore<ExternalDataConsentReceipt>

    public init(receiptURL: URL = ExternalDataConsentStore.defaultReceiptURL) {
        self.receiptURL = receiptURL
        receiptStore = Self.makeReceiptStore(receiptURL: receiptURL)
    }

    init(receiptURL: URL, expectedReceiptOwnerID: uid_t) {
        self.receiptURL = receiptURL
        receiptStore = Self.makeReceiptStore(
            receiptURL: receiptURL,
            expectedReceiptOwnerID: expectedReceiptOwnerID
        )
    }

    init(
        receiptURL: URL,
        beforeAcceptRename: @escaping @Sendable () throws -> Void
    ) {
        self.receiptURL = receiptURL
        receiptStore = Self.makeReceiptStore(
            receiptURL: receiptURL,
            hooks: ExternalDataConsentStoreHooks(beforeAcceptReproof: beforeAcceptRename)
        )
    }

    init(
        receiptURL: URL,
        beforeRevokeUnlink: @escaping @Sendable () throws -> Void
    ) {
        self.receiptURL = receiptURL
        receiptStore = Self.makeReceiptStore(
            receiptURL: receiptURL,
            hooks: ExternalDataConsentStoreHooks(beforeRevokeReproof: beforeRevokeUnlink)
        )
    }

    init(receiptURL: URL, hooks: ExternalDataConsentStoreHooks) {
        self.receiptURL = receiptURL
        receiptStore = Self.makeReceiptStore(receiptURL: receiptURL, hooks: hooks)
    }

    public func status() async -> ExternalDataConsentStatus {
        do {
            let receipt = try await receiptStore.read()
            guard receipt.schemaVersion == ExternalDataConsentReceipt.currentSchemaVersion,
                  receipt.policyVersion == ExternalDataConsentReceipt.currentPolicyVersion,
                  receipt.externalProviderRiskAccepted,
                  receipt.documentToolAccessAccepted
            else {
                return .required
            }
            return .current(receipt)
        } catch {
            return .required
        }
    }

    public func acceptBothStatements(at date: Date) async throws {
        let receipt = ExternalDataConsentReceipt(
            schemaVersion: ExternalDataConsentReceipt.currentSchemaVersion,
            policyVersion: ExternalDataConsentReceipt.currentPolicyVersion,
            acceptedAt: date,
            externalProviderRiskAccepted: true,
            documentToolAccessAccepted: true
        )
        do {
            try await receiptStore.replace(with: receipt)
        } catch let error as SecureJSONReceiptStoreError {
            throw Self.externalError(for: error)
        }
    }

    public func revoke() async throws {
        do {
            try await receiptStore.removeIfPresent()
        } catch let error as SecureJSONReceiptStoreError {
            throw Self.externalError(for: error)
        }
    }

    private nonisolated static func makeReceiptStore(
        receiptURL: URL,
        expectedReceiptOwnerID: uid_t = geteuid(),
        hooks: ExternalDataConsentStoreHooks = ExternalDataConsentStoreHooks()
    ) -> SecureJSONReceiptStore<ExternalDataConsentReceipt> {
        SecureJSONReceiptStore(
            receiptURL: receiptURL,
            expectedReceiptOwnerID: expectedReceiptOwnerID,
            allowedTopLevelMemberSets: [[
                "schema_version",
                "policy_version",
                "accepted_at",
                "external_provider_risk_accepted",
                "document_tool_access_accepted"
            ]],
            hooks: hooks.secureStoreHooks
        )
    }

    private nonisolated static func externalError(
        for error: SecureJSONReceiptStoreError
    ) -> ExternalDataConsentStoreError {
        switch error {
        case .invalidReceiptPath:
            .invalidReceiptPath
        case .missingPath:
            .missingPath
        case .insecureFilesystemState:
            .insecureFilesystemState
        case let .filesystemOperationFailed(code):
            .filesystemOperationFailed(code)
        case .invalidReceiptEncoding:
            .invalidReceiptEncoding
        }
    }
}
