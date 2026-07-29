import Foundation
import LocalOCRCore
import LocalOCRMCP
import LocalOCRService
import MCP
import Testing

@Test func dispatcherReturnsLegacyScalarResultsWithoutStructuredContent() async throws {
    let service = MCPFakeService(
        pageCount: .success(.init(pages: 7)),
        image: .success(.init(text: "recognized image"))
    )
    let dispatcher = MCPToolDispatcher(
        service: service,
        currentDirectory: URL(fileURLWithPath: "/cwd")
    )

    let pageCount = await dispatcher.call(
        name: "get_pdf_page_count",
        arguments: ["file_path": "input.pdf"]
    )
    let image = await dispatcher.call(
        name: "ocr_image",
        arguments: ["file_path": "/image.png"]
    )

    #expect(try resultText(pageCount) == "7")
    #expect(pageCount.structuredContent == nil)
    #expect(pageCount.isError == false)
    #expect(try resultText(image) == "recognized image")
    #expect(image.structuredContent == nil)
    #expect(image.isError == false)
    #expect(service.pageCountURLs.map(\.path) == ["/cwd/input.pdf"])
    #expect(service.imageRequests.map(\.fileURL.path) == ["/image.png"])
}

@Test func dispatcherReturnsCanonicalInspectionJSONAndMatchingStructure() async throws {
    let response = InspectPDFResponse(
        sourcePath: "/fixture/input.pdf",
        sourceSHA256: "sha",
        pages: 2,
        searchablePages: 1,
        ocrNeededPages: 1,
        characters: 12,
        fullySearchable: false,
        pageDetails: [.init(page: 1, characters: 12, searchable: true)]
    )
    let service = MCPFakeService(inspect: .success(response))
    let dispatcher = MCPToolDispatcher(
        service: service,
        currentDirectory: URL(fileURLWithPath: "/cwd")
    )
    let expected = #"{"characters":12,"fully_searchable":false,"ocr_needed_pages":1,"page_details":[{"characters":12,"page":1,"searchable":true}],"pages":2,"searchable_pages":1,"source_path":"\/fixture\/input.pdf","source_sha256":"sha"}"#
    let expectedValue = try value(from: expected)

    let result = await dispatcher.call(
        name: "inspect_pdf",
        arguments: ["file_path": "input.pdf"]
    )

    #expect(try resultText(result) == expected)
    #expect(result.structuredContent == expectedValue)
    #expect(result.isError == false)
    #expect(service.inspectURLs.map(\.path) == ["/cwd/input.pdf"])
}

@Test func dispatcherMapsPDFOptionsAndKeepsPartialPDFAsSuccess() async throws {
    let response = PDFOCRResponse(
        sourcePath: "/fixture/input.pdf",
        sourceSHA256: "sha",
        pages: [
            .init(
                page: 1,
                text: "Text",
                method: .visionOCR,
                lines: [
                    .init(
                        text: "Line",
                        confidence: 0.75,
                        x: 0.1,
                        y: 0.2,
                        width: 0.3,
                        height: 0.4
                    ),
                ]
            ),
        ],
        failedPages: [2],
        emptyOCRPages: [3],
        rotatedOCRPages: [.init(page: 1, orientation: .left)]
    )
    let service = MCPFakeService(ocr: .success(response))
    let dispatcher = MCPToolDispatcher(
        service: service,
        currentDirectory: URL(fileURLWithPath: "/cwd")
    )
    let expected = #"{"empty_ocr_pages":[3],"failed_pages":[2],"pages":[{"lines":[{"confidence":0.75,"height":0.4,"text":"Line","width":0.3,"x":0.1,"y":0.2}],"method":"vision_ocr","page":1,"text":"Text"}],"rotated_ocr_pages":[{"orientation":"left","page":1}],"source_path":"\/fixture\/input.pdf","source_sha256":"sha"}"#
    let expectedValue = try value(from: expected)

    let result = await dispatcher.call(
        name: "ocr_pdf",
        arguments: [
            "file_path": "input.pdf",
            "page_range": "2-3",
            "dpi": 300,
            "force_ocr": true,
            "include_lines": true,
        ]
    )

    #expect(try resultText(result) == expected)
    #expect(result.structuredContent == expectedValue)
    #expect(result.isError == false)
    let request = try #require(service.pdfRequests.first)
    #expect(request.fileURL.path == "/cwd/input.pdf")
    #expect(request.pageRange == "2-3")
    #expect(request.dpi == 300)
    #expect(request.forceOCR)
    #expect(request.includeLines)
}

