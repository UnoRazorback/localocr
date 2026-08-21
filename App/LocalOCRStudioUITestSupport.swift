#if DEBUG
import Foundation
@_spi(Testing) @_spi(UITesting) import LocalOCRStudioKit

@MainActor
enum LocalOCRStudioUITestSupport {
    private enum FixtureState: String, Sendable {
        case empty
        case result
        case resultBusy
        case error
        case batchReview
        case batchProcessing
        case batchComplete

        var isBatch: Bool {
            switch self {
            case .batchReview, .batchProcessing, .batchComplete:
                true
            case .empty, .result, .resultBusy, .error:
                false
            }
        }

        var batchExecutionMode: FixtureBatchExecutionMode {
            switch self {
            case .batchProcessing:
                .processing
            case .batchComplete:
                .complete
            case .empty, .result, .resultBusy, .error, .batchReview:
                .review
            }
        }
    }

    static func makeViewIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LocalOCRStudioView? {
        guard let testSession = environment["LOCALOCR_STUDIO_UI_TEST_SESSION"],
              !testSession.isEmpty,
              let rawState = environment["LOCALOCR_STUDIO_UI_STATE"],
              let state = FixtureState(rawValue: rawState)
        else {
            return nil
        }

        let client = FixtureClient(state: state)
        let model = StudioViewModel(client: client)
        let actions = StudioDocumentActions(
            client: client,
            clipboard: NSPasteboardStudioClipboard(),
            textWriter: AtomicStudioTextWriter()
        )
        let batchCoordinator = makeBatchCoordinator(for: state)

        switch state {
        case .empty:
            break
        case .result, .resultBusy, .error:
            model.open(fixtureSourceURL)
        case .batchReview, .batchProcessing, .batchComplete:
            prepareBatchFixture(batchCoordinator, for: state)
        }

        if state == .resultBusy {
            return LocalOCRStudioView(
                model: model,
                actions: actions,
                batchCoordinator: batchCoordinator,
                isCreatingSearchablePDF: true,
                searchableProgress: .assembling
            )
        }

        if state.isBatch {
            return LocalOCRStudioView(
                model: model,
                actions: actions,
                batchCoordinator: batchCoordinator,
                workspaceMode: .batch,
                isCreatingSearchablePDF: false,
                searchableProgress: nil
            )
        }

        return LocalOCRStudioView(
            model: model,
            actions: actions,
            batchCoordinator: batchCoordinator
        )
    }

    private static let fixtureSourceURL = URL(
        fileURLWithPath: "/tmp/fixture-invoice.pdf"
    )

    private struct FixtureClient: StudioOCRClient {
        let state: FixtureState

        func processDocument(
            at sourceURL: URL,
            progress: @escaping @Sendable (StudioProgress) -> Void
        ) async throws -> StudioDocumentResult {
            switch state {
            case .empty, .batchReview, .batchProcessing, .batchComplete:
                throw FixtureError.unavailable
            case .result, .resultBusy:
                progress(.recognizing(page: 2, total: 2))
                return StudioDocumentResult(
                    sourceURL: sourceURL,
                    sourceSHA256: String(repeating: "a", count: 64),
                    kind: .pdf,
                    pageCount: 2,
                    searchablePages: 1,
                    ocrNeededPages: 1,
                    text: """
                    LOCALOCR UI FIXTURE
                    Quarterly planning is complete.
                    Owner: Ray Consulting
                    """,
                    failedPages: []
                )
            case .error:
                throw FixtureError.expectedFailure
            }
        }

        func makeSearchablePDF(
            sourceURL _: URL,
            destinationURL _: URL,
            progress _: @escaping @Sendable (StudioProgress) -> Void
        ) async throws -> URL {
            throw FixtureError.unavailable
        }
    }

    private enum FixtureError: Error {
        case expectedFailure
        case unavailable
    }

    private static func makeBatchCoordinator(
        for state: FixtureState
    ) -> StudioBatchCoordinator {
        StudioBatchCoordinator(
            enumerator: FixtureBatchEnumerator(discovery: batchDiscovery),
            planner: FixtureBatchPlanner(),
            executor: FixtureBatchExecutor(mode: state.batchExecutionMode)
        )
    }

