import Foundation
import LocalOCRCore
import LocalOCRIntelligence
import LocalOCRService
import MCP
@testable import LocalOCRMCP
import Testing

@Suite struct MCPToolDispatcherTests {
    private let currentDirectory = URL(fileURLWithPath: "/tmp/localocr-dispatch", isDirectory: true)

    @Test func dispatcherMapsPDFDefaultsAndReturnsMatchingCanonicalObjectContent() async throws {
        let service = FakeOCRService()
        let dispatcher = makeDispatcher(service: service, currentDirectory: currentDirectory)

        let result = await dispatcher.callTool(
            name: "ocr_pdf",
            arguments: ["file_path": "partial.pdf"]
        )

        let request = try #require(await service.lastPDFRequest())
        #expect(request.fileURL.path == "/tmp/localocr-dispatch/partial.pdf")
        #expect(request.dpi == 250)
        #expect(request.forceOCR == false)
        #expect(request.includeLines == false)
        #expect(result.isError == nil)
        #expect(result.structuredContent?.objectValue?["failed_pages"] == .array([.int(2)]))
        #expect(text(in: result) == "{\"empty_ocr_pages\":[],\"failed_pages\":[2],\"pages\":[{\"method\":\"existing_text\",\"page\":1,\"text\":\"found text\"}],\"rotated_ocr_pages\":[],\"source_path\":\"/tmp/localocr-dispatch/partial.pdf\",\"source_sha256\":\"abc\"}")
    }

    @Test func dispatcherPreservesLegacyScalarResults() async {
        let service = FakeOCRService()
        let dispatcher = makeDispatcher(service: service, currentDirectory: currentDirectory)

        let count = await dispatcher.callTool(name: "get_pdf_page_count", arguments: ["file_path": "input.pdf"])
        let image = await dispatcher.callTool(name: "ocr_image", arguments: ["file_path": "scan.png"])

        #expect(text(in: count) == "3")
        #expect(count.structuredContent == nil)
        #expect(text(in: image) == "image text")
        #expect(image.structuredContent == nil)
        #expect(await service.pageCountURL()?.path == "/tmp/localocr-dispatch/input.pdf")
        #expect(await service.imageURL()?.path == "/tmp/localocr-dispatch/scan.png")
    }

    @Test func dispatcherMapsInspectionAndSearchablePDFDefaults() async throws {
        let service = FakeOCRService()
        let dispatcher = makeDispatcher(service: service, currentDirectory: currentDirectory)

        let inspection = await dispatcher.callTool(name: "inspect_pdf", arguments: ["file_path": "input.pdf"])
        let searchable = await dispatcher.callTool(name: "make_searchable_pdf", arguments: ["file_path": "input.pdf"])

        #expect(await service.inspectURL()?.path == "/tmp/localocr-dispatch/input.pdf")
        #expect(inspection.structuredContent?.objectValue?["searchable_pages"] == .int(1))
        #expect(text(in: inspection) == "{\"characters\":10,\"fully_searchable\":true,\"ocr_needed_pages\":0,\"page_details\":[{\"characters\":10,\"page\":1,\"searchable\":true}],\"pages\":1,\"searchable_pages\":1,\"source_path\":\"/tmp/localocr-dispatch/input.pdf\",\"source_sha256\":\"inspect\"}")
        let searchableRequest = try #require(await service.searchableRequest())
        #expect(searchableRequest.fileURL.path == "/tmp/localocr-dispatch/input.pdf")
        #expect(searchableRequest.outputURL == nil)
        #expect(searchableRequest.dpi == 250)
        #expect(searchableRequest.forceOCR == false)
        #expect(searchable.structuredContent?.objectValue?["output_path"] == .string("/tmp/localocr-dispatch/input_searchable.pdf"))
    }

