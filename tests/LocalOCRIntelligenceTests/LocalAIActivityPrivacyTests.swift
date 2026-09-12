import Foundation
@testable import LocalOCRIntelligence
import LocalOCRModelBridgeProtocol
import LocalOCRModelCore
import Testing

@Suite struct LocalAIActivityPrivacyTests {
    // Catches an expanded encoder shape or a factory that accepts arbitrary runtime identity or route metadata.
    @Test func v1FactoriesProduceOnlyTheExactSeventeenKeyShape() async throws {
        let expectedKeys: Set<String> = [
            "schema_version", "activity_id", "producer_id", "producer_role", "platform",
            "runtime_family", "runtime_identifier", "route", "operation", "product_task",
            "state", "started_at", "heartbeat_at", "expires_at", "ended_at", "outcome",
            "evidence",
        ]
        #expect(LocalAIActivityContract.v1Keys == expectedKeys)

        let foundation = LocalAIActivityDescriptor.foundationModels(
            role: .studio,
            platform: .ios,
            task: .summarize
        )
        let localRuntime = LocalAIActivityDescriptor.localRuntime(
            role: .mcp,
            platform: .ipados,
            task: .extract
        )

        #expect(foundation == LocalAIActivityDescriptor(
            producerID: "com.rayconsulting.localocr",
            producerRole: .studio,
            platform: .ios,
            runtimeFamily: .foundationModels,
            runtimeIdentifier: "SystemLanguageModel.default",
            route: .onDevice,
            operation: .generation,
            productTask: .summarize
        ))
        #expect(localRuntime == LocalAIActivityDescriptor(
            producerID: "com.rayconsulting.localocr",
            producerRole: .mcp,
            platform: .ipados,
            runtimeFamily: .localRuntime,
            runtimeIdentifier: nil,
            route: .onDeviceLoopback,
            operation: .generation,
            productTask: .extract
        ))

        let fixture = try PrivacyActivityFixture()
        defer { fixture.remove() }
        let activeID = try await fixture.ledger.begin(foundation)
        let activeData = try #require(fixture.recordData(in: "active").first)
        try await fixture.ledger.end(activeID, outcome: .success)
        let second: String = try await fixture.reporter.withActivity(localRuntime) { "second" }
        #expect(second == "second")

        let recentData = try fixture.recordData(in: "recent")
        #expect(recentData.count == 2)
        let data = [activeData] + recentData
        for recordData in data {
            let object = try #require(
                JSONSerialization.jsonObject(with: recordData) as? [String: Any]
            )
            #expect(Set(object.keys) == expectedKeys)
        }
    }

    // Catches IntelligenceError.cancelled being persisted as a failure instead of a generic cancellation.
    @Test func intelligenceCancellationRecordsCancellationAndRethrowsTheExactError() async {
        let ledger = PrivacyOutcomeLedger()
        let reporter = LocalAIActivityReporter(
            ledger: ledger,
            clock: SystemLocalAIActivityClock()
        )

        do {
            let _: String = try await reporter.withActivity(
                .foundationModels(role: .studio, task: .summarize)
            ) {
                throw IntelligenceError.cancelled
            }
            Issue.record("Expected IntelligenceError.cancelled")
        } catch let error as IntelligenceError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await ledger.outcomes == [.cancelled])
    }

    // Catches document, result, requested-field, path, URL, or error payloads entering router-owned records.
    @Test func routerSuccessAndFailureNeverWriteAnyContentCanary() async throws {
        let fixture = try PrivacyActivityFixture()
        defer { fixture.remove() }

        let successProvider = PrivacyCanaryProvider(
            behavior: .success(privacyForbiddenCanaries.joined(separator: " | "))
        )
        let successRouter = privacyRouter(provider: successProvider, reporter: fixture.reporter)
        let success = try await successRouter.summarize(privacyCanaryDocument)
        #expect(success.value.text == privacyForbiddenCanaries.joined(separator: " | "))

        let ownedError = PrivacyOwnedError(message: "model-error-canary")
        let failureProvider = PrivacyCanaryProvider(behavior: .failure(ownedError))
        let failureRouter = privacyRouter(provider: failureProvider, reporter: fixture.reporter)
        do {
            _ = try await failureRouter.extract(
                ["total", "prompt-canary", "https://example.invalid"],
                from: privacyCanaryDocument
            )
            Issue.record("Expected the provider's exact error")
        } catch let error as PrivacyOwnedError {
            #expect(error === ownedError)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let records = try fixture.recordData(in: "recent").map(LocalAIActivityContract.decode)
        #expect(records.count == 2)
        #expect(Set(records.compactMap(\.outcome)) == [.success, .failure])
        let allBytes = try fixture.allLedgerBytes()
        for canary in privacyForbiddenCanaries {
            #expect(!allBytes.contains(Data(canary.utf8)))
        }
    }

    // Catches an unavailable or permission-denied ledger replacing an owned value or exact owned error.
    @Test func unavailableAndPermissionDeniedLedgersPreserveOwnedResults() async throws {
        let unavailableURL = FileManager.default.temporaryDirectory.appending(
            path: "LocalOCR-privacy-missing-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let unavailableReporter = LocalAIActivityReporter(
            ledger: LocalAIActivityLedger(containerURL: unavailableURL),
            clock: SystemLocalAIActivityClock()
        )
        let exactValue = PrivacyOwnedValue(value: "response-canary")
        let returned: PrivacyOwnedValue = try await unavailableReporter.withActivity(
            .foundationModels(role: .studio, task: .organize)
        ) {
            exactValue
        }
        #expect(returned == exactValue)

        let deniedURL = try makePrivateTemporaryDirectory(prefix: "LocalOCR-privacy-denied")
        defer {
            _ = chmod(deniedURL.path, 0o700)
            try? FileManager.default.removeItem(at: deniedURL)
        }
        guard chmod(deniedURL.path, 0o500) == 0 else {
            Issue.record("Could not create the permission-denied fixture")
            return
        }
        let deniedReporter = LocalAIActivityReporter(
            ledger: LocalAIActivityLedger(containerURL: deniedURL),
            clock: SystemLocalAIActivityClock()
        )
        let exactError = PrivacyOwnedError(message: "model-error-canary")
        do {
            let _: String = try await deniedReporter.withActivity(
                .localRuntime(role: .cli, platform: .macos, task: .extract)
            ) {
                throw exactError
            }
            Issue.record("Expected the provider's exact error")
        } catch let error as PrivacyOwnedError {
            #expect(error === exactError)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // Catches malformed or future-schema active entries blocking or contaminating a new owned operation.
    @Test(arguments: [
        Data("not-json model-error-canary".utf8),
        Data(#"{"schema_version":999,"prompt":"prompt-canary"}"#.utf8),
    ])
    func malformedAndUnknownSchemaEntriesFailClosedWithoutChangingTheOwnedValue(
        hostileData: Data
    ) async throws {
        let fixture = try PrivacyActivityFixture(hostileActiveData: hostileData)
        defer { fixture.remove() }
        let exactValue = PrivacyOwnedValue(value: "response-canary")

        let returned: PrivacyOwnedValue = try await fixture.reporter.withActivity(
            .foundationModels(role: .mcp, task: .summarize)
        ) {
            exactValue
        }

        #expect(returned == exactValue)
        #expect(try fixture.recordData(in: "active").isEmpty)
        let recent = try fixture.recordData(in: "recent")
        #expect(recent.count == 1)
        #expect(try LocalAIActivityContract.decode(recent[0]).outcome == .success)
        let allBytes = try fixture.allLedgerBytes()
        #expect(!allBytes.contains(Data("prompt-canary".utf8)))
        #expect(!allBytes.contains(Data("model-error-canary".utf8)))
    }
}

let privacyForbiddenCanaries = [
    "SECRET OCR TEXT", "/Users/scott/private.pdf", "invoice.pdf",
    "prompt-canary", "response-canary", "total", "$9,999.00",
    "https://example.invalid", "model-error-canary",
]

private let privacyCanaryDocument = IntelligenceDocument(pages: [
    .init(number: 1, text: privacyForbiddenCanaries.joined(separator: " | ")),
])

private struct PrivacyOwnedValue: Sendable, Equatable {
    let value: String
}

private final class PrivacyOwnedError: Error, @unchecked Sendable {
    let message: String

    init(message: String) {
        self.message = message
    }
}

private actor PrivacyOutcomeLedger: LocalAIActivityLedgerWriting {
    private(set) var outcomes: [LocalAIActivityOutcome] = []

    func begin(_ descriptor: LocalAIActivityDescriptor) async throws -> UUID {
        _ = descriptor
        return UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
    }

    func heartbeat(_ activityID: UUID) async throws {
        _ = activityID
    }

    func end(_ activityID: UUID, outcome: LocalAIActivityOutcome) async throws {
        _ = activityID
        outcomes.append(outcome)
    }

    func cleanupExpired() async {}
}

private actor PrivacySelectionStore: LocalIntelligenceSelectionStoring {
    func state() async -> LocalIntelligenceSelectionState {
        .selected(.appleSystemDefault)
    }

    func selectApple(at date: Date) async throws { _ = date }

    func selectExternal(
        _ identity: LocalModelIdentity,
        qualification: LocalModelQualificationReceipt,
        acknowledgment: ExternalLocalModelAcknowledgment
    ) async throws {
        _ = identity
        _ = qualification
        _ = acknowledgment
    }

    func reset(at date: Date) async throws { _ = date }
}

private struct PrivacyUnusedTransport: ModelBridgeTransporting {
    func send(_ request: ModelBridgeRequest) async throws -> ModelBridgeResponse {
        Issue.record("Apple Foundation Models routing must not invoke the bridge")
        return ModelBridgeResponse(id: request.id)
    }
}

private actor PrivacyCanaryProvider: DocumentIntelligenceProviding {
    enum Behavior: Sendable {
        case success(String)
        case failure(PrivacyOwnedError)
    }

    nonisolated let availability: IntelligenceAvailability = .available
    private let behavior: Behavior

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func summarize(
        _ document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<IntelligenceSummary> {
        _ = document
        switch behavior {
        case let .success(value):
            return .init(
                value: .init(text: value, citations: [.init(page: 1, quote: value)]),
                model: .appleSystemDefault
            )
        case let .failure(error):
            throw error
        }
    }

    func organize(
        _ document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<OrganizationSuggestion> {
        _ = document
        switch behavior {
        case let .success(value):
            return .init(
                value: .init(
                    title: value,
                    category: value,
                    tags: [value],
                    citations: [.init(page: 1, quote: value)]
                ),
                model: .appleSystemDefault
            )
        case let .failure(error):
            throw error
        }
    }

    func extract(
        _ names: [String],
        from document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<[ExtractedDocumentField]> {
        _ = names
        _ = document
        switch behavior {
        case let .success(value):
            return .init(
                value: [.init(name: value, value: value, sourcePage: 1, evidence: value)],
                model: .appleSystemDefault
            )
        case let .failure(error):
            throw error
        }
    }
}

private func privacyRouter(
    provider: any DocumentIntelligenceProviding,
    reporter: any LocalAIActivityReporting
) -> LocalIntelligenceProviderRouter {
    LocalIntelligenceProviderRouter(
        selectionStore: PrivacySelectionStore(),
        transport: PrivacyUnusedTransport(),
        appleProviderFactory: { provider },
        activityReporter: reporter,
        producerRole: .studio,
        platform: .macos
    )
}

private final class PrivacyActivityFixture: @unchecked Sendable {
    let containerURL: URL
    let ledger: LocalAIActivityLedger
    let reporter: LocalAIActivityReporter

    init(hostileActiveData: Data? = nil) throws {
        containerURL = try makePrivateTemporaryDirectory(prefix: "LocalOCR-privacy")
        if let hostileActiveData {
            let activeURL = containerURL
                .appending(path: "LocalAIActivity/v1/active", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: activeURL, withIntermediateDirectories: true)
            for directory in [
                containerURL.appending(path: "LocalAIActivity", directoryHint: .isDirectory),
                containerURL.appending(path: "LocalAIActivity/v1", directoryHint: .isDirectory),
                activeURL,
            ] {
                guard chmod(directory.path, 0o700) == 0 else {
                    throw PrivacyFixtureError.permissions
                }
            }
            let hostileURL = activeURL.appending(
                path: "11111111-1111-4111-8111-111111111111.json",
                directoryHint: .notDirectory
            )
            try hostileActiveData.write(to: hostileURL)
            guard chmod(hostileURL.path, 0o600) == 0 else {
                throw PrivacyFixtureError.permissions
            }
        }
        let clock = SystemLocalAIActivityClock()
        ledger = LocalAIActivityLedger(containerURL: containerURL, clock: clock)
        reporter = LocalAIActivityReporter(
            ledger: ledger,
            clock: clock
        )
    }

    func recordData(in directory: String) throws -> [Data] {
        let directoryURL = containerURL
            .appending(path: "LocalAIActivity/v1", directoryHint: .isDirectory)
            .appending(path: directory, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map { try Data(contentsOf: $0) }
    }

    func allLedgerBytes() throws -> Data {
        let root = containerURL.appending(path: "LocalAIActivity", directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return Data()
        }
        var bytes = Data()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                bytes.append(try Data(contentsOf: url))
            }
        }
        return bytes
    }

    func remove() {
        try? FileManager.default.removeItem(at: containerURL)
    }
}

private enum PrivacyFixtureError: Error {
    case permissions
}

private func makePrivateTemporaryDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "\(prefix)-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    guard chmod(url.path, 0o700) == 0 else {
        throw PrivacyFixtureError.permissions
    }
    return url
}
