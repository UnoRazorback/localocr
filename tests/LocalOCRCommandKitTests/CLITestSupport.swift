import Foundation
import LocalOCRCore
import LocalOCRCommandKit
import LocalOCRIntelligence
import LocalOCRModelCore
import LocalOCRService

enum FixtureFailure: Error, Sendable {
    case operation
}

enum FixtureBehavior: Sendable {
    case success
    case operationFailure
    case cancellation
}

actor RequestRecorder {
    private(set) var ocrRequests: [PDFOCRRequest] = []
    private(set) var batchRequests: [BatchOCRRequest] = []
    private(set) var imageRequests: [ImageOCRRequest] = []
    private(set) var searchableRequests: [SearchablePDFRequest] = []

    func record(_ request: PDFOCRRequest) { ocrRequests.append(request) }
    func record(_ request: BatchOCRRequest) { batchRequests.append(request) }
    func record(_ request: ImageOCRRequest) { imageRequests.append(request) }
    func record(_ request: SearchablePDFRequest) { searchableRequests.append(request) }

    func lastOCRRequest() -> PDFOCRRequest? { ocrRequests.last }
    func lastBatchRequest() -> BatchOCRRequest? { batchRequests.last }
    func lastImageRequest() -> ImageOCRRequest? { imageRequests.last }
    func lastSearchableRequest() -> SearchablePDFRequest? { searchableRequests.last }
    func hasOCRRequests() -> Bool { !ocrRequests.isEmpty }
}

struct FixtureService: LocalOCRServing {
    let inspect: InspectPDFResponse
    let ocr: PDFOCRResponse
    let batch: BatchOCRResponse
    let image: ImageOCRResponse
    let searchable: SearchablePDFResponse
    let behavior: FixtureBehavior
    let recorder: RequestRecorder

    init(
        inspect: InspectPDFResponse = .fixture,
        ocr: PDFOCRResponse = .fixture,
        batch: BatchOCRResponse = .fixture,
        image: ImageOCRResponse = .fixture,
        searchable: SearchablePDFResponse = .fixture,
        behavior: FixtureBehavior = .success,
        recorder: RequestRecorder = RequestRecorder()
    ) {
        self.inspect = inspect
        self.ocr = ocr
        self.batch = batch
        self.image = image
        self.searchable = searchable
        self.behavior = behavior
        self.recorder = recorder
    }

    func pageCount(at fileURL: URL) async throws -> PageCountResponse {
        PageCountResponse(pages: 2)
    }

    func inspectPDF(at fileURL: URL) async throws -> InspectPDFResponse {
        try throwIfNeeded()
        return inspect
    }

    func ocrPDF(
        _ request: PDFOCRRequest,
        progress: @escaping @Sendable (OCRProgress) -> Void
    ) async throws -> PDFOCRResponse {
        await recorder.record(request)
        try throwIfNeeded()
        progress(.inspecting)
        progress(.completed)
        return ocr
    }

    func ocrPDFBatch(
        _ request: BatchOCRRequest,
        progress: @escaping @Sendable (BatchProgress) -> Void
    ) async -> BatchOCRResponse {
        await recorder.record(request)
        progress(BatchProgress(currentItem: 1, totalItems: request.fileURLs.count, sourcePath: request.fileURLs[0].path, progress: .inspecting))
        return batch
    }

    func ocrImage(_ request: ImageOCRRequest) async throws -> ImageOCRResponse {
        await recorder.record(request)
        try throwIfNeeded()
        return image
    }

    func makeSearchablePDF(
        _ request: SearchablePDFRequest,
        progress: @escaping @Sendable (OCRProgress) -> Void
    ) async throws -> SearchablePDFResponse {
        await recorder.record(request)
        try throwIfNeeded()
        progress(.inspecting)
        return searchable
    }

    private func throwIfNeeded() throws {
        switch behavior {
        case .success: return
        case .operationFailure: throw FixtureFailure.operation
        case .cancellation: throw CancellationError()
        }
    }
}

