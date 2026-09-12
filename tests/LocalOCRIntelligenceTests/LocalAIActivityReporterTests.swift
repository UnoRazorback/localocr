import Foundation
@testable import LocalOCRIntelligence
import Testing

@Suite struct LocalAIActivityReporterTests {
    private let activityID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

    // Catches a reporter that returns before ending a successful owned operation or records lifecycle calls out of order.
    @Test func successfulOperationReturnsExactValueAfterOrderedBeginAndEnd() async throws {
        let ledger = ReporterSpyLedger(activityID: activityID)
        let reporter = LocalAIActivityReporter(ledger: ledger, clock: ImmediateReporterClock())

        let value: String = try await reporter.withActivity(
            .foundationModels(role: .mcp, task: .extract)
        ) {
            "model-result"
        }

        #expect(value == "model-result")
        #expect(await ledger.calls == [
            .begin(.foundationModels(role: .mcp, task: .extract)),
            .end(activityID, .success)
        ])
    }

    // Catches a reporter that transforms CancellationError or records cancellation as a detailed/non-generic failure.
    @Test func cancellationRethrowsCancellationAndEndsWithGenericCancelledOutcome() async {
        let ledger = ReporterSpyLedger(activityID: activityID)
        let reporter = LocalAIActivityReporter(ledger: ledger, clock: ImmediateReporterClock())

        await #expect(throws: CancellationError.self) {
            try await reporter.withActivity(.foundationModels(role: .studio, task: .organize)) {
                throw CancellationError()
            }
        }

        #expect(await ledger.calls == [
            .begin(.foundationModels(role: .studio, task: .organize)),
            .end(activityID, .cancelled)
        ])
    }

    // Catches a reporter that changes an owned model error or writes anything more specific than generic failure.
    @Test func nonCancellationRethrowsExactErrorAndEndsWithGenericFailureOutcome() async {
        let ledger = ReporterSpyLedger(activityID: activityID)
        let reporter = LocalAIActivityReporter(ledger: ledger, clock: ImmediateReporterClock())

        await #expect(throws: ReporterTestError.modelFailure) {
            try await reporter.withActivity(.foundationModels(role: .cli, task: .summarize)) {
                throw ReporterTestError.modelFailure
            }
        }

        #expect(await ledger.calls == [
            .begin(.foundationModels(role: .cli, task: .summarize)),
            .end(activityID, .failure)
        ])
    }

    // Catches a heartbeat loop using the wrong 15-second cadence, missing the 30-second renewal, or surviving operation completion.
    @Test func thirtyOneSecondOperationHeartbeatsAtFifteenAndThirtySecondsThenCleansUpTask() async throws {
        let ledger = ReporterSpyLedger(activityID: activityID)
        let clock = ControllableReporterClock()
        let operationGate = ReporterAsyncGate()
        let reporter = LocalAIActivityReporter(ledger: ledger, clock: clock)
        let task = Task {
            try await reporter.withActivity(.foundationModels(role: .iosApp, platform: .ios, task: .extract)) {
                await operationGate.wait()
                return 31
            }
        }

        #expect(await waitUntil { clock.pendingSleepCount == 1 })
        clock.advance(by: .seconds(15))
        #expect(await waitUntil { await ledger.heartbeatCount == 1 && clock.pendingSleepCount == 1 })
        clock.advance(by: .seconds(15))
        #expect(await waitUntil { await ledger.heartbeatCount == 2 && clock.pendingSleepCount == 1 })
        clock.advance(by: .seconds(1))
        await operationGate.open()

        #expect(try await task.value == 31)
        #expect(clock.requestedSleeps == [.seconds(15), .seconds(15), .seconds(15)])
        #expect(clock.cancelledSleepCount == 1)
        #expect(clock.pendingSleepCount == 0)
        #expect(await ledger.calls == [
            .begin(.foundationModels(role: .iosApp, platform: .ios, task: .extract)),
            .heartbeat(activityID),
            .heartbeat(activityID),
            .end(activityID, .success)
        ])
    }

    // Catches a begin failure that prevents the owned operation from running or alters its successful value.
    @Test func beginFailureNeverBlocksOwnedModelOperation() async throws {
        let ledger = ReporterSpyLedger(activityID: activityID, failures: [.begin])
        let reporter = LocalAIActivityReporter(ledger: ledger, clock: ImmediateReporterClock())

        let value: String = try await reporter.withActivity(
            .foundationModels(role: .mcp, task: .extract)
        ) {
            "model-result"
        }

        #expect(value == "model-result")
        #expect(await ledger.calls == [.begin(.foundationModels(role: .mcp, task: .extract))])
    }

    // Catches a heartbeat or end write failure that replaces the owned operation's successful value.
    @Test func heartbeatAndEndFailuresNeverReplaceOwnedModelValue() async throws {
        let ledger = ReporterSpyLedger(activityID: activityID, failures: [.heartbeat, .end])
        let clock = ControllableReporterClock()
        let operationGate = ReporterAsyncGate()
        let reporter = LocalAIActivityReporter(ledger: ledger, clock: clock)
        let task = Task {
            try await reporter.withActivity(.foundationModels(role: .studio, task: .organize)) {
                await operationGate.wait()
                return "unchanged"
            }
        }

        #expect(await waitUntil { clock.pendingSleepCount == 1 })
        clock.advance(by: .seconds(15))
        #expect(await waitUntil { await ledger.heartbeatCount == 1 && clock.pendingSleepCount == 1 })
        await operationGate.open()

        #expect(try await task.value == "unchanged")
        #expect(clock.cancelledSleepCount == 1)
        #expect(await ledger.calls == [
            .begin(.foundationModels(role: .studio, task: .organize)),
            .heartbeat(activityID),
            .end(activityID, .success)
        ])
    }

    // Catches an end write failure that masks or transforms the owned operation's original error.
    @Test func endFailureNeverReplacesOwnedModelError() async {
        let ledger = ReporterSpyLedger(activityID: activityID, failures: [.end])
        let reporter = LocalAIActivityReporter(ledger: ledger, clock: ImmediateReporterClock())

        await #expect(throws: ReporterTestError.modelFailure) {
            try await reporter.withActivity(.foundationModels(role: .studio, task: .summarize)) {
                throw ReporterTestError.modelFailure
            }
        }

        #expect(await ledger.calls == [
            .begin(.foundationModels(role: .studio, task: .summarize)),
            .end(activityID, .failure)
        ])
    }

    // Catches a disabled reporter that starts lifecycle side effects or changes the owned operation's result.
    @Test func disabledReporterCallsOwnedOperationDirectly() async throws {
        let reporter = DisabledLocalAIActivityReporter()
        let value: String = try await reporter.withActivity(
            .foundationModels(role: .studio, task: .summarize)
        ) {
            "direct-result"
        }

        #expect(value == "direct-result")
    }

    // Catches a default that silently opts applications into cross-process wake signaling.
    @Test func defaultReporterUsesNoWakeHintOnEveryPlatform() async {
        let ledger = ReporterSpyLedger(activityID: activityID)
        let reporter = LocalAIActivityReporter(ledger: ledger, clock: ImmediateReporterClock())

        #expect(await reporter.wakeHint is NoLocalAIActivityWakeHint)
    }
}

