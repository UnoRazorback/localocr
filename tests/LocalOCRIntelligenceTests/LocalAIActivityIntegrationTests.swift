import Foundation
import Darwin
@testable import LocalOCRIntelligence
import LocalOCRModelBridgeProtocol
import LocalOCRModelCore
import Testing

@Suite struct LocalAIActivityIntegrationTests {
    @Test func productionFactoryUsesApprovedContainerAndPersistsLifecycle() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/localocr-production-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var requestedGroups: [String] = []
        let reporter = LocalAIActivityProduction.makeReporter(containerResolver: { group in
            requestedGroups.append(group)
            return root
        }, isAuthorized: { true })
        #expect(requestedGroups == ["DZ8B5454ZN.com.rayconsulting.local-ai-activity"])
        #expect(reporter is LocalAIActivityReporter)
        let result = try await reporter.withActivity(.localRuntime(role: .cli, platform: .macos, task: .summarize)) {
            let active = root.appending(path: "LocalAIActivity/v1/active")
            let activeEntries = try FileManager.default.contentsOfDirectory(atPath: active.path)
            #expect(activeEntries.count == 1)
            return "owned result"
        }
        #expect(result == "owned result")
        let recent = root.appending(path: "LocalAIActivity/v1/recent")
        let entries = try FileManager.default.contentsOfDirectory(at: recent, includingPropertiesForKeys: nil)
        let data = try Data(contentsOf: #require(entries.first))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == LocalAIActivityContract.v1Keys)
        #expect(object["runtime_identifier"] is NSNull)
        #expect(object["outcome"] as? String == "success")
        #expect(!String(decoding: data, as: UTF8.self).contains(root.path))
    }

    @Test func productionSignatureRequiresApprovedTeamAndGroupTogether() {
        let group = "DZ8B5454ZN.com.rayconsulting.local-ai-activity"
        #expect(LocalAIActivityProduction.signatureIsAuthorized(team: "DZ8B5454ZN", groups: [group]))
        #expect(!LocalAIActivityProduction.signatureIsAuthorized(team: nil, groups: [group]))
        #expect(!LocalAIActivityProduction.signatureIsAuthorized(team: "OTHERTEAM1", groups: [group]))
        #expect(!LocalAIActivityProduction.signatureIsAuthorized(team: "DZ8B5454ZN", groups: nil))
        #expect(!LocalAIActivityProduction.signatureIsAuthorized(team: "DZ8B5454ZN", groups: ["group.unapproved"]))
    }

    @Test func productionFactoryRejectsUnauthorizedCodeBeforeResolvingContainer() {
        var resolved = false
        let reporter = LocalAIActivityProduction.makeReporter(containerResolver: { _ in
            resolved = true
            return URL(fileURLWithPath: "/private/tmp")
        }, isAuthorized: { false })
        #expect(!resolved)
        #expect(reporter is DisabledLocalAIActivityReporter)
    }

    @Test func productionFactoryDisablesWhenContainerUnavailableOrInsecure() async throws {
        let missing = URL(fileURLWithPath: "/private/tmp/absent-\(UUID().uuidString)", isDirectory: true)
        let resolvers: [(String) throws -> URL?] = [
            { _ in nil }, { _ in throw CocoaError(.fileReadNoPermission) }, { _ in missing }
        ]
        for resolver in resolvers {
            let reporter = LocalAIActivityProduction.makeReporter(containerResolver: resolver, isAuthorized: { true })
            #expect(reporter is DisabledLocalAIActivityReporter)
            #expect(try await reporter.withActivity(.foundationModels(role: .studio, task: .extract)) { 42 } == 42)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    // Catches an environment that drops the explicit platform/role before constructing its shared router.
    @Test func injectedEnvironmentPassesRoleAndPlatformToTheRouterBoundary() async throws {
        let reporter = Task4RecordingActivityReporter()
        let locator = Task6LocatorSpy()
        let store = Task6SelectionStore(.selected(.appleSystemDefault))
        let apple = Task6FixtureProvider(identity: .appleSystemDefault)
        let environment = LocalIntelligenceEnvironment.live(
            bridgeLocator: locator,
            selectionStore: store,
            appleProviderFactory: { apple },
            activityReporter: reporter,
            producerRole: .iosApp,
            platform: .ipados,
            now: { task6Now }
        )

        _ = try await environment.router.summarize(task6Document)

        #expect(await reporter.descriptors == [
            .foundationModels(role: .iosApp, platform: .ipados, task: .summarize)
        ])
        #expect(locator.resolutionCount == 0)
    }

