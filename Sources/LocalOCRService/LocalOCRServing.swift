import Foundation
import LocalOCRCore

public struct BatchProgress: Sendable, Equatable {
    public let currentItem: Int
    public let totalItems: Int
    public let sourcePath: String
    public let progress: OCRProgress

    public init(
        currentItem: Int,
        totalItems: Int,
        sourcePath: String,
        progress: OCRProgress
    ) {
        self.currentItem = currentItem
        self.totalItems = totalItems
        self.sourcePath = sourcePath
        self.progress = progress
    }
}

public protocol LocalOCRServing: Sendable {
    func pageCount(at fileURL: URL) async throws -> PageCountResponse
    func inspectPDF(at fileURL: URL) async throws -> InspectPDFResponse
    func ocrPDF(
        _ request: PDFOCRRequest,
        progress: @escaping @Sendable (OCRProgress) -> Void
    ) async throws -> PDFOCRResponse
    func ocrPDFBatch(
        _ request: BatchOCRRequest,
        progress: @escaping @Sendable (BatchProgress) -> Void
    ) async -> BatchOCRResponse
    func ocrImage(_ request: ImageOCRRequest) async throws -> ImageOCRResponse
    func makeSearchablePDF(
        _ request: SearchablePDFRequest,
        progress: @escaping @Sendable (OCRProgress) -> Void
    ) async throws -> SearchablePDFResponse
}

public extension LocalOCRServing {
    func ocrPDF(_ request: PDFOCRRequest) async throws -> PDFOCRResponse {
        try await ocrPDF(request, progress: { _ in })
    }

    func ocrPDFBatch(_ request: BatchOCRRequest) async -> BatchOCRResponse {
        await ocrPDFBatch(request, progress: { _ in })
    }

    func makeSearchablePDF(
        _ request: SearchablePDFRequest
    ) async throws -> SearchablePDFResponse {
        try await makeSearchablePDF(request, progress: { _ in })
    }
}
