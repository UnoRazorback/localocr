import Foundation
import LocalOCRCore
import LocalOCRIntelligence
import LocalOCRService

public actor LocalOCRStudioClient: StudioOCRClient {
    private let service: any LocalOCRServing
    private let hasher: @Sendable (URL) async throws -> String

    public init(
        service: any LocalOCRServing = LocalOCRService(),
        hasher: @escaping @Sendable (URL) async throws -> String = {
            try await FileHashing.sha256(of: $0)
        }
    ) {
        self.service = service
        self.hasher = hasher
    }

    public func processDocument(
        at sourceURL: URL,
        progress: @escaping @Sendable (StudioProgress) -> Void
    ) async throws -> StudioDocumentResult {
        if sourceURL.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame {
            return try await processPDF(at: sourceURL, progress: progress)
        }
        return try await processImage(at: sourceURL)
    }

    public func makeSearchablePDF(
        sourceURL: URL,
        destinationURL: URL,
        progress: @escaping @Sendable (StudioProgress) -> Void
    ) async throws -> URL {
        let response = try await service.makeSearchablePDF(
            SearchablePDFRequest(fileURL: sourceURL, outputURL: destinationURL),
            progress: { event in
                if let studioProgress = Self.studioProgress(for: event) {
                    progress(studioProgress)
                }
            }
        )
        return URL(fileURLWithPath: response.outputPath)
    }

    private func processPDF(
        at sourceURL: URL,
        progress: @escaping @Sendable (StudioProgress) -> Void
    ) async throws -> StudioDocumentResult {
        let initialHash = try await hasher(sourceURL)
        let inspection = try await service.inspectPDF(at: sourceURL)
        let response = try await service.ocrPDF(
            PDFOCRRequest(fileURL: sourceURL),
            progress: { event in
                if let studioProgress = Self.studioProgress(for: event) {
                    progress(studioProgress)
                }
            }
        )
        let finalHash = try await hasher(sourceURL)

        guard initialHash == finalHash,
              inspection.sourceSHA256 == initialHash,
              response.sourceSHA256 == initialHash
        else {
            throw StudioClientError.sourceChanged
        }

        return StudioDocumentResult(
            sourceURL: sourceURL,
            sourceSHA256: initialHash,
            kind: .pdf,
            pageCount: inspection.pages,
            searchablePages: inspection.searchablePages,
            ocrNeededPages: inspection.ocrNeededPages,
            text: Self.formattedText(from: response),
            failedPages: response.failedPages,
            intelligenceDocument: IntelligenceDocument(
                pages: response.pages.map {
                    IntelligenceSourcePage(number: $0.page, text: $0.text)
                }
            )
        )
    }

    private func processImage(at sourceURL: URL) async throws -> StudioDocumentResult {
        let initialHash = try await hasher(sourceURL)
        let response = try await service.ocrImage(ImageOCRRequest(fileURL: sourceURL))
        let finalHash = try await hasher(sourceURL)

        guard initialHash == finalHash else {
            throw StudioClientError.sourceChanged
        }

        return StudioDocumentResult(
            sourceURL: sourceURL,
            sourceSHA256: initialHash,
            kind: .image,
            pageCount: 1,
            searchablePages: 0,
            ocrNeededPages: 1,
            text: response.text,
            failedPages: [],
            intelligenceDocument: IntelligenceDocument(
                pages: [IntelligenceSourcePage(number: 1, text: response.text)]
            )
        )
    }

    private static func studioProgress(for event: OCRProgress) -> StudioProgress? {
        switch event {
        case .inspecting:
            .inspecting
        case let .recognizing(page, total):
            .recognizing(page: page, total: total)
        case .assembling:
            .assembling
        case .completed:
            nil
        }
    }

    private static func formattedText(from response: PDFOCRResponse) -> String {
        response.pages
            .sorted { $0.page < $1.page }
            .map { "--- Page \($0.page) ---\n\($0.text)" }
            .joined(separator: "\n\n")
    }
}