@Test func dispatcherReturnsFlatPartialBatchItems() async throws {
    let success = PDFOCRResponse(
        sourcePath: "/ok.pdf",
        sourceSHA256: "oksha",
        pages: [],
        failedPages: [2],
        emptyOCRPages: [],
        rotatedOCRPages: []
    )
    let response = BatchOCRResponse(
        processed: 2,
        succeeded: 1,
        failed: 1,
        results: [
            .success(success),
            .failure(sourcePath: "/bad.pdf", message: "unreadable"),
        ]
    )
    let service = MCPFakeService(batch: response)
    let dispatcher = MCPToolDispatcher(
        service: service,
        currentDirectory: URL(fileURLWithPath: "/cwd")
    )
    let expected = #"{"failed":1,"processed":2,"results":[{"empty_ocr_pages":[],"failed_pages":[2],"pages":[],"rotated_ocr_pages":[],"source_path":"\/ok.pdf","source_sha256":"oksha","status":"ok"},{"error":"unreadable","source_path":"\/bad.pdf","status":"error"}],"succeeded":1}"#
    let expectedValue = try value(from: expected)

    let result = await dispatcher.call(
        name: "ocr_pdf_batch",
        arguments: ["file_paths": ["one.pdf", "/two.pdf"]]
    )

    #expect(try resultText(result) == expected)
    #expect(result.structuredContent == expectedValue)
    #expect(result.isError == false)
    let request = try #require(service.batchRequests.first)
    #expect(request.fileURLs.map(\.path) == ["/cwd/one.pdf", "/two.pdf"])
    #expect(request.dpi == 250)
    #expect(request.pageRange == nil)
    #expect(request.forceOCR == false)
    #expect(request.includeLines == false)
}

@Test func dispatcherMapsSearchableRequestAndResponse() async throws {
    let response = SearchablePDFResponse(outputPath: "/cwd/out.pdf", failedPages: [4])
    let service = MCPFakeService(searchable: .success(response))
    let dispatcher = MCPToolDispatcher(
        service: service,
        currentDirectory: URL(fileURLWithPath: "/cwd")
    )
    let expected = #"{"failed_pages":[4],"output_path":"\/cwd\/out.pdf"}"#
    let expectedValue = try value(from: expected)

    let result = await dispatcher.call(
        name: "make_searchable_pdf",
        arguments: [
            "file_path": "input.pdf",
            "output_path": "out.pdf",
            "dpi": 400,
            "force_ocr": true,
        ]
    )

    #expect(try resultText(result) == expected)
    #expect(result.structuredContent == expectedValue)
    #expect(result.isError == false)
    let request = try #require(service.searchableRequests.first)
    #expect(request.fileURL.path == "/cwd/input.pdf")
    #expect(request.outputURL?.path == "/cwd/out.pdf")
    #expect(request.dpi == 400)
    #expect(request.forceOCR)
}

@Test func dispatcherReturnsStructuredInvalidArgumentsWithoutCallingService() async throws {
    let service = MCPFakeService()
    let dispatcher = MCPToolDispatcher(
        service: service,
        currentDirectory: URL(fileURLWithPath: "/cwd")
    )
    let expected = #"{"error":{"code":"invalid_arguments","message":"dpi must be an integer from 72 through 600"}}"#
    let expectedValue = try value(from: expected)

    let result = await dispatcher.call(
        name: "ocr_pdf",
        arguments: ["file_path": "/input.pdf", "dpi": 601]
    )

    #expect(try resultText(result) == expected)
    #expect(result.structuredContent == expectedValue)
    #expect(result.isError == true)
    #expect(service.pdfRequests.isEmpty)
}

@Test func dispatcherReturnsUnknownToolAsRecoverableError() async throws {
    let dispatcher = MCPToolDispatcher(
        service: MCPFakeService(),
        currentDirectory: URL(fileURLWithPath: "/cwd")
    )
    let expected = #"{"error":{"code":"invalid_arguments","message":"unknown tool 'missing_tool'"}}"#

    let result = await dispatcher.call(name: "missing_tool", arguments: [:])

    #expect(try resultText(result) == expected)
    #expect(result.isError == true)
}