    @Test func dispatcherReturnsPartialBatchAndDoesNotThrowServiceErrors() async throws {
        let service = FakeOCRService()
        let dispatcher = makeDispatcher(service: service, currentDirectory: currentDirectory)

        let batch = await dispatcher.callTool(
            name: "ocr_pdf_batch",
            arguments: ["file_paths": ["good.pdf", "bad.pdf"], "include_lines": true]
        )
        let batchRequest = try #require(await service.lastBatchRequest())
        #expect(batchRequest.fileURLs.map(\.path) == ["/tmp/localocr-dispatch/good.pdf", "/tmp/localocr-dispatch/bad.pdf"])
        #expect(batchRequest.pageRange == nil)
        #expect(batchRequest.dpi == 250)
        #expect(batchRequest.forceOCR == false)
        #expect(batchRequest.includeLines == true)
        #expect(batch.structuredContent?.objectValue?["failed"] == .int(1))
        #expect(batch.structuredContent?.objectValue?["results"]?.arrayValue?.count == 2)

        await service.setFailure(.outputExists)
        let failure = await dispatcher.callTool(name: "make_searchable_pdf", arguments: ["file_path": "input.pdf"])
        #expect(failure.isError == true)
        #expect(text(in: failure) == "{\"error\":{\"code\":\"output_exists\",\"message\":\"The output file already exists.\"}}")
    }

    @Test func dispatcherReturnsStableErrorsForInvalidAndUnknownCalls() async {
        let dispatcher = makeDispatcher(service: FakeOCRService(), currentDirectory: currentDirectory)

        let invalid = await dispatcher.callTool(name: "ocr_pdf", arguments: ["file_path": "input.pdf", "dpi": 601])
        let unknown = await dispatcher.callTool(name: "missing_tool", arguments: [:])

        #expect(invalid.isError == true)
        #expect(text(in: invalid) == "{\"error\":{\"code\":\"invalid_arguments\",\"message\":\"dpi must be an integer from 72 through 600\"}}")
        #expect(unknown.isError == true)
        #expect(text(in: unknown) == "{\"error\":{\"code\":\"unknown_tool\",\"message\":\"unknown tool: missing_tool\"}}")
    }

    @Test func dispatcherMapsEveryStableLocalOCRErrorCode() async {
        let service = FakeOCRService()
        let dispatcher = makeDispatcher(service: service, currentDirectory: currentDirectory)
        let cases: [(LocalOCRError, String)] = [
            (.fileNotFound, "file_not_found"),
            (.permissionDenied, "file_not_readable"),
            (.unsupportedFormat("txt"), "unsupported_format"),
            (.unreadablePDF, "invalid_pdf"),
            (.invalidPageSelection("0"), "invalid_page_range"),
            (.invalidDestination, "invalid_output"),
            (.outputExists, "output_exists"),
            (.imageDecodeFailed, "image_decode_failed"),
            (.cancelled, "cancelled"),
            (.rasterizationFailed(page: 1), "processing_failed")
        ]

        for (error, code) in cases {
            await service.setFailure(error)
            let result = await dispatcher.callTool(name: "ocr_image", arguments: ["file_path": "scan.png"])
            #expect(result.isError == true)
            #expect(errorCode(in: result) == code)
        }
    }

    @Test func dispatcherInitializationAndStaticCatalogDoNotReadConsent() async {
        let consent = FakeConsentStore(.required)

        _ = MCPToolDispatcher(
            service: FakeOCRService(),
            textLoader: FakeTextLoader(),
            intelligence: FakeIntelligenceProvider(),
            consentStore: consent,
            currentDirectory: currentDirectory
        )
        _ = MCPToolCatalog.tools

        #expect(await consent.statusReadCount() == 0)
    }

    @Test func unknownToolsAndInvalidArgumentsReturnBeforeConsentIsRead() async {
        let consent = FakeConsentStore(.required)
        let dispatcher = makeDispatcher(consentStore: consent, currentDirectory: currentDirectory)

        let unknown = await dispatcher.callTool(name: "missing_tool", arguments: [:])
        let invalid = await dispatcher.callTool(
            name: "extract_document_fields",
            arguments: ["file_path": "form.pdf", "fields": ["date", " date "]]
        )

        #expect(errorCode(in: unknown) == "unknown_tool")
        #expect(errorCode(in: invalid) == "invalid_arguments")
        #expect(await consent.statusReadCount() == 0)
    }

