import Foundation

public protocol StudioOCRClient: Sendable {
    func processDocument(
        at sourceURL: URL,
        progress: @escaping @Sendable (StudioProgress) -> Void
    ) async throws -> StudioDocumentResult

    func makeSearchablePDF(
        sourceURL: URL,
        destinationURL: URL,
        progress: @escaping @Sendable (StudioProgress) -> Void
    ) async throws -> URL
}