    private static func prepareBatchFixture(
        _ coordinator: StudioBatchCoordinator,
        for state: FixtureState
    ) {
        coordinator.addSelections([
            URL(fileURLWithPath: "/tmp/LocalOCR-UI-Fixture-Selection")
        ])
        coordinator.chooseOutputRoot(
            URL(fileURLWithPath: "/tmp/LocalOCR-UI-Fixture-Output", isDirectory: true)
        )

        guard state != .batchReview else { return }
        Task { @MainActor in
            await coordinator.waitUntilPreparationIdleForTesting()
            try? await Task.sleep(for: .milliseconds(250))
            coordinator.start()
            if state == .batchComplete {
                await coordinator.waitUntilIdleForTesting()
            }
        }
    }

    private static let batchDiscovery = StudioBatchDiscovery(
        candidates: [
            batchCandidate(
                id: "00000000-0000-0000-0000-000000000001",
                filename: "Quarterly Report.pdf",
                kind: .pdf
            ),
            batchCandidate(
                id: "00000000-0000-0000-0000-000000000002",
                filename: "Receipt.png",
                kind: .image
            ),
        ],
        skipped: [
            StudioBatchSkippedInput(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                sourceURL: URL(fileURLWithPath: "/tmp/LocalOCR-UI-Fixture/notes.txt"),
                reason: StudioBatchIssue(
                    title: "Unsupported File",
                    message: "Choose a PDF or image file.",
                    details: nil
                )
            )
        ],
        duplicateCount: 1,
        selectedFolderRoots: []
    )

    private static func batchCandidate(
        id: String,
        filename: String,
        kind: StudioDocumentKind
    ) -> StudioBatchCandidate {
        let sourceURL = URL(
            fileURLWithPath: "/tmp/LocalOCR-UI-Fixture/\(filename)"
        )
        return StudioBatchCandidate(
            id: UUID(uuidString: id)!,
            sourceURL: sourceURL,
            standardizedSourceURL: sourceURL,
            kind: kind,
            relativePath: "Client Records/\(filename)",
            outputGroupName: "Client Records"
        )
    }

    private actor FixtureBatchEnumerator: StudioBatchInputEnumerating {
        let discovery: StudioBatchDiscovery

        init(discovery: StudioBatchDiscovery) {
            self.discovery = discovery
        }

        func discover(selections _: [URL]) async -> StudioBatchDiscovery {
            discovery
        }
    }

    private actor FixtureBatchPlanner: StudioBatchOutputPlanning {
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
                        reservation: reservation(
                            for: candidate,
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
            outputRoot: URL
        ) async throws -> StudioBatchReservation {
            reservation(for: item.candidate, outputRoot: outputRoot)
        }

        private func reservation(
            for candidate: StudioBatchCandidate,
            outputRoot: URL
        ) -> StudioBatchReservation {
            let stem = candidate.sourceURL.deletingPathExtension().lastPathComponent
            let filename = candidate.kind == .pdf
                ? "\(stem)_searchable.pdf"
                : "\(stem).txt"
            return StudioBatchReservation(
                finalURL: outputRoot.appendingPathComponent(filename),
                outputRoot: outputRoot
            )
        }
    }

    private actor FixtureBatchExecutor: StudioBatchItemExecuting {
        let mode: FixtureBatchExecutionMode

        init(mode: FixtureBatchExecutionMode) {
            self.mode = mode
        }

        func execute(
            _ item: StudioBatchItem,
            progress: @escaping @Sendable (StudioProgress) -> Void
        ) async throws -> URL {
            progress(.recognizing(page: 1, total: 2))
            switch mode {
            case .review:
                throw FixtureError.unavailable
            case .processing:
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw CancellationError()
            case .complete:
                if item.id.uuidString.hasSuffix("0002") {
                    throw FixtureError.expectedFailure
                }
                return item.reservation.finalURL
            }
        }
    }

    private enum FixtureBatchExecutionMode: Sendable {
        case review
        case processing
        case complete
    }
}
#endif