    @Test func everyValidDocumentToolFailsClosedBeforeAnyOperationalDependencyAccess() async {
        let service = FakeOCRService()
        let loader = FakeTextLoader()
        let intelligence = FakeIntelligenceProvider()
        let consent = FakeConsentStore(.required)
        let dispatcher = makeDispatcher(
            service: service,
            textLoader: loader,
            intelligence: intelligence,
            consentStore: consent,
            currentDirectory: currentDirectory
        )
        let calls: [(String, [String: Value])] = [
            ("get_pdf_page_count", ["file_path": "input.pdf"]),
            ("inspect_pdf", ["file_path": "input.pdf"]),
            ("make_searchable_pdf", ["file_path": "input.pdf"]),
            ("ocr_image", ["file_path": "input.png"]),
            ("ocr_pdf", ["file_path": "input.pdf"]),
            ("ocr_pdf_batch", ["file_paths": ["input.pdf"]]),
            ("organize_document", ["file_path": "input.pdf"]),
            ("summarize_document", ["file_path": "input.pdf"]),
            ("extract_document_fields", ["file_path": "input.pdf", "fields": ["date"]]),
        ]
        let expected = "{\"error\":{\"code\":\"external_data_acknowledgment_required\",\"message\":\"Accept the LocalOCR MCP external-data acknowledgment in LocalOCR Studio Help or with `localocr mcp-consent accept`, then retry.\"}}"

        for (name, arguments) in calls {
            let result = await dispatcher.callTool(name: name, arguments: arguments)
            #expect(result.isError == true)
            #expect(text(in: result) == expected)
        }

        #expect(await consent.statusReadCount() == 9)
        #expect(await service.totalCallCount() == 0)
        #expect(await loader.loadCount() == 0)
        #expect(await intelligence.operationCount() == 0)
    }

