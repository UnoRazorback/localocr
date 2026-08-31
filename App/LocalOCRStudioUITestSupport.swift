#if DEBUG
import Foundation
import LocalOCRIntelligence
import LocalOCRModelCore
@_spi(Testing) @_spi(UITesting) import LocalOCRStudioKit

@MainActor
enum LocalOCRStudioUITestSupport {
    private enum AgentFixtureState: String, Sendable {
        case disconnected
        case connected
        case conflict
        case failure
    }

    static func helpTopicIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HelpTopicID? {
        guard let testSession = environment["LOCALOCR_STUDIO_UI_TEST_SESSION"],
              !testSession.isEmpty,
              let rawTopic = environment["LOCALOCR_STUDIO_HELP_TOPIC"]
        else {
            return nil
        }
        return HelpTopicID(rawValue: rawTopic)
    }

    static func makeAgentConnectionGuideModelIfRequested(
        bundleURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AgentConnectionGuideModel? {
        guard let testSession = environment["LOCALOCR_STUDIO_UI_TEST_SESSION"],
              !testSession.isEmpty
        else {
            return nil
        }
        guard let rawState = environment["LOCALOCR_STUDIO_AGENT_STATE"],
              let state = AgentFixtureState(rawValue: rawState)
        else {
            return AgentConnectionGuideModel(
                bundleURL: bundleURL,
                consentStore: UITestConsentStore()
            )
        }

        let installations = [
            AgentClientInstallation(
                kind: .codex,
                executableURL: URL(fileURLWithPath: "/fixture/bin/codex"),
                displayName: "Codex",
                version: "fixture"
            ),
            AgentClientInstallation(
                kind: .claudeCode,
                executableURL: URL(fileURLWithPath: "/fixture/bin/claude"),
                displayName: "Claude Code",
                version: "fixture"
            ),
        ]
        let runner = UITestAgentCommandRunner(
            state: state,
            helperPath: bundleURL.appendingPathComponent(
                "Contents/Helpers/localocr-mcp"
            ).path
        )
        return AgentConnectionGuideModel(
            bundleURL: bundleURL,
            consentStore: UITestConsentStore(),
            discoverClients: {
                AgentClientDiscoveryResult(
                    installations: installations,
                    rejections: []
                )
            },
            runCommand: { command in
                try await runner.run(command)
            }
        )
    }

    private actor UITestAgentCommandRunner {
        private var state: AgentFixtureState
        private let helperPath: String

        init(state: AgentFixtureState, helperPath: String) {
            self.state = state
            self.helperPath = helperPath
        }

        func run(_ command: AgentClientCommandSpec) throws -> AgentClientCommandResult {
            if command.arguments.prefix(2) == ["mcp", "add"] {
                state = .connected
                return result()
            }
            if command.arguments.prefix(2) == ["mcp", "remove"] {
                state = .disconnected
                return result()
            }

            switch state {
            case .disconnected:
                throw AgentClientCommandRunnerError.exited(status: 1)
            case .connected:
                return result(stdout: "command: \(helperPath)")
            case .conflict:
                return result(
                    stdout: "command: /Applications/Other LocalOCR.app/Contents/Helpers/localocr-mcp"
                )
            case .failure:
                throw AgentClientCommandRunnerError.launchFailed
            }
        }

        private func result(stdout: String = "") -> AgentClientCommandResult {
            AgentClientCommandResult(
                exitStatus: 0,
                stdout: Data(stdout.utf8),
                stderr: Data()
            )
        }
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
        case modelManager
        case modelRecovery
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
                 .intelligenceUnsupportedLanguage, .intelligenceError,
                 .modelManager, .modelRecovery, .error:
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
                 .intelligenceUnsupportedLanguage, .intelligenceError,
                 .modelManager, .modelRecovery, .error,
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
        let usesRecoverySelection = state == .modelRecovery
        let fixtureLocalModelManager = FixtureLocalIntelligenceManager(
            usesRecoverySelection: usesRecoverySelection
        )
        let localModelManager = StudioLocalModelManagerViewModel(
            manager: fixtureLocalModelManager,
            initialModels: FixtureLocalIntelligenceManager.seedDescriptors(
                usesRecoverySelection: usesRecoverySelection
            ),
            initialSelection: FixtureLocalIntelligenceManager.initialSelection(
                usesRecoverySelection: usesRecoverySelection
            )
        )

        switch state {
        case .empty:
            break
        case .result, .resultBusy, .intelligenceAvailable,
             .intelligenceRunning, .intelligenceResults,
             .intelligenceMacOSUnavailable, .intelligenceDeviceIneligible,
             .intelligenceDisabled, .intelligenceNotReady,
             .intelligenceUnsupportedLanguage, .intelligenceError,
             .modelManager, .modelRecovery, .error:
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
                localModelManager: localModelManager,
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
                localModelManager: localModelManager,
                workspaceMode: .batch,
                isCreatingSearchablePDF: false,
                searchableProgress: nil
            )
        }

        return LocalOCRStudioView(
            model: model,
            actions: actions,
            batchCoordinator: batchCoordinator,
            intelligenceModel: intelligenceModel,
            localModelManager: localModelManager
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
                 .intelligenceUnsupportedLanguage, .intelligenceError,
                 .modelManager, .modelRecovery:
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
        case .modelManager:
            providerMode = .externalResults
            availability = .available
        case .modelRecovery:
            providerMode = .selectionFailure
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
        case .modelRecovery:
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
            case externalResults
            case running
            case failure
            case selectionFailure
        }

        let mode: Mode
        let availability: IntelligenceAvailability

        func summarize(
            _ document: IntelligenceDocument
        ) async throws -> ProvenancedIntelligenceResult<IntelligenceSummary> {
            try await waitOrFailIfNeeded()
            return ProvenancedIntelligenceResult(value: IntelligenceSummary(
                text: "Quarterly planning is complete",
                citations: [IntelligenceCitation(page: 2, quote: "Quarterly planning is complete.")]
            ), model: provenance)
        }

        func organize(
            _ document: IntelligenceDocument
        ) async throws -> ProvenancedIntelligenceResult<OrganizationSuggestion> {
            try await waitOrFailIfNeeded()
            return ProvenancedIntelligenceResult(value: OrganizationSuggestion(
                title: "Quarterly Planning",
                category: "Business",
                tags: ["planning", "quarterly"],
                citations: [IntelligenceCitation(page: 2, quote: "Quarterly planning is complete.")]
            ), model: provenance)
        }

        func extract(
            _ names: [String],
            from document: IntelligenceDocument
        ) async throws -> ProvenancedIntelligenceResult<[ExtractedDocumentField]> {
            try await waitOrFailIfNeeded()
            return ProvenancedIntelligenceResult(value: [
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
            ], model: provenance)
        }

        private var provenance: LocalModelProvenance {
            mode == .externalResults
                ? LocalModelProvenance(
                    provider: .ollama,
                    providerDisplayName: "Ollama",
                    model: "gemma4:8b",
                    processing: .onDeviceLoopback,
                    fingerprint: "sha256:ui-fixture",
                    qualifiedAt: Date(timeIntervalSince1970: 1_788_050_400)
                )
                : .appleSystemDefault
        }

        private func waitOrFailIfNeeded() async throws {
            switch mode {
            case .results, .externalResults:
                return
            case .running:
                try await Task.sleep(for: .seconds(3_600))
            case .failure:
                throw FixtureError.expectedFailure
            case .selectionFailure:
                throw IntelligenceError.selection(.modelUnavailable(Self.ollamaIdentity))
            }
        }

        private static let ollamaIdentity = LocalModelIdentity(
            provider: .ollama,
            model: "gemma4:8b",
            fingerprint: "sha256:ui-fixture",
            harnessVersion: "0.11.0"
        )
    }

