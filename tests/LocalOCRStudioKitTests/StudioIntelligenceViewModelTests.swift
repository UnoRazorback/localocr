import Foundation
import LocalOCRIntelligence
import LocalOCRModelCore
import LocalOCRStudioKit
import Testing

@Suite struct StudioIntelligenceViewModelTests {
    @Test @MainActor func operationsStartIdleAndCompleteIndependently() async {
        let provider = ControlledIntelligenceProvider()
        let model = StudioIntelligenceViewModel(provider: provider, availability: .available)
        model.setDocument(document("Invoice 1048"), identity: "invoice-hash")

        #expect(model.summaryState == .idle)
        #expect(model.organizationState == .idle)
        #expect(model.fieldsState == .idle)

        model.summarize()
        await provider.waitForRequest(.summary)
        #expect(model.summaryState == .running)
        #expect(model.organizationState == .idle)
        #expect(model.fieldsState == .idle)

        let summary = IntelligenceSummary(
            text: "An invoice.",
            citations: [IntelligenceCitation(page: 1, quote: "Invoice 1048")]
        )
        await provider.succeedSummary(summary)
        await flushIntelligenceStateUpdates()

        #expect(model.summaryState == .result(summary))
        #expect(model.summaryModel == .appleSystemDefault)
        #expect(model.organizationState == .idle)
        #expect(model.fieldsState == .idle)
    }

    @Test @MainActor func everyOperationRetainsActualResultProvenanceAfterFutureSelectionChanges() async {
        let firstModel = LocalModelProvenance(
            provider: .ollama,
            providerDisplayName: "Ollama",
            model: "gemma4:8b",
            processing: .onDeviceLoopback,
            fingerprint: "sha256:first",
            qualifiedAt: Date(timeIntervalSince1970: 1_788_050_400)
        )
        let provider = ControlledIntelligenceProvider(provenance: firstModel)
        let model = StudioIntelligenceViewModel(provider: provider, availability: .available)
        model.setDocument(document("Invoice 1048"), identity: "invoice-hash")

        model.summarize()
        model.organize()
        model.extractFields()
        await provider.waitForRequest(.summary)
        await provider.waitForRequest(.organization)
        await provider.waitForRequest(.fields)
        await provider.succeedSummary(IntelligenceSummary(
            text: "An invoice.",
            citations: [IntelligenceCitation(page: 1, quote: "Invoice 1048")]
        ))
        await provider.succeedOrganization(OrganizationSuggestion(
            title: "Invoice 1048",
            category: "Finance",
            tags: ["invoice"],
            citations: [IntelligenceCitation(page: 1, quote: "Invoice 1048")]
        ))
        await provider.succeedFields([ExtractedDocumentField(
            name: "reference_number",
            value: "1048",
            sourcePage: 1,
            evidence: "Invoice 1048"
        )])
        await flushIntelligenceStateUpdates()

        await provider.changeFutureProvenance(to: .appleSystemDefault)

        #expect(model.summaryModel == firstModel)
        #expect(model.organizationModel == firstModel)
        #expect(model.fieldsModel == firstModel)
    }

    @Test @MainActor func selectionFailureOffersExplicitRecoveryWithoutReplacingDocumentOrFallingBack() async {
        let identity = LocalModelIdentity(
            provider: .ollama,
            model: "gemma4:8b",
            fingerprint: "sha256:first",
            harnessVersion: "1.0.0"
        )
        let provider = ControlledIntelligenceProvider()
        let model = StudioIntelligenceViewModel(provider: provider, availability: .available)
        model.setDocument(document("Invoice 1048"), identity: "invoice-hash")

        model.summarize()
        await provider.waitForRequest(.summary)
        await provider.failSummary(IntelligenceError.selection(.modelUnavailable(identity)))
        await flushIntelligenceStateUpdates()

        #expect(model.recovery?.failedOperation == .summary)
        #expect(model.recovery?.actions == [.retry, .chooseAnotherLocalModel, .useAppleSystemModel])
        #expect(model.summaryModel == nil)
        #expect(await provider.requests() == [.summary])
    }