    @Test func currentConsentDispatchesEachPurposeLimitedIntelligenceOperationWithStructuredResults() async throws {
        let service = FakeOCRService()
        let loader = FakeTextLoader()
        let intelligence = FakeIntelligenceProvider()
        let consent = FakeConsentStore(.current(currentConsentReceipt))
        let dispatcher = makeDispatcher(
            service: service,
            textLoader: loader,
            intelligence: intelligence,
            consentStore: consent,
            currentDirectory: currentDirectory
        )

        let summary = await dispatcher.callTool(
            name: "summarize_document",
            arguments: ["file_path": "summary.pdf"]
        )
        let organization = await dispatcher.callTool(
            name: "organize_document",
            arguments: ["file_path": "organization.png"]
        )
        let extraction = await dispatcher.callTool(
            name: "extract_document_fields",
            arguments: ["file_path": "form.pdf", "fields": [" date ", "total"]]
        )

        #expect(text(in: summary) == "{\"citations\":[{\"page\":1,\"quote\":\"Invoice total\"}],\"text\":\"A short summary.\"}")
        #expect(summary.structuredContent?.objectValue?["text"] == .string("A short summary."))
        #expect(text(in: organization) == "{\"category\":\"Finance\",\"citations\":[{\"page\":1,\"quote\":\"Invoice total\"}],\"tags\":[\"invoice\",\"paid\"],\"title\":\"Paid invoice\"}")
        #expect(organization.structuredContent?.objectValue?["category"] == .string("Finance"))
        #expect(text(in: extraction) == "{\"fields\":[{\"evidence\":null,\"name\":\"date\",\"source_page\":null,\"value\":null},{\"evidence\":\"Total: $19.00\",\"name\":\"total\",\"source_page\":1,\"value\":\"$19.00\"}]}")
        let extractedFields = extraction.structuredContent?.objectValue?["fields"]?.arrayValue
        #expect(extractedFields?.count == 2)
        #expect(extractedFields?.first?.objectValue?["value"] == .null)
        #expect(await loader.loadedPaths().map(\.path) == [
            "/tmp/localocr-dispatch/summary.pdf",
            "/tmp/localocr-dispatch/organization.png",
            "/tmp/localocr-dispatch/form.pdf",
        ])
        #expect(await intelligence.operations() == [
            .summarize,
            .organize,
            .extract(["date", "total"]),
        ])
        #expect(await service.totalCallCount() == 0)
        #expect(await consent.statusReadCount() == 3)
    }

    @Test func revokingConsentBetweenCallsImmediatelyBlocksTheNextCall() async {
        let service = FakeOCRService()
        let consent = FakeConsentStore(.current(currentConsentReceipt))
        let dispatcher = makeDispatcher(
            service: service,
            consentStore: consent,
            currentDirectory: currentDirectory
        )

        let allowed = await dispatcher.callTool(
            name: "get_pdf_page_count",
            arguments: ["file_path": "first.pdf"]
        )
        await consent.setStatus(.required)
        let blocked = await dispatcher.callTool(
            name: "get_pdf_page_count",
            arguments: ["file_path": "second.pdf"]
        )

        #expect(text(in: allowed) == "3")
        #expect(errorCode(in: blocked) == "external_data_acknowledgment_required")
        #expect(await consent.statusReadCount() == 2)
        #expect(await service.totalCallCount() == 1)
        #expect(await service.pageCountURL()?.lastPathComponent == "first.pdf")
    }

    @Test func dispatcherMapsEveryIntelligenceFailureToStableContentFreeActionableErrors() async {
        let provider = FakeIntelligenceProvider()
        let dispatcher = makeDispatcher(
            intelligence: provider,
            currentDirectory: currentDirectory
        )
        let cases: [(IntelligenceError, String, String)] = [
            (.unavailable(.requiresMacOS26), "local_intelligence_requires_macos_26", "Local Intelligence requires macOS 26 or later. Ordinary OCR tools remain available."),
            (.unavailable(.deviceNotEligible), "local_intelligence_device_not_eligible", "This Mac is not eligible for Apple Intelligence. Ordinary OCR tools remain available."),
            (.unavailable(.appleIntelligenceNotEnabled), "apple_intelligence_not_enabled", "Enable Apple Intelligence in System Settings, then retry. Ordinary OCR tools remain available."),
            (.unavailable(.modelNotReady), "local_intelligence_model_not_ready", "Apple Intelligence is not ready. Finish downloading or preparing the model, then retry. Ordinary OCR tools remain available."),
            (.unavailable(.unsupportedLanguage), "local_intelligence_language_not_supported", "Apple Intelligence does not support this document language. Ordinary OCR tools remain available."),
            (.emptyDocument, "local_intelligence_invalid_input", "The document does not contain usable OCR text or the requested fields are invalid. Ordinary OCR tools remain available."),
            (.invalidFields, "local_intelligence_invalid_input", "The document does not contain usable OCR text or the requested fields are invalid. Ordinary OCR tools remain available."),
            (.contextOverflow, "local_intelligence_generation_failed", "Local Intelligence could not process this document. Ordinary OCR tools remain available."),
            (.ungroundedOutput, "local_intelligence_output_not_grounded", "Local Intelligence could not ground its result in the document. Ordinary OCR tools remain available."),
            (.cancelled, "cancelled", "OCR processing was cancelled."),
        ]

        for (failure, code, message) in cases {
            await provider.setFailure(failure)
            let result = await dispatcher.callTool(
                name: "summarize_document",
                arguments: ["file_path": "private-document.pdf"]
            )
            #expect(errorCode(in: result) == code)
            #expect(errorMessage(in: result) == message)
            #expect(text(in: result)?.contains("private-document.pdf") == false)
            #expect(text(in: result)?.contains("Invoice total") == false)
        }

        await provider.setFailure(CancellationError())
        let cancelled = await dispatcher.callTool(
            name: "summarize_document",
            arguments: ["file_path": "private-document.pdf"]
        )
        #expect(errorCode(in: cancelled) == "cancelled")

        await provider.setFailure(FakeProviderFailure())
        let unknown = await dispatcher.callTool(
            name: "summarize_document",
            arguments: ["file_path": "private-document.pdf"]
        )
        #expect(errorCode(in: unknown) == "local_intelligence_generation_failed")
        #expect(errorMessage(in: unknown) == "Local Intelligence could not process this document. Ordinary OCR tools remain available.")
    }

    @Test func dispatcherMapsTaskCancellationToTheCancelledToolError() async {
        let consent = FakeConsentStore(.current(currentConsentReceipt))
        let dispatcher = makeDispatcher(
            service: FakeOCRService(),
            consentStore: consent,
            currentDirectory: currentDirectory
        )
        let task = Task {
            await dispatcher.callTool(name: "get_pdf_page_count", arguments: ["file_path": "input.pdf"])
        }
        task.cancel()

        let result = await task.value

        #expect(result.isError == true)
        #expect(errorCode(in: result) == "cancelled")
        #expect(await consent.statusReadCount() == 0)
    }
}