private enum ReporterTestError: Error {
    case modelFailure
    case ledgerFailure
}

private enum ReporterLedgerFailurePoint: Hashable {
    case begin
    case heartbeat
    case end
}

private enum ReporterLedgerCall: Sendable, Equatable {
    case begin(LocalAIActivityDescriptor)
    case heartbeat(UUID)
    case end(UUID, LocalAIActivityOutcome)
}

private actor ReporterSpyLedger: LocalAIActivityLedgerWriting {
    let activityID: UUID
    let failures: Set<ReporterLedgerFailurePoint>
    private(set) var calls: [ReporterLedgerCall] = []

    init(activityID: UUID, failures: Set<ReporterLedgerFailurePoint> = []) {
        self.activityID = activityID
        self.failures = failures
    }

    var heartbeatCount: Int {
        calls.reduce(into: 0) { count, call in
            if case .heartbeat = call { count += 1 }
        }
    }

    func begin(_ descriptor: LocalAIActivityDescriptor) async throws -> UUID {
        calls.append(.begin(descriptor))
        if failures.contains(.begin) { throw ReporterTestError.ledgerFailure }
        return activityID
    }

    func heartbeat(_ activityID: UUID) async throws {
        calls.append(.heartbeat(activityID))
        if failures.contains(.heartbeat) { throw ReporterTestError.ledgerFailure }
    }

    func end(_ activityID: UUID, outcome: LocalAIActivityOutcome) async throws {
        calls.append(.end(activityID, outcome))
        if failures.contains(.end) { throw ReporterTestError.ledgerFailure }
    }

    func cleanupExpired() async {}
}

private struct ImmediateReporterClock: LocalAIActivityClock {
    func now() -> Date { Date(timeIntervalSince1970: 0) }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .seconds(60))
    }
}

private final class ControllableReporterClock: LocalAIActivityClock, @unchecked Sendable {
    private struct Sleeper {
        let id: UUID
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var elapsed: Duration = .zero
    private var sleepers: [Sleeper] = []
    private var requests: [Duration] = []
    private var cancellations = 0

    var pendingSleepCount: Int { lock.withLock { sleepers.count } }
    var requestedSleeps: [Duration] { lock.withLock { requests } }
    var cancelledSleepCount: Int { lock.withLock { cancellations } }

    func now() -> Date {
        lock.withLock { Date(timeIntervalSince1970: durationSeconds(elapsed)) }
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate = lock.withLock { () -> Bool in
                    requests.append(duration)
                    guard !Task.isCancelled else { return true }
                    sleepers.append(Sleeper(id: id, deadline: elapsed + duration, continuation: continuation))
                    return false
                }
                if immediate { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = self.lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                guard let index = self.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                self.cancellations += 1
                return self.sleepers.remove(at: index).continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            elapsed += duration
            let ready = sleepers.filter { $0.deadline <= elapsed }
            sleepers.removeAll { $0.deadline <= elapsed }
            return ready.map(\.continuation)
        }
        ready.forEach { $0.resume() }
    }
}

private actor ReporterAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<10_000 {
        if await predicate() { return true }
        await Task.yield()
    }
    return false
}

private func durationSeconds(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
}
