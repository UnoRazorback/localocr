#if DEBUG
import Foundation
import LocalOCRIntelligence
@_spi(Testing) @_spi(UITesting) import LocalOCRStudioKit

@MainActor
enum LocalOCRStudioUITestSupport {
    static func makeAgentConnectionGuideModelIfRequested(
        bundleURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AgentConnectionGuideModel? {
        guard let testSession = environment["LOCALOCR_STUDIO_UI_TEST_SESSION"],
              !testSession.isEmpty
        else {
            return nil
        }
        return AgentConnectionGuideModel(
            bundleURL: bundleURL,
            consentStore: UITestConsentStore()
        )
    }

    private enum FixtureState: String, Sendable {
        case empty
        case result
        case resultBusy
        case intelligenceAvailable
        case intelligenceRunning
        case intelligenceResults
        case intelligenceMacOSUnavailable
        case intelligenceDeviceIneligible
        case intelligenceDisabled
        case intelligenceNotReady
        case intelligenceUnsupportedLanguage
        case intelligenceError
        case error
        case batchReview
        case batchProcessing
        case batchComplete
        case batchSkippedOnly
        case batchPlanningFailure

        var isBatch: Bool {
            switch self {
            case .batchReview, .batchProcessing, .batchComplete,
                 .batchSkippedOnly, .batchPlanningFailure:
                true
            case .empty, .result, .resultBusy, .intelligenceAvailable,
                 .intelligenceRunning, .intelligenceResults,
                 .intelligenceMacOSUnavailable, .intelligenceDeviceIneligible,
                 .intelligenceDisabled, .intelligenceNotReady,
                 .intelligenceUnsupportedLanguage, .intelligenceError, .error:
                false
            }
        }

        var batchExecutionMode: FixtureBatchExecutionMode {
            switch self {
            case .batchReview, .batchProcessing:
                .processing
            case .batchComplete:
                .complete
            case .empty, .result, .resultBusy, .intelligenceAvailable,
                 .intelligenceRunning, .intelligenceResults,
                 .intelligenceMacOSUnavailable, .intelligenceDeviceIneligible,
                 .intelligenceDisabled, .intelligenceNotReady,
                 .intelligenceUnsupportedLanguage, .intelligenceError, .error,
                 .batchSkippedOnly, .batchPlanningFailure:
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
        let intelligenceModel = makeIntelligenceModel(for: state)

        switch state {
        case .empty:
            break
        case .result, .resultBusy, .intelligenceAvailable,
             .intelligenceRunning, .intelligenceResults,
             .intelligenceMacOSUnavailable, .intelligenceDeviceIneligible,
             .intelligenceDisabled, .intelligenceNotReady,
             .intelligenceUnsupportedLanguage, .intelligenceError, .error:
            model.open(fixtureSourceURL)
        case .batchReview, .batchProcessing, .batchComplete,
             .batchSkippedOnly, .batchPlanningFailure:
            prepareBatchFixture(batchCoordinator, for: state)
        }

        if state == .resultBusy {
            return LocalOCRStudioView(
                model: model,
                actions: actions,
                batchCoordinator: batchCoordinator,
                intelligenceModel: intelligenceModel,
                isCreatingSearchablePDF: true,
                searchableProgress: .assembling
            )
        }

        if state.isBatch {
            return LocalOCRStudioView(
                model: model,
                actions: actions,
                batchCoordinator: batchCoordinator,
                intelligenceModel: intelligenceModel,
                workspaceMode: .batch,
                isCreatingSearchablePDF: false,
                searchableProgress: nil
            )
        }

        return LocalOCRStudioView(
            model: model,
            actions: actions,
            batchCoordinator: batchCoordinator,
            intelligenceModel: intelligenceModel
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
            case .empty, .batchReview, .batchProcessing, .batchComplete,
                 .batchSkippedOnly, .batchPlanningFailure:
                throw FixtureError.unavailable
            case .result, .resultBusy, .intelligenceAvailable,
                 .intelligenceRunning, .intelligenceResults,
                 .intelligenceMacOSUnavailable, .intelligenceDeviceIneligible,
                 .intelligenceDisabled, .intelligenceNotReady,
                 .intelligenceUnsupportedLanguage, .intelligenceError:
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

    private actor UITestConsentStore: ExternalDataConsentStoring {
        private var currentStatus: ExternalDataConsentStatus = .required

        func status() async -> ExternalDataConsentStatus {
            currentStatus
        }

        func acceptBothStatements(at date: Date) async throws {
            currentStatus = .current(ExternalDataConsentReceipt(
                schemaVersion: ExternalDataConsentReceipt.currentSchemaVersion,
                policyVersion: ExternalDataConsentReceipt.currentPolicyVersion,
                acceptedAt: date,
                externalProviderRiskAccepted: true,
                documentToolAccessAccepted: true
            ))
        }

        func revoke() async throws {
            currentStatus = .required
        }
    }

    private static func makeIntelligenceModel(
        for state: FixtureState
    ) -> StudioIntelligenceViewModel {
        let providerMode: FixtureIntelligenceProvider.Mode
        let availability: IntelligenceAvailability
        switch state {
        case .intelligenceRunning:
            providerMode = .running
            availability = .available
        case .intelligenceResults:
            providerMode = .results
            availability = .available
        case .intelligenceError:
            providerMode = .failure
            availability = .available
        case .intelligenceMacOSUnavailable:
            providerMode = .results
            availability = .requiresMacOS26
        case .intelligenceDeviceIneligible:
            providerMode = .results
            availability = .deviceNotEligible
        case .intelligenceDisabled:
            providerMode = .results
            availability = .appleIntelligenceNotEnabled
        case .intelligenceNotReady:
            providerMode = .results
            availability = .modelNotReady
        case .intelligenceUnsupportedLanguage:
            providerMode = .results
            availability = .unsupportedLanguage
        case .empty, .result, .resultBusy, .intelligenceAvailable, .error,
             .batchReview, .batchProcessing, .batchComplete,
             .batchSkippedOnly, .batchPlanningFailure:
            providerMode = .results
            availability = .available
        }

        let provider = FixtureIntelligenceProvider(
            mode: providerMode,
            availability: availability
        )
        let model = StudioIntelligenceViewModel(
            provider: provider,
            availability: availability
        )
        let identity = "\(fixtureSourceURL.standardizedFileURL.path)|\(String(repeating: "a", count: 64))"
        model.setDocument(fixtureIntelligenceDocument, identity: identity)

        switch state {
        case .intelligenceRunning:
            model.summarize()
        case .intelligenceResults:
            model.summarize()
            model.organize()
            model.extractFields()
        case .intelligenceError:
            model.summarize()
        default:
            break
        }
        return model
    }

    private static let fixtureIntelligenceDocument = IntelligenceDocument(pages: [
        IntelligenceSourcePage(number: 1, text: "Date: 2026-08-27"),
        IntelligenceSourcePage(
            number: 2,
            text: "Quarterly planning is complete. Reference: QP-27"
        ),
    ])

    private struct FixtureIntelligenceProvider: DocumentIntelligenceProviding {
        enum Mode: Sendable {
            case results
            case running
            case failure
        }

        let mode: Mode
        let availability: IntelligenceAvailability

        func summarize(_ document: IntelligenceDocument) async throws -> IntelligenceSummary {
            try await waitOrFailIfNeeded()
            return IntelligenceSummary(
                text: "Quarterly planning is complete",
                citations: [IntelligenceCitation(page: 2, quote: "Quarterly planning is complete.")]
            )
        }

        func organize(_ document: IntelligenceDocument) async throws -> OrganizationSuggestion {
            try await waitOrFailIfNeeded()
            return OrganizationSuggestion(
                title: "Quarterly Planning",
                category: "Business",
                tags: ["planning", "quarterly"],
                citations: [IntelligenceCitation(page: 2, quote: "Quarterly planning is complete.")]
            )
        }

        func extract(
            _ names: [String],
            from document: IntelligenceDocument
        ) async throws -> [ExtractedDocumentField] {
            try await waitOrFailIfNeeded()
            return [
                ExtractedDocumentField(
                    name: "date",
                    value: "2026-08-27",
                    sourcePage: 1,
                    evidence: "Date: 2026-08-27"
                ),
                ExtractedDocumentField(
                    name: "total",
                    value: nil,
                    sourcePage: nil,
                    evidence: nil
                ),
                ExtractedDocumentField(
                    name: "reference_number",
                    value: "QP-27",
                    sourcePage: 2,
                    evidence: "Reference: QP-27"
                ),
            ]
        }

        private func waitOrFailIfNeeded() async throws {
            switch mode {
            case .results:
                return
            case .running:
                try await Task.sleep(for: .seconds(3_600))
            case .failure:
                throw FixtureError.expectedFailure
            }
        }
    }

    private static func makeBatchCoordinator(
        for state: FixtureState
    ) -> StudioBatchCoordinator {
        StudioBatchCoordinator(
            enumerator: FixtureBatchEnumerator(discovery: discovery(for: state)),
            planner: FixtureBatchPlanner(
                shouldFail: state == .batchPlanningFailure
            ),
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

        guard state == .batchProcessing || state == .batchComplete else { return }
        Task { @MainActor in
            await coordinator.waitUntilPreparationIdleForTesting()
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

    private static let skippedOnlyDiscovery = StudioBatchDiscovery(
        candidates: [],
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
        duplicateCount: 0,
        selectedFolderRoots: []
    )

    private static func discovery(for state: FixtureState) -> StudioBatchDiscovery {
        state == .batchSkippedOnly ? skippedOnlyDiscovery : batchDiscovery
    }

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
        let shouldFail: Bool

        init(shouldFail: Bool) {
            self.shouldFail = shouldFail
        }

        func makePlan(
            discovery: StudioBatchDiscovery,
            outputRoot: URL
        ) async throws -> StudioBatchPlan {
            if shouldFail {
                throw FixtureError.expectedFailure
            }
            return StudioBatchPlan(
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
