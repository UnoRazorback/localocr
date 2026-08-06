import Foundation
import LocalOCRCore
import LocalOCRService
import LocalOCRStudioKit
import Testing

@Suite struct StudioClientTests {
@Test func pdfProcessingInspectsThenOCRsAndPreservesSourceHash() async throws {
    let sourceURL = URL(fileURLWithPath: "/tmp/invoice.PDF")
    let service = RecordingStudioService(
        inspection: inspection(sourceURL: sourceURL, hash: "source-hash"),
        ocrResponse: makePDFResponse(
            sourceURL: sourceURL,
            hash: "source-hash",
            pages: [
                OCRPageResponse(page: 1, text: "Invoice 1048", method: .existingText, lines: nil),
                OCRPageResponse(page: 2, text: "Total due: $2,450.00", method: .visionOCR, lines: nil)
            ]
        )
    )
    let client = LocalOCRStudioClient(service: service, hasher: { _ in "source-hash" })
    let progress = StudioProgressRecorder()

    let result = try await client.processDocument(at: sourceURL, progress: progress.record)

    #expect(await service.operations() == [.inspectPDF, .ocrPDF])
    #expect(result.sourceURL == sourceURL)
    #expect(result.sourceSHA256 == "source-hash")
    #expect(result.kind == .pdf)
    #expect(result.pageCount == 2)
    #expect(result.searchablePages == 1)
    #expect(result.ocrNeededPages == 1)
    #expect(result.failedPages == [])
    #expect(result.text == """
    --- Page 1 ---
    Invoice 1048

    --- Page 2 ---
    Total due: $2,450.00
    """)
    #expect(progress.events == [.inspecting, .recognizing(page: 2, total: 2), .assembling])
}

@Test func imageProcessingUsesImageOCRAndPreservesSourceHash() async throws {
    let sourceURL = URL(fileURLWithPath: "/tmp/receipt.PNG")
    let service = RecordingStudioService(image: ImageOCRResponse(text: "Coffee $4.50"))
    let client = LocalOCRStudioClient(service: service, hasher: { _ in "image-hash" })

    let result = try await client.processDocument(at: sourceURL, progress: { _ in })

    #expect(await service.operations() == [.ocrImage])
    #expect(result.sourceURL == sourceURL)
    #expect(result.sourceSHA256 == "image-hash")
    #expect(result.kind == .image)
    #expect(result.pageCount == 1)
    #expect(result.searchablePages == 0)
    #expect(result.ocrNeededPages == 1)
    #expect(result.text == "Coffee $4.50")
}

@Test func sourceMutationFailsInsteadOfReturningAResult() async throws {
    let sourceURL = URL(fileURLWithPath: "/tmp/mutable.pdf")
    let service = RecordingStudioService(
        inspection: inspection(sourceURL: sourceURL, hash: "before"),
        ocrResponse: makePDFResponse(sourceURL: sourceURL, hash: "before", pages: [])
    )
    let hashValues = HashSequence(values: ["before", "after"])
    let client = LocalOCRStudioClient(service: service, hasher: { _ in try await hashValues.next() })

    await #expect(throws: StudioClientError.sourceChanged) {
        try await client.processDocument(at: sourceURL, progress: { _ in })
    }
}

@Test func pdfTextUsesPageOrderedSeparators() async throws {
    let sourceURL = URL(fileURLWithPath: "/tmp/out-of-order.pdf")
    let service = RecordingStudioService(
        inspection: inspection(sourceURL: sourceURL, hash: "stable"),
        ocrResponse: makePDFResponse(
            sourceURL: sourceURL,
            hash: "stable",
            pages: [
                OCRPageResponse(page: 2, text: "Second", method: .visionOCR, lines: nil),
                OCRPageResponse(page: 1, text: "First", method: .existingText, lines: nil)
            ]
        )
    )
    let client = LocalOCRStudioClient(service: service, hasher: { _ in "stable" })

    let result = try await client.processDocument(at: sourceURL, progress: { _ in })

    #expect(result.text == """
    --- Page 1 ---
    First

    --- Page 2 ---
    Second
    """)
}

@Test func imageResultDoesNotOfferSearchablePDF() async throws {
    let sourceURL = URL(fileURLWithPath: "/tmp/receipt.jpg")
    let service = RecordingStudioService(image: ImageOCRResponse(text: "Receipt"))
    let client = LocalOCRStudioClient(service: service, hasher: { _ in "image-hash" })

    _ = try await client.processDocument(at: sourceURL, progress: { _ in })

    #expect(await service.searchablePDFRequests() == [])
}

@Test func searchablePDFDelegatesToTheApprovedDestination() async throws {
    let sourceURL = URL(fileURLWithPath: "/tmp/source.pdf")
    let destinationURL = URL(fileURLWithPath: "/tmp/approved-output.pdf")
    let service = RecordingStudioService(
        searchable: SearchablePDFResponse(outputPath: destinationURL.path, failedPages: [])
    )
    let client = LocalOCRStudioClient(service: service, hasher: { _ in "unused" })

    let resultURL = try await client.makeSearchablePDF(
        sourceURL: sourceURL,
        destinationURL: destinationURL,
        progress: { _ in }
    )

    #expect(resultURL == destinationURL)
    #expect(await service.searchablePDFRequests().map(\.fileURL) == [sourceURL])
    #expect(await service.searchablePDFRequests().map(\.outputURL) == [destinationURL])
}
}

private enum StudioServiceOperation: Sendable, Equatable {
    case inspectPDF
    case ocrPDF
    case ocrImage
    case makeSearchablePDF
}

private actor RecordingStudioService: LocalOCRServing {
    private let inspectionResponse: InspectPDFResponse
    private let pdfResponse: PDFOCRResponse
    private let imageResponse: ImageOCRResponse
    private let searchableResponse: SearchablePDFResponse
    private var recordedOperations: [StudioServiceOperation] = []
    private var recordedSearchableRequests: [SearchablePDFRequest] = []

    init(
        inspection: InspectPDFResponse = inspection(sourceURL: URL(fileURLWithPath: "/tmp/default.pdf"), hash: "default"),
        ocrResponse: PDFOCRResponse = makePDFResponse(sourceURL: URL(fileURLWithPath: "/tmp/default.pdf"), hash: "default", pages: []),
        image: ImageOCRResponse = ImageOCRResponse(text: ""),
        searchable: SearchablePDFResponse = SearchablePDFResponse(outputPath: "/tmp/default-output.pdf", failedPages: [])
    ) {
        inspectionResponse = inspection
        pdfResponse = ocrResponse
        imageResponse = image
        searchableResponse = searchable
    }

    func operations() -> [StudioServiceOperation] { recordedOperations }
    func searchablePDFRequests() -> [SearchablePDFRequest] { recordedSearchableRequests }

    func pageCount(at _: URL) async throws -> PageCountResponse { PageCountResponse(pages: 1) }

    func inspectPDF(at _: URL) async throws -> InspectPDFResponse {
        recordedOperations.append(.inspectPDF)
        return inspectionResponse
    }

    func ocrPDF(
        _: PDFOCRRequest,
        progress: @escaping @Sendable (OCRProgress) -> Void
    ) async throws -> PDFOCRResponse {
        recordedOperations.append(.ocrPDF)
        progress(.inspecting)
        progress(.recognizing(page: 2, total: 2))
        progress(.assembling)
        progress(.completed)
        return pdfResponse
    }

    func ocrPDFBatch(
        _: BatchOCRRequest,
        progress _: @escaping @Sendable (BatchProgress) -> Void
    ) async -> BatchOCRResponse {
        BatchOCRResponse(processed: 0, succeeded: 0, failed: 0, results: [])
    }

    func ocrImage(_: ImageOCRRequest) async throws -> ImageOCRResponse {
        recordedOperations.append(.ocrImage)
        return imageResponse
    }

    func makeSearchablePDF(
        _ request: SearchablePDFRequest,
        progress: @escaping @Sendable (OCRProgress) -> Void
    ) async throws -> SearchablePDFResponse {
        recordedOperations.append(.makeSearchablePDF)
        recordedSearchableRequests.append(request)
        progress(.inspecting)
        progress(.completed)
        return searchableResponse
    }
}

private actor HashSequence {
    private var values: [String]

    init(values: [String]) {
        self.values = values
    }

    func next() throws -> String {
        guard !values.isEmpty else { throw HashSequenceError.exhausted }
        return values.removeFirst()
    }
}

private enum HashSequenceError: Error {
    case exhausted
}

private final class StudioProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StudioProgress] = []

    var events: [StudioProgress] {
        lock.withLock { storage }
    }

    func record(_ event: StudioProgress) {
        lock.withLock { storage.append(event) }
    }
}

private func inspection(sourceURL: URL, hash: String) -> InspectPDFResponse {
    InspectPDFResponse(
        sourcePath: sourceURL.path,
        sourceSHA256: hash,
        pages: 2,
        searchablePages: 1,
        ocrNeededPages: 1,
        characters: 28,
        fullySearchable: false,
        pageDetails: []
    )
}

private func makePDFResponse(sourceURL: URL, hash: String, pages: [OCRPageResponse]) -> PDFOCRResponse {
    PDFOCRResponse(
        sourcePath: sourceURL.path,
        sourceSHA256: hash,
        pages: pages,
        failedPages: [],
        emptyOCRPages: [],
        rotatedOCRPages: []
    )
}
