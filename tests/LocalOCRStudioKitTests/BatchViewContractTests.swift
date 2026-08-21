import Foundation
@_spi(Testing) @testable import LocalOCRStudioKit
import Observation
import Testing

@Suite struct BatchViewContractTests {
    @Test @MainActor func coordinatorItemStateChangesNotifyObservationConsumers() async {
        let candidate = observedCandidate()
        let discovery = StudioBatchDiscovery(
            candidates: [candidate],
            skipped: [],
            duplicateCount: 0,
            selectedFolderRoots: []
        )
        let executor = ObservedSuspendingExecutor()
        let coordinator = StudioBatchCoordinator(
            enumerator: ObservedEnumerator(discovery: discovery),
            planner: ObservedPlanner(),
            executor: executor
        )
        coordinator.addSelections([candidate.sourceURL])
        await coordinator.waitUntilPreparationIdleForTesting()
        coordinator.chooseOutputRoot(URL(fileURLWithPath: "/tmp/observed-output"))
        await coordinator.waitUntilPreparationIdleForTesting()
        #expect(coordinator.canStart)

        let recorder = ObservationChangeRecorder()
        withObservationTracking {
            _ = coordinator.items
        } onChange: {
            recorder.recordChange()
        }

        coordinator.start()
        await executor.waitUntilStarted()

        #expect(recorder.changeCount > 0)
        coordinator.cancel()
        await coordinator.waitUntilIdleForTesting()
    }

    @Test @MainActor func mixedDropResolvesOnceInProviderOrder() {
        var accumulator = BatchDropAccumulator()
        let generation = accumulator.begin(expectedCount: 3)
        let first = URL(fileURLWithPath: "/tmp/first.pdf")
        let third = URL(fileURLWithPath: "/tmp/third.png")

        #expect(accumulator.resolve(third, at: 2, generation: generation) == nil)
        #expect(accumulator.resolve(nil, at: 1, generation: generation) == nil)
        #expect(
            accumulator.resolve(first, at: 0, generation: generation)
                == [first, third]
        )
        #expect(accumulator.resolve(first, at: 0, generation: generation) == nil)
    }

    @Test @MainActor func staleDropGenerationCannotJoinTheCurrentSelection() {
        var accumulator = BatchDropAccumulator()
        let staleGeneration = accumulator.begin(expectedCount: 1)
        let currentGeneration = accumulator.begin(expectedCount: 1)
        let staleURL = URL(fileURLWithPath: "/tmp/stale.pdf")
        let currentURL = URL(fileURLWithPath: "/tmp/current.pdf")

        #expect(
            accumulator.resolve(staleURL, at: 0, generation: staleGeneration)
                == nil
        )
        #expect(
            accumulator.resolve(currentURL, at: 0, generation: currentGeneration)
                == [currentURL]
        )
    }

    @Test func diagnosticsIncludeOperationalStateWithoutIssueDetails() {
        let candidate = StudioBatchCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sourceURL: URL(fileURLWithPath: "/Users/tester/Documents/invoice.pdf"),
            standardizedSourceURL: URL(fileURLWithPath: "/Users/tester/Documents/invoice.pdf"),
            kind: .pdf,
            relativePath: "invoice.pdf",
            outputGroupName: nil
        )
        let issue = StudioBatchIssue(
            title: "Couldn’t Process Document",
            message: "The document could not be processed.",
            details: "SECRET OCR TEXT cache-key=abc environment=private"
        )
        let outputRoot = URL(fileURLWithPath: "/Users/tester/Output")
        let item = StudioBatchItem(
            id: candidate.id,
            candidate: candidate,
            reservation: StudioBatchReservation(
                finalURL: outputRoot.appendingPathComponent("invoice_searchable.pdf"),
                outputRoot: outputRoot
            ),
            state: .failed(issue)
        )

        let diagnostics = BatchDiagnostics.make(
            version: "0.3.0-beta.1",
            build: "2",
            phase: .complete,
            discovery: StudioBatchDiscovery(
                candidates: [candidate],
                skipped: [],
                duplicateCount: 0,
                selectedFolderRoots: []
            ),
            items: [item]
        )

        #expect(diagnostics.contains("LocalOCR Studio 0.3.0-beta.1 (2)"))
        #expect(diagnostics.contains("Phase: complete"))
        #expect(diagnostics.contains("Failed: 1"))
        #expect(diagnostics.contains("State: failed"))
        #expect(diagnostics.contains("Category: Couldn’t Process Document"))
        #expect(diagnostics.contains("Message: The document could not be processed."))
        #expect(diagnostics.contains("Source: /Users/tester/Documents/invoice.pdf"))
        #expect(!diagnostics.contains("SECRET OCR TEXT"))
        #expect(!diagnostics.contains("cache-key"))
        #expect(!diagnostics.contains("environment=private"))
    }

    @Test func emptyBatchInvitesInputAndAllowsReturningToSingleDocumentMode() {
        let contract = BatchViewContract(
            phase: .empty,
            acceptedCount: 0,
            skippedCount: 0,
            hasOutputRoot: false
        )

        #expect(contract.primaryTitle == "Prepare Batch")
        #expect(contract.summaryText == "Add files or folders to begin")
        #expect(contract.canAddInputs)
        #expect(contract.canChooseOutput)
        #expect(!contract.canStart)
        #expect(!contract.canCancel)
        #expect(!contract.canRetryFailed)
        #expect(!contract.canRevealOutput)
        #expect(!contract.canCopyDiagnostics)
        #expect(!contract.canStartNewBatch)
        #expect(contract.canReturnToSingle)
    }

    @Test func reviewRequiresOutputBeforeStart() {
        let contract = BatchViewContract(
            phase: .reviewing,
            acceptedCount: 3,
            skippedCount: 1,
            hasOutputRoot: false
        )

        #expect(contract.primaryTitle == "Review Batch")
        #expect(contract.canStart == false)
        #expect(contract.summaryText == "3 supported • 1 skipped")
    }

    @Test func reviewWithOutputEnablesExplicitStartAndReportsDuplicates() {
        let contract = BatchViewContract(
            phase: .reviewing,
            acceptedCount: 2,
            skippedCount: 0,
            duplicateCount: 1,
            hasOutputRoot: true
        )

        #expect(contract.summaryText == "2 supported • 0 skipped • 1 duplicate")
        #expect(contract.canAddInputs)
        #expect(contract.canChooseOutput)
        #expect(contract.canStart)
        #expect(contract.canCopyDiagnostics)
        #expect(contract.canReturnToSingle)
    }

    @Test func processingOffersOnlyCancellationAndDiagnostics() {
        let contract = BatchViewContract(
            phase: .processing,
            acceptedCount: 3,
            skippedCount: 1,
            completedCount: 1,
            failedCount: 0,
            cancelledCount: 0,
            hasOutputRoot: true
        )

        #expect(contract.primaryTitle == "Processing Batch")
        #expect(contract.summaryText == "1 of 3 completed • 1 skipped")
        #expect(!contract.canAddInputs)
        #expect(!contract.canChooseOutput)
        #expect(!contract.canStart)
        #expect(contract.canCancel)
        #expect(contract.canCopyDiagnostics)
        #expect(!contract.canReturnToSingle)
    }

    @Test func completionReportsEveryTerminalCountAndEnablesRecovery() {
        let contract = BatchViewContract(
            phase: .complete,
            acceptedCount: 4,
            skippedCount: 2,
            completedCount: 2,
            failedCount: 1,
            cancelledCount: 1,
            hasOutputRoot: true
        )

        #expect(contract.primaryTitle == "Batch Complete")
        #expect(
            contract.summaryText
                == "2 completed • 1 failed • 2 skipped • 1 cancelled"
        )
        #expect(!contract.canCancel)
        #expect(contract.canRetryFailed)
        #expect(contract.canRevealOutput)
        #expect(contract.canCopyDiagnostics)
        #expect(contract.canStartNewBatch)
        #expect(contract.canReturnToSingle)
    }

    @Test func completionWithoutFailuresOrOutputDisablesUnavailableActions() {
        let contract = BatchViewContract(
            phase: .complete,
            acceptedCount: 2,
            skippedCount: 0,
            completedCount: 2,
            failedCount: 0,
            cancelledCount: 0,
            hasOutputRoot: false
        )

        #expect(!contract.canRetryFailed)
        #expect(!contract.canRevealOutput)
        #expect(contract.canStartNewBatch)
    }
}

