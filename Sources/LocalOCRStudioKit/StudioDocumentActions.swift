import AppKit
import Foundation
import LocalOCRCore

public protocol StudioClipboardWriting {
    func write(_ text: String)
}

public protocol StudioTextWriting {
    func write(_ text: String, to destinationURL: URL) throws
}

public struct NSPasteboardStudioClipboard: StudioClipboardWriting {
    public init() {}

    public func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

public struct AtomicStudioTextWriter: StudioTextWriting {
    public init() {}

    public func write(_ text: String, to destinationURL: URL) throws {
        try Data(text.utf8).write(to: destinationURL, options: .atomic)
    }
}

@MainActor
public final class StudioDocumentActions {
    private let client: any StudioOCRClient
    private let clipboard: any StudioClipboardWriting
    private let textWriter: any StudioTextWriting

    public init(
        client: any StudioOCRClient,
        clipboard: any StudioClipboardWriting,
        textWriter: any StudioTextWriting
    ) {
        self.client = client
        self.clipboard = clipboard
        self.textWriter = textWriter
    }

    public func copy(_ result: StudioDocumentResult) {
        clipboard.write(result.text)
    }

    public func suggestedTextFilename(for result: StudioDocumentResult) -> String {
        "\(sourceStem(for: result)).txt"
    }

    public func suggestedSearchableFilename(for result: StudioDocumentResult) -> String {
        "\(sourceStem(for: result))_searchable.pdf"
    }

    public func saveText(_ result: StudioDocumentResult, to destinationURL: URL) throws {
        try textWriter.write(result.text, to: destinationURL)
    }

    public func createSearchablePDF(
        _ result: StudioDocumentResult,
        at destinationURL: URL,
        progress: @escaping @Sendable (StudioProgress) -> Void
    ) async throws -> URL {
        guard result.kind == .pdf else {
            throw LocalOCRError.unsupportedFormat("Searchable PDF output is available only for PDF documents.")
        }

        return try await client.makeSearchablePDF(
            sourceURL: result.sourceURL,
            destinationURL: destinationURL,
            progress: progress
        )
    }

    private func sourceStem(for result: StudioDocumentResult) -> String {
        result.sourceURL.deletingPathExtension().lastPathComponent
    }
}