extension InspectPDFResponse {
    static let fixture = InspectPDFResponse(
        sourcePath: "/tmp/input.pdf",
        sourceSHA256: "abc",
        pages: 2,
        searchablePages: 1,
        ocrNeededPages: 1,
        characters: 42,
        fullySearchable: false,
        pageDetails: [
            PageInspectionResponse(page: 1, characters: 42, searchable: true),
            PageInspectionResponse(page: 2, characters: 0, searchable: false)
        ]
    )
}

extension PDFOCRResponse {
    static let fixture = PDFOCRResponse(
        sourcePath: "/tmp/input.pdf",
        sourceSHA256: "abc",
        pages: [OCRPageResponse(page: 1, text: "Hello", method: .existingText, lines: nil)],
        failedPages: [],
        emptyOCRPages: [],
        rotatedOCRPages: []
    )
}

extension BatchOCRResponse {
    static let fixture = BatchOCRResponse(processed: 0, succeeded: 0, failed: 0, results: [])
}

extension ImageOCRResponse {
    static let fixture = ImageOCRResponse(text: "recognized image text")
}

extension SearchablePDFResponse {
    static let fixture = SearchablePDFResponse(outputPath: "/tmp/output.pdf", failedPages: [])
}

private final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var stdout = ""
    private(set) var stderr = ""

    func appendStdout(_ text: String) {
        lock.withLock { stdout += text }
    }

    func appendStderr(_ text: String) {
        lock.withLock { stderr += text }
    }

    func readStdout() -> String {
        lock.withLock { stdout }
    }

    func readStderr() -> String {
        lock.withLock { stderr }
    }
}

final class CLIHarness: @unchecked Sendable {
    private let capture = OutputCapture()
    private let application: CLIApplication

    init(service: any LocalOCRServing) {
        application = CLIApplication(
            service: service,
            output: CommandOutput(
                stdout: { [capture] text in capture.appendStdout(text) },
                stderr: { [capture] text in capture.appendStderr(text) }
            )
        )
    }

    init(
        service: any LocalOCRServing,
        consentStore: any ExternalDataConsentStoring,
        consentIO: any ConsentCommandIO
    ) {
        application = CLIApplication(
            service: service,
            output: CommandOutput(
                stdout: { [capture] text in capture.appendStdout(text) },
                stderr: { [capture] text in capture.appendStderr(text) }
            ),
            consentStore: consentStore,
            consentIO: consentIO
        )
    }

    init(
        service: any LocalOCRServing,
        intelligenceManager: any LocalIntelligenceManaging,
        consentStore: any ExternalDataConsentStoring = FixtureConsentStore(),
        consentIO: any ConsentCommandIO = FixtureConsentIO(isTerminal: false, answers: []),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        application = CLIApplication(
            service: service,
            output: CommandOutput(
                stdout: { [capture] text in capture.appendStdout(text) },
                stderr: { [capture] text in capture.appendStderr(text) }
            ),
            consentStore: consentStore,
            consentIO: consentIO,
            intelligenceManager: intelligenceManager,
            now: now
        )
    }

    var stdout: String {
        capture.readStdout()
    }

    var stderr: String {
        capture.readStderr()
    }