@Test func dispatcherMapsEveryLocalOCRErrorToAStableCode() async throws {
    let cases: [(LocalOCRError, String)] = [
        (.fileNotFound, "file_not_found"),
        (.permissionDenied, "file_not_readable"),
        (.unsupportedFormat("txt"), "unsupported_format"),
        (.unreadablePDF, "invalid_pdf"),
        (.invalidPageSelection("3-1"), "invalid_page_range"),
        (.pageOutOfBounds(page: 8, total: 2), "invalid_page_range"),
        (.invalidDestination, "invalid_output"),
        (.outputExists, "output_exists"),
        (.imageDecodeFailed, "image_decode_failed"),
        (.cancelled, "cancelled"),
        (.rasterizationFailed(page: 2), "processing_failed"),
        (.recognitionFailed(page: 2, message: "failed"), "processing_failed"),
        (.insufficientDiskSpace, "processing_failed"),
        (.outputValidationFailed, "processing_failed"),
    ]

    for (error, code) in cases {
        let dispatcher = MCPToolDispatcher(
            service: MCPFakeService(pageCount: .failure(error)),
            currentDirectory: URL(fileURLWithPath: "/cwd")
        )
        let result = await dispatcher.call(
            name: "get_pdf_page_count",
            arguments: ["file_path": "/input.pdf"]
        )
        let object = try #require(result.structuredContent?.objectValue)
        let errorObject = try #require(object["error"]?.objectValue)
        #expect(errorObject["code"] == Value.string(code))
        #expect(result.isError == true)
    }
}

@Test func dispatcherReturnsExactStructuredServiceErrorForScalarAndObjectTools() async throws {
    let scalarDispatcher = MCPToolDispatcher(
        service: MCPFakeService(pageCount: .failure(.fileNotFound)),
        currentDirectory: URL(fileURLWithPath: "/cwd")
    )
    let objectDispatcher = MCPToolDispatcher(
        service: MCPFakeService(searchable: .failure(.outputExists)),
        currentDirectory: URL(fileURLWithPath: "/cwd")
    )
    let scalarExpected = #"{"error":{"code":"file_not_found","message":"File not found"}}"#
    let objectExpected = #"{"error":{"code":"output_exists","message":"Output already exists"}}"#
    let scalarExpectedValue = try value(from: scalarExpected)
    let objectExpectedValue = try value(from: objectExpected)

    let scalarResult = await scalarDispatcher.call(
        name: "get_pdf_page_count",
        arguments: ["file_path": "/input.pdf"]
    )
    let objectResult = await objectDispatcher.call(
        name: "make_searchable_pdf",
        arguments: ["file_path": "/input.pdf"]
    )

    #expect(try resultText(scalarResult) == scalarExpected)
    #expect(scalarResult.structuredContent == scalarExpectedValue)
    #expect(scalarResult.isError == true)
    #expect(try resultText(objectResult) == objectExpected)
    #expect(objectResult.structuredContent == objectExpectedValue)
    #expect(objectResult.isError == true)
}

@Test func dispatcherMapsTaskCancellationAndUnexpectedFailures() async throws {
    let cancelled = MCPToolDispatcher(
        service: MCPFakeService(pageCount: .cancellation),
        currentDirectory: URL(fileURLWithPath: "/cwd")
    )
    let unexpected = MCPToolDispatcher(
        service: MCPFakeService(pageCount: .unexpected),
        currentDirectory: URL(fileURLWithPath: "/cwd")
    )

    let cancelledResult = await cancelled.call(
        name: "get_pdf_page_count",
        arguments: ["file_path": "/input.pdf"]
    )
    let unexpectedResult = await unexpected.call(
        name: "get_pdf_page_count",
        arguments: ["file_path": "/input.pdf"]
    )
    let cancelledExpected = #"{"error":{"code":"cancelled","message":"Operation cancelled"}}"#
    let unexpectedExpected = #"{"error":{"code":"processing_failed","message":"OCR processing failed"}}"#
    let cancelledExpectedValue = try value(from: cancelledExpected)
    let unexpectedExpectedValue = try value(from: unexpectedExpected)

    #expect(try resultText(cancelledResult) == cancelledExpected)
    #expect(cancelledResult.structuredContent == cancelledExpectedValue)
    #expect(cancelledResult.isError == true)
    #expect(try resultText(unexpectedResult) == unexpectedExpected)
    #expect(unexpectedResult.structuredContent == unexpectedExpectedValue)
    #expect(unexpectedResult.isError == true)
}

@Test func dispatcherMapsCancelledPartialBatchToStableError() async throws {
    let service = MCPBatchCancellationService()
    let dispatcher = MCPToolDispatcher(
        service: service,
        currentDirectory: URL(fileURLWithPath: "/cwd")
    )
    let call = Task {
        await dispatcher.call(
            name: "ocr_pdf_batch",
            arguments: ["file_paths": ["/input.pdf"]]
        )
    }

    await service.waitUntilStarted()
    call.cancel()
    let result = await call.value
    let expected = #"{"error":{"code":"cancelled","message":"Operation cancelled"}}"#
    let expectedValue = try value(from: expected)

    #expect(try resultText(result) == expected)
    #expect(result.structuredContent == expectedValue)
    #expect(result.isError == true)
}

