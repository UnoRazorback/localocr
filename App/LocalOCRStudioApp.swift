import AppKit
import LocalOCRStudioKit
import SwiftUI

@main
struct LocalOCRStudioApp: App {
    var body: some Scene {
        WindowGroup {
            LocalOCRStudioRoot.makeView()
        }
        .defaultSize(width: 900, height: 640)
    }
}

@MainActor
enum LocalOCRStudioRoot {
    static func makeView() -> LocalOCRStudioView {
        #if DEBUG
        if let fixtureView = LocalOCRStudioUITestSupport.makeViewIfRequested() {
            return fixtureView
        }
        #endif

        let client = LocalOCRStudioClient()
        let model = StudioViewModel(client: client)
        let actions = StudioDocumentActions(
            client: client,
            clipboard: NSPasteboardStudioClipboard(),
            textWriter: AtomicStudioTextWriter()
        )
        return LocalOCRStudioView(model: model, actions: actions)
    }
}
