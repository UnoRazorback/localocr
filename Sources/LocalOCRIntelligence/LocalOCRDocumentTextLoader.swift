import Foundation
import LocalOCRService
import UniformTypeIdentifiers

public protocol DocumentTextLoading: Sendable {
    func load(_ sourceURL: URL) async throws -> IntelligenceDocument
}

public enum LocalOCRDocumentTextLoaderError: Error, Sendable, Equatable {
    case unsupportedFormat(String)
}

public struct LocalOCRDocumentTextLoader: DocumentTextLoading {
    private let service: any LocalOCRServing

    public init(service: any LocalOCRServing) {
        self.service = service
    }

    public func load(_ sourceURL: URL) async throws -> IntelligenceDocument {
        if sourceURL.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame {
            let response = try await service.ocrPDF(
                PDFOCRRequest(fileURL: sourceURL, includeLines: false)
            )
            return IntelligenceDocument(
                pages: response.pages.map { page in
                    IntelligenceSourcePage(number: page.page, text: page.text)
                }
            )
        }

        if UTType(filenameExtension: sourceURL.pathExtension)?.conforms(to: .image) == true {
            let response = try await service.ocrImage(ImageOCRRequest(fileURL: sourceURL))
            return IntelligenceDocument(pages: [.init(number: 1, text: response.text)])
        }

        throw LocalOCRDocumentTextLoaderError.unsupportedFormat(
            sourceURL.pathExtension.lowercased()
        )
    }
}
