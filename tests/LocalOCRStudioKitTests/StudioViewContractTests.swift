import Darwin
import Foundation
import LocalOCRIntelligence
import LocalOCRModelCore
@testable import LocalOCRStudioKit
import Testing

@Suite struct StudioViewContractTests {
    @Test func searchablePDFBusyStateDisablesResultFooterActions() {
        let availability = StudioResultActionAvailability(
            isCreatingSearchablePDF: true
        )

        #expect(availability.footerActionsAreEnabled == false)
    }

    @Test func emptyInvitesOneLocalDocumentWithoutOfferingActions() {
        let contract = StudioViewContract(state: .empty)

        #expect(contract.primaryTitle == "Drop a document here")
        #expect(contract.statusText == "PDF or image • Processed locally on this Mac.")
        #expect(contract.canCopy == false)
        #expect(contract.canSaveText == false)
        #expect(contract.canCreateSearchablePDF == false)
        #expect(contract.canProcessAnotherDocument == false)
        #expect(contract.canCancel == false)
        #expect(contract.canRetry == false)
    }

    @Test func processingNamesTheDocumentAndKeepsTheLocalProcessingPromiseVisible() {
        let sourceURL = URL(fileURLWithPath: "/tmp/Client Notes.pdf")
        let contract = StudioViewContract(
            state: .processing(
                sourceURL: sourceURL,
                progress: .recognizing(page: 2, total: 4)
            )
        )

        #expect(contract.primaryTitle == "Client Notes.pdf")
        #expect(contract.statusText == "Recognizing page 2 of 4 • Processing locally on this Mac.")
        #expect(contract.canCopy == false)
        #expect(contract.canSaveText == false)
        #expect(contract.canCreateSearchablePDF == false)
        #expect(contract.canProcessAnotherDocument == false)
        #expect(contract.canCancel == true)
        #expect(contract.canRetry == false)
    }

    @Test func pdfResultOffersEveryDocumentAction() {
        let contract = StudioViewContract(
            state: .result(result(kind: .pdf, pageCount: 4))
        )

        #expect(contract.primaryTitle == "Quarterly Report.pdf")
        #expect(contract.statusText == "4 pages • 3 already searchable • 1 recognized")
        #expect(contract.canCopy == true)
        #expect(contract.canSaveText == true)
        #expect(contract.canCreateSearchablePDF == true)
        #expect(contract.canProcessAnotherDocument == true)
        #expect(contract.canCancel == false)
        #expect(contract.canRetry == false)
    }

    @Test func imageResultDoesNotOfferSearchablePDF() {
        let contract = StudioViewContract(
            state: .result(
                result(
                    kind: .image,
                    pageCount: 1,
                    searchablePages: 0,
                    ocrNeededPages: 1
                )
            )
        )

        #expect(contract.primaryTitle == "Quarterly Report.pdf")
        #expect(contract.statusText == "Image • Text ready")
        #expect(contract.canCopy == true)
        #expect(contract.canSaveText == true)
        #expect(contract.canCreateSearchablePDF == false)
        #expect(contract.canProcessAnotherDocument == true)
        #expect(contract.canCancel == false)
        #expect(contract.canRetry == false)
    }

    @Test func failureOffersRecoveryWithoutDocumentActions() {
        let sourceURL = URL(fileURLWithPath: "/tmp/damaged.pdf")
        let error = StudioPresentedError(
            title: "Couldn’t Read Document",
            message: "This document appears to be damaged or unreadable.",
            details: nil
        )
        let contract = StudioViewContract(state: .failure(sourceURL: sourceURL, error))

        #expect(contract.primaryTitle == "Couldn’t Read Document")
        #expect(contract.statusText == "This document appears to be damaged or unreadable.")
        #expect(contract.canCopy == false)
        #expect(contract.canSaveText == false)
        #expect(contract.canCreateSearchablePDF == false)
        #expect(contract.canProcessAnotherDocument == false)
        #expect(contract.canCancel == false)
        #expect(contract.canRetry == true)
    }