    func stdoutJSON() -> [String: Any] {
        let data = Data(stdout.utf8)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func run(_ arguments: [String]) async -> Int32 {
        await application.run(arguments: arguments)
    }
}

enum FixtureIntelligenceManagerBehavior: Sendable {
    case success
    case operationalFailure
    case cancellation
    case intelligenceFailure(IntelligenceError)
}

actor FixtureIntelligenceManager: LocalIntelligenceManaging {
    private var descriptors: [LocalModelDescriptor]
    private var selectionState: LocalIntelligenceSelectionState
    private let qualificationOutcomes: [LocalModelIdentity: LocalModelQualificationOutcome]
    private let qualifyBehavior: FixtureIntelligenceManagerBehavior
    private let selectBehavior: FixtureIntelligenceManagerBehavior
    private let resetBehavior: FixtureIntelligenceManagerBehavior
    private var modelsCallCount = 0
    private var qualifyIdentities: [LocalModelIdentity] = []
    private var selectedAppleCount = 0
    private var selectedExternalValues: [(LocalModelIdentity, Date)] = []
    private var resetCount = 0
    private var statusCallCount = 0

    init(
        descriptors: [LocalModelDescriptor],
        selectionState: LocalIntelligenceSelectionState = .none,
        qualificationOutcomes: [LocalModelIdentity: LocalModelQualificationOutcome] = [:],
        qualifyBehavior: FixtureIntelligenceManagerBehavior = .success,
        selectBehavior: FixtureIntelligenceManagerBehavior = .success,
        resetBehavior: FixtureIntelligenceManagerBehavior = .success
    ) {
        self.descriptors = descriptors
        self.selectionState = selectionState
        self.qualificationOutcomes = qualificationOutcomes
        self.qualifyBehavior = qualifyBehavior
        self.selectBehavior = selectBehavior
        self.resetBehavior = resetBehavior
    }

    func models() async -> [LocalModelDescriptor] {
        modelsCallCount += 1
        return descriptors
    }

    func qualify(_ identity: LocalModelIdentity) async throws -> LocalModelQualificationOutcome {
        try throwForBehavior(qualifyBehavior)
        qualifyIdentities.append(identity)
        return qualificationOutcomes[identity] ?? LocalModelQualificationOutcome(
            status: .failed,
            receipt: nil,
            failures: ["fixture_failure"]
        )
    }

    func selectApple() async throws {
        try throwForBehavior(selectBehavior)
        selectedAppleCount += 1
        selectionState = .selected(.appleSystemDefault)
    }

    func selectExternal(
        _ identity: LocalModelIdentity,
        acknowledgmentAcceptedAt: Date
    ) async throws {
        try throwForBehavior(selectBehavior)
        selectedExternalValues.append((identity, acknowledgmentAcceptedAt))
    }

    func status() async -> LocalIntelligenceSelectionState {
        statusCallCount += 1
        return selectionState
    }

    func reset() async throws {
        try throwForBehavior(resetBehavior)
        resetCount += 1
        selectionState = .none
    }

    func modelCalls() -> Int { modelsCallCount }
    func qualifiedIdentities() -> [LocalModelIdentity] { qualifyIdentities }
    func appleSelections() -> Int { selectedAppleCount }
    func externalSelections() -> [(LocalModelIdentity, Date)] { selectedExternalValues }
    func resets() -> Int { resetCount }
    func statusCalls() -> Int { statusCallCount }

    private func throwForBehavior(_ behavior: FixtureIntelligenceManagerBehavior) throws {
        switch behavior {
        case .success:
            return
        case .operationalFailure:
            throw FixtureFailure.operation
        case .cancellation:
            throw CancellationError()
        case let .intelligenceFailure(error):
            throw error
        }
    }
}

extension LocalModelDescriptor {
    static let fixtureApple = LocalModelDescriptor(
        identity: .appleSystemDefault,
        displayName: "Apple Foundation Models — system default",
        locality: .verifiedLocal,
        localityReason: "Built into macOS and runs on device.",
        qualification: .passed,
        available: true,
        selected: false
    )

