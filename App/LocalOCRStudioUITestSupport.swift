#if DEBUG
import Foundation
@_spi(UITesting) import LocalOCRStudioKit

@MainActor
enum LocalOCRStudioUITestSupport {
    private enum FixtureState: String, Sendable {
        case empty
        case result
        case resultBusy
        case error
    }

    static func makeViewIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LocalOCRStudioView? {
        guard let testSession = environment["LOCALOCR_STUDIO_UI_TEST_SESSION"],
              !testSession.isEmpty,
              let rawState = environment["LOCALOCR_STUDIO_UI_STATE"],
              let state = FixtureState(rawValue: rawState)
        else {
            return nil
        }

        let client = FixtureClient(state: state)
        let model = StudioViewModel(client: client)
        let actions = StudioDocumentActions(
            client: client,
            clipboard: NSPasteboardStudioClipboard(),
            textWriter: AtomicStudioTextWriter()
        )

        switch state {
        case .empty:
            break
        case .result, .resultBusy, .error:
            model.open(fixtureSourceURL)
        }

        if state == .resultBusy {
            return LocalOCRStudioView(
                model: model,
                actions: actions,
                isCreatingSearchablePDF: true,
                searchableProgress: .assembling
            )
        }

        return LocalOCRStudioView(model: model, actions: actions)
    }

    private static let fixtureSourceURL = URL(
        fileURLWithPath: "/tmp/fixture-invoice.pdf"
    )

    private struct FixtureClient: StudioOCRClient {
        let state: FixtureState

        func processDocument(
            at sourceURL: URL,
            progress: @escaping @Sendable (StudioProgress) -> Void
        ) async throws -> StudioDocumentResult {
            switch state {
            case .empty:
                throw FixtureError.unavailable
            case .result, .resultBusy:
                progress(.recognizing(page: 2, total: 2))
                return StudioDocumentResult(
                    sourceURL: sourceURL,
                    sourceSHA256: String(repeating: "a", count: 64),
                    kind: .pdf,
                    pageCount: 2,
                    searchablePages: 1,
                    ocrNeededPages: 1,
                    text: """
                    LOCALOCR UI FIXTURE
                    Quarterly planning is complete.
                    Owner: Ray Consulting
                    """,
                    failedPages: []
                )
            case .error:
                throw FixtureError.expectedFailure
            }
        }

        func makeSearchablePDF(
            sourceURL _: URL,
            destinationURL _: URL,
            progress _: @escaping @Sendable (StudioProgress) -> Void
        ) async throws -> URL {
            throw FixtureError.unavailable
        }
    }

    private enum FixtureError: Error {
        case expectedFailure
        case unavailable
    }
}
#endif
