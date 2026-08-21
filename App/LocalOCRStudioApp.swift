import AppKit
import LocalOCRStudioKit
import SwiftUI

@main
struct LocalOCRStudioApp: App {
    @NSApplicationDelegateAdaptor(LocalOCRStudioAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                EmptyView()
            }
            CommandGroup(replacing: .appSettings) {
                EmptyView()
            }
        }
    }
}

@MainActor
final class LocalOCRStudioAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        showMainWindow()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMainWindow()
        return true
    }

    private func showMainWindow() {
        let window: NSWindow
        if let mainWindow {
            window = mainWindow
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "LocalOCR Studio"
            window.contentViewController = NSHostingController(
                rootView: LocalOCRStudioRoot.makeView()
            )
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            mainWindow = window
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow else { return true }
        sender.contentViewController = NSHostingController(
            rootView: LocalOCRStudioRoot.makeView(includeUITestFixture: false)
        )
        return true
    }
}

@MainActor
enum LocalOCRStudioRoot {
    static func makeView(
        includeUITestFixture: Bool = true
    ) -> LocalOCRStudioView {
        #if DEBUG
        if includeUITestFixture,
           let fixtureView = LocalOCRStudioUITestSupport.makeViewIfRequested() {
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
        let batchCoordinator = StudioBatchCoordinator(
            enumerator: BatchInputEnumerator(),
            planner: BatchOutputPlanner(),
            executor: StudioBatchExecutor(client: client)
        )
        return LocalOCRStudioView(
            model: model,
            actions: actions,
            batchCoordinator: batchCoordinator
        )
    }
}
