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
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: fixture.applicationDirectory.path
        ) == ["mcp-consent.json"])
    }

    @Test func revokeRemovesOnlyTheValidatedReceipt() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(acceptedAt: firstDate)
        let unrelatedURL = fixture.applicationDirectory.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: unrelatedURL)
        let store = ExternalDataConsentStore(receiptURL: fixture.receiptURL)

        try await store.revoke()

        #expect(await store.status() == .required)
        #expect(FileManager.default.fileExists(atPath: fixture.applicationDirectory.path))
        #expect(try String(contentsOf: unrelatedURL, encoding: .utf8) == "keep")
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

    @Test func nonPrivateApplicationDirectoryRequiresConsent() async throws {
        let fixture = try ConsentFixture()
        defer { fixture.remove() }
        try fixture.writeReceipt(acceptedAt: firstDate)
        try chmod(fixture.applicationDirectory.path, 0o755).requireSuccess()

        #expect(await ExternalDataConsentStore(receiptURL: fixture.receiptURL).status() == .required)
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
        #expect(try FileManager.default.contentsOfDirectory(atPath: movedDirectory.path).isEmpty)
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
        try writeRaw(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
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
