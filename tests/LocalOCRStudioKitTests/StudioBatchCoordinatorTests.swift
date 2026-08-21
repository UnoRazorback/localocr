import Foundation
import LocalOCRCore
@_spi(Testing) @testable import LocalOCRStudioKit
import Testing

@Suite struct StudioBatchCoordinatorTests {
    @Test @MainActor func preparesAReviewBeforeStartingAnyExecution() async {
        let enumerator = ImmediateCoordinatorEnumerator()
        let planner = CoordinatorPlanner()
        let executor = ControlledBatchExecutor()
        let coordinator = StudioBatchCoordinator(
            enumerator: enumerator,
            planner: planner,
            executor: executor
        )
        let selections = testURLs("one.pdf", "two.jpg")

        coordinator.addSelections(selections)
        await coordinator.waitUntilIdleForTesting()

        #expect(coordinator.phase == .reviewing)
        #expect(coordinator.discovery?.candidates.count == 2)
        #expect(coordinator.items.isEmpty)
        #expect(!coordinator.canStart)

        coordinator.chooseOutputRoot(testURL("review-output"))
        await coordinator.waitUntilIdleForTesting()

        #expect(coordinator.phase == .reviewing)
        #expect(coordinator.items.count == 2)
        #expect(coordinator.items.allSatisfy { $0.state == .queued })
        #expect(coordinator.canStart)
        #expect(await executor.requestCount() == 0)
    }

    @Test @MainActor func emptyDiscoveryStaysEmptyAndRetainsSkippedReviewInformation() async {
        let skippedURL = testURL("unsupported.txt")
        let enumerator = ImmediateCoordinatorEnumerator(result: StudioBatchDiscovery(
            candidates: [],
            skipped: [StudioBatchSkippedInput(
                id: UUID(),
                sourceURL: skippedURL,
                reason: testIssue("Unsupported File")
            )],
            duplicateCount: 0,
            selectedFolderRoots: []
        ))
        let coordinator = StudioBatchCoordinator(
            enumerator: enumerator,
            planner: CoordinatorPlanner(),
            executor: ControlledBatchExecutor()
        )

        coordinator.addSelections([skippedURL])
        await coordinator.waitUntilIdleForTesting()

        #expect(coordinator.phase == .empty)
        #expect(coordinator.discovery?.skipped.count == 1)
        #expect(coordinator.summary.skipped == 1)
        #expect(coordinator.items.isEmpty)
        #expect(coordinator.actionError == nil)
        #expect(!coordinator.canStart)
    }

