import Foundation
import LocalOCRCore
import LocalOCRStudioKit
import Testing

@Suite struct StudioDocumentActionsTests {
    @Test @MainActor func copyWritesExactRecognizedText() {
        let clipboard = RecordingClipboard()
        let actions = StudioDocumentActions(
            client: ActionRecordingClient(),
            clipboard: clipboard,
            textWriter: AtomicStudioTextWriter()
        )

        actions.copy(result(sourcePath: "/tmp/invoice.pdf", text: "Invoice 1048\nTotal due: $2,450.00"))

        #expect(clipboard.text == "Invoice 1048\nTotal due: $2,450.00")
    }

    @Test @MainActor func suggestedTextNameUsesSourceStem() {
        let actions = StudioDocumentActions(
            client: ActionRecordingClient(),
            clipboard: RecordingClipboard(),
            textWriter: AtomicStudioTextWriter()
        )

        let filename = actions.suggestedTextFilename(for: result(sourcePath: "/tmp/April.Invoice.PDF", text: ""))

        #expect(filename == "April.Invoice.txt")
    }

    @Test @MainActor func textSaveWritesUTF8Atomically() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let destinationURL = directoryURL.appending(path: "recognized.txt")
        let actions = StudioDocumentActions(
            client: ActionRecordingClient(),
            clipboard: RecordingClipboard(),
            textWriter: AtomicStudioTextWriter()
        )

        try actions.saveText(
            result(sourcePath: "/tmp/receipt.png", text: "Café ☕️"),
            to: destinationURL
        )

        #expect(try String(contentsOf: destinationURL, encoding: .utf8) == "Café ☕️")
    }

    @Test @MainActor func searchablePDFFailsForImageResults() async {
        let client = ActionRecordingClient()
        let actions = StudioDocumentActions(
            client: client,
            clipboard: RecordingClipboard(),
            textWriter: AtomicStudioTextWriter()
        )

        await #expect(throws: LocalOCRError.self) {
            try await actions.createSearchablePDF(
                result(sourcePath: "/tmp/receipt.jpg", kind: .image, text: "Receipt"),
                at: URL(fileURLWithPath: "/tmp/receipt_searchable.pdf"),
                progress: { _ in }
            )
        }
        #expect(await client.searchableRequests() == [])
    }

    @Test @MainActor func searchablePDFUsesTheChosenDestination() async throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.pdf")
        let destinationURL = URL(fileURLWithPath: "/tmp/user-selected.pdf")
        let client = ActionRecordingClient(searchableOutputURL: destinationURL)
        let actions = StudioDocumentActions(
            client: client,
            clipboard: RecordingClipboard(),
            textWriter: AtomicStudioTextWriter()
        )

        let outputURL = try await actions.createSearchablePDF(
            result(sourcePath: sourceURL.path, text: "Source"),
            at: destinationURL,
            progress: { _ in }
        )

        #expect(outputURL == destinationURL)
        #expect(await client.searchableRequests() == [RecordedSearchableRequest(
            sourceURL: sourceURL,
            destinationURL: destinationURL
        )])
    }
}

private final class RecordingClipboard: StudioClipboardWriting {
    private(set) var text: String?

    func write(_ text: String) {
        self.text = text
    }
}

private actor ActionRecordingClient: StudioOCRClient {
    private let searchableOutputURL: URL
    private var requests: [RecordedSearchableRequest] = []

    init(searchableOutputURL: URL = URL(fileURLWithPath: "/tmp/default-output.pdf")) {
        self.searchableOutputURL = searchableOutputURL
    }

    func processDocument(
        at _: URL,
        progress _: @escaping @Sendable (StudioProgress) -> Void
    ) async throws -> StudioDocumentResult {
        throw LocalOCRError.unsupportedFormat("Not used by document actions")
    }

    func makeSearchablePDF(
        sourceURL: URL,
        destinationURL: URL,
        progress _: @escaping @Sendable (StudioProgress) -> Void
    ) async throws -> URL {
        requests.append(RecordedSearchableRequest(sourceURL: sourceURL, destinationURL: destinationURL))
        return searchableOutputURL
    }

    func searchableRequests() -> [RecordedSearchableRequest] { requests }
}

private struct RecordedSearchableRequest: Equatable, Sendable {
    let sourceURL: URL
    let destinationURL: URL
}

private func result(
    sourcePath: String,
    kind: StudioDocumentKind = .pdf,
    text: String
) -> StudioDocumentResult {
    StudioDocumentResult(
        sourceURL: URL(fileURLWithPath: sourcePath),
        sourceSHA256: "test-hash",
        kind: kind,
        pageCount: 1,
        searchablePages: kind == .pdf ? 1 : 0,
        ocrNeededPages: kind == .pdf ? 0 : 1,
        text: text,
        failedPages: []
    )
}

private func makeTemporaryDirectory() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appending(path: "StudioDocumentActionsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
    return directoryURL
}