@Test func dispatcherConvertsNonFiniteResponseEncodingFailureAndSurvives() async throws {
    let nonFiniteResponse = PDFOCRResponse(
        sourcePath: "/input.pdf",
        sourceSHA256: "sha",
        pages: [
            .init(
                page: 1,
                text: "text",
                method: .visionOCR,
                lines: [
                    .init(
                        text: "line",
                        confidence: .nan,
                        x: 0,
                        y: 0,
                        width: 1,
                        height: 1
                    ),
                ]
            ),
        ],
        failedPages: [],
        emptyOCRPages: [],
        rotatedOCRPages: []
    )
    let dispatcher = MCPToolDispatcher(
        service: MCPFakeService(
            pageCount: .success(.init(pages: 3)),
            ocr: .success(nonFiniteResponse)
        ),
        currentDirectory: URL(fileURLWithPath: "/cwd")
    )
    let expected = #"{"error":{"code":"processing_failed","message":"OCR processing failed"}}"#
    let expectedValue = try value(from: expected)

    let failed = await dispatcher.call(
        name: "ocr_pdf",
        arguments: ["file_path": "/input.pdf"]
    )
    let survived = await dispatcher.call(
        name: "get_pdf_page_count",
        arguments: ["file_path": "/input.pdf"]
    )

    #expect(try resultText(failed) == expected)
    #expect(failed.structuredContent == expectedValue)
    #expect(failed.isError == true)
    #expect(try resultText(survived) == "3")
    #expect(survived.structuredContent == nil)
    #expect(survived.isError == false)
}

private func resultText(_ result: CallTool.Result) throws -> String {
    let content = try #require(result.content.first)
    guard case let .text(text, _, _) = content else {
        throw MCPDispatcherTestError.unexpectedContent
    }
    return text
}

private func value(from json: String) throws -> Value {
    try JSONDecoder().decode(Value.self, from: Data(json.utf8))
}

private enum MCPDispatcherTestError: Error {
    case unexpectedContent
    case fixtureFailure
}

private final class MCPFakeService: @unchecked Sendable, LocalOCRServing {
    enum Outcome<Response: Sendable>: Sendable {
        case success(Response)
        case failure(LocalOCRError)
        case cancellation
        case unexpected
    }

    private let lock = NSLock()
    private let pageCountOutcome: Outcome<PageCountResponse>
    private let inspectOutcome: Outcome<InspectPDFResponse>
    private let ocrOutcome: Outcome<PDFOCRResponse>
    private let batchOutcome: BatchOCRResponse
    private let imageOutcome: Outcome<ImageOCRResponse>
    private let searchableOutcome: Outcome<SearchablePDFResponse>
    private var pageCountURLStorage: [URL] = []
    private var inspectURLStorage: [URL] = []
    private var pdfRequestStorage: [PDFOCRRequest] = []
    private var batchRequestStorage: [BatchOCRRequest] = []
    private var imageRequestStorage: [ImageOCRRequest] = []
    private var searchableRequestStorage: [SearchablePDFRequest] = []

    init(
        pageCount: Outcome<PageCountResponse> = .success(.init(pages: 1)),
        inspect: Outcome<InspectPDFResponse> = .success(.fixture),
        ocr: Outcome<PDFOCRResponse> = .success(.fixture),
        batch: BatchOCRResponse = .init(processed: 0, succeeded: 0, failed: 0, results: []),
        image: Outcome<ImageOCRResponse> = .success(.init(text: "image")),
        searchable: Outcome<SearchablePDFResponse> = .success(.init(outputPath: "/out.pdf", failedPages: []))
    ) {
        pageCountOutcome = pageCount
        inspectOutcome = inspect
        ocrOutcome = ocr
        batchOutcome = batch
        imageOutcome = image
        searchableOutcome = searchable
    }

    func pageCount(at fileURL: URL) async throws -> PageCountResponse {
        lock.withLock { pageCountURLStorage.append(fileURL) }
        return try pageCountOutcome.value()
    }

    func inspectPDF(at fileURL: URL) async throws -> InspectPDFResponse {
        lock.withLock { inspectURLStorage.append(fileURL) }
        return try inspectOutcome.value()
    }

