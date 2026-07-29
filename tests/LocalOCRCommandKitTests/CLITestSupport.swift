import Foundation
import LocalOCRCore
import LocalOCRCommandKit
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
