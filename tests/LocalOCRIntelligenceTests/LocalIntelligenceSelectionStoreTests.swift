import Darwin
import Foundation
@testable import LocalOCRIntelligence
import LocalOCRModelCore
import Testing

@Suite(.serialized) struct LocalIntelligenceSelectionStoreTests {
    private let selectedAt = Date(timeIntervalSince1970: 1_788_307_200)

    @Test func externalSelectionRequiresMatchingQualificationAndAcknowledgment() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.remove() }
        let identity = fixtureOllamaIdentity
        let store = LocalIntelligenceSelectionStore(receiptURL: fixture.receiptURL)
        let qualification = fixtureQualification(identity)
        let acknowledgment = fixtureAcknowledgment(identity)

        try await store.selectExternal(
            identity,
            qualification: qualification,
            acknowledgment: acknowledgment
        )

        #expect(await store.state() == .selected(.external(
            identity: identity,
            qualification: qualification,
            acknowledgment: acknowledgment
        )))
    }

    @Test func selectionStoreRejectsSymlinkedReceiptDirectory() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.remove() }
        let externalDirectory = fixture.baseURL.appending(
            path: "external",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: externalDirectory,
            withIntermediateDirectories: false
        )
        try chmod(externalDirectory.path, 0o700).requireSelectionSuccess()
        try FileManager.default.createSymbolicLink(
            at: fixture.applicationDirectory,
            withDestinationURL: externalDirectory
        )
        let store = LocalIntelligenceSelectionStore(receiptURL: fixture.receiptURL)

        await #expect(throws: LocalIntelligenceSelectionStoreError.insecureFilesystemState) {
            try await store.selectApple(at: selectedAt)
        }
        #expect(!FileManager.default.fileExists(
            atPath: externalDirectory.appending(path: "local-intelligence-selection.json").path
        ))
    }

    @Test func intelligenceErrorCarriesTheStableSelectionFailure() {
        let failure = LocalIntelligenceSelectionFailure.providerUnavailable(.ollama)

        #expect(IntelligenceError.selection(failure) == .selection(failure))
    }

    @Test func missingLegacyReceiptMigratesOnceToAppleSystemDefault() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.remove() }
        let store = LocalIntelligenceSelectionStore(receiptURL: fixture.receiptURL)

        #expect(await store.state() == .selected(.appleSystemDefault))
        #expect(await store.state() == .selected(.appleSystemDefault))
        #expect(FileManager.default.fileExists(atPath: fixture.receiptURL.path))
        #expect(try selectionPermissions(of: fixture.applicationDirectory) == 0o700)
        #expect(try selectionPermissions(of: fixture.receiptURL) == 0o600)
    }

    @Test func explicitResetPersistsNoneAndNeverRemigratesAsLegacyAbsence() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.remove() }
        let firstStore = LocalIntelligenceSelectionStore(receiptURL: fixture.receiptURL)
        _ = await firstStore.state()

        try await firstStore.reset(at: selectedAt)

        #expect(await firstStore.state() == .none)
        let relaunchedStore = LocalIntelligenceSelectionStore(receiptURL: fixture.receiptURL)
        #expect(await relaunchedStore.state() == .none)
        let object = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.receiptURL)
        ) as? [String: Any])
        #expect(Set(object.keys) == ["schema_version", "policy_version", "state", "reset_at"])
        #expect(object["state"] as? String == "none")
    }

    @Test func staleQualificationPolicyIsRejectedBeforePersistence() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.remove() }
        let identity = fixtureOllamaIdentity
        let stale = LocalModelQualificationReceipt(
            policyVersion: 2,
            fixtureVersion: 1,
            identity: identity,
            passedActions: [.summary, .organization, .extraction],
            qualifiedAt: selectedAt
        )
        let store = LocalIntelligenceSelectionStore(receiptURL: fixture.receiptURL)

        await #expect(throws: IntelligenceError.selection(.qualificationRequired(identity))) {
            try await store.selectExternal(
                identity,
                qualification: stale,
                acknowledgment: fixtureAcknowledgment(identity)
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.receiptURL.path))
    }

    @Test func partialQualificationIsRejectedBeforePersistence() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.remove() }
        let identity = fixtureOllamaIdentity
        let partial = LocalModelQualificationReceipt(
            policyVersion: 1,
            fixtureVersion: 1,
            identity: identity,
            passedActions: [.summary, .organization],
            qualifiedAt: selectedAt
        )
        let store = LocalIntelligenceSelectionStore(receiptURL: fixture.receiptURL)

        await #expect(throws: IntelligenceError.selection(.qualificationRequired(identity))) {
            try await store.selectExternal(
                identity,
                qualification: partial,
                acknowledgment: fixtureAcknowledgment(identity)
            )
        }
    }

    @Test func mismatchedQualificationIdentityIsRejectedBeforePersistence() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.remove() }
        let identity = fixtureOllamaIdentity
        let otherIdentity = LocalModelIdentity(
            provider: .ollama,
            model: "other:8b",
            fingerprint: "sha256:other",
            harnessVersion: identity.harnessVersion
        )
        let store = LocalIntelligenceSelectionStore(receiptURL: fixture.receiptURL)

        await #expect(throws: IntelligenceError.selection(.qualificationRequired(identity))) {
            try await store.selectExternal(
                identity,
                qualification: fixtureQualification(otherIdentity),
                acknowledgment: fixtureAcknowledgment(identity)
            )
        }
    }

    @Test func staleOrMismatchedAcknowledgmentIsRejectedBeforePersistence() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.remove() }
        let identity = fixtureOllamaIdentity
        let stale = ExternalLocalModelAcknowledgment(
            policyVersion: 2,
            identity: identity,
            acceptedAt: selectedAt
        )
        let store = LocalIntelligenceSelectionStore(receiptURL: fixture.receiptURL)

        await #expect(throws: IntelligenceError.selection(.acknowledgmentRequired(identity))) {
            try await store.selectExternal(
                identity,
                qualification: fixtureQualification(identity),
                acknowledgment: stale
            )
        }
    }

    @Test func corruptOrUnsupportedReceiptReturnsInvalidWithoutOverwritingIt() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.remove() }
        let unsupported = Data("""
        {"schema_version":2,"policy_version":1,"state":"selected","selection":{"appleSystemDefault":{}}}
        """.utf8)
        try fixture.writeRaw(unsupported)
        let store = LocalIntelligenceSelectionStore(receiptURL: fixture.receiptURL)

        #expect(await store.state() == .invalid(.corruptReceipt))
        #expect(try Data(contentsOf: fixture.receiptURL) == unsupported)
    }

    @Test func duplicateNestedIdentityMemberIsRejectedAsCorrupt() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.remove() }
        let identity = fixtureOllamaIdentity
        let receipt = LocalIntelligenceSelectionReceipt.selected(.external(
            identity: identity,
            qualification: fixtureQualification(identity),
            acknowledgment: fixtureAcknowledgment(identity)
        ))
        let validData = try selectionReceiptData(receipt)
        let validJSON = try #require(String(data: validData, encoding: .utf8))
        let marker = "\"provider\":\"ollama\""
        let range = try #require(validJSON.range(of: marker))
        let duplicateJSON = validJSON.replacingCharacters(
            in: range,
            with: "\(marker),\(marker)"
        )
        try fixture.writeRaw(Data(duplicateJSON.utf8))

        #expect(await LocalIntelligenceSelectionStore(
            receiptURL: fixture.receiptURL
        ).state() == .invalid(.corruptReceipt))
    }

    @Test func insecureReceiptPermissionsReturnInvalid() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.remove() }
        let store = LocalIntelligenceSelectionStore(receiptURL: fixture.receiptURL)
        try await store.selectApple(at: selectedAt)
        try chmod(fixture.receiptURL.path, 0o644).requireSelectionSuccess()

        #expect(await store.state() == .invalid(.corruptReceipt))
    }

    @Test func hardLinkedReceiptIsRejectedByBothSecureStores() async throws {
        let selectionFixture = try SelectionFixture()
        defer { selectionFixture.remove() }
        let selectionStore = LocalIntelligenceSelectionStore(receiptURL: selectionFixture.receiptURL)
        try await selectionStore.selectApple(at: selectedAt)
        let selectionLink = selectionFixture.baseURL.appending(path: "selection-link.json")
        try FileManager.default.linkItem(at: selectionFixture.receiptURL, to: selectionLink)

        #expect(await selectionStore.state() == .invalid(.corruptReceipt))

        let consentFixture = try SelectionFixture(receiptName: "mcp-consent.json")
        defer { consentFixture.remove() }
        let consentStore = ExternalDataConsentStore(receiptURL: consentFixture.receiptURL)
        try await consentStore.acceptBothStatements(at: selectedAt)
        let consentLink = consentFixture.baseURL.appending(path: "consent-link.json")
        try FileManager.default.linkItem(at: consentFixture.receiptURL, to: consentLink)

        #expect(await consentStore.status() == .required)
    }
}

