import Darwin
import Foundation
@testable import LocalOCRIntelligence
import Testing

@Suite(.serialized) struct ExternalDataConsentStoreTests {
    private let firstDate = Date(timeIntervalSince1970: 1_787_788_800)
    private let secondDate = Date(timeIntervalSince1970: 1_787_875_200)

    @Test func missingReceiptRequiresConsentWithoutCreatingAnything() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        let store = ExternalDataConsentStore(receiptURL: fixture.receiptURL)

        #expect(await store.status() == .required)
        #expect(!FileManager.default.fileExists(atPath: fixture.applicationDirectory.path))
    }

    @Test func validReceiptIsCurrent() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(acceptedAt: firstDate)
        let store = ExternalDataConsentStore(receiptURL: fixture.receiptURL)

        let expected = ExternalDataConsentReceipt(
            schemaVersion: 1,
            policyVersion: 1,
            acceptedAt: firstDate,
            externalProviderRiskAccepted: true,
            documentToolAccessAccepted: true
        )
        #expect(await store.status() == .current(expected))
    }

    @Test func acceptPreparesSecureSiblingBeforeAtomicallyReplacingReceipt() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(acceptedAt: firstDate)
        let originalData = try Data(contentsOf: fixture.receiptURL)
        let receiptURL = fixture.receiptURL
        let applicationDirectory = fixture.applicationDirectory
        let store = ExternalDataConsentStore(
            receiptURL: receiptURL,
            beforeAcceptRename: {
                guard try Data(contentsOf: receiptURL) == originalData else {
                    throw ConsentProbeError.receiptChangedBeforeCommit
                }
                let temporaryNames = try FileManager.default.contentsOfDirectory(
                    atPath: applicationDirectory.path
                ).filter { $0.hasPrefix(".mcp-consent.json.") && $0.hasSuffix(".tmp") }
                guard temporaryNames.count == 1 else {
                    throw ConsentProbeError.secureTemporaryFileMissing
                }
                let temporaryURL = applicationDirectory.appending(path: temporaryNames[0])
                guard try permissions(of: temporaryURL) == 0o600 else {
                    throw ConsentProbeError.insecurePermissions
                }
            }
        )

        try await store.acceptBothStatements(at: secondDate)

        let expected = ExternalDataConsentReceipt(
            schemaVersion: 1,
            policyVersion: 1,
            acceptedAt: secondDate,
            externalProviderRiskAccepted: true,
            documentToolAccessAccepted: true
        )
        #expect(await store.status() == .current(expected))
        #expect(try permissions(of: fixture.applicationDirectory) == 0o700)
        #expect(try permissions(of: fixture.receiptURL) == 0o600)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.applicationDirectory.path
        )
        #expect(names.contains("mcp-consent.json"))
        #expect(names.filter(isQuarantineName).count == 1)
        #expect(try directoryContainsFile(with: originalData, at: fixture.applicationDirectory))
    }

    @Test func revokeRemovesOnlyTheValidatedReceipt() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(acceptedAt: firstDate)
        let unrelatedURL = fixture.applicationDirectory.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: unrelatedURL)
        let originalData = try Data(contentsOf: fixture.receiptURL)
        let store = ExternalDataConsentStore(receiptURL: fixture.receiptURL)

        try await store.revoke()

        #expect(await store.status() == .required)
        #expect(FileManager.default.fileExists(atPath: fixture.applicationDirectory.path))
        #expect(try String(contentsOf: unrelatedURL, encoding: .utf8) == "keep")
        #expect(try directoryContainsFile(with: originalData, at: fixture.applicationDirectory))
        #expect(try quarantineReceipts(in: fixture.applicationDirectory).count == 1)
    }

    @Test func malformedJSONRequiresConsent() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeRaw(Data("{not-json".utf8))

        #expect(await ExternalDataConsentStore(receiptURL: fixture.receiptURL).status() == .required)
    }

    @Test func symbolicLinkReceiptIsRequiredAndMutationsDoNotFollowIt() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.createApplicationDirectory()
        let targetURL = fixture.baseURL.appending(path: "target.json")
        let sentinel = Data("do-not-touch".utf8)
        try sentinel.write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.receiptURL,
            withDestinationURL: targetURL
        )
        let store = ExternalDataConsentStore(receiptURL: fixture.receiptURL)

        #expect(await store.status() == .required)
        await #expect(throws: (any Error).self) {
            try await store.acceptBothStatements(at: firstDate)
        }
        await #expect(throws: (any Error).self) {
            try await store.revoke()
        }
        #expect(try Data(contentsOf: targetURL) == sentinel)
        #expect(fixture.isSymbolicLink(at: fixture.receiptURL))
    }

    @Test func symbolicLinkParentIsRequiredAndMutationsDoNotFollowIt() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        let externalDirectory = fixture.baseURL.appending(path: "external", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: false)
        try chmod(externalDirectory.path, 0o700).requireSuccess()
        let targetReceipt = externalDirectory.appending(path: "mcp-consent.json")
        let sentinel = Data("do-not-touch".utf8)
        try sentinel.write(to: targetReceipt)
        try FileManager.default.createSymbolicLink(
            at: fixture.applicationDirectory,
            withDestinationURL: externalDirectory
        )
        let store = ExternalDataConsentStore(receiptURL: fixture.receiptURL)

        #expect(await store.status() == .required)
        await #expect(throws: (any Error).self) {
            try await store.acceptBothStatements(at: firstDate)
        }
        await #expect(throws: (any Error).self) {
            try await store.revoke()
        }
        #expect(try Data(contentsOf: targetReceipt) == sentinel)
        #expect(fixture.isSymbolicLink(at: fixture.applicationDirectory))
    }

    @Test func groupOrOtherReadableReceiptRequiresConsent() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(acceptedAt: firstDate)
        try chmod(fixture.receiptURL.path, 0o644).requireSuccess()

        #expect(await ExternalDataConsentStore(receiptURL: fixture.receiptURL).status() == .required)
    }

    @Test func ownerReadOnlyReceiptRequiresConsent() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(acceptedAt: firstDate)
        try chmod(fixture.receiptURL.path, 0o400).requireSuccess()

        #expect(await ExternalDataConsentStore(receiptURL: fixture.receiptURL).status() == .required)
    }

    @Test(arguments: [mode_t(0o4600), mode_t(0o2600), mode_t(0o1600)])
    func receiptWithSpecialPermissionBitsRequiresConsent(mode: mode_t) async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(acceptedAt: firstDate)
        try chmod(fixture.receiptURL.path, mode).requireSuccess()

        #expect(await ExternalDataConsentStore(receiptURL: fixture.receiptURL).status() == .required)
    }

    @Test func nonPrivateApplicationDirectoryRequiresConsent() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(acceptedAt: firstDate)
        try chmod(fixture.applicationDirectory.path, 0o755).requireSuccess()

        #expect(await ExternalDataConsentStore(receiptURL: fixture.receiptURL).status() == .required)
    }

    @Test(arguments: [mode_t(0o4700), mode_t(0o2700), mode_t(0o1700)])
    func applicationDirectoryWithSpecialPermissionBitsRequiresConsent(mode: mode_t) async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(acceptedAt: firstDate)
        try chmod(fixture.applicationDirectory.path, mode).requireSuccess()

        #expect(await ExternalDataConsentStore(receiptURL: fixture.receiptURL).status() == .required)
    }

    @Test func repeatedInvalidApplicationDirectoryChecksDoNotLeakDescriptors() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(acceptedAt: firstDate)
        try chmod(fixture.applicationDirectory.path, 0o755).requireSuccess()
        let store = ExternalDataConsentStore(receiptURL: fixture.receiptURL)
        let descriptorsBefore = try openFileDescriptorCount()

        for _ in 0..<32 {
            #expect(await store.status() == .required)
        }

        let descriptorsAfter = try openFileDescriptorCount()
        #expect(descriptorsAfter <= descriptorsBefore + 2)
    }

    @Test func receiptOwnedByAnotherUserRequiresConsent() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(acceptedAt: firstDate)
        let differentUserID = geteuid() == uid_t.max ? geteuid() - 1 : geteuid() + 1
        let store = ExternalDataConsentStore(
            receiptURL: fixture.receiptURL,
            expectedReceiptOwnerID: differentUserID
        )

        #expect(await store.status() == .required)
    }

    @Test(arguments: [(2, 1), (1, 2)])
    func unknownSchemaOrPolicyVersionRequiresConsent(
        schemaVersion: Int,
        policyVersion: Int
    ) async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(
            schemaVersion: schemaVersion,
            policyVersion: policyVersion,
            acceptedAt: firstDate
        )

        #expect(await ExternalDataConsentStore(receiptURL: fixture.receiptURL).status() == .required)
    }

    @Test(arguments: [(false, true), (true, false)])
    func falseAcknowledgmentRequiresConsent(
        externalProviderRiskAccepted: Bool,
        documentToolAccessAccepted: Bool
    ) async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(
            acceptedAt: firstDate,
            externalProviderRiskAccepted: externalProviderRiskAccepted,
            documentToolAccessAccepted: documentToolAccessAccepted
        )

        #expect(await ExternalDataConsentStore(receiptURL: fixture.receiptURL).status() == .required)
    }

    @Test func encodedReceiptContainsOnlyApprovedKeys() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        let store = ExternalDataConsentStore(receiptURL: fixture.receiptURL)

        try await store.acceptBothStatements(at: firstDate)

        let object = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.receiptURL)
        ) as? [String: Any])
        #expect(Set(object.keys) == [
            "schema_version",
            "policy_version",
            "accepted_at",
            "external_provider_risk_accepted",
            "document_tool_access_accepted"
        ])
        #expect(object["schema_version"] as? Int == 1)
        #expect(object["policy_version"] as? Int == 1)
        #expect(object["external_provider_risk_accepted"] as? Bool == true)
        #expect(object["document_tool_access_accepted"] as? Bool == true)
        #expect(object["accepted_at"] is String)
    }

    @Test func receiptWithAnUnapprovedKeyRequiresConsent() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(acceptedAt: firstDate, extraKey: ("provider", "private"))

        #expect(await ExternalDataConsentStore(receiptURL: fixture.receiptURL).status() == .required)
    }

    @Test(arguments: [
        "schema_version",
        "policy_version",
        "accepted_at",
        "external_provider_risk_accepted",
        "document_tool_access_accepted"
    ])
    func duplicateApprovedJSONMemberRequiresConsent(memberName: String) async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        let formatter = ISO8601DateFormatter()
        let values = [
            "schema_version": "1",
            "policy_version": "1",
            "accepted_at": "\"\(formatter.string(from: firstDate))\"",
            "external_provider_risk_accepted": "true",
            "document_tool_access_accepted": "true"
        ]
        let members = [
            "\"schema_version\":1",
            "\"policy_version\":1",
            "\"accepted_at\":\"\(formatter.string(from: firstDate))\"",
            "\"external_provider_risk_accepted\":true",
            "\"document_tool_access_accepted\":true",
            "\"\(memberName)\":\(try #require(values[memberName]))"
        ]
        try fixture.writeRaw(Data("{\(members.joined(separator: ","))}".utf8))

        #expect(await ExternalDataConsentStore(receiptURL: fixture.receiptURL).status() == .required)
    }

    @Test func escapedDuplicateApprovedJSONMemberRequiresConsent() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        let formatter = ISO8601DateFormatter()
        let json = """
        {"schema_version":1,"policy_version":1,"accepted_at":"\(formatter.string(from: firstDate))","external_provider_risk_accepted":true,"document_tool_access_accepted":true,"schema_\\u0076ersion":1}
        """
        try fixture.writeRaw(Data(json.utf8))

        #expect(await ExternalDataConsentStore(receiptURL: fixture.receiptURL).status() == .required)
    }

    @Test func acceptRejectsParentSubstitutionBeforeRenameWithoutWritingThroughLink() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.createApplicationDirectory()
        let originalDirectory = fixture.applicationDirectory
        let movedDirectory = fixture.baseURL.appending(path: "moved-application", directoryHint: .isDirectory)
        let externalDirectory = fixture.baseURL.appending(path: "external-accept", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: false)
        try chmod(externalDirectory.path, 0o700).requireSuccess()
        let store = ExternalDataConsentStore(
            receiptURL: fixture.receiptURL,
            beforeAcceptRename: {
                try FileManager.default.moveItem(at: originalDirectory, to: movedDirectory)
                try FileManager.default.createSymbolicLink(
                    at: originalDirectory,
                    withDestinationURL: externalDirectory
                )
            }
        )

        await #expect(throws: (any Error).self) {
            try await store.acceptBothStatements(at: firstDate)
        }

        #expect(!FileManager.default.fileExists(
            atPath: externalDirectory.appending(path: "mcp-consent.json").path
        ))
        #expect(try quarantineReceipts(in: movedDirectory).count == 1)
        #expect(!FileManager.default.fileExists(
            atPath: movedDirectory.appending(path: "mcp-consent.json").path
        ))
    }

    @Test func acceptQuarantinesSourceSubstitutedAtTheFinalMutationInterval() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.createApplicationDirectory()
        let replacementData = try fixture.receiptData(acceptedAt: secondDate)
        let applicationDirectory = fixture.applicationDirectory
        let preservedOwnedTemporary = fixture.baseURL.appending(path: "owned-accept-temp")
        let hooks = ExternalDataConsentStoreHooks(
            beforeAcceptFinalMutation: {
                let candidate = try temporaryReceipt(in: applicationDirectory)
                let temporaryURL = try #require(candidate)
                try FileManager.default.moveItem(at: temporaryURL, to: preservedOwnedTemporary)
                try replacementData.write(to: temporaryURL)
                try chmod(temporaryURL.path, 0o600).requireSuccess()
            }
        )
        let store = ExternalDataConsentStore(receiptURL: fixture.receiptURL, hooks: hooks)

        await #expect(throws: (any Error).self) {
            try await store.acceptBothStatements(at: firstDate)
        }

        #expect(await store.status() == .required)
        #expect(!FileManager.default.fileExists(atPath: fixture.receiptURL.path))
        #expect(try directoryContainsFile(with: replacementData, at: applicationDirectory))
        #expect(FileManager.default.fileExists(atPath: preservedOwnedTemporary.path))
    }

    @Test func acceptQuarantinesDestinationSubstitutedAtTheFinalMutationInterval() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.createApplicationDirectory()
        let replacementData = try fixture.receiptData(acceptedAt: secondDate)
        let receiptURL = fixture.receiptURL
        let hooks = ExternalDataConsentStoreHooks(
            beforeAcceptFinalMutation: {
                try replacementData.write(to: receiptURL)
                try chmod(receiptURL.path, 0o600).requireSuccess()
            }
        )
        let store = ExternalDataConsentStore(receiptURL: receiptURL, hooks: hooks)

        await #expect(throws: (any Error).self) {
            try await store.acceptBothStatements(at: firstDate)
        }

        #expect(await store.status() == .required)
        #expect(!FileManager.default.fileExists(atPath: receiptURL.path))
        #expect(try directoryContainsFile(with: replacementData, at: fixture.applicationDirectory))
    }

    @Test func acceptPreservesAReplacementInsertedAfterQuarantineVerification() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(acceptedAt: firstDate)
        let originalData = try Data(contentsOf: fixture.receiptURL)
        let unknownData = Data("unknown-accept-quarantine".utf8)
        let applicationDirectory = fixture.applicationDirectory
        let preservedOriginal = fixture.baseURL.appending(path: "verified-accept-original")
        let hooks = ExternalDataConsentStoreHooks(
            afterQuarantineVerification: {
                try replaceVerifiedQuarantine(
                    in: applicationDirectory,
                    movingExpectedTo: preservedOriginal,
                    with: unknownData
                )
            }
        )
        let store = ExternalDataConsentStore(receiptURL: fixture.receiptURL, hooks: hooks)

        try await store.acceptBothStatements(at: secondDate)

        let expected = ExternalDataConsentReceipt(
            schemaVersion: 1,
            policyVersion: 1,
            acceptedAt: secondDate,
            externalProviderRiskAccepted: true,
            documentToolAccessAccepted: true
        )
        #expect(await store.status() == .current(expected))
        #expect(try Data(contentsOf: preservedOriginal) == originalData)
        #expect(try directoryContainsFile(with: unknownData, at: applicationDirectory))
    }

    @Test func revokeRejectsParentSubstitutionWithoutDeletingEitherTarget() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(acceptedAt: firstDate)
        let originalReceiptData = try Data(contentsOf: fixture.receiptURL)
        let originalDirectory = fixture.applicationDirectory
        let movedDirectory = fixture.baseURL.appending(path: "moved-revoke", directoryHint: .isDirectory)
        let externalDirectory = fixture.baseURL.appending(path: "external-revoke", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: false)
        try chmod(externalDirectory.path, 0o700).requireSuccess()
        let externalReceipt = externalDirectory.appending(path: "mcp-consent.json")
        let externalData = Data("external".utf8)
        try externalData.write(to: externalReceipt)
        let store = ExternalDataConsentStore(
            receiptURL: fixture.receiptURL,
            beforeRevokeUnlink: {
                try FileManager.default.moveItem(at: originalDirectory, to: movedDirectory)
                try FileManager.default.createSymbolicLink(
                    at: originalDirectory,
                    withDestinationURL: externalDirectory
                )
            }
        )

        await #expect(throws: (any Error).self) {
            try await store.revoke()
        }

        #expect(try Data(contentsOf: movedDirectory.appending(path: "mcp-consent.json")) == originalReceiptData)
        #expect(try Data(contentsOf: externalReceipt) == externalData)
    }

    @Test func revokeQuarantinesReceiptSubstitutedAtTheFinalMutationInterval() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(acceptedAt: firstDate)
        let replacementData = try fixture.receiptData(acceptedAt: secondDate)
        let receiptURL = fixture.receiptURL
        let preservedOriginal = fixture.baseURL.appending(path: "preserved-revoke-original")
        let hooks = ExternalDataConsentStoreHooks(
            beforeRevokeFinalMutation: {
                try FileManager.default.moveItem(at: receiptURL, to: preservedOriginal)
                try replacementData.write(to: receiptURL)
                try chmod(receiptURL.path, 0o600).requireSuccess()
            }
        )
        let store = ExternalDataConsentStore(receiptURL: receiptURL, hooks: hooks)

        await #expect(throws: (any Error).self) {
            try await store.revoke()
        }

        #expect(await store.status() == .required)
        #expect(!FileManager.default.fileExists(atPath: receiptURL.path))
        #expect(try Data(contentsOf: preservedOriginal) != replacementData)
        #expect(try directoryContainsFile(with: replacementData, at: fixture.applicationDirectory))
    }

    @Test func revokePreservesAReplacementInsertedAfterQuarantineVerification() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(acceptedAt: firstDate)
        let originalData = try Data(contentsOf: fixture.receiptURL)
        let unknownData = Data("unknown-revoke-quarantine".utf8)
        let applicationDirectory = fixture.applicationDirectory
        let preservedOriginal = fixture.baseURL.appending(path: "verified-revoke-original")
        let hooks = ExternalDataConsentStoreHooks(
            afterQuarantineVerification: {
                try replaceVerifiedQuarantine(
                    in: applicationDirectory,
                    movingExpectedTo: preservedOriginal,
                    with: unknownData
                )
            }
        )
        let store = ExternalDataConsentStore(receiptURL: fixture.receiptURL, hooks: hooks)

        try await store.revoke()

        #expect(await store.status() == .required)
        #expect(!FileManager.default.fileExists(atPath: fixture.receiptURL.path))
        #expect(try Data(contentsOf: preservedOriginal) == originalData)
        #expect(try directoryContainsFile(with: unknownData, at: applicationDirectory))
    }

    @Test func temporaryCleanupQuarantinesAReplacementAtItsFinalMutationInterval() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.createApplicationDirectory()
        let replacementData = Data("replacement-must-survive".utf8)
        let applicationDirectory = fixture.applicationDirectory
        let preservedOwnedTemporary = fixture.baseURL.appending(path: "preserved-cleanup-temp")
        let hooks = ExternalDataConsentStoreHooks(
            beforeAcceptReproof: {
                throw ConsentProbeError.stopBeforeAcceptCommit
            },
            beforeTemporaryCleanupFinalMutation: {
                let candidate = try temporaryReceipt(in: applicationDirectory)
                let temporaryURL = try #require(candidate)
                try FileManager.default.moveItem(at: temporaryURL, to: preservedOwnedTemporary)
                try replacementData.write(to: temporaryURL)
                try chmod(temporaryURL.path, 0o600).requireSuccess()
            }
        )
        let store = ExternalDataConsentStore(receiptURL: fixture.receiptURL, hooks: hooks)

        await #expect(throws: (any Error).self) {
            try await store.acceptBothStatements(at: firstDate)
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.receiptURL.path))
        #expect(try directoryContainsFile(with: replacementData, at: applicationDirectory))
        #expect(FileManager.default.fileExists(atPath: preservedOwnedTemporary.path))
    }

    @Test func temporaryCleanupPreservesAReplacementInsertedAfterQuarantineVerification() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.createApplicationDirectory()
        let unknownData = Data("unknown-temporary-quarantine".utf8)
        let applicationDirectory = fixture.applicationDirectory
        let preservedOwnedTemporary = fixture.baseURL.appending(path: "verified-owned-temporary")
        let hooks = ExternalDataConsentStoreHooks(
            beforeAcceptReproof: {
                throw ConsentProbeError.stopBeforeAcceptCommit
            },
            afterQuarantineVerification: {
                try replaceVerifiedQuarantine(
                    in: applicationDirectory,
                    movingExpectedTo: preservedOwnedTemporary,
                    with: unknownData
                )
            }
        )
        let store = ExternalDataConsentStore(receiptURL: fixture.receiptURL, hooks: hooks)

        await #expect(throws: (any Error).self) {
            try await store.acceptBothStatements(at: firstDate)
        }

        #expect(await store.status() == .required)
        #expect(!FileManager.default.fileExists(atPath: fixture.receiptURL.path))
        #expect((try Data(contentsOf: preservedOwnedTemporary)).count > 0)
        #expect(try Data(contentsOf: preservedOwnedTemporary) != unknownData)
        #expect(try directoryContainsFile(with: unknownData, at: applicationDirectory))
    }

    @Test func applicationDirectoryCreationSyncFailureDoesNotCreateAReceipt() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        let syncFailure = DirectorySyncFailure(failingDirectoryCall: 1)
        let hooks = ExternalDataConsentStoreHooks(synchronizeDescriptor: syncFailure.synchronize)
        let store = ExternalDataConsentStore(receiptURL: fixture.receiptURL, hooks: hooks)

        await #expect(throws: (any Error).self) {
            try await store.acceptBothStatements(at: firstDate)
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.receiptURL.path))
    }

    @Test func acceptDirectorySyncFailureLeavesConsentRequired() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.createApplicationDirectory()
        let syncFailure = DirectorySyncFailure(failingDirectoryCall: 1)
        let hooks = ExternalDataConsentStoreHooks(synchronizeDescriptor: syncFailure.synchronize)
        let store = ExternalDataConsentStore(receiptURL: fixture.receiptURL, hooks: hooks)

        await #expect(throws: (any Error).self) {
            try await store.acceptBothStatements(at: firstDate)
        }

        #expect(await ExternalDataConsentStore(receiptURL: fixture.receiptURL).status() == .required)
    }

    @Test func replacingReceiptQuarantineSyncFailureLeavesConsentRequired() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(acceptedAt: firstDate)
        let syncFailure = DirectorySyncFailure(failingDirectoryCall: 2)
        let hooks = ExternalDataConsentStoreHooks(synchronizeDescriptor: syncFailure.synchronize)
        let store = ExternalDataConsentStore(receiptURL: fixture.receiptURL, hooks: hooks)

        await #expect(throws: (any Error).self) {
            try await store.acceptBothStatements(at: secondDate)
        }

        #expect(await ExternalDataConsentStore(receiptURL: fixture.receiptURL).status() == .required)
    }

    @Test func revokeQuarantineDirectorySyncFailureStillLeavesConsentRequired() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(acceptedAt: firstDate)
        let syncFailure = DirectorySyncFailure(failingDirectoryCall: 1)
        let hooks = ExternalDataConsentStoreHooks(synchronizeDescriptor: syncFailure.synchronize)
        let store = ExternalDataConsentStore(receiptURL: fixture.receiptURL, hooks: hooks)

        await #expect(throws: (any Error).self) {
            try await store.revoke()
        }

        #expect(await ExternalDataConsentStore(receiptURL: fixture.receiptURL).status() == .required)
    }
}