private let currentConsentReceipt = ExternalDataConsentReceipt(
    schemaVersion: ExternalDataConsentReceipt.currentSchemaVersion,
    policyVersion: ExternalDataConsentReceipt.currentPolicyVersion,
    acceptedAt: Date(timeIntervalSince1970: 1_700_000_000),
    externalProviderRiskAccepted: true,
    documentToolAccessAccepted: true
)

private func makeDispatcher(
    service: any LocalOCRServing = FakeOCRService(),
    textLoader: any DocumentTextLoading = FakeTextLoader(),
    intelligence: any DocumentIntelligenceProviding = FakeIntelligenceProvider(),
    consentStore: any ExternalDataConsentStoring = FakeConsentStore(.current(currentConsentReceipt)),
    currentDirectory: URL
) -> MCPToolDispatcher {
    MCPToolDispatcher(
        service: service,
        textLoader: textLoader,
        intelligence: intelligence,
        consentStore: consentStore,
        currentDirectory: currentDirectory
    )
}

private func text(in result: CallTool.Result) -> String? {
    guard case let .text(text, _, _)? = result.content.first else { return nil }
    return text
}

private func errorCode(in result: CallTool.Result) -> String? {
    guard let text = text(in: result) else { return nil }
    return (try? JSONDecoder().decode(Value.self, from: Data(text.utf8)))?
        .objectValue?["error"]?.objectValue?["code"]?.stringValue
}

private func errorMessage(in result: CallTool.Result) -> String? {
    guard let text = text(in: result) else { return nil }
    return (try? JSONDecoder().decode(Value.self, from: Data(text.utf8)))?
        .objectValue?["error"]?.objectValue?["message"]?.stringValue
}

private actor FakeOCRService: LocalOCRServing {
    private var pdfRequest: PDFOCRRequest?
    private var batchRequest: BatchOCRRequest?
    private var searchablePDFRequest: SearchablePDFRequest?
    private var pageURL: URL?
    private var inspectionURL: URL?
    private var recognizedImageURL: URL?
    private var failure: LocalOCRError?
    private var callCount = 0

    func setFailure(_ failure: LocalOCRError?) {
        self.failure = failure
    }

    func lastPDFRequest() -> PDFOCRRequest? { pdfRequest }
    func lastBatchRequest() -> BatchOCRRequest? { batchRequest }
    func searchableRequest() -> SearchablePDFRequest? { searchablePDFRequest }
    func pageCountURL() -> URL? { pageURL }
    func inspectURL() -> URL? { inspectionURL }
    func imageURL() -> URL? { recognizedImageURL }
    func totalCallCount() -> Int { callCount }

    func pageCount(at fileURL: URL) async throws -> PageCountResponse {
        callCount += 1
        pageURL = fileURL
        try throwIfConfigured()
        return PageCountResponse(pages: 3)
    }

    func inspectPDF(at fileURL: URL) async throws -> InspectPDFResponse {
        callCount += 1
        inspectionURL = fileURL
        try throwIfConfigured()
        return InspectPDFResponse(sourcePath: fileURL.path, sourceSHA256: "inspect", pages: 1, searchablePages: 1, ocrNeededPages: 0, characters: 10, fullySearchable: true, pageDetails: [PageInspectionResponse(page: 1, characters: 10, searchable: true)])
    }

    func ocrPDF(_ request: PDFOCRRequest, progress _: @escaping @Sendable (OCRProgress) -> Void) async throws -> PDFOCRResponse {
        callCount += 1
        pdfRequest = request
        try throwIfConfigured()
        return pdfResponse(path: request.fileURL.path)
    }

    func ocrPDFBatch(_ request: BatchOCRRequest, progress _: @escaping @Sendable (BatchProgress) -> Void) async -> BatchOCRResponse {
        callCount += 1
        batchRequest = request
        let first = pdfResponse(path: request.fileURLs[0].path)
        return BatchOCRResponse(
            processed: 2,
            succeeded: 1,
            failed: 1,
            results: [.success(first), .failure(sourcePath: request.fileURLs[1].path, message: "invalid PDF")]
        )
    }

    func ocrImage(_ request: ImageOCRRequest) async throws -> ImageOCRResponse {
        callCount += 1
        recognizedImageURL = request.fileURL
        try throwIfConfigured()
        return ImageOCRResponse(text: "image text")
    }

    func makeSearchablePDF(_ request: SearchablePDFRequest, progress _: @escaping @Sendable (OCRProgress) -> Void) async throws -> SearchablePDFResponse {
        callCount += 1
        searchablePDFRequest = request
        try throwIfConfigured()
        return SearchablePDFResponse(outputPath: request.outputURL?.path ?? "/tmp/localocr-dispatch/input_searchable.pdf", failedPages: [2])
    }

    private func pdfResponse(path: String) -> PDFOCRResponse {
        PDFOCRResponse(
            sourcePath: path,
            sourceSHA256: "abc",
            pages: [OCRPageResponse(page: 1, text: "found text", method: .existingText, lines: nil)],
            failedPages: [2],
            emptyOCRPages: [],
            rotatedOCRPages: []
        )
    }

    private func throwIfConfigured() throws {
        if let failure { throw failure }
    }
}