    static let fixtureOllama = LocalModelDescriptor(
        identity: LocalModelIdentity(
            provider: .ollama,
            model: "gemma4:8b",
            fingerprint: "sha256:abc",
            harnessVersion: "0.13.0"
        ),
        displayName: "Gemma 4 8B",
        locality: .verifiedLocal,
        localityReason: "Verified local Ollama model.",
        qualification: .passed,
        available: true,
        selected: false
    )
}

actor FixtureConsentStore: ExternalDataConsentStoring {
    private var storedStatus: ExternalDataConsentStatus
    private var statusCallCount = 0
    private var acceptedDates: [Date] = []
    private var revokeCount = 0

    init(status: ExternalDataConsentStatus = .required) {
        storedStatus = status
    }

    func status() async -> ExternalDataConsentStatus {
        statusCallCount += 1
        return storedStatus
    }

    func acceptBothStatements(at date: Date) async throws {
        acceptedDates.append(date)
        storedStatus = .current(
            ExternalDataConsentReceipt(
                schemaVersion: ExternalDataConsentReceipt.currentSchemaVersion,
                policyVersion: ExternalDataConsentReceipt.currentPolicyVersion,
                acceptedAt: date,
                externalProviderRiskAccepted: true,
                documentToolAccessAccepted: true
            )
        )
    }

    func revoke() async throws {
        revokeCount += 1
        storedStatus = .required
    }

    func acceptanceCount() -> Int { acceptedDates.count }
    func revocations() -> Int { revokeCount }
    func statusCalls() -> Int { statusCallCount }
}

actor FailingConsentStore: ExternalDataConsentStoring {
    func status() async -> ExternalDataConsentStatus {
        .required
    }

    func acceptBothStatements(at date: Date) async throws {
        throw FixtureFailure.operation
    }

    func revoke() async throws {
        throw FixtureFailure.operation
    }
}

final class FixtureConsentIO: @unchecked Sendable, ConsentCommandIO {
    private let lock = NSLock()
    let isTerminal: Bool
    private var answers: [String?]
    private var capturedStdout = ""
    private var capturedStderr = ""
    private var readLineCallCount = 0

    init(isTerminal: Bool, answers: [String?]) {
        self.isTerminal = isTerminal
        self.answers = answers
    }

    func readLine() -> String? {
        lock.withLock {
            readLineCallCount += 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    var hasPendingInput: Bool {
        lock.withLock { !answers.isEmpty }
    }

    func stdout(_ text: String) {
        lock.withLock { capturedStdout += text }
    }

    func stderr(_ text: String) {
        lock.withLock { capturedStderr += text }
    }

    var stdoutText: String {
        lock.withLock { capturedStdout }
    }

    var stderrText: String {
        lock.withLock { capturedStderr }
    }

    var readLineCalls: Int {
        lock.withLock { readLineCallCount }
    }
}

final class FixtureBridgeLocator: @unchecked Sendable, ModelBridgeExecutableLocating {
    private let lock = NSLock()
    private var count = 0

    func executableURL() throws -> URL {
        lock.withLock { count += 1 }
        throw ModelBridgeExecutableLocatorError.helperNotFound
    }

    var resolutionCount: Int {
        lock.withLock { count }
    }
}

let fixtureQualificationDate = Date(timeIntervalSince1970: 1_725_000_000)

func fixtureQualificationReceipt(
    identity: LocalModelIdentity = LocalModelDescriptor.fixtureOllama.identity,
    qualifiedAt: Date = fixtureQualificationDate
) -> LocalModelQualificationReceipt {
    LocalModelQualificationReceipt(
        policyVersion: LocalModelQualificationReceipt.currentPolicyVersion,
        fixtureVersion: LocalModelQualificationReceipt.currentFixtureVersion,
        identity: identity,
        passedActions: Set(LocalIntelligenceAction.allCases),
        qualifiedAt: qualifiedAt
    )
}

func fixtureExternalSelection(
    identity: LocalModelIdentity = LocalModelDescriptor.fixtureOllama.identity,
    acceptedAt: Date = fixtureQualificationDate.addingTimeInterval(60)
) -> LocalIntelligenceSelection {
    .external(
        identity: identity,
        qualification: fixtureQualificationReceipt(identity: identity),
        acknowledgment: ExternalLocalModelAcknowledgment(
            policyVersion: ExternalLocalModelAcknowledgment.currentPolicyVersion,
            identity: identity,
            acceptedAt: acceptedAt
        )
    )
}

func fixtureDescriptor(
    identity: LocalModelIdentity = LocalModelDescriptor.fixtureOllama.identity,
    locality: LocalModelLocality = .verifiedLocal,
    localityReason: String = "Verified local Ollama model.",
    qualification: LocalModelQualificationStatus = .passed,
    available: Bool = true,
    selected: Bool = false
) -> LocalModelDescriptor {
    LocalModelDescriptor(
        identity: identity,
        displayName: identity.model == "gemma4:8b" ? "Gemma 4 8B" : identity.model,
        locality: locality,
        localityReason: localityReason,
        qualification: qualification,
        available: available,
        selected: selected
    )
}
