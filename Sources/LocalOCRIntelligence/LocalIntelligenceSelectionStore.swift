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
            ],
            receiptSchema: Self.receiptSchema
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
            ],
            receiptSchema: Self.receiptSchema
        )
    }

    init(receiptURL: URL, hooks: SecureJSONReceiptStoreHooks) {
        self.receiptURL = receiptURL
        receiptStore = SecureJSONReceiptStore(
            receiptURL: receiptURL,
            allowedTopLevelMemberSets: [
                ["schema_version", "policy_version", "state", "reset_at"],
                ["schema_version", "policy_version", "state", "selection"]
            ],
            receiptSchema: Self.receiptSchema,
            hooks: hooks
        )
    }

    private nonisolated static var receiptSchema: SecureJSONReceiptSchema {
        let identity = SecureJSONReceiptSchema.object(
            required: [
                "provider": .value,
                "model": .value
            ],
            optional: [
                "fingerprint": .value,
                "harnessVersion": .value
            ]
        )
        let qualification = SecureJSONReceiptSchema.object(required: [
            "policy_version": .value,
            "fixture_version": .value,
            "identity": identity,
            "passed_actions": .array(.value),
            "qualified_at": .value
        ])
        let acknowledgment = SecureJSONReceiptSchema.object(required: [
            "policy_version": .value,
            "identity": identity,
            "accepted_at": .value
        ])
        let selection = SecureJSONReceiptSchema.oneOf([
            .object(required: [
                "appleSystemDefault": .object(required: [:])
            ]),
            .object(required: [
                "external": .object(required: [
                    "identity": identity,
                    "qualification": qualification,
                    "acknowledgment": acknowledgment
                ])
            ])
        ])
        return .oneOf([
            .object(required: [
                "schema_version": .value,
                "policy_version": .value,
                "state": .value,
                "reset_at": .value
            ]),
            .object(required: [
                "schema_version": .value,
                "policy_version": .value,
                "state": .value,
                "selection": selection
            ])
        ])
    }

    public func state() async -> LocalIntelligenceSelectionState {
        do {
            return validate(try await receiptStore.read())
        } catch SecureJSONReceiptStoreError.missingPath {
            let migrated = LocalIntelligenceSelection.appleSystemDefault
            do {
                if try await receiptStore.createIfAbsent(with: .selected(migrated)) {
                    return .selected(migrated)
                }
                return validate(try await receiptStore.read())
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
        case let .none(resetAt):
            return .reset(at: resetAt)
        case .selected(.appleSystemDefault):
            return .selected(.appleSystemDefault)
        case let .selected(.external(identity, qualification, acknowledgment)):
            guard Self.hasBoundedIdentityFields(identity),
                  identity.provider != .appleFoundationModels,
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

    private nonisolated static func hasBoundedIdentityFields(
        _ identity: LocalModelIdentity
    ) -> Bool {
        identity.model.utf8.count <= 1_024 &&
            (identity.fingerprint?.utf8.count ?? 0) <= 1_024 &&
            (identity.harnessVersion?.utf8.count ?? 0) <= 256
    }
}