private actor FakeTextLoader: DocumentTextLoading {
    private var paths: [URL] = []

    func load(_ sourceURL: URL) async throws -> IntelligenceDocument {
        paths.append(sourceURL)
        return IntelligenceDocument(pages: [
            .init(number: 1, text: "Invoice total: $19.00")
        ])
    }

    func loadCount() -> Int { paths.count }
    func loadedPaths() -> [URL] { paths }
}

private actor FakeIntelligenceProvider: DocumentIntelligenceProviding {
    enum Operation: Sendable, Equatable {
        case summarize
        case organize
        case extract([String])
    }

    private var calls: [Operation] = []
    private var failure: (any Error & Sendable)?

    var availability: IntelligenceAvailability { .available }

    func setFailure(_ failure: (any Error & Sendable)?) {
        self.failure = failure
    }

    func operationCount() -> Int { calls.count }
    func operations() -> [Operation] { calls }

    func summarize(_ document: IntelligenceDocument) async throws -> IntelligenceSummary {
        calls.append(.summarize)
        try throwIfConfigured()
        return IntelligenceSummary(
            text: "A short summary.",
            citations: [.init(page: 1, quote: "Invoice total")]
        )
    }

    func organize(_ document: IntelligenceDocument) async throws -> OrganizationSuggestion {
        calls.append(.organize)
        try throwIfConfigured()
        return OrganizationSuggestion(
            title: "Paid invoice",
            category: "Finance",
            tags: ["invoice", "paid"],
            citations: [.init(page: 1, quote: "Invoice total")]
        )
    }

    func extract(
        _ names: [String],
        from document: IntelligenceDocument
    ) async throws -> [ExtractedDocumentField] {
        calls.append(.extract(names))
        try throwIfConfigured()
        return [
            .init(name: names[0], value: nil, sourcePage: nil, evidence: nil),
            .init(name: names[1], value: "$19.00", sourcePage: 1, evidence: "Total: $19.00"),
        ]
    }

    private func throwIfConfigured() throws {
        if let failure { throw failure }
    }
}

private struct FakeProviderFailure: Error, Sendable {}

private actor FakeConsentStore: ExternalDataConsentStoring {
    private var currentStatus: ExternalDataConsentStatus
    private var reads = 0

    init(_ status: ExternalDataConsentStatus) {
        currentStatus = status
    }

    func status() async -> ExternalDataConsentStatus {
        reads += 1
        return currentStatus
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

    func setStatus(_ status: ExternalDataConsentStatus) {
        currentStatus = status
    }

    func statusReadCount() -> Int { reads }
}