private let fixtureOllamaIdentity = LocalModelIdentity(
    provider: .ollama,
    model: "gemma4:8b",
    fingerprint: "sha256:fixture",
    harnessVersion: "0.11.8"
)

private func fixtureQualification(
    _ identity: LocalModelIdentity
) -> LocalModelQualificationReceipt {
    LocalModelQualificationReceipt(
        policyVersion: 1,
        fixtureVersion: 1,
        identity: identity,
        passedActions: [.summary, .organization, .extraction],
        qualifiedAt: Date(timeIntervalSince1970: 1_788_220_800)
    )
}

private func fixtureAcknowledgment(
    _ identity: LocalModelIdentity
) -> ExternalLocalModelAcknowledgment {
    ExternalLocalModelAcknowledgment(
        policyVersion: 1,
        identity: identity,
        acceptedAt: Date(timeIntervalSince1970: 1_788_307_200)
    )
}

private func selectionReceiptData(
    _ receipt: LocalIntelligenceSelectionReceipt
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(receipt)
}

private struct SelectionFixture {
    let baseURL: URL
    let applicationDirectory: URL
    let receiptURL: URL

    init(receiptName: String = "local-intelligence-selection.json") throws {
        baseURL = try physicalSelectionURL(for: FileManager.default.temporaryDirectory)
            .appending(
                path: "LocalOCR-selection-tests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        applicationDirectory = baseURL.appending(path: "application", directoryHint: .isDirectory)
        receiptURL = applicationDirectory.appending(path: receiptName)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: false)
        try chmod(baseURL.path, 0o700).requireSelectionSuccess()
    }

    func remove() {
        try? FileManager.default.removeItem(at: baseURL)
    }

    func writeRaw(_ data: Data) throws {
        if !FileManager.default.fileExists(atPath: applicationDirectory.path) {
            try FileManager.default.createDirectory(
                at: applicationDirectory,
                withIntermediateDirectories: false
            )
            try chmod(applicationDirectory.path, 0o700).requireSelectionSuccess()
        }
        try data.write(to: receiptURL)
        try chmod(receiptURL.path, 0o600).requireSelectionSuccess()
    }
}

private struct SelectionPOSIXError: Error {
    let code: Int32
}

private func physicalSelectionURL(for url: URL) throws -> URL {
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &resolved) != nil else {
        throw SelectionPOSIXError(code: errno)
    }
    let path = String(
        decoding: resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
        as: UTF8.self
    )
    return URL(fileURLWithPath: path, isDirectory: true)
}

private func selectionPermissions(of url: URL) throws -> mode_t {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
        throw SelectionPOSIXError(code: errno)
    }
    return metadata.st_mode & 0o777
}

private extension Int32 {
    func requireSelectionSuccess() throws {
        guard self == 0 else { throw SelectionPOSIXError(code: errno) }
    }
}