    private actor FixtureLocalIntelligenceManager: LocalIntelligenceManaging {
        private static let testedAt = Date(timeIntervalSince1970: 1_788_050_400)
        private static let ollama = LocalModelIdentity(
            provider: .ollama,
            model: "gemma4:8b",
            fingerprint: "sha256:ui-fixture",
            harnessVersion: "0.11.0"
        )
        private static let blocked = LocalModelIdentity(
            provider: .ollama,
            model: "cloud-model",
            fingerprint: "sha256:blocked",
            harnessVersion: "0.11.0"
        )
        private static let unverified = LocalModelIdentity(
            provider: .lmStudio,
            model: "local-metadata-missing",
            fingerprint: "sha256:unverified",
            harnessVersion: "0.3.20"
        )
        private static let qualifiedLMStudio = LocalModelIdentity(
            provider: .lmStudio,
            model: "qwen2.5-7b-instruct",
            fingerprint: "sha256:lm-fixture",
            harnessVersion: "0.3.20"
        )

        private var selection: LocalIntelligenceSelectionState
        private var ollamaQualification: LocalModelQualificationStatus

        init(usesRecoverySelection: Bool) {
            selection = Self.initialSelection(usesRecoverySelection: usesRecoverySelection)
            ollamaQualification = usesRecoverySelection ? .passed : .untested
        }

        nonisolated static func initialSelection(
            usesRecoverySelection: Bool
        ) -> LocalIntelligenceSelectionState {
            guard usesRecoverySelection else { return .selected(.appleSystemDefault) }
            return .selected(.external(
                identity: ollama,
                qualification: qualificationReceipt(ollama),
                acknowledgment: ExternalLocalModelAcknowledgment(
                    policyVersion: ExternalLocalModelAcknowledgment.currentPolicyVersion,
                    identity: ollama,
                    acceptedAt: testedAt
                )
            ))
        }

        nonisolated static func seedDescriptors(
            usesRecoverySelection: Bool
        ) -> [LocalModelDescriptor] {
            let externalSelected = usesRecoverySelection
            return [
                LocalModelDescriptor(
                    identity: .appleSystemDefault,
                    displayName: "Apple Foundation Models — system default",
                    locality: .verifiedLocal,
                    localityReason: "Built into macOS and runs on device.",
                    qualification: .passed,
                    available: true,
                    selected: !externalSelected
                ),
                LocalModelDescriptor(
                    identity: ollama,
                    displayName: ollama.model,
                    locality: .verifiedLocal,
                    localityReason: "Inference is local to this Mac.",
                    qualification: externalSelected ? .passed : .untested,
                    available: true,
                    selected: externalSelected,
                    qualifiedAt: externalSelected ? testedAt : nil
                ),
                LocalModelDescriptor(
                    identity: blocked,
                    displayName: blocked.model,
                    locality: .blocked,
                    localityReason: "cloud or remote execution",
                    qualification: .untested,
                    available: true,
                    selected: false
                ),
                LocalModelDescriptor(
                    identity: unverified,
                    displayName: unverified.model,
                    locality: .unverified,
                    localityReason: "local execution could not be verified",
                    qualification: .untested,
                    available: true,
                    selected: false
                ),
                LocalModelDescriptor(
                    identity: qualifiedLMStudio,
                    displayName: qualifiedLMStudio.model,
                    locality: .verifiedLocal,
                    localityReason: "Inference is local to this Mac.",
                    qualification: .passed,
                    available: true,
                    selected: false,
                    qualifiedAt: testedAt
                ),
            ]
        }

        func models() async -> [LocalModelDescriptor] {
            [
                descriptor(
                    identity: .appleSystemDefault,
                    locality: .verifiedLocal,
                    reason: "Built into macOS and runs on device.",
                    qualification: .passed,
                    available: true
                ),
                descriptor(
                    identity: Self.ollama,
                    locality: .verifiedLocal,
                    reason: "Inference is local to this Mac.",
                    qualification: ollamaQualification,
                    available: true
                ),
                descriptor(
                    identity: Self.blocked,
                    locality: .blocked,
                    reason: "cloud or remote execution",
                    qualification: .untested,
                    available: true
                ),
                descriptor(
                    identity: Self.unverified,
                    locality: .unverified,
                    reason: "local execution could not be verified",
                    qualification: .untested,
                    available: true
                ),
                descriptor(
                    identity: Self.qualifiedLMStudio,
                    locality: .verifiedLocal,
                    reason: "Inference is local to this Mac.",
                    qualification: .passed,
                    available: true
                ),
            ]
        }

        func qualify(_ identity: LocalModelIdentity) async throws -> LocalModelQualificationOutcome {
            guard identity == Self.ollama else {
                throw IntelligenceError.selection(.qualificationRequired(identity))
            }
            ollamaQualification = .passed
            let receipt = Self.qualificationReceipt(identity)
            return LocalModelQualificationOutcome(status: .passed, receipt: receipt, failures: [])
        }

        func selectApple() async throws { selection = .selected(.appleSystemDefault) }

        func selectExternal(
            _ identity: LocalModelIdentity,
            acknowledgmentAcceptedAt: Date
        ) async throws {
            guard identity == Self.ollama, ollamaQualification == .passed else {
                throw IntelligenceError.selection(.qualificationRequired(identity))
            }
            selection = .selected(.external(
                identity: identity,
                qualification: Self.qualificationReceipt(identity),
                acknowledgment: ExternalLocalModelAcknowledgment(
                    policyVersion: ExternalLocalModelAcknowledgment.currentPolicyVersion,
                    identity: identity,
                    acceptedAt: acknowledgmentAcceptedAt
                )
            ))
        }

        func status() async -> LocalIntelligenceSelectionState { selection }
        func reset() async throws { selection = .reset(at: Self.testedAt) }

        private func descriptor(
            identity: LocalModelIdentity,
            locality: LocalModelLocality,
            reason: String,
            qualification: LocalModelQualificationStatus,
            available: Bool
        ) -> LocalModelDescriptor {
            let selected: Bool = switch selection {
            case .selected(.appleSystemDefault): identity == .appleSystemDefault
            case let .selected(.external(selectedIdentity, _, _)): identity == selectedIdentity
            case .none, .reset, .invalid: false
            }
            return LocalModelDescriptor(
                identity: identity,
                displayName: identity.model,
                locality: locality,
                localityReason: reason,
                qualification: qualification,
                available: available,
                selected: selected,
                qualifiedAt: qualification == .passed && identity != .appleSystemDefault
                    ? Self.testedAt : nil
            )
        }

        private nonisolated static func qualificationReceipt(
            _ identity: LocalModelIdentity
        ) -> LocalModelQualificationReceipt {
            LocalModelQualificationReceipt(
                policyVersion: LocalModelQualificationReceipt.currentPolicyVersion,
                fixtureVersion: LocalModelQualificationReceipt.currentFixtureVersion,
                identity: identity,
                passedActions: Set(LocalIntelligenceAction.allCases),
                qualifiedAt: Self.testedAt
            )
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
