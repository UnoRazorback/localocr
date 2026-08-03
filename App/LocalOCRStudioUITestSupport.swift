#if DEBUG
import Foundation
import LocalOCRStudioKit

@MainActor
enum LocalOCRStudioUITestSupport {
    private enum FixtureState: String, Sendable {
        case empty
        case result
        case error
    }

    static func makeViewIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LocalOCRStudioView? {
        guard let configurationPath = environment["XCTestConfigurationFilePath"],
              !configurationPath.isEmpty,
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
        case .result, .error:
            model.open(fixtureSourceURL)
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
            case .result:
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