    func ocrPDF(
        _ request: PDFOCRRequest,
        progress _: @escaping @Sendable (OCRProgress) -> Void
    ) async throws -> PDFOCRResponse {
        lock.withLock { pdfRequestStorage.append(request) }
        return try ocrOutcome.value()
    }

    func ocrPDFBatch(
        _ request: BatchOCRRequest,
        progress _: @escaping @Sendable (BatchProgress) -> Void
    ) async -> BatchOCRResponse {
        lock.withLock { batchRequestStorage.append(request) }
        return batchOutcome
    }

    func ocrImage(_ request: ImageOCRRequest) async throws -> ImageOCRResponse {
        lock.withLock { imageRequestStorage.append(request) }
        return try imageOutcome.value()
    }

    func makeSearchablePDF(
        _ request: SearchablePDFRequest,
        progress _: @escaping @Sendable (OCRProgress) -> Void
    ) async throws -> SearchablePDFResponse {
        lock.withLock { searchableRequestStorage.append(request) }
        return try searchableOutcome.value()
    }

    var pageCountURLs: [URL] { lock.withLock { pageCountURLStorage } }
    var inspectURLs: [URL] { lock.withLock { inspectURLStorage } }
    var pdfRequests: [PDFOCRRequest] { lock.withLock { pdfRequestStorage } }
    var batchRequests: [BatchOCRRequest] { lock.withLock { batchRequestStorage } }
    var imageRequests: [ImageOCRRequest] { lock.withLock { imageRequestStorage } }
    var searchableRequests: [SearchablePDFRequest] { lock.withLock { searchableRequestStorage } }
}

private extension MCPFakeService.Outcome {
    func value() throws -> Response {
        switch self {
        case let .success(value): return value
        case let .failure(error): throw error
        case .cancellation: throw CancellationError()
        case .unexpected: throw MCPDispatcherTestError.fixtureFailure
        }
    }
}

private extension InspectPDFResponse {
    static let fixture = InspectPDFResponse(
        sourcePath: "/input.pdf",
        sourceSHA256: "sha",
        pages: 1,
        searchablePages: 1,
        ocrNeededPages: 0,
        characters: 4,
        fullySearchable: true,
        pageDetails: [.init(page: 1, characters: 4, searchable: true)]
    )
}

private extension PDFOCRResponse {
    static let fixture = PDFOCRResponse(
        sourcePath: "/input.pdf",
        sourceSHA256: "sha",
        pages: [],
        failedPages: [],
        emptyOCRPages: [],
        rotatedOCRPages: []
    )
}

struct MCPBatchCancellationService: LocalOCRServing {
    private let startSignal = MCPBatchStartSignal()

    func waitUntilStarted() async {
        await startSignal.wait()
    }

    func pageCount(at _: URL) async throws -> PageCountResponse {
        throw MCPBatchCancellationServiceError.unexpectedCall
    }

    func inspectPDF(at _: URL) async throws -> InspectPDFResponse {
        throw MCPBatchCancellationServiceError.unexpectedCall
    }

    func ocrPDF(
        _: PDFOCRRequest,
        progress _: @escaping @Sendable (OCRProgress) -> Void
    ) async throws -> PDFOCRResponse {
        throw MCPBatchCancellationServiceError.unexpectedCall
    }

    func ocrPDFBatch(
        _: BatchOCRRequest,
        progress _: @escaping @Sendable (BatchProgress) -> Void
    ) async -> BatchOCRResponse {
        await startSignal.start()
        try? await Task.sleep(for: .seconds(5))
        return BatchOCRResponse(
            processed: 1,
            succeeded: 1,
            failed: 0,
            results: [
                .success(
                    PDFOCRResponse(
                        sourcePath: "/input.pdf",
                        sourceSHA256: "partial",
                        pages: [],
                        failedPages: [],
                        emptyOCRPages: [],
                        rotatedOCRPages: []
                    )
                ),
            ]
        )
    }

    func ocrImage(_: ImageOCRRequest) async throws -> ImageOCRResponse {
        throw MCPBatchCancellationServiceError.unexpectedCall
    }

    func makeSearchablePDF(
        _: SearchablePDFRequest,
        progress _: @escaping @Sendable (OCRProgress) -> Void
    ) async throws -> SearchablePDFResponse {
        throw MCPBatchCancellationServiceError.unexpectedCall
    }
}

private actor MCPBatchStartSignal {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            if started {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func start() {
        started = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private enum MCPBatchCancellationServiceError: Error {
    case unexpectedCall
}