    @Test @MainActor func organizationFailureDoesNotReplaceOtherOperationState() async {
        let provider = ControlledIntelligenceProvider()
        let model = StudioIntelligenceViewModel(provider: provider, availability: .available)
        model.setDocument(document("Invoice 1048"), identity: "invoice-hash")

        model.organize()
        await provider.waitForRequest(.organization)
        await provider.failOrganization(TestIntelligenceError.failed)
        await flushIntelligenceStateUpdates()

        #expect(model.organizationState == .failure(StudioPresentedError(
            title: "Local Intelligence Failed",
            message: "Local Intelligence could not finish this request. Please try again.",
            details: nil
        )))
        #expect(model.summaryState == .idle)
        #expect(model.fieldsState == .idle)
    }

    @Test @MainActor func unavailableOperationDoesNotInvokeProvider() async {
        let provider = ControlledIntelligenceProvider()
        let model = StudioIntelligenceViewModel(
            provider: provider,
            availability: .appleIntelligenceNotEnabled
        )
        model.setDocument(document("Invoice 1048"), identity: "invoice-hash")

        model.summarize()
        model.organize()
        model.extractFields()
        await flushIntelligenceStateUpdates()

        #expect(model.summaryState == .unavailable(.appleIntelligenceNotEnabled))
        #expect(model.organizationState == .unavailable(.appleIntelligenceNotEnabled))
        #expect(model.fieldsState == .unavailable(.appleIntelligenceNotEnabled))
        #expect(await provider.requests() == [])
    }

    @Test @MainActor func fieldExtractionUsesFixedDesktopFields() async {
        let provider = ControlledIntelligenceProvider()
        let model = StudioIntelligenceViewModel(provider: provider, availability: .available)
        model.setDocument(document("Invoice 1048"), identity: "invoice-hash")

        model.extractFields()
        await provider.waitForRequest(.fields)

        #expect(await provider.requestedFieldNames() == ["date", "total", "reference_number"])
        #expect(model.fieldsState == .running)
    }

    @Test @MainActor func newDocumentCancelsAndClearsEveryOperation() async {
        let provider = ControlledIntelligenceProvider()
        let model = StudioIntelligenceViewModel(provider: provider, availability: .available)
        model.setDocument(document("First"), identity: "first-hash")
        model.summarize()
        model.organize()
        model.extractFields()
        await provider.waitForRequest(.summary)
        await provider.waitForRequest(.organization)
        await provider.waitForRequest(.fields)

        model.setDocument(document("Second"), identity: "second-hash")
        await provider.waitForCancellation(.summary)
        await provider.waitForCancellation(.organization)
        await provider.waitForCancellation(.fields)

        #expect(model.summaryState == .idle)
        #expect(model.organizationState == .idle)
        #expect(model.fieldsState == .idle)
    }

    @Test @MainActor func staleCompletionCannotOverwriteCurrentDocument() async {
        let provider = ControlledIntelligenceProvider()
        let model = StudioIntelligenceViewModel(provider: provider, availability: .available)
        model.setDocument(document("First"), identity: "first-hash")
        model.summarize()
        await provider.waitForRequest(.summary)

        model.setDocument(document("Second"), identity: "second-hash")
        await provider.succeedSummaryIgnoringCancellation(IntelligenceSummary(
            text: "Old summary",
            citations: [IntelligenceCitation(page: 1, quote: "First")]
        ))
        await flushIntelligenceStateUpdates()

        #expect(model.summaryState == .idle)
    }

    @Test @MainActor func workspaceSwitchAndWindowTeardownClearWithoutInvokingProvider() async {
        let provider = ControlledIntelligenceProvider()
        let model = StudioIntelligenceViewModel(provider: provider, availability: .available)
        model.setDocument(document("Batch must not analyze this"), identity: "single-hash")

        model.clearForWorkspaceSwitch()
        model.summarize()
        model.clearForWindowTeardown()
        await flushIntelligenceStateUpdates()

        #expect(model.summaryState == .idle)
        #expect(model.organizationState == .idle)
        #expect(model.fieldsState == .idle)
        #expect(await provider.requests() == [])
    }
}

private enum IntelligenceOperationRequest: Sendable, Equatable, Hashable {
    case summary
    case organization
    case fields
}

private enum TestIntelligenceError: Error {
    case failed
}