    // Catches reporting that starts during discovery, cache/status reads, or selection mutation.
    @Test func discoverySelectionAndReceiptAccessEmitNoActivity() async throws {
        let reporter = Task4RecordingActivityReporter()
        let locator = Task6LocatorSpy()
        let store = Task6SelectionStore(.selected(.appleSystemDefault))
        let environment = LocalIntelligenceEnvironment.live(
            bridgeLocator: locator,
            selectionStore: store,
            appleProviderFactory: { Task6FixtureProvider(identity: .appleSystemDefault) },
            activityReporter: reporter,
            producerRole: .studio,
            platform: .macos,
            now: { task6Now }
        )

        _ = await environment.manager.models()
        _ = await environment.manager.status()
        try await environment.manager.selectApple()
        try await environment.manager.reset()

        #expect(await reporter.descriptors.isEmpty)
    }

    // Catches a router integration that lets an unavailable ledger replace the provider's exact value or error.
    @Test func reporterWriteFailurePreservesExactProviderValueAndError() async throws {
        let reporter = LocalAIActivityReporter(
            ledger: Task4ThrowingActivityLedger(),
            clock: Task4IdleActivityClock()
        )
        let success = Task6FixtureProvider(identity: .appleSystemDefault)
        let successRouter = task6Router(
            transport: Task6Transport { request in ModelBridgeResponse(id: request.id) },
            apple: success,
            state: .selected(.appleSystemDefault),
            reporter: reporter,
            role: .studio
        )

        let result = try await successRouter.summarize(task6Document)
        #expect(result.value.text == "Invoice Q-104 totals $144.17 on 2026-08-29.")

        let failure = Task6FixtureProvider(
            identity: .appleSystemDefault,
            failure: Task4OwnedModelError.exact
        )
        let failureRouter = task6Router(
            transport: Task6Transport { request in ModelBridgeResponse(id: request.id) },
            apple: failure,
            state: .selected(.appleSystemDefault),
            reporter: reporter,
            role: .studio
        )
        await #expect(throws: Task4OwnedModelError.exact) {
            try await failureRouter.organize(task6Document)
        }
    }

    // Catches validation that resolves a caller-supplied final symlink before checking its file type.
    @Test func crossAppFixtureRejectsSuppliedFinalSymlink() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "local-ai-activity-symlink-\(UUID().uuidString)", directoryHint: .isDirectory)
        let target = root.appending(path: "target", directoryHint: .isDirectory)
        let supplied = root.appending(path: "supplied", directoryHint: .notDirectory)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: supplied, withDestinationURL: target)
        defer { try? fileManager.removeItem(at: root) }

        #expect(throws: CrossAppAcceptanceFixtureError.self) {
            _ = try CrossAppAcceptanceProducerFixture(environment: [
                "LOCAL_AI_ACTIVITY_ACCEPTANCE_CONTAINER": supplied.path,
                "LOCAL_AI_ACTIVITY_ACCEPTANCE_EXPECTATION": "active",
                "LOCAL_AI_ACTIVITY_ACCEPTANCE_NOW": "2026-08-31T14:00:10Z",
            ])
        }
    }
}

@Suite(
    .serialized,
    .enabled(if: CrossAppAcceptanceEnvironment.isRequested)
)
struct LocalAIActivityCrossAppProducerTests {
    // Catches a producer acceptance path that ends the lease instead of leaving one active record for the reader.
    @Test func writeActiveFoundationModelsLease() async throws {
        try await CrossAppAcceptanceProducerFixture().writeActiveFoundationModelsLease()
    }

    // Catches a producer acceptance path that bypasses reporter lifecycle mapping for success.
    @Test func writeEndedSuccessLease() async throws {
        try await CrossAppAcceptanceProducerFixture().writeEndedSuccessLease()
    }

    // Catches a producer acceptance path that records cancellation as failure or success.
    @Test func writeEndedCancelledLease() async throws {
        try await CrossAppAcceptanceProducerFixture().writeEndedCancelledLease()
    }

    // Catches a producer acceptance path that records a model failure as success or cancellation.
    @Test func writeEndedFailureLease() async throws {
        try await CrossAppAcceptanceProducerFixture().writeEndedFailureLease()
    }

    // Catches producer-side cleanup that removes the valid expired-recent fixture before the reader can reject it.
    @Test func writeExpiredRecentLease() async throws {
        try await CrossAppAcceptanceProducerFixture().writeExpiredRecentLease()
    }
}

private enum CrossAppAcceptanceEnvironment {
    private static let keys = [
        "LOCAL_AI_ACTIVITY_ACCEPTANCE_CONTAINER",
        "LOCAL_AI_ACTIVITY_ACCEPTANCE_EXPECTATION",
        "LOCAL_AI_ACTIVITY_ACCEPTANCE_NOW",
    ]

    static var isRequested: Bool {
        keys.contains { ProcessInfo.processInfo.environment[$0] != nil }
    }
}

private struct CrossAppAcceptanceProducerFixture {
    private let containerURL: URL
    private let acceptanceNow: Date
    private let acceptanceExpectation: CrossAppAcceptanceExpectation