    // Catches Studio composition that drops its role before the shared router writes a lease.
    @Test func studioRouterWritesOneIndependentStudioLease() async throws {
        let fixture = try StudioActivityFixture()
        defer { fixture.remove() }
        let provider = StudioActivityProvider()
        let router = studioRouter(provider: provider, reporter: fixture.reporter)

        let result = try await router.summarize(studioActivityDocument)
        let files = try fixture.activityFiles(in: "recent")
        let records = try files.map { try LocalAIActivityContract.decode(Data(contentsOf: $0)) }

        #expect(result.value.text == "Studio result remains available.")
        #expect(try fixture.activityFiles(in: "active").isEmpty)
        #expect(records.count == 1)
        #expect(records.first?.producerRole == .studio)
        #expect(records.first?.productTask == .summarize)
        #expect(records.first?.outcome == .success)
        #expect(files.first?.deletingPathExtension().lastPathComponent.lowercased()
            == records.first?.activityID.uuidString.lowercased())
    }

    // Catches reporting availability replacing the Studio model result shown to the user.
    @Test @MainActor func studioResultSurvivesReporterWriteFailure() async {
        let reporter = LocalAIActivityReporter(
            ledger: StudioFailingActivityLedger(),
            clock: SystemLocalAIActivityClock()
        )
        let router = studioRouter(provider: StudioActivityProvider(), reporter: reporter)
        let model = StudioIntelligenceViewModel(provider: router, availability: .available)
        model.setDocument(studioActivityDocument, identity: "studio-fixture")

        model.summarize()
        for _ in 0..<100 {
            if model.summaryState != .running { break }
            await Task.yield()
        }

        #expect(model.summaryState == .result(IntelligenceSummary(
            text: "Studio result remains available.",
            citations: [.init(page: 1, quote: "Private Studio fixture")]
        )))
    }
}

private func result(
    kind: StudioDocumentKind,
    pageCount: Int,
    searchablePages: Int = 3,
    ocrNeededPages: Int = 1
) -> StudioDocumentResult {
    StudioDocumentResult(
        sourceURL: URL(fileURLWithPath: "/tmp/Quarterly Report.pdf"),
        sourceSHA256: "fixture-hash",
        kind: kind,
        pageCount: pageCount,
        searchablePages: searchablePages,
        ocrNeededPages: ocrNeededPages,
        text: "Recognized text",
        failedPages: []
    )
}

private let studioActivityDocument = IntelligenceDocument(pages: [
    .init(number: 1, text: "Private Studio fixture")
])

private func studioRouter(
    provider: any DocumentIntelligenceProviding,
    reporter: any LocalAIActivityReporting
) -> LocalIntelligenceProviderRouter {
    LocalIntelligenceProviderRouter(
        selectionStore: StudioActivitySelectionStore(),
        transport: StdioModelBridgeClient(),
        appleProviderFactory: { provider },
        activityReporter: reporter,
        producerRole: .studio,
        platform: .macos
    )
}

private actor StudioActivitySelectionStore: LocalIntelligenceSelectionStoring {
    func state() async -> LocalIntelligenceSelectionState { .selected(.appleSystemDefault) }
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

private actor StudioActivityProvider: DocumentIntelligenceProviding {
    nonisolated let availability: IntelligenceAvailability = .available

    func summarize(
        _ document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<IntelligenceSummary> {
        _ = document
        return .init(
            value: .init(
                text: "Studio result remains available.",
                citations: [.init(page: 1, quote: "Private Studio fixture")]
            ),
            model: .appleSystemDefault
        )
    }

    func organize(
        _ document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<OrganizationSuggestion> {
        _ = document
        return .init(value: .init(title: "", category: "", tags: [], citations: []), model: .appleSystemDefault)
    }

    func extract(
        _ names: [String],
        from document: IntelligenceDocument
    ) async throws -> ProvenancedIntelligenceResult<[ExtractedDocumentField]> {
        _ = names
        _ = document
        return .init(value: [], model: .appleSystemDefault)
    }
}

private actor StudioFailingActivityLedger: LocalAIActivityLedgerWriting {
    func begin(_ descriptor: LocalAIActivityDescriptor) async throws -> UUID {
        _ = descriptor
        throw StudioActivityError.unavailable
    }
    func heartbeat(_ activityID: UUID) async throws { _ = activityID }
    func end(_ activityID: UUID, outcome: LocalAIActivityOutcome) async throws {
        _ = activityID
        _ = outcome
    }
    func cleanupExpired() async {}
}

private enum StudioActivityError: Error {
    case unavailable
}

private final class StudioActivityFixture: @unchecked Sendable {
    let containerURL: URL
    let reporter: LocalAIActivityReporter

    init() throws {
        containerURL = FileManager.default.temporaryDirectory.appending(
            path: "LocalOCR-studio-activity-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: false)
        guard chmod(containerURL.path, 0o700) == 0 else { throw StudioActivityError.unavailable }
        let clock = SystemLocalAIActivityClock()
        reporter = LocalAIActivityReporter(
            ledger: LocalAIActivityLedger(containerURL: containerURL, clock: clock),
            clock: clock
        )
    }

    func activityFiles(in directory: String) throws -> [URL] {
        let url = containerURL
            .appending(path: "LocalAIActivity/v1", directoryHint: .isDirectory)
            .appending(path: directory, directoryHint: .isDirectory)
        return try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
    }

    func remove() {
        try? FileManager.default.removeItem(at: containerURL)
    }
}