private actor ControlledIntelligenceProvider: DocumentIntelligenceProviding {
    let availability: IntelligenceAvailability = .available

    private var provenance: LocalModelProvenance

    private var recordedRequests: [IntelligenceOperationRequest] = []
    private var fieldNames: [String] = []
    private var summaryContinuation: CheckedContinuation<IntelligenceSummary, any Error>?
    private var organizationContinuation: CheckedContinuation<OrganizationSuggestion, any Error>?
    private var fieldsContinuation: CheckedContinuation<[ExtractedDocumentField], any Error>?
    private var requestWaiters: [IntelligenceOperationRequest: [CheckedContinuation<Void, Never>]] = [:]
    private var cancellations: Set<IntelligenceOperationRequest> = []
    private var cancellationWaiters: [IntelligenceOperationRequest: [CheckedContinuation<Void, Never>]] = [:]

    init(provenance: LocalModelProvenance = .appleSystemDefault) {
        self.provenance = provenance
    }

    func summarize(
        _ document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<IntelligenceSummary> {
        recordedRequests.append(.summary)
        resumeRequestWaiters(.summary)
        let value = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { summaryContinuation = $0 }
        }, onCancel: {
            Task { await self.recordCancellation(.summary) }
        })
        return ProvenancedIntelligenceResult(value: value, model: provenance)
    }

    func organize(
        _ document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<OrganizationSuggestion> {
        recordedRequests.append(.organization)
        resumeRequestWaiters(.organization)
        let value = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { organizationContinuation = $0 }
        }, onCancel: {
            Task { await self.recordCancellation(.organization) }
        })
        return ProvenancedIntelligenceResult(value: value, model: provenance)
    }

    func extract(
        _ names: [String],
        from document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<[ExtractedDocumentField]> {
        recordedRequests.append(.fields)
        fieldNames = names
        resumeRequestWaiters(.fields)
        let value = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { fieldsContinuation = $0 }
        }, onCancel: {
            Task { await self.recordCancellation(.fields) }
        })
        return ProvenancedIntelligenceResult(value: value, model: provenance)
    }

    func requests() -> [IntelligenceOperationRequest] { recordedRequests }
    func requestedFieldNames() -> [String] { fieldNames }

    func waitForRequest(_ operation: IntelligenceOperationRequest) async {
        guard !recordedRequests.contains(operation) else { return }
        await withCheckedContinuation { requestWaiters[operation, default: []].append($0) }
    }

    func waitForCancellation(_ operation: IntelligenceOperationRequest) async {
        guard !cancellations.contains(operation) else { return }
        await withCheckedContinuation { cancellationWaiters[operation, default: []].append($0) }
    }

    func succeedSummary(_ result: IntelligenceSummary) {
        summaryContinuation?.resume(returning: result)
        summaryContinuation = nil
    }

    func failSummary(_ error: any Error) {
        summaryContinuation?.resume(throwing: error)
        summaryContinuation = nil
    }

    func succeedOrganization(_ result: OrganizationSuggestion) {
        organizationContinuation?.resume(returning: result)
        organizationContinuation = nil
    }

    func succeedFields(_ result: [ExtractedDocumentField]) {
        fieldsContinuation?.resume(returning: result)
        fieldsContinuation = nil
    }

    func changeFutureProvenance(to provenance: LocalModelProvenance) {
        self.provenance = provenance
    }

    func succeedSummaryIgnoringCancellation(_ result: IntelligenceSummary) {
        succeedSummary(result)
    }

    func failOrganization(_ error: any Error) {
        organizationContinuation?.resume(throwing: error)
        organizationContinuation = nil
    }

    private func resumeRequestWaiters(_ operation: IntelligenceOperationRequest) {
        let waiters = requestWaiters.removeValue(forKey: operation) ?? []
        waiters.forEach { $0.resume() }
    }

    private func recordCancellation(_ operation: IntelligenceOperationRequest) {
        cancellations.insert(operation)
        let waiters = cancellationWaiters.removeValue(forKey: operation) ?? []
        waiters.forEach { $0.resume() }
    }
}

private func document(_ text: String) -> IntelligenceDocument {
    IntelligenceDocument(pages: [IntelligenceSourcePage(number: 1, text: text)])
}

@MainActor
private func flushIntelligenceStateUpdates() async {
    for _ in 0..<10 { await Task.yield() }
}