    @Test @MainActor func planningFailureLeavesTheDiscoveryReviewableAndPresentsTheError() async {
        let planner = CoordinatorPlanner(planFailure: .expected)
        let coordinator = StudioBatchCoordinator(
            enumerator: ImmediateCoordinatorEnumerator(),
            planner: planner,
            executor: ControlledBatchExecutor()
        )

        coordinator.addSelections([testURL("scan.pdf")])
        await coordinator.waitUntilIdleForTesting()
        coordinator.chooseOutputRoot(testURL("unsafe-output"))
        await coordinator.waitUntilIdleForTesting()

        #expect(coordinator.phase == .reviewing)
        #expect(coordinator.discovery?.candidates.count == 1)
        #expect(coordinator.items.isEmpty)
        #expect(coordinator.outputRoot == testURL("unsafe-output").standardizedFileURL)
        #expect(coordinator.actionError == StudioBatchIssue(
            title: "Couldn’t Process Document",
            message: "The document could not be processed. Please try again.",
            details: "Technical details are hidden to protect your privacy."
        ))
        #expect(!coordinator.canStart)
    }

    @Test @MainActor func lateOverlappingSelectionDiscoveryCannotReplaceTheNewestReview() async {
        let enumerator = ControlledCoordinatorEnumerator()
        let coordinator = StudioBatchCoordinator(
            enumerator: enumerator,
            planner: CoordinatorPlanner(),
            executor: ControlledBatchExecutor()
        )
        let first = testURL("first.pdf")
        let second = testURL("second.pdf")

        coordinator.addSelections([first])
        await enumerator.waitForRequestCount(1)
        coordinator.addSelections([second])
        #expect(await enumerator.requestCount() == 1)

        await enumerator.succeed(0, with: discovery(for: [first]))
        await enumerator.waitForRequestCount(2)
        await enumerator.succeed(1, with: discovery(for: [first, second]))
        await coordinator.waitUntilIdleForTesting()

        #expect(coordinator.phase == .reviewing)
        #expect(coordinator.discovery?.candidates.map(\.sourceURL) == [first, second])
    }

    @Test @MainActor func lateOverlappingOutputPlanCannotReplaceTheNewestOutput() async {
        let planner = ControlledCoordinatorPlanner()
        let coordinator = StudioBatchCoordinator(
            enumerator: ImmediateCoordinatorEnumerator(),
            planner: planner,
            executor: ControlledBatchExecutor()
        )
        let firstRoot = testURL("first-output")
        let secondRoot = testURL("second-output")

        coordinator.addSelections([testURL("scan.pdf")])
        await coordinator.waitUntilIdleForTesting()
        coordinator.chooseOutputRoot(firstRoot)
        await planner.waitForRequestCount(1)
        coordinator.chooseOutputRoot(secondRoot)
        #expect(await planner.requestCount() == 1)

        let firstRequest = await planner.request(at: 0)
        await planner.succeed(0, with: plan(
            discovery: firstRequest.discovery,
            outputRoot: firstRoot
        ))
        await planner.waitForRequestCount(2)
        let secondRequest = await planner.request(at: 1)
        await planner.succeed(1, with: plan(
            discovery: secondRequest.discovery,
            outputRoot: secondRoot
        ))
        await coordinator.waitUntilIdleForTesting()

        #expect(coordinator.outputRoot == secondRoot.standardizedFileURL)
        #expect(coordinator.items.allSatisfy {
            $0.reservation.outputRoot == secondRoot.standardizedFileURL
        })
    }

    @Test @MainActor func preparationChangesCoalesceBehindOneSuspendedPlannerCall() async {
        let enumerator = ImmediateCoordinatorEnumerator()
        let planner = ControlledCoordinatorPlanner()
        let coordinator = StudioBatchCoordinator(
            enumerator: enumerator,
            planner: planner,
            executor: ControlledBatchExecutor()
        )
        let source = testURL("coalesced.pdf")
        let firstRoot = testURL("coalesced-output-0")
        let latestRoot = testURL("coalesced-output-100")

        coordinator.addSelections([source])
        await coordinator.waitUntilIdleForTesting()
        coordinator.chooseOutputRoot(firstRoot)
        await planner.waitForRequestCount(1)

        for index in 1...100 {
            coordinator.chooseOutputRoot(testURL("coalesced-output-\(index)"))
        }

        #expect(coordinator.ownedPreparationTaskCountForTesting == 1)
        #expect(coordinator.pendingPreparationRequestCountForTesting == 1)
        #expect(await enumerator.requestCount() == 2)
        #expect(await planner.requestCount() == 1)

        let firstRequest = await planner.request(at: 0)
        await planner.succeed(0, with: plan(
            discovery: firstRequest.discovery,
            outputRoot: firstRequest.outputRoot
        ))
        await planner.waitForRequestCount(2)

        #expect(await enumerator.requestCount() == 3)
        let latestRequest = await planner.request(at: 1)
        #expect(latestRequest.outputRoot == latestRoot.standardizedFileURL)
        await planner.succeed(1, with: plan(
            discovery: latestRequest.discovery,
            outputRoot: latestRequest.outputRoot
        ))
        await coordinator.waitUntilIdleForTesting()

        #expect(coordinator.ownedPreparationTaskCountForTesting == 0)
        #expect(coordinator.pendingPreparationRequestCountForTesting == 0)
        #expect(coordinator.outputRoot == latestRoot.standardizedFileURL)
        #expect(coordinator.items.count == 1)
        #expect(coordinator.items[0].reservation.outputRoot == latestRoot.standardizedFileURL)
    }

    @Test @MainActor func stalePlanningCannotReplaceTheRealPlannersActiveClaims() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioBatchCoordinatorPlanning-\(UUID().uuidString)", isDirectory: true)
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        let first = root.appending(path: "input/first.pdf")
        let second = root.appending(path: "input/second.pdf")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: first.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: first)
        try Data().write(to: second)
        defer { try? FileManager.default.removeItem(at: root) }

        let planner = ReorderingRealCoordinatorPlanner()
        let executor = ControlledBatchExecutor()
        let coordinator = StudioBatchCoordinator(
            enumerator: ImmediateCoordinatorEnumerator(),
            planner: planner,
            executor: executor
        )
        coordinator.addSelections([first])
        await coordinator.waitUntilIdleForTesting()
        coordinator.chooseOutputRoot(output)
        await planner.waitForRequestCount(1)

        coordinator.addSelections([second])
        await planner.releaseFirstAfterAnyOverlappingRequest()
        await coordinator.waitUntilIdleForTesting()

        #expect(coordinator.items.count == 2)
        let originalFirstReservation = coordinator.items[0].reservation.finalURL

        coordinator.start()
        await executor.waitForRequestCount(1)
        await executor.fail(0, with: CoordinatorTestError.expected)
        await executor.waitForRequestCount(2)
        await executor.fail(1, with: CoordinatorTestError.expected)
        await coordinator.waitUntilIdleForTesting()

        coordinator.retryFailed()
        await executor.waitForRequestCount(3)

        #expect((await executor.requestedItems())[2].reservation.finalURL == originalFirstReservation)

        await executor.succeed(2)
        await executor.waitForRequestCount(4)
        await executor.succeed(3)
        await coordinator.waitUntilIdleForTesting()
    }

    @Test @MainActor func resetRejectsLateDiscoveryAndPlanningResults() async {
        let enumerator = ControlledCoordinatorEnumerator()
        let discoveryCoordinator = StudioBatchCoordinator(
            enumerator: enumerator,
            planner: CoordinatorPlanner(),
            executor: ControlledBatchExecutor()
        )
        let source = testURL("late.pdf")

        discoveryCoordinator.addSelections([source])
        await enumerator.waitForRequestCount(1)
        discoveryCoordinator.startNewBatch()
        await enumerator.succeed(0, with: discovery(for: [source]))
        await discoveryCoordinator.waitUntilIdleForTesting()

        assertEmptySession(discoveryCoordinator)

        let planner = ControlledCoordinatorPlanner()
        let planningCoordinator = StudioBatchCoordinator(
            enumerator: ImmediateCoordinatorEnumerator(),
            planner: planner,
            executor: ControlledBatchExecutor()
        )
        planningCoordinator.addSelections([source])
        await planningCoordinator.waitUntilIdleForTesting()
        planningCoordinator.chooseOutputRoot(testURL("late-output"))
        await planner.waitForRequestCount(1)
        let request = await planner.request(at: 0)
        planningCoordinator.addSelections([testURL("discarded-pending.pdf")])
        #expect(planningCoordinator.pendingPreparationRequestCountForTesting == 1)
        planningCoordinator.startNewBatch()
        #expect(planningCoordinator.pendingPreparationRequestCountForTesting == 0)
        await planner.succeed(0, with: plan(
            discovery: request.discovery,
            outputRoot: request.outputRoot
        ))
        await planningCoordinator.waitUntilIdleForTesting()

        #expect(await planner.requestCount() == 1)
        assertEmptySession(planningCoordinator)
    }

    @Test @MainActor func processingRejectsSelectionAndOutputChanges() async {
        let enumerator = ImmediateCoordinatorEnumerator()
        let planner = CoordinatorPlanner()
        let executor = ControlledBatchExecutor()
        let coordinator = await readyCoordinator(
            itemNames: ["one.pdf"],
            enumerator: enumerator,
            planner: planner,
            executor: executor
        )
        let originalRoot = coordinator.outputRoot
        let enumerationCount = await enumerator.requestCount()
        let planningCount = await planner.planRequestCount()

        coordinator.start()
        await executor.waitForRequestCount(1)
        coordinator.addSelections([testURL("ignored.pdf")])
        coordinator.chooseOutputRoot(testURL("ignored-output"))

        #expect(coordinator.phase == .processing)
        #expect(coordinator.items.count == 1)
        #expect(coordinator.outputRoot == originalRoot)
        #expect(await enumerator.requestCount() == enumerationCount)
        #expect(await planner.planRequestCount() == planningCount)

        await executor.succeed(0)
        await coordinator.waitUntilIdleForTesting()
    }

    @Test @MainActor func processingNeverExceedsOneActiveItem() async {
        let executor = ControlledBatchExecutor()
        let coordinator = await readyCoordinator(
            itemNames: ["one.pdf", "two.pdf", "three.pdf"],
            executor: executor
        )

        coordinator.start()
        await executor.completeAllInOrder(expectedCount: 3)
        await coordinator.waitUntilIdleForTesting()

        #expect(await executor.maximumActiveCount() == 1)
        #expect(await executor.requestCount() == 3)
        #expect(coordinator.phase == .complete)
        #expect(coordinator.summary.completed == 3)
    }

    @Test @MainActor func progressTargetsOnlyItsRowAndProcessingContinuesAfterFailure() async {
        let executor = ControlledBatchExecutor()
        let coordinator = await readyCoordinator(
            itemNames: ["one.pdf", "two.pdf"],
            executor: executor
        )

        coordinator.start()
        await executor.waitForRequestCount(1)
        await executor.sendProgress(.recognizing(page: 1, total: 4), for: 0)
        await coordinator.waitUntilProgressDeliveredForTesting()

        #expect(coordinator.items[0].state == .processing(.recognizing(page: 1, total: 4)))
        #expect(coordinator.items[1].state == .queued)

        await executor.fail(0, with: LocalOCRError.fileNotFound)
        await executor.waitForRequestCount(2)

        #expect(coordinator.items[0].state == .failed(StudioBatchIssue(
            title: "File Not Found",
            message: "The selected document is no longer available.",
            details: nil
        )))
        #expect(coordinator.items[1].state == .processing(.inspecting))

        await executor.sendProgress(.assembling, for: 0)
        await executor.sendProgress(.recognizing(page: 2, total: 2), for: 1)
        await coordinator.waitUntilProgressDeliveredForTesting()

        #expect(coordinator.items[0].state.isRetryable)
        #expect(coordinator.items[1].state == .processing(.recognizing(page: 2, total: 2)))

        await executor.succeed(1)
        await coordinator.waitUntilIdleForTesting()

        #expect(coordinator.phase == .complete)
        #expect(coordinator.summary.failed == 1)
        #expect(coordinator.summary.completed == 1)
    }

    @Test @MainActor func sameItemProgressIsDeliveredInCallbackOrder() async {
        let executor = ControlledBatchExecutor()
        let coordinator = await readyCoordinator(
            itemNames: ["ordered.pdf"],
            executor: executor
        )

        coordinator.start()
        await executor.waitForRequestCount(1)
        await executor.sendProgress(
            [
                .recognizing(page: 1, total: 3),
                .assembling,
            ],
            for: 0
        )
        await coordinator.waitUntilProgressDeliveredForTesting()

        #expect(coordinator.items[0].state == .processing(.assembling))

        await executor.succeed(0)
        await coordinator.waitUntilIdleForTesting()
        #expect(coordinator.summary.completed == 1)
    }

    @Test @MainActor func cancellingBeforeTheFirstExecutorAwaitCancelsEveryQueuedItem() async {
        let executor = ControlledBatchExecutor()
        let coordinator = await readyCoordinator(
            itemNames: ["one.pdf", "two.pdf"],
            executor: executor
        )

        coordinator.start()
        coordinator.cancel()
        await coordinator.waitUntilIdleForTesting()

        #expect(await executor.requestCount() == 0)
        #expect(coordinator.phase == .complete)
        #expect(coordinator.items.allSatisfy { $0.state == .cancelled })
        #expect(coordinator.summary.cancelled == 2)
        #expect(coordinator.summary.failed == 0)
    }

    @Test @MainActor func executorCancellationCancelsTheActiveAndRemainingItemsWithoutFailure() async {
        let executor = ControlledBatchExecutor()
        let coordinator = await readyCoordinator(
            itemNames: ["one.pdf", "two.pdf", "three.pdf"],
            executor: executor
        )

        coordinator.start()
        await executor.waitForRequestCount(1)
        await executor.fail(0, with: LocalOCRError.cancelled)
        await coordinator.waitUntilIdleForTesting()

        #expect(coordinator.phase == .complete)
        #expect(coordinator.items.allSatisfy { $0.state == .cancelled })
        #expect(coordinator.summary.cancelled == 3)
        #expect(coordinator.summary.failed == 0)
        #expect(coordinator.actionError == nil)
    }

    @Test @MainActor func rawCancellationErrorIsNeverPresentedAsAnItemFailure() async {
        let executor = ControlledBatchExecutor()
        let coordinator = await readyCoordinator(
            itemNames: ["one.pdf"],
            executor: executor
        )

        coordinator.start()
        await executor.waitForRequestCount(1)
        await executor.fail(0, with: CancellationError())
        await coordinator.waitUntilIdleForTesting()

        #expect(coordinator.phase == .complete)
        #expect(coordinator.items.allSatisfy { $0.state == .cancelled })
        #expect(coordinator.summary.cancelled == 1)
        #expect(coordinator.summary.failed == 0)
        #expect(coordinator.actionError == nil)
    }

    @Test @MainActor func cancellationBetweenItemsPreservesCompletionAndRejectsLateError() async {
        let executor = ControlledBatchExecutor()
        let coordinator = await readyCoordinator(
            itemNames: ["one.pdf", "two.pdf", "three.pdf"],
            executor: executor
        )

        coordinator.start()
        await executor.waitForRequestCount(1)
        await executor.succeed(0)
        await executor.waitForRequestCount(2)

        #expect(coordinator.items[0].state.isTerminal)
        #expect(coordinator.summary.completed == 1)
        #expect(coordinator.items[2].state == .queued)

        coordinator.cancel()
        await executor.sendProgress(.assembling, for: 1)
        await executor.fail(1, with: CoordinatorTestError.expected)
        await coordinator.waitUntilIdleForTesting()

        #expect(coordinator.items[0].state == .completed(
            coordinator.items[0].reservation.finalURL
        ))
        #expect(coordinator.items[1].state == .cancelled)
        #expect(coordinator.items[2].state == .cancelled)
        #expect(coordinator.summary.completed == 1)
        #expect(coordinator.summary.cancelled == 2)
        #expect(coordinator.summary.failed == 0)
    }

    @Test @MainActor func doubleStartCancelAndResetAreIdempotentAgainstALateSuccess() async {
        let executor = ControlledBatchExecutor()
        let coordinator = await readyCoordinator(
            itemNames: ["one.pdf", "two.pdf"],
            executor: executor
        )

        coordinator.start()
        coordinator.start()
        await executor.waitForRequestCount(1)

        #expect(await executor.requestCount() == 1)

        coordinator.cancel()
        coordinator.cancel()
        #expect(coordinator.items.allSatisfy { $0.state == .cancelled })

        coordinator.startNewBatch()
        coordinator.startNewBatch()
        await executor.sendProgress(.recognizing(page: 99, total: 99), for: 0)
        await executor.succeed(0)
        await coordinator.waitUntilIdleForTesting()

        assertEmptySession(coordinator)
        #expect(await executor.requestCount() == 1)
    }

    @Test @MainActor func newBatchDoesNotReuseSelectionsOrOutputFromThePriorSession() async {
        let enumerator = ImmediateCoordinatorEnumerator()
        let coordinator = await readyCoordinator(
            itemNames: ["old.pdf"],
            enumerator: enumerator,
            executor: ControlledBatchExecutor()
        )
        let newSource = testURL("new.pdf")

        coordinator.startNewBatch()
        coordinator.addSelections([newSource])
        await coordinator.waitUntilIdleForTesting()

        #expect(coordinator.phase == .reviewing)
        #expect(coordinator.discovery?.candidates.map(\.sourceURL) == [newSource])
        #expect(coordinator.outputRoot == nil)
        #expect(coordinator.items.isEmpty)
        #expect(!coordinator.canStart)
        #expect(await enumerator.lastRequest() == [newSource])
    }

    @Test @MainActor func replacementBatchWaitsForCancellationIgnoringExecutorToDrain() async {
        let executor = ControlledBatchExecutor()
        let coordinator = await readyCoordinator(
            itemNames: ["old.pdf"],
            executor: executor
        )

        coordinator.start()
        await executor.waitForRequestCount(1)
        coordinator.startNewBatch()
        coordinator.addSelections([testURL("replacement.pdf")])
        coordinator.chooseOutputRoot(testURL("replacement-output"))
        await coordinator.waitUntilPreparationIdleForTesting()

        #expect(coordinator.phase == .reviewing)
        #expect(coordinator.canStart)
        coordinator.start()
        #expect(await executor.requestCount() == 1)
        #expect(await executor.maximumActiveCount() == 1)

        await executor.succeed(0)
        await coordinator.waitUntilIdleForTesting()
        #expect(coordinator.phase == .reviewing)

        coordinator.start()
        await executor.waitForRequestCount(2)
        #expect(await executor.maximumActiveCount() == 1)
        await executor.succeed(1)
        await coordinator.waitUntilIdleForTesting()

        #expect(coordinator.phase == .complete)
        #expect(coordinator.summary.completed == 1)
    }

    @Test @MainActor func coordinatorCanDeallocateWhileCancelledPlanningIgnoresCancellation() async {
        let planner = ControlledCoordinatorPlanner()
        var coordinator: StudioBatchCoordinator? = StudioBatchCoordinator(
            enumerator: ImmediateCoordinatorEnumerator(),
            planner: planner,
            executor: ControlledBatchExecutor()
        )
        coordinator?.addSelections([testURL("planning-retain.pdf")])
        await coordinator?.waitUntilIdleForTesting()
        coordinator?.chooseOutputRoot(testURL("planning-retain-output"))
        await planner.waitForRequestCount(1)
        let request = await planner.request(at: 0)
        weak let weakCoordinator = coordinator

        coordinator?.startNewBatch()
        coordinator = nil

        #expect(weakCoordinator == nil)

        await planner.succeed(0, with: plan(
            discovery: request.discovery,
            outputRoot: request.outputRoot
        ))
    }

    @Test @MainActor func coordinatorCanDeallocateWhileCancelledExecutionIgnoresCancellation() async {
        let executor = ControlledBatchExecutor()
        var coordinator: StudioBatchCoordinator? = await readyCoordinator(
            itemNames: ["execution-retain.pdf"],
            executor: executor
        )
        coordinator?.start()
        await executor.waitForRequestCount(1)
        weak let weakCoordinator = coordinator

        coordinator?.startNewBatch()
        coordinator = nil

        #expect(weakCoordinator == nil)

        await executor.succeed(0)
    }

    @Test @MainActor func retryRefreshesAndExecutesOnlyFailedItems() async {
        let skipped = testIssue("Already Searchable")
        let planner = CoordinatorPlanner(initialStates: [
            .queued,
            .queued,
            .skipped(skipped),
            .cancelled,
        ])
        let executor = ControlledBatchExecutor()
        let coordinator = await readyCoordinator(
            itemNames: ["complete.pdf", "retry.pdf", "skip.pdf", "cancel.pdf"],
            planner: planner,
            executor: executor
        )

        coordinator.start()
        await executor.waitForRequestCount(1)
        await executor.succeed(0)
        await executor.waitForRequestCount(2)
        await executor.fail(1, with: LocalOCRError.recognitionFailed(page: 1, message: "test"))
        await coordinator.waitUntilIdleForTesting()

        let completedState = coordinator.items[0].state
        let skippedState = coordinator.items[2].state
        let cancelledState = coordinator.items[3].state
        let failedID = coordinator.items[1].id

        coordinator.retryFailed()
        await executor.waitForRequestCount(3)

        #expect(await planner.refreshedItemIDs() == [failedID])
        #expect((await executor.requestedItems())[2].id == failedID)

        await executor.succeed(2)
        await coordinator.waitUntilIdleForTesting()

        #expect(coordinator.items[0].state == completedState)
        #expect(coordinator.items[2].state == skippedState)
        #expect(coordinator.items[3].state == cancelledState)
        #expect(coordinator.summary.completed == 2)
        #expect(coordinator.summary.failed == 0)
        #expect(coordinator.summary.skipped == 1)
        #expect(coordinator.summary.cancelled == 1)
    }

    @Test @MainActor func retryPlanningFailureStaysFailedAndDoesNotBlockLaterFailures() async {
        let planner = CoordinatorPlanner()
        let executor = ControlledBatchExecutor()
        let coordinator = await readyCoordinator(
            itemNames: ["first.pdf", "second.pdf"],
            planner: planner,
            executor: executor
        )

        coordinator.start()
        await executor.waitForRequestCount(1)
        await executor.fail(0, with: CoordinatorTestError.expected)
        await executor.waitForRequestCount(2)
        await executor.fail(1, with: CoordinatorTestError.expected)
        await coordinator.waitUntilIdleForTesting()

        let firstID = coordinator.items[0].id
        let secondID = coordinator.items[1].id
        await planner.setRefreshFailure(for: firstID)

        coordinator.retryFailed()
        await executor.waitForRequestCount(3)

        #expect(await planner.refreshedItemIDs() == [firstID, secondID])
        #expect((await executor.requestedItems())[2].id == secondID)
        #expect(coordinator.items[0].state == .failed(StudioBatchIssue(
            title: "Couldn’t Process Document",
            message: "The document could not be processed. Please try again.",
            details: "Technical details are hidden to protect your privacy."
        )))

        await executor.succeed(2)
        await coordinator.waitUntilIdleForTesting()

        #expect(coordinator.summary.failed == 1)
        #expect(coordinator.summary.completed == 1)
        #expect(await executor.maximumActiveCount() == 1)
    }

    @Test @MainActor func retryRefreshesAnExternallyOccupiedReservationWithTheSamePlanner() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioBatchCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        let input = root.appending(path: "input", directoryHint: .isDirectory)
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        let source = input.appending(path: "scan.pdf")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data().write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        let executor = ControlledBatchExecutor()
        let planner = BatchOutputPlanner()
        let coordinator = StudioBatchCoordinator(
            enumerator: BatchInputEnumerator(),
            planner: planner,
            executor: executor
        )
        coordinator.addSelections([source])
        await coordinator.waitUntilIdleForTesting()
        coordinator.chooseOutputRoot(output)
        await coordinator.waitUntilIdleForTesting()

        coordinator.start()
        await executor.waitForRequestCount(1)
        await executor.fail(0, with: LocalOCRError.outputExists)
        await coordinator.waitUntilIdleForTesting()
        let occupiedURL = coordinator.items[0].reservation.finalURL
        try Data("external".utf8).write(to: occupiedURL)

        coordinator.retryFailed()
        await executor.waitForRequestCount(2)

        let refreshedItem = (await executor.requestedItems())[1]
        #expect(refreshedItem.reservation.finalURL == output.appending(path: "scan_searchable_2.pdf"))
        #expect(try String(contentsOf: occupiedURL, encoding: .utf8) == "external")

        await executor.succeed(1)
        await coordinator.waitUntilIdleForTesting()

        #expect(coordinator.items[0].state == .completed(
            output.appending(path: "scan_searchable_2.pdf")
        ))
    }
}