private struct ConsentFixture {
    let baseURL: URL
    let applicationDirectory: URL
    let receiptURL: URL

    init() throws {
        baseURL = try physicalURL(for: FileManager.default.temporaryDirectory)
            .appending(path: "LocalOCR-consent-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        applicationDirectory = baseURL.appending(path: "application", directoryHint: .isDirectory)
        receiptURL = applicationDirectory.appending(path: "mcp-consent.json")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: false)
        try chmod(baseURL.path, 0o700).requireSuccess()
    }

    func createApplicationDirectory() throws {
        try FileManager.default.createDirectory(
            at: applicationDirectory,
            withIntermediateDirectories: false
        )
        try chmod(applicationDirectory.path, 0o700).requireSuccess()
    }

    func writeReceipt(
        schemaVersion: Int = 1,
        policyVersion: Int = 1,
        acceptedAt: Date,
        externalProviderRiskAccepted: Bool = true,
        documentToolAccessAccepted: Bool = true,
        extraKey: (String, Any)? = nil
    ) throws {
        try writeRaw(receiptData(
            schemaVersion: schemaVersion,
            policyVersion: policyVersion,
            acceptedAt: acceptedAt,
            externalProviderRiskAccepted: externalProviderRiskAccepted,
            documentToolAccessAccepted: documentToolAccessAccepted,
            extraKey: extraKey
        ))
    }