private final class ObservationChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var changes = 0

    var changeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return changes
    }

    func recordChange() {
        lock.lock()
        changes += 1
        lock.unlock()
    }
}

private actor ObservedEnumerator: StudioBatchInputEnumerating {
    let discovery: StudioBatchDiscovery

    init(discovery: StudioBatchDiscovery) {
        self.discovery = discovery
    }

    func discover(selections _: [URL]) async -> StudioBatchDiscovery {
        discovery
    }
}

private actor ObservedPlanner: StudioBatchOutputPlanning {
    func makePlan(
        discovery: StudioBatchDiscovery,
        outputRoot: URL
    ) async throws -> StudioBatchPlan {
        StudioBatchPlan(
            outputRoot: outputRoot,
            items: discovery.candidates.map { candidate in
                StudioBatchItem(
                    id: candidate.id,
                    candidate: candidate,
                    reservation: StudioBatchReservation(
                        finalURL: outputRoot.appendingPathComponent("observed.pdf"),
                        outputRoot: outputRoot
                    ),
                    state: .queued
                )
            },
            skipped: discovery.skipped,
            duplicateCount: discovery.duplicateCount
        )
    }

    func refreshReservation(
        for item: StudioBatchItem,
        outputRoot _: URL
    ) async throws -> StudioBatchReservation {
        item.reservation
    }
}

private actor ObservedSuspendingExecutor: StudioBatchItemExecuting {
    private var hasStarted = false

    func execute(
        _ item: StudioBatchItem,
        progress _: @escaping @Sendable (StudioProgress) -> Void
    ) async throws -> URL {
        hasStarted = true
        while !Task.isCancelled {
            await Task.yield()
        }
        throw CancellationError()
    }

    func waitUntilStarted() async {
        while !hasStarted {
            await Task.yield()
        }
    }
}

private func observedCandidate() -> StudioBatchCandidate {
    let sourceURL = URL(fileURLWithPath: "/tmp/observed.pdf")
    return StudioBatchCandidate(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
        sourceURL: sourceURL,
        standardizedSourceURL: sourceURL,
        kind: .pdf,
        relativePath: "observed.pdf",
        outputGroupName: nil
    )
}
