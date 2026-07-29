import Foundation
import LocalOCRCore
import LocalOCRService
import MCP
@testable import LocalOCRMCP
import Testing

@Suite struct MCPToolDispatcherTests {
    private let currentDirectory = URL(fileURLWithPath: "/tmp/localocr-dispatch", isDirectory: true)

    @Test func dispatcherMapsPDFDefaultsAndReturnsMatchingCanonicalObjectContent() async throws {
        let service = FakeOCRService()
        let dispatcher = MCPToolDispatcher(service: service, currentDirectory: currentDirectory)

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
        let dispatcher = MCPToolDispatcher(service: service, currentDirectory: currentDirectory)

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
        let dispatcher = MCPToolDispatcher(service: service, currentDirectory: currentDirectory)

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
        let dispatcher = MCPToolDispatcher(service: service, currentDirectory: currentDirectory)

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
        let dispatcher = MCPToolDispatcher(service: FakeOCRService(), currentDirectory: currentDirectory)

        let invalid = await dispatcher.callTool(name: "ocr_pdf", arguments: ["file_path": "input.pdf", "dpi": 601])
        let unknown = await dispatcher.callTool(name: "missing_tool", arguments: [:])

        #expect(invalid.isError == true)
        #expect(text(in: invalid) == "{\"error\":{\"code\":\"invalid_arguments\",\"message\":\"dpi must be an integer from 72 through 600\"}}")
        #expect(unknown.isError == true)
        #expect(text(in: unknown) == "{\"error\":{\"code\":\"unknown_tool\",\"message\":\"unknown tool: missing_tool\"}}")
    }

    @Test func dispatcherMapsEveryStableLocalOCRErrorCode() async {
        let service = FakeOCRService()
        let dispatcher = MCPToolDispatcher(service: service, currentDirectory: currentDirectory)
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

private actor FakeOCRService: LocalOCRServing {
    private var pdfRequest: PDFOCRRequest?
    private var batchRequest: BatchOCRRequest?
    private var searchablePDFRequest: SearchablePDFRequest?
    private var pageURL: URL?
    private var inspectionURL: URL?
    private var recognizedImageURL: URL?
    private var failure: LocalOCRError?

    func setFailure(_ failure: LocalOCRError?) {
        self.failure = failure
    }

    func lastPDFRequest() -> PDFOCRRequest? { pdfRequest }
    func lastBatchRequest() -> BatchOCRRequest? { batchRequest }
    func searchableRequest() -> SearchablePDFRequest? { searchablePDFRequest }
    func pageCountURL() -> URL? { pageURL }
    func inspectURL() -> URL? { inspectionURL }
    func imageURL() -> URL? { recognizedImageURL }

    func pageCount(at fileURL: URL) async throws -> PageCountResponse {
        pageURL = fileURL
        try throwIfConfigured()
        return PageCountResponse(pages: 3)
    }

    func inspectPDF(at fileURL: URL) async throws -> InspectPDFResponse {
        inspectionURL = fileURL
        try throwIfConfigured()
        return InspectPDFResponse(sourcePath: fileURL.path, sourceSHA256: "inspect", pages: 1, searchablePages: 1, ocrNeededPages: 0, characters: 10, fullySearchable: true, pageDetails: [PageInspectionResponse(page: 1, characters: 10, searchable: true)])
    }

    func ocrPDF(_ request: PDFOCRRequest, progress _: @escaping @Sendable (OCRProgress) -> Void) async throws -> PDFOCRResponse {
        pdfRequest = request
        try throwIfConfigured()
        return pdfResponse(path: request.fileURL.path)
    }

    func ocrPDFBatch(_ request: BatchOCRRequest, progress _: @escaping @Sendable (BatchProgress) -> Void) async -> BatchOCRResponse {
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
        recognizedImageURL = request.fileURL
        try throwIfConfigured()
        return ImageOCRResponse(text: "image text")
    }

    func makeSearchablePDF(_ request: SearchablePDFRequest, progress _: @escaping @Sendable (OCRProgress) -> Void) async throws -> SearchablePDFResponse {
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
