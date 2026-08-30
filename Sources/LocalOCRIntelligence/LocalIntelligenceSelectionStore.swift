import Darwin
import Foundation
import LocalOCRModelCore

public typealias LocalIntelligenceSelectionStoreError = SecureJSONReceiptStoreError

public actor LocalIntelligenceSelectionStore: LocalIntelligenceSelectionStoring {
    public static var defaultReceiptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(
                path: "Library/Application Support/com.rayconsulting.localocr",
                directoryHint: .isDirectory
            )
            .appending(path: "local-intelligence-selection.json", directoryHint: .notDirectory)
    }

    public nonisolated let receiptURL: URL

    private let receiptStore: SecureJSONReceiptStore<LocalIntelligenceSelectionReceipt>

    public init(receiptURL: URL = LocalIntelligenceSelectionStore.defaultReceiptURL) {
        self.receiptURL = receiptURL
        receiptStore = SecureJSONReceiptStore(
            receiptURL: receiptURL,
            allowedTopLevelMemberSets: [
                ["schema_version", "policy_version", "state", "reset_at"],
                ["schema_version", "policy_version", "state", "selection"]
            ]
        )
    }

    init(receiptURL: URL, expectedReceiptOwnerID: uid_t) {
        self.receiptURL = receiptURL
        receiptStore = SecureJSONReceiptStore(
            receiptURL: receiptURL,
            expectedReceiptOwnerID: expectedReceiptOwnerID,
            allowedTopLevelMemberSets: [
                ["schema_version", "policy_version", "state", "reset_at"],
                ["schema_version", "policy_version", "state", "selection"]
            ]
        )
    }

    public func state() async -> LocalIntelligenceSelectionState {
        do {
            return validate(try await receiptStore.read())
        } catch SecureJSONReceiptStoreError.missingPath {
            let migrated = LocalIntelligenceSelection.appleSystemDefault
            do {
                try await receiptStore.replace(with: .selected(migrated))
                return .selected(migrated)
            } catch {
                return .invalid(.corruptReceipt)
            }
        } catch {
            return .invalid(.corruptReceipt)
        }
    }

    public func selectApple(at date: Date) async throws {
        _ = date
        try await receiptStore.replace(with: .selected(.appleSystemDefault))
    }

    public func selectExternal(
        _ identity: LocalModelIdentity,
        qualification: LocalModelQualificationReceipt,
        acknowledgment: ExternalLocalModelAcknowledgment
    ) async throws {
        let selection = LocalIntelligenceSelection.external(
            identity: identity,
            qualification: qualification,
            acknowledgment: acknowledgment
        )
        if case let .invalid(failure) = validate(.selected(selection)) {
            throw IntelligenceError.selection(failure)
        }
        try await receiptStore.replace(with: .selected(selection))
    }

    public func reset(at date: Date) async throws {
        try await receiptStore.replace(with: .none(resetAt: date))
    }

    private func validate(
        _ receipt: LocalIntelligenceSelectionReceipt
    ) -> LocalIntelligenceSelectionState {
        switch receipt {
        case .none:
            return .none
        case .selected(.appleSystemDefault):
            return .selected(.appleSystemDefault)
        case let .selected(.external(identity, qualification, acknowledgment)):
            guard identity.provider != .appleFoundationModels,
                  qualification.policyVersion == LocalModelQualificationReceipt.currentPolicyVersion,
                  qualification.fixtureVersion == LocalModelQualificationReceipt.currentFixtureVersion,
                  qualification.identity == identity,
                  qualification.passedActions == Set(LocalIntelligenceAction.allCases)
            else {
                return .invalid(.qualificationRequired(identity))
            }
            guard acknowledgment.policyVersion == ExternalLocalModelAcknowledgment.currentPolicyVersion,
                  acknowledgment.identity == identity
            else {
                return .invalid(.acknowledgmentRequired(identity))
            }
            return .selected(.external(
                identity: identity,
                qualification: qualification,
                acknowledgment: acknowledgment
            ))
        }
    }
}
