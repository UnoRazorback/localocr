import AppKit
import LocalOCRIntelligence
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
            CommandGroup(after: .help) {
                Button("Connect to Your Agent") {
                    appDelegate.showAgentConnectionGuide()
                }
            }
        }
    }
}

@MainActor
final class LocalOCRStudioAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var mainWindow: NSWindow?
    private var helpWindow: NSWindow?
    private var helpModel: AgentConnectionGuideModel?

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

    func showAgentConnectionGuide() {
        let model: AgentConnectionGuideModel
        let window: NSWindow
        if let helpWindow, let helpModel {
            window = helpWindow
            model = helpModel
        } else {
            #if DEBUG
            model = LocalOCRStudioUITestSupport.makeAgentConnectionGuideModelIfRequested(
                bundleURL: Bundle.main.bundleURL
            ) ?? AgentConnectionGuideModel(bundleURL: Bundle.main.bundleURL)
            #else
            model = AgentConnectionGuideModel(bundleURL: Bundle.main.bundleURL)
            #endif
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Connect to Your Agent"
            window.contentViewController = NSHostingController(
                rootView: AgentConnectionGuideView(model: model)
            )
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            helpWindow = window
            helpModel = model
        }

        model.resetSessionAcknowledgments()
        Task { await model.refreshReceiptStatus() }
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
        let intelligenceProvider: any DocumentIntelligenceProviding
        let initialIntelligenceAvailability: IntelligenceAvailability
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            intelligenceProvider = FoundationModelsIntelligenceProvider()
            initialIntelligenceAvailability = .modelNotReady
        } else {
            intelligenceProvider = UnavailableIntelligenceProvider(.requiresMacOS26)
            initialIntelligenceAvailability = .requiresMacOS26
        }
        #else
        intelligenceProvider = UnavailableIntelligenceProvider(.requiresMacOS26)
        initialIntelligenceAvailability = .requiresMacOS26
        #endif
        let intelligenceModel = StudioIntelligenceViewModel(
            provider: intelligenceProvider,
            availability: initialIntelligenceAvailability
        )
        return LocalOCRStudioView(
            model: model,
            actions: actions,
            batchCoordinator: batchCoordinator,
            intelligenceModel: intelligenceModel
        )
    }
}