    func receiptData(
        schemaVersion: Int = 1,
        policyVersion: Int = 1,
        acceptedAt: Date,
        externalProviderRiskAccepted: Bool = true,
        documentToolAccessAccepted: Bool = true,
        extraKey: (String, Any)? = nil
    ) throws -> Data {
        let formatter = ISO8601DateFormatter()
        var object: [String: Any] = [
            "schema_version": schemaVersion,
            "policy_version": policyVersion,
            "accepted_at": formatter.string(from: acceptedAt),
            "external_provider_risk_accepted": externalProviderRiskAccepted,
            "document_tool_access_accepted": documentToolAccessAccepted
        ]
        if let extraKey {
            object[extraKey.0] = extraKey.1
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func writeRaw(_ data: Data) throws {
        if !FileManager.default.fileExists(atPath: applicationDirectory.path) {
            try createApplicationDirectory()
        }
        try data.write(to: receiptURL)
        try chmod(receiptURL.path, 0o600).requireSuccess()
    }

    func isSymbolicLink(at url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFLNK
    }

    func remove() {
        try? FileManager.default.removeItem(at: baseURL)
    }
}

private enum ConsentProbeError: Error {
    case receiptChangedBeforeCommit
    case secureTemporaryFileMissing
    case insecurePermissions
    case stopBeforeAcceptCommit
    case quarantineMissing
}

private final class DirectorySyncFailure: @unchecked Sendable {
    private let lock = NSLock()
    private let failingDirectoryCall: Int
    private var directoryCallCount = 0

    init(failingDirectoryCall: Int) {
        self.failingDirectoryCall = failingDirectoryCall
    }

    func synchronize(_ descriptor: Int32) -> Int32 {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            return -1
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            return fsync(descriptor)
        }
        lock.lock()
        directoryCallCount += 1
        let shouldFail = directoryCallCount == failingDirectoryCall
        lock.unlock()
        if shouldFail {
            __error().pointee = EIO
            return -1
        }
        return fsync(descriptor)
    }
}

private func temporaryReceipt(in directory: URL) throws -> URL? {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).first {
        $0.lastPathComponent.hasPrefix(".mcp-consent.json.") &&
            $0.lastPathComponent.hasSuffix(".tmp")
    }
}