private actor ImmediateCoordinatorEnumerator: StudioBatchInputEnumerating {
    private let fixedResult: StudioBatchDiscovery?
    private var requests: [[URL]] = []

    init(result: StudioBatchDiscovery? = nil) {
        fixedResult = result
    }

    func discover(selections: [URL]) async -> StudioBatchDiscovery {
        requests.append(selections)
        return fixedResult ?? discovery(for: selections)
    }

    func requestCount() -> Int {
        requests.count
    }

    func lastRequest() -> [URL]? {
        requests.last
    }
}

private actor ControlledCoordinatorEnumerator: StudioBatchInputEnumerating {
    private var requests: [[URL]] = []
    private var continuations: [Int: CheckedContinuation<StudioBatchDiscovery, Never>] = [:]
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func discover(selections: [URL]) async -> StudioBatchDiscovery {
        let index = requests.count
        requests.append(selections)
        resumeRequestWaiters()
        return await withCheckedContinuation { continuation in
            continuations[index] = continuation
        }
    }

    func waitForRequestCount(_ expected: Int) async {
        guard requests.count < expected else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((expected, continuation))
        }
    }

    func requestCount() -> Int {
        requests.count
    }

    func succeed(_ index: Int, with result: StudioBatchDiscovery) {
        continuations.removeValue(forKey: index)?.resume(returning: result)
    }

    private func resumeRequestWaiters() {
        let ready = requestWaiters.filter { requests.count >= $0.0 }
        requestWaiters.removeAll { requests.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

private actor CoordinatorPlanner: StudioBatchOutputPlanning {
    private let initialStates: [StudioBatchItemState]?
    private let planFailure: CoordinatorTestError?
    private var planRequests: [(StudioBatchDiscovery, URL)] = []
    private var refreshRequests: [UUID] = []
    private var refreshFailures: Set<UUID> = []

    init(
        initialStates: [StudioBatchItemState]? = nil,
        planFailure: CoordinatorTestError? = nil
    ) {
        self.initialStates = initialStates
        self.planFailure = planFailure
    }

    func makePlan(
        discovery: StudioBatchDiscovery,
        outputRoot: URL
    ) async throws -> StudioBatchPlan {
        planRequests.append((discovery, outputRoot))
        if let planFailure {
            throw planFailure
        }
        return plan(
            discovery: discovery,
            outputRoot: outputRoot,
            states: initialStates
        )
    }

    func refreshReservation(
        for item: StudioBatchItem,
        outputRoot: URL
    ) async throws -> StudioBatchReservation {
        refreshRequests.append(item.id)
        if refreshFailures.contains(item.id) {
            throw CoordinatorTestError.expected
        }
        return StudioBatchReservation(
            finalURL: item.reservation.finalURL
                .deletingPathExtension()
                .appendingPathExtension("retry.\(item.reservation.finalURL.pathExtension)"),
            outputRoot: outputRoot
        )
    }

    func planRequestCount() -> Int {
        planRequests.count
    }

    func refreshedItemIDs() -> [UUID] {
        refreshRequests
    }

    func setRefreshFailure(for id: UUID) {
        refreshFailures.insert(id)
    }
}

private actor ControlledCoordinatorPlanner: StudioBatchOutputPlanning {
    struct Request: Sendable {
        let discovery: StudioBatchDiscovery
        let outputRoot: URL
    }

    private var requests: [Request] = []
    private var continuations: [Int: CheckedContinuation<StudioBatchPlan, any Error>] = [:]
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func makePlan(
        discovery: StudioBatchDiscovery,
        outputRoot: URL
    ) async throws -> StudioBatchPlan {
        let index = requests.count
        requests.append(Request(discovery: discovery, outputRoot: outputRoot))
        resumeRequestWaiters()
        return try await withCheckedThrowingContinuation { continuation in
            continuations[index] = continuation
        }
    }

    func refreshReservation(
        for item: StudioBatchItem,
        outputRoot: URL
    ) async throws -> StudioBatchReservation {
        StudioBatchReservation(finalURL: item.reservation.finalURL, outputRoot: outputRoot)
    }

    func waitForRequestCount(_ expected: Int) async {
        guard requests.count < expected else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((expected, continuation))
        }
    }

    func request(at index: Int) -> Request {
        requests[index]
    }

    func requestCount() -> Int {
        requests.count
    }

    func succeed(_ index: Int, with result: StudioBatchPlan) {
        continuations.removeValue(forKey: index)?.resume(returning: result)
    }

    private func resumeRequestWaiters() {
        let ready = requestWaiters.filter { requests.count >= $0.0 }
        requestWaiters.removeAll { requests.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

private actor ReorderingRealCoordinatorPlanner: StudioBatchOutputPlanning {
    private struct PendingRequest {
        let discovery: StudioBatchDiscovery
        let outputRoot: URL
        let continuation: CheckedContinuation<StudioBatchPlan, any Error>
    }

    private let planner = BatchOutputPlanner()
    private var requestCount = 0
    private var firstRelease: CheckedContinuation<Void, Never>?
    private var secondRequest: PendingRequest?
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var hasReleasedFirst = false

    func makePlan(
        discovery: StudioBatchDiscovery,
        outputRoot: URL
    ) async throws -> StudioBatchPlan {
        let index = requestCount
        requestCount += 1
        resumeRequestWaiters()

        if index == 0 {
            await withCheckedContinuation { continuation in
                firstRelease = continuation
            }
            return try await planner.makePlan(discovery: discovery, outputRoot: outputRoot)
        }
        if hasReleasedFirst {
            return try await planner.makePlan(discovery: discovery, outputRoot: outputRoot)
        }
        return try await withCheckedThrowingContinuation { continuation in
            secondRequest = PendingRequest(
                discovery: discovery,
                outputRoot: outputRoot,
                continuation: continuation
            )
        }
    }

    func refreshReservation(
        for item: StudioBatchItem,
        outputRoot: URL
    ) async throws -> StudioBatchReservation {
        try await planner.refreshReservation(for: item, outputRoot: outputRoot)
    }

    func waitForRequestCount(_ expected: Int) async {
        guard requestCount < expected else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((expected, continuation))
        }
    }

    func releaseFirstAfterAnyOverlappingRequest() async {
        hasReleasedFirst = true
        if let secondRequest {
            self.secondRequest = nil
            do {
                let plan = try await planner.makePlan(
                    discovery: secondRequest.discovery,
                    outputRoot: secondRequest.outputRoot
                )
                secondRequest.continuation.resume(returning: plan)
            } catch {
                secondRequest.continuation.resume(throwing: error)
            }
        }
        firstRelease?.resume()
        firstRelease = nil
    }

    private func resumeRequestWaiters() {
        let ready = requestWaiters.filter { requestCount >= $0.0 }
        requestWaiters.removeAll { requestCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

private actor ControlledBatchExecutor: StudioBatchItemExecuting {
    private var items: [StudioBatchItem] = []
    private var progressHandlers: [@Sendable (StudioProgress) -> Void] = []
    private var continuations: [Int: CheckedContinuation<URL, any Error>] = [:]
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var activeCount = 0
    private var recordedMaximumActiveCount = 0

    func execute(
        _ item: StudioBatchItem,
        progress: @escaping @Sendable (StudioProgress) -> Void
    ) async throws -> URL {
        let index = items.count
        items.append(item)
        progressHandlers.append(progress)
        activeCount += 1
        recordedMaximumActiveCount = max(recordedMaximumActiveCount, activeCount)
        resumeRequestWaiters()
        defer { activeCount -= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[index] = continuation
        }
    }

    func waitForRequestCount(_ expected: Int) async {
        guard items.count < expected else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((expected, continuation))
        }
    }

    func sendProgress(_ progress: StudioProgress, for index: Int) {
        progressHandlers[index](progress)
    }

    func sendProgress(_ progressValues: [StudioProgress], for index: Int) {
        for progress in progressValues {
            progressHandlers[index](progress)
        }
    }

    func succeed(_ index: Int, at url: URL? = nil) {
        let destination = url ?? items[index].reservation.finalURL
        continuations.removeValue(forKey: index)?.resume(returning: destination)
    }

    func fail(_ index: Int, with error: any Error) {
        continuations.removeValue(forKey: index)?.resume(throwing: error)
    }

    func completeAllInOrder(expectedCount: Int) async {
        for index in 0..<expectedCount {
            await waitForRequestCount(index + 1)
            succeed(index)
        }
    }

    func requestCount() -> Int {
        items.count
    }

    func requestedItems() -> [StudioBatchItem] {
        items
    }

    func maximumActiveCount() -> Int {
        recordedMaximumActiveCount
    }

    private func resumeRequestWaiters() {
        let ready = requestWaiters.filter { items.count >= $0.0 }
        requestWaiters.removeAll { items.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

private enum CoordinatorTestError: Error, Sendable {
    case expected
}

@MainActor
private func readyCoordinator(
    itemNames: [String],
    enumerator: ImmediateCoordinatorEnumerator = ImmediateCoordinatorEnumerator(),
    planner: CoordinatorPlanner = CoordinatorPlanner(),
    executor: ControlledBatchExecutor
) async -> StudioBatchCoordinator {
    let coordinator = StudioBatchCoordinator(
        enumerator: enumerator,
        planner: planner,
        executor: executor
    )
    coordinator.addSelections(itemNames.map(testURL))
    await coordinator.waitUntilIdleForTesting()
    coordinator.chooseOutputRoot(testURL("output"))
    await coordinator.waitUntilIdleForTesting()
    return coordinator
}

private func discovery(for selections: [URL]) -> StudioBatchDiscovery {
    StudioBatchDiscovery(
        candidates: selections.map { sourceURL in
            StudioBatchCandidate(
                id: UUID(),
                sourceURL: sourceURL,
                standardizedSourceURL: sourceURL.standardizedFileURL,
                kind: sourceURL.pathExtension.lowercased() == "pdf" ? .pdf : .image,
                relativePath: sourceURL.lastPathComponent,
                outputGroupName: nil
            )
        },
        skipped: [],
        duplicateCount: 0,
        selectedFolderRoots: []
    )
}

private func plan(
    discovery: StudioBatchDiscovery,
    outputRoot: URL,
    states: [StudioBatchItemState]? = nil
) -> StudioBatchPlan {
    let physicalRoot = outputRoot.standardizedFileURL
        .resolvingSymlinksInPath()
        .standardizedFileURL
    return StudioBatchPlan(
        outputRoot: physicalRoot,
        items: discovery.candidates.enumerated().map { index, candidate in
            StudioBatchItem(
                id: candidate.id,
                candidate: candidate,
                reservation: StudioBatchReservation(
                    finalURL: physicalRoot.appending(path: "item-\(index + 1).out"),
                    outputRoot: physicalRoot
                ),
                state: states?[index] ?? .queued
            )
        },
        skipped: discovery.skipped,
        duplicateCount: discovery.duplicateCount
    )
}

private func testURLs(_ names: String...) -> [URL] {
    names.map(testURL)
}

private func testURL(_ name: String) -> URL {
    URL(fileURLWithPath: "/tmp/StudioBatchCoordinatorTests/\(name)")
}

private func testIssue(_ title: String) -> StudioBatchIssue {
    StudioBatchIssue(title: title, message: "test", details: nil)
}

@MainActor
private func assertEmptySession(_ coordinator: StudioBatchCoordinator) {
    #expect(coordinator.phase == .empty)
    #expect(coordinator.discovery == nil)
    #expect(coordinator.outputRoot == nil)
    #expect(coordinator.items.isEmpty)
    #expect(coordinator.actionError == nil)
    #expect(coordinator.summary == StudioBatchSummary(items: [], skippedCount: 0))
    #expect(!coordinator.canStart)
}
