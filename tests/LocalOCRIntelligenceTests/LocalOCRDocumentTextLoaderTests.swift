import Foundation
@testable import LocalOCRIntelligence
import LocalOCRCore
import LocalOCRService
import Testing

@Suite struct LocalOCRDocumentTextLoaderTests {
    @Test func pdfLoadsOnlyRecognizedPageText() async throws {
        let service = RecordingService(pdfPages: [
            .init(page: 2, text: "second", method: .visionOCR, lines: nil),
            .init(page: 1, text: "first", method: .existingText, lines: nil),
            .init(page: 3, text: "   ", method: .visionOCR, lines: nil),
        ])

        let document = try await LocalOCRDocumentTextLoader(service: service)
            .load(URL(fileURLWithPath: "/tmp/input.PDF"))

        #expect(document.pages == [
            .init(number: 1, text: "first"),
            .init(number: 2, text: "second"),
        ])
        #expect(await service.lastPDFRequest?.fileURL.path == "/tmp/input.PDF")
        #expect(await service.lastPDFRequest?.includeLines == false)
        #expect(await service.operationCount == 1)
    }

    @Test func imageLoadsRecognizedTextAsPageOne() async throws {
        let service = RecordingService(imageText: "receipt total: $19")

        let document = try await LocalOCRDocumentTextLoader(service: service)
            .load(URL(fileURLWithPath: "/tmp/receipt.png"))

        #expect(document.pages == [.init(number: 1, text: "receipt total: $19")])
        #expect(await service.lastImageRequest?.fileURL.path == "/tmp/receipt.png")
        #expect(await service.operationCount == 1)
    }

    @Test func unsupportedFormatFailsWithoutCallingOCR() async {
        let service = RecordingService()

        await #expect(throws: LocalOCRDocumentTextLoaderError.unsupportedFormat("txt")) {
            try await LocalOCRDocumentTextLoader(service: service)
                .load(URL(fileURLWithPath: "/tmp/notes.txt"))
        }

        #expect(await service.operationCount == 0)
    }
}

private actor RecordingService: LocalOCRServing {
    private let pdfPages: [OCRPageResponse]
    private let imageText: String

    private(set) var lastPDFRequest: PDFOCRRequest?
    private(set) var lastImageRequest: ImageOCRRequest?
    private(set) var operationCount = 0

    init(pdfPages: [OCRPageResponse] = [], imageText: String = "") {
        self.pdfPages = pdfPages
        self.imageText = imageText
    }

    func pageCount(at _: URL) async throws -> PageCountResponse {
        PageCountResponse(pages: 1)
    }

    func inspectPDF(at _: URL) async throws -> InspectPDFResponse {
        InspectPDFResponse(
            sourcePath: "/tmp/input.pdf",
            sourceSHA256: "test",
            pages: 1,
            searchablePages: 0,
            ocrNeededPages: 1,
            characters: 0,
            fullySearchable: false,
            pageDetails: []
        )
    }

    func ocrPDF(
        _ request: PDFOCRRequest,
        progress _: @escaping @Sendable (OCRProgress) -> Void
    ) async throws -> PDFOCRResponse {
        lastPDFRequest = request
        operationCount += 1
        return PDFOCRResponse(
            sourcePath: request.fileURL.path,
            sourceSHA256: "test",
            pages: pdfPages,
            failedPages: [],
            emptyOCRPages: [],
            rotatedOCRPages: []
        )
    }

    func ocrPDFBatch(
        _: BatchOCRRequest,
        progress _: @escaping @Sendable (BatchProgress) -> Void
    ) async -> BatchOCRResponse {
        BatchOCRResponse(processed: 0, succeeded: 0, failed: 0, results: [])
    }

    func ocrImage(_ request: ImageOCRRequest) async throws -> ImageOCRResponse {
        lastImageRequest = request
        operationCount += 1
        return ImageOCRResponse(text: imageText)
    }

    func makeSearchablePDF(
        _: SearchablePDFRequest,
        progress _: @escaping @Sendable (OCRProgress) -> Void
    ) async throws -> SearchablePDFResponse {
        SearchablePDFResponse(outputPath: "/tmp/output.pdf", failedPages: [])
    }
}