    init() throws {
        try self.init(environment: ProcessInfo.processInfo.environment)
    }

    init(environment: [String: String]) throws {
        guard let container = environment["LOCAL_AI_ACTIVITY_ACCEPTANCE_CONTAINER"],
              !container.isEmpty,
              let expectation = environment["LOCAL_AI_ACTIVITY_ACCEPTANCE_EXPECTATION"],
              !expectation.isEmpty,
              let nowValue = environment["LOCAL_AI_ACTIVITY_ACCEPTANCE_NOW"],
              !nowValue.isEmpty
        else {
            throw CrossAppAcceptanceFixtureError.missingEnvironment
        }
        guard let parsedExpectation = CrossAppAcceptanceExpectation(rawValue: expectation) else {
            throw CrossAppAcceptanceFixtureError.invalidExpectation
        }

        let formatter = ISO8601DateFormatter()
        guard let now = formatter.date(from: nowValue),
              now.timeIntervalSince1970.rounded() == now.timeIntervalSince1970
        else {
            throw CrossAppAcceptanceFixtureError.invalidClock
        }

        let fileManager = FileManager.default
        let suppliedCandidate = URL(fileURLWithPath: container, isDirectory: true)
            .standardizedFileURL
        var suppliedStatus = stat()
        guard lstat(suppliedCandidate.path, &suppliedStatus) == 0 else {
            throw CrossAppAcceptanceFixtureError.invalidContainer
        }
        guard suppliedStatus.st_mode & S_IFMT != S_IFLNK else {
            throw CrossAppAcceptanceFixtureError.invalidContainer
        }
        let candidate = suppliedCandidate
            .resolvingSymlinksInPath()
        let temporaryRoot = fileManager.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let temporaryPrefix = temporaryRoot.path.hasSuffix("/")
            ? temporaryRoot.path
            : temporaryRoot.path + "/"
        guard candidate.path.hasPrefix(temporaryPrefix), candidate != temporaryRoot else {
            throw CrossAppAcceptanceFixtureError.nonTemporaryContainer
        }
        let resourceValues = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard resourceValues.isDirectory == true, resourceValues.isSymbolicLink != true else {
            throw CrossAppAcceptanceFixtureError.invalidContainer
        }
        guard try fileManager.contentsOfDirectory(atPath: candidate.path).isEmpty else {
            throw CrossAppAcceptanceFixtureError.nonemptyContainer
        }

        containerURL = candidate
        acceptanceNow = now
        acceptanceExpectation = parsedExpectation
    }

    func writeActiveFoundationModelsLease() async throws {
        try requireExpectation(.active)
        let ledger = makeLedger(at: acceptanceNow)
        _ = try await ledger.begin(.foundationModels(role: .studio, task: .summarize))
        try requireSingleRecord(in: .active, state: .active, outcome: nil)
    }

    func writeEndedSuccessLease() async throws {
        try requireExpectation(.recentSuccess)
        let reporter = makeReporter(at: acceptanceNow)
        let _: Void = try await reporter.withActivity(
            .foundationModels(role: .studio, task: .summarize)
        ) {}
        try requireSingleRecord(in: .recent, state: .ended, outcome: .success)
    }

    func writeEndedCancelledLease() async throws {
        try requireExpectation(.recentCancelled)
        let reporter = makeReporter(at: acceptanceNow)
        do {
            let _: Void = try await reporter.withActivity(
                .foundationModels(role: .studio, task: .summarize)
            ) {
                throw CancellationError()
            }
            throw CrossAppAcceptanceFixtureError.operationDidNotThrow
        } catch is CancellationError {
            // The reporter must preserve the operation's cancellation while recording a generic outcome.
        }
        try requireSingleRecord(in: .recent, state: .ended, outcome: .cancelled)
    }

    func writeEndedFailureLease() async throws {
        try requireExpectation(.recentFailure)
        let reporter = makeReporter(at: acceptanceNow)
        do {
            let _: Void = try await reporter.withActivity(
                .foundationModels(role: .studio, task: .summarize)
            ) {
                throw CrossAppAcceptanceOperationError.syntheticFailure
            }
            throw CrossAppAcceptanceFixtureError.operationDidNotThrow
        } catch CrossAppAcceptanceOperationError.syntheticFailure {
            // The reporter must preserve the operation's failure while recording a generic outcome.
        }
        try requireSingleRecord(in: .recent, state: .ended, outcome: .failure)
    }

    func writeExpiredRecentLease() async throws {
        try requireExpectation(.expiredRecent)
        let endedAt = acceptanceNow.addingTimeInterval(-86_401)
        let reporter = makeReporter(at: endedAt)
        let _: Void = try await reporter.withActivity(
            .foundationModels(role: .studio, task: .summarize)
        ) {}
        let record = try requireSingleRecord(
            in: .recent,
            state: .ended,
            outcome: .success
        )
        guard record.expiresAt < acceptanceNow else {
            throw CrossAppAcceptanceFixtureError.recordMismatch
        }
    }

