import Foundation
import LocalOCRCommandKit
import LocalOCRCore
import LocalOCRService
import Testing

final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutput = ""
    private var standardError = ""

    func writeStandardOutput(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        standardOutput += text
    }

    func writeStandardError(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        standardError += text
    }

    var stdout: String { lock.withLock { standardOutput } }
    var stderr: String { lock.withLock { standardError } }
}

struct CLIHarness: Sendable {
    let service: FakeOCRService
    let capture = OutputCapture()

    init(service: FakeOCRService = .fixture()) { self.service = service }

    func run(_ arguments: [String]) async -> Int32 {
        await CLIApplication(
            service: service,
            output: CommandOutput(
                stdout: capture.writeStandardOutput,
                stderr: capture.writeStandardError
            )
        ).run(arguments: arguments)
    }

    var stdout: String { capture.stdout }
    var stderr: String { capture.stderr }

    func stdoutJSON() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
    }
}

final class FakeOCRService: @unchecked Sendable, LocalOCRServing {
    enum Outcome<Response: Sendable>: Sendable {
        case success(Response)
        case failure(LocalOCRError)
        case cancellation
    }

    private let lock = NSLock()
    private let pageCountOutcome: Outcome<PageCountResponse>
    private let inspectOutcome: Outcome<InspectPDFResponse>
    private let ocrOutcome: Outcome<PDFOCRResponse>
    private let batchOutcome: BatchOCRResponse
    private let imageOutcome: Outcome<ImageOCRResponse>
    private let searchableOutcome: Outcome<SearchablePDFResponse>
    private var pdfRequests: [PDFOCRRequest] = []
    private var batchRequests: [BatchOCRRequest] = []
    private var imageRequests: [ImageOCRRequest] = []
    private var searchableRequests: [SearchablePDFRequest] = []

    init(
        pageCount: Outcome<PageCountResponse> = .success(.init(pages: 2)),
        inspect: Outcome<InspectPDFResponse> = .success(.fixture),
        ocr: Outcome<PDFOCRResponse> = .success(.fixture()),
        batch: BatchOCRResponse = .fixture,
        image: Outcome<ImageOCRResponse> = .success(.init(text: "recognized image")),
        searchable: Outcome<SearchablePDFResponse> = .success(.init(outputPath: "/tmp/output.pdf", failedPages: []))
    ) {
        pageCountOutcome = pageCount
        inspectOutcome = inspect
        ocrOutcome = ocr
        batchOutcome = batch
        imageOutcome = image
        searchableOutcome = searchable
    }

    static func fixture(
        pageCount: Outcome<PageCountResponse> = .success(.init(pages: 2)),
        inspect: Outcome<InspectPDFResponse> = .success(.fixture),
        ocr: Outcome<PDFOCRResponse> = .success(.fixture()),
        batch: BatchOCRResponse = .fixture,
        image: Outcome<ImageOCRResponse> = .success(.init(text: "recognized image")),
        searchable: Outcome<SearchablePDFResponse> = .success(.init(outputPath: "/tmp/output.pdf", failedPages: []))
    ) -> FakeOCRService {
        FakeOCRService(pageCount: pageCount, inspect: inspect, ocr: ocr, batch: batch, image: image, searchable: searchable)
    }

    func pageCount(at _: URL) async throws -> PageCountResponse { try pageCountOutcome.value() }
    func inspectPDF(at _: URL) async throws -> InspectPDFResponse { try inspectOutcome.value() }

    func ocrPDF(_ request: PDFOCRRequest, progress: @escaping @Sendable (OCRProgress) -> Void) async throws -> PDFOCRResponse {
        lock.withLock { pdfRequests.append(request) }
        progress(.recognizing(page: 1, total: 2))
        return try ocrOutcome.value()
    }

    func ocrPDFBatch(_ request: BatchOCRRequest, progress: @escaping @Sendable (BatchProgress) -> Void) async -> BatchOCRResponse {
        lock.withLock { batchRequests.append(request) }
        progress(.init(currentItem: 1, totalItems: request.fileURLs.count, sourcePath: request.fileURLs[0].path, progress: .recognizing(page: 1, total: 1)))
        return batchOutcome
    }

    func ocrImage(_ request: ImageOCRRequest) async throws -> ImageOCRResponse {
        lock.withLock { imageRequests.append(request) }
        return try imageOutcome.value()
    }

    func makeSearchablePDF(_ request: SearchablePDFRequest, progress: @escaping @Sendable (OCRProgress) -> Void) async throws -> SearchablePDFResponse {
        lock.withLock { searchableRequests.append(request) }
        progress(.assembling)
        return try searchableOutcome.value()
    }

    var lastPDFRequest: PDFOCRRequest? { lock.withLock { pdfRequests.last } }
    var lastBatchRequest: BatchOCRRequest? { lock.withLock { batchRequests.last } }
    var lastImageRequest: ImageOCRRequest? { lock.withLock { imageRequests.last } }
    var lastSearchableRequest: SearchablePDFRequest? { lock.withLock { searchableRequests.last } }
}

private extension FakeOCRService.Outcome {
    func value() throws -> Response {
        switch self {
        case let .success(value): return value
        case let .failure(error): throw error
        case .cancellation: throw CancellationError()
        }
    }
}

extension InspectPDFResponse {
    static let fixture = InspectPDFResponse(sourcePath: "/tmp/input.pdf", sourceSHA256: "sha", pages: 2, searchablePages: 1, ocrNeededPages: 1, characters: 12, fullySearchable: false, pageDetails: [.init(page: 1, characters: 12, searchable: true), .init(page: 2, characters: 0, searchable: false)])
}

extension PDFOCRResponse {
    static func fixture(failedPages: [Int] = []) -> PDFOCRResponse {
        PDFOCRResponse(sourcePath: "/tmp/input.pdf", sourceSHA256: "sha", pages: [.init(page: 1, text: "First page", method: .existingText, lines: [.init(text: "First page", confidence: 1, x: 0, y: 0, width: 1, height: 1)]), .init(page: 2, text: "Second page", method: .visionOCR, lines: nil)], failedPages: failedPages, emptyOCRPages: [], rotatedOCRPages: [])
    }
}

extension BatchOCRResponse {
    static let fixture = BatchOCRResponse(processed: 2, succeeded: 2, failed: 0, results: [.success(.fixture()), .success(.fixture())])
    static let partialFixture = BatchOCRResponse(processed: 2, succeeded: 1, failed: 1, results: [.success(.fixture()), .failure(sourcePath: "/tmp/bad.pdf", message: "unreadable")])
}