private func quarantineReceipts(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { isQuarantineName($0.lastPathComponent) }
}

private func isQuarantineName(_ name: String) -> Bool {
    name.hasPrefix(".mcp-consent.json.") && name.hasSuffix(".quarantine")
}

private func replaceVerifiedQuarantine(
    in directory: URL,
    movingExpectedTo preservedURL: URL,
    with replacementData: Data
) throws {
    let quarantines = try quarantineReceipts(in: directory)
    guard quarantines.count == 1, let quarantine = quarantines.first else {
        throw ConsentProbeError.quarantineMissing
    }
    try FileManager.default.moveItem(at: quarantine, to: preservedURL)
    try replacementData.write(to: quarantine)
    try chmod(quarantine.path, 0o600).requireSuccess()
}

private func directoryContainsFile(with expectedData: Data, at directory: URL) throws -> Bool {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey]
    ).contains { url in
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return false
        }
        return (try? Data(contentsOf: url)) == expectedData
    }
}

private func permissions(of url: URL) throws -> mode_t {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
        throw POSIXTestError(code: errno)
    }
    return metadata.st_mode & 0o777
}

private struct POSIXTestError: Error {
    let code: Int32
}

private func openFileDescriptorCount() throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
}

private func physicalURL(for url: URL) throws -> URL {
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &resolved) != nil else {
        throw POSIXTestError(code: errno)
    }
    let path = String(
        decoding: resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
        as: UTF8.self
    )
    return URL(fileURLWithPath: path, isDirectory: true)
}

private extension Int32 {
    func requireSuccess() throws {
        guard self == 0 else { throw POSIXTestError(code: errno) }
    }
}