    private func makeLedger(at date: Date) -> LocalAIActivityLedger {
        LocalAIActivityLedger(
            containerURL: containerURL,
            clock: CrossAppAcceptanceClock(now: date)
        )
    }

    private func makeReporter(at date: Date) -> LocalAIActivityReporter {
        let clock = CrossAppAcceptanceClock(now: date)
        return LocalAIActivityReporter(
            ledger: LocalAIActivityLedger(containerURL: containerURL, clock: clock),
            clock: clock
        )
    }

    private func requireExpectation(_ expected: CrossAppAcceptanceExpectation) throws {
        guard acceptanceExpectation == expected else {
            throw CrossAppAcceptanceFixtureError.invalidExpectation
        }
    }

    @discardableResult
    private func requireSingleRecord(
        in directory: LocalAILedgerDirectory,
        state: LocalAIActivityState,
        outcome: LocalAIActivityOutcome?
    ) throws -> LocalAIActivityRecord {
        let ledgerURL = containerURL
            .appending(path: "LocalAIActivity/v1/\(directory.rawValue)", directoryHint: .isDirectory)
        let recordURLs = try FileManager.default.contentsOfDirectory(
            at: ledgerURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        guard recordURLs.count == 1 else {
            throw CrossAppAcceptanceFixtureError.recordMismatch
        }
        let record = try LocalAIActivityContract.decode(Data(contentsOf: recordURLs[0]))
        guard record.state == state,
              record.outcome == outcome,
              record.producerID == LocalAIActivityContract.localOCRProducerID,
              record.producerRole == .studio,
              record.platform == .macos,
              record.runtimeFamily == .foundationModels,
              record.runtimeIdentifier == LocalAIActivityContract.foundationModelsIdentifier,
              record.route == .onDevice,
              record.operation == .generation,
              record.productTask == .summarize,
              record.evidence == .participatingAppReported
        else {
            throw CrossAppAcceptanceFixtureError.recordMismatch
        }
        return record
    }
}

private struct CrossAppAcceptanceClock: LocalAIActivityClock {
    let nowValue: Date

    init(now: Date) {
        nowValue = now
    }

    func now() -> Date { nowValue }

    func sleep(for duration: Duration) async throws {
        _ = duration
        try await Task.sleep(for: .seconds(3_600))
    }
}

private enum CrossAppAcceptanceExpectation: String {
    case active
    case recentSuccess = "recent_success"
    case recentCancelled = "recent_cancelled"
    case recentFailure = "recent_failure"
    case expiredRecent = "expired_recent"
}

private enum CrossAppAcceptanceOperationError: Error {
    case syntheticFailure
}

private enum CrossAppAcceptanceFixtureError: Error {
    case missingEnvironment
    case invalidExpectation
    case invalidClock
    case nonTemporaryContainer
    case invalidContainer
    case nonemptyContainer
    case operationDidNotThrow
    case recordMismatch
}

actor Task4RecordingActivityReporter: LocalAIActivityReporting {
    private(set) var descriptors: [LocalAIActivityDescriptor] = []

    func withActivity<T: Sendable>(
        _ descriptor: LocalAIActivityDescriptor,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        descriptors.append(descriptor)
        return try await operation()
    }
}

func task4LocalRuntimeDescriptor(
    role: LocalAIProducerRole,
    platform: LocalAIPlatform = .macos,
    task: LocalAIProductTask
) -> LocalAIActivityDescriptor {
    LocalAIActivityDescriptor(
        producerID: LocalAIActivityContract.localOCRProducerID,
        producerRole: role,
        platform: platform,
        runtimeFamily: .localRuntime,
        runtimeIdentifier: nil,
        route: .onDeviceLoopback,
        operation: .generation,
        productTask: task
    )
}

private enum Task4OwnedModelError: Error {
    case exact
}

private enum Task4ReporterWriteError: Error {
    case unavailable
}

private actor Task4ThrowingActivityLedger: LocalAIActivityLedgerWriting {
    func begin(_ descriptor: LocalAIActivityDescriptor) async throws -> UUID {
        _ = descriptor
        throw Task4ReporterWriteError.unavailable
    }

    func heartbeat(_ activityID: UUID) async throws { _ = activityID }
    func end(_ activityID: UUID, outcome: LocalAIActivityOutcome) async throws {
        _ = activityID
        _ = outcome
    }
    func cleanupExpired() async {}
}

private struct Task4IdleActivityClock: LocalAIActivityClock {
    func now() -> Date { task6Now }
    func sleep(for duration: Duration) async throws { _ = duration }
}
