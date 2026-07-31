# LocalOCR Studio Beta 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, verify, sign, notarize, and privately stage the first functional LocalOCR Studio macOS beta while preserving the existing CLI and six-tool MCP server.

**Architecture:** A thin Xcode-built SwiftUI application links a new testable `LocalOCRStudioKit` Swift package library, which calls `LocalOCRService` directly. The existing `localocr` and `localocr-mcp` executables remain separate native products and are embedded by the already-reviewed direct-release pipeline under `Contents/Helpers`.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Observation, UniformTypeIdentifiers, PDFKit, ImageIO, Swift Testing, XCTest UI tests, XcodeGen 2.46.0, stable Xcode 26.6, Swift Package Manager, Developer ID, Hardened Runtime, `notarytool`, `stapler`, `spctl`, pytest

## Global Constraints

- Product name is exactly `LocalOCR Studio`.
- Bundle identifier is exactly `com.rayconsulting.localocr`.
- Marketing version is exactly `0.2.0`; build number is exactly `1`.
- Minimum operating system is macOS 14; the only release architecture is `arm64`.
- The GUI processes one PDF or ImageIO-decodable image at a time.
- The MCP server retains all six existing tools, including batch PDF OCR.
- The GUI calls `LocalOCRService` directly and never launches the CLI or MCP server.
- Processing starts automatically after Open or drag-and-drop.
- Recognized text is read-only; there is no document or result history.
- The original source is never overwritten or modified.
- Searchable PDF output is available only for PDF input and uses Save As.
- Documents, recognized text, paths, and caches stay local; the app makes no network requests.
- The app and both helpers contain no `com.apple.security.get-task-allow`.
- Stable Xcode is `/Applications/Xcode.app/Contents/Developer`.
- Signing identity is `Developer ID Application: John Scott Ray (DZ8B5454ZN)` and team is `DZ8B5454ZN`.
- Sign both helpers first and the containing app last, with Hardened Runtime and secure timestamps.
- Publication remains blocked until downloaded-copy acceptance passes on the build Mac and a second Mac and the owner explicitly authorizes the beta.

---

## Planned File Structure

```text
App/
  LocalOCRStudioApp.swift                 Thin @main application entry point
  LocalOCRStudioUITestSupport.swift       DEBUG-only deterministic UI state
AppUITests/
  LocalOCRStudioUITests.swift             Empty/result/error UI smoke tests
Sources/LocalOCRStudioKit/
  StudioModels.swift                      Document, result, state, progress models
  StudioOCRClient.swift                   GUI-facing async service protocol
  LocalOCRStudioClient.swift              LocalOCRService adapter and immutability checks
  StudioErrorPresentation.swift           Plain-language and sanitized error mapping
  StudioViewModel.swift                   Cancellation-safe @MainActor state machine
  StudioDocumentActions.swift             Pasteboard and save-panel actions
  LocalOCRStudioView.swift                Focused Canvas composition
  StudioDropZoneView.swift                Open and drag/drop input
  StudioResultView.swift                  Read-only result and export actions
  StudioStatusViews.swift                 Empty, processing, and error states
tests/LocalOCRStudioKitTests/
  StudioClientTests.swift
  StudioViewModelTests.swift
  StudioDocumentActionsTests.swift
  StudioErrorPresentationTests.swift
project.yml                                XcodeGen source of truth
LocalOCR Studio.xcodeproj/                 Generated and committed Xcode project
scripts/build-unsigned-studio-app.sh        Stable-Xcode unsigned Release app build
tests/contract/test_studio_app_project.py   Build and metadata policy contract
```

`LocalOCRStudioKit` owns all application behavior and views. The Xcode app
target contains only the process entry point and DEBUG-only UI-test setup.
This keeps behavior testable with `swift test` and the distributable bundle
testable with `xcodebuild`.

### Task 1: Add the Studio domain and direct service adapter

**Files:**
- Modify: `Package.swift`
- Create: `Sources/LocalOCRStudioKit/StudioModels.swift`
- Create: `Sources/LocalOCRStudioKit/StudioOCRClient.swift`
- Create: `Sources/LocalOCRStudioKit/LocalOCRStudioClient.swift`
- Create: `tests/LocalOCRStudioKitTests/StudioClientTests.swift`

**Interfaces:**
- Consumes: `LocalOCRServing`, `InspectPDFResponse`, `PDFOCRResponse`, `ImageOCRResponse`, `SearchablePDFRequest`, `FileHashing.sha256(of:)`
- Produces: `StudioDocumentKind`, `StudioProgress`, `StudioDocumentResult`, `StudioClientError`, `StudioOCRClient`, and `LocalOCRStudioClient`

- [ ] **Step 1: Add the library and test targets to the package**

Add this product:

```swift
.library(name: "LocalOCRStudioKit", targets: ["LocalOCRStudioKit"])
```

Add these targets:

```swift
.target(
    name: "LocalOCRStudioKit",
    dependencies: ["LocalOCRService", "LocalOCRCore"],
    swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
),
.testTarget(
    name: "LocalOCRStudioKitTests",
    dependencies: ["LocalOCRStudioKit", "LocalOCRService", "LocalOCRCore"],
    path: "tests/LocalOCRStudioKitTests",
    swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
)
```

- [ ] **Step 2: Write failing model and adapter tests**

Cover these exact cases:

```swift
@Test func pdfProcessingInspectsThenOCRsAndPreservesSourceHash()
@Test func imageProcessingUsesImageOCRAndPreservesSourceHash()
@Test func sourceMutationFailsInsteadOfReturningAResult()
@Test func pdfTextUsesPageOrderedSeparators()
@Test func imageResultDoesNotOfferSearchablePDF()
@Test func searchablePDFDelegatesToTheApprovedDestination()
```

Use a `RecordingStudioService: LocalOCRServing` fake and an injected
`@Sendable (URL) async throws -> String` hasher so source mutation can be
simulated without changing a real fixture.

Run:

```bash
swift test --filter LocalOCRStudioKitTests.StudioClientTests
```

Expected: FAIL because `LocalOCRStudioKit` and its types do not exist.

- [ ] **Step 3: Define the exact public domain types**

```swift
public enum StudioDocumentKind: Sendable, Equatable {
    case pdf
    case image
}

public enum StudioProgress: Sendable, Equatable {
    case inspecting
    case recognizing(page: Int, total: Int)
    case assembling
}

public struct StudioDocumentResult: Sendable, Equatable {
    public let sourceURL: URL
    public let sourceSHA256: String
    public let kind: StudioDocumentKind
    public let pageCount: Int
    public let searchablePages: Int
    public let ocrNeededPages: Int
    public let text: String
    public let failedPages: [Int]
}

public enum StudioClientError: Error, Sendable, Equatable {
    case sourceChanged
}
```

Format PDF output exactly as:

```text
--- Page 1 ---
Invoice 1048

--- Page 2 ---
Total due: $2,450.00
```

An image result has `pageCount == 1`, `searchablePages == 0`,
`ocrNeededPages == 1`, and its recognized text without a page heading.

- [ ] **Step 4: Define the GUI-facing protocol**

```swift
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
```

- [ ] **Step 5: Implement `LocalOCRStudioClient`**

Make it an `actor` with this initializer:

```swift
public init(
    service: any LocalOCRServing = LocalOCRService(),
    hasher: @escaping @Sendable (URL) async throws -> String = {
        try await FileHashing.sha256(of: $0)
    }
)
```

Classify `pdf` case-insensitively by extension. For PDFs:

1. Hash the source.
2. Call `inspectPDF(at:)`.
3. Call `ocrPDF(PDFOCRRequest(fileURL: sourceURL), progress:)`.
4. Hash the source again.
5. Require both hashes and both service-reported hashes to equal the initial
   value.
6. Return page-ordered formatted text.

For other files, call `ocrImage(ImageOCRRequest(fileURL: sourceURL))`, then
rehash and require equality. Let the service reject unsupported image data.

Map `OCRProgress.completed` to no additional callback; map the other cases
one-for-one to `StudioProgress`.

- [ ] **Step 6: Run focused and package tests**

```bash
swift test --filter LocalOCRStudioKitTests.StudioClientTests
swift test
```

Expected: PASS, including all existing CLI/MCP/core suites.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/LocalOCRStudioKit \
  tests/LocalOCRStudioKitTests/StudioClientTests.swift
git commit -m "feat: add LocalOCR Studio service adapter"
```

### Task 2: Implement cancellation-safe application state

**Files:**
- Create: `Sources/LocalOCRStudioKit/StudioViewModel.swift`
- Create: `Sources/LocalOCRStudioKit/StudioErrorPresentation.swift`
- Create: `tests/LocalOCRStudioKitTests/StudioViewModelTests.swift`
- Create: `tests/LocalOCRStudioKitTests/StudioErrorPresentationTests.swift`

**Interfaces:**
- Consumes: `StudioOCRClient`, `StudioProgress`, `StudioDocumentResult`, `LocalOCRError`, `StudioClientError`
- Produces: `StudioPresentedError`, `StudioErrorPresentation`, `StudioState`, and `@MainActor @Observable StudioViewModel`

- [ ] **Step 1: Write the failing state-machine tests**

Cover:

```swift
@Test func startsEmpty()
@Test func openingAFileMovesFromProcessingToResult()
@Test func progressUpdatesTheCurrentProcessingState()
@Test func openingASecondFileCancelsTheFirst()
@Test func lateFirstResultCannotReplaceTheSecondResult()
@Test func cancelReturnsToEmptyWithoutShowingAnError()
@Test func clearRemovesTheVisibleResultAndSourceReference()
@Test func failureContainsCurrentSourceAndPresentedErrorWithoutPriorResult()
```

Use a continuation-controlled `StudioOCRClient` fake and assert cancellation
was observed. Run:

```bash
swift test --filter LocalOCRStudioKitTests.StudioViewModelTests
```

Expected: FAIL because the state machine does not exist.

- [ ] **Step 2: Write failing error-presentation tests**

Freeze these titles:

```text
File Not Found
Unsupported File
Couldn’t Read Document
Permission Needed
OCR Failed
Not Enough Disk Space
Choose Another Destination
Output Already Exists
Document Changed
Operation Cancelled
```

Assert technical details contain no newline-delimited source content and no
unrelated `/Users/` path.

- [ ] **Step 3: Implement the error model**

```swift
public struct StudioPresentedError: Sendable, Equatable {
    public let title: String
    public let message: String
    public let details: String?
}

public enum StudioErrorPresentation {
    public static func present(_ error: any Error) -> StudioPresentedError
}
```

Map every `LocalOCRError` case explicitly. Unknown errors use
`title == "Couldn’t Process Document"` and a sanitized localized description.

- [ ] **Step 4: Define state**

```swift
public enum StudioState: Equatable {
    case empty
    case processing(sourceURL: URL, progress: StudioProgress)
    case result(StudioDocumentResult)
    case failure(sourceURL: URL, StudioPresentedError)
}
```

- [ ] **Step 5: Implement `StudioViewModel`**

```swift
@MainActor
@Observable
public final class StudioViewModel {
    public private(set) var state: StudioState = .empty

    public init(client: any StudioOCRClient = LocalOCRStudioClient())
    public func open(_ sourceURL: URL)
    public func retry()
    public func cancel()
    public func clear()
}
```

Keep:

```swift
private var processingTask: Task<Void, Never>?
private var generation = UUID()
private var retryURL: URL?
```

Every `open` cancels the prior task, creates a new generation, and updates
state only when the completing task still owns that generation. Treat
`CancellationError` and `LocalOCRError.cancelled` as cancellation, not failure.
Map every other error through `StudioErrorPresentation.present(_:)`.

- [ ] **Step 6: Run tests**

```bash
swift test --filter LocalOCRStudioKitTests.StudioViewModelTests
swift test --filter LocalOCRStudioKitTests.StudioErrorPresentationTests
swift test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LocalOCRStudioKit/StudioViewModel.swift \
  Sources/LocalOCRStudioKit/StudioErrorPresentation.swift \
  tests/LocalOCRStudioKitTests/StudioViewModelTests.swift \
  tests/LocalOCRStudioKitTests/StudioErrorPresentationTests.swift
git commit -m "feat: add LocalOCR Studio document state"
```

### Task 3: Add document actions

**Files:**
- Create: `Sources/LocalOCRStudioKit/StudioDocumentActions.swift`
- Create: `tests/LocalOCRStudioKitTests/StudioDocumentActionsTests.swift`

**Interfaces:**
- Consumes: `StudioDocumentResult`, `StudioOCRClient`
- Produces: `StudioClipboardWriting`, `StudioTextWriting`, `NSPasteboardStudioClipboard`, `AtomicStudioTextWriter`, `StudioDocumentActions`

- [ ] **Step 1: Write failing action tests**

Cover:

```swift
@Test func copyWritesExactRecognizedText()
@Test func suggestedTextNameUsesSourceStem()
@Test func textSaveWritesUTF8Atomically()
@Test func searchablePDFFailsForImageResults()
@Test func searchablePDFUsesTheChosenDestination()
```

- [ ] **Step 2: Implement action interfaces**

```swift
public protocol StudioClipboardWriting {
    func write(_ text: String)
}

public protocol StudioTextWriting {
    func write(_ text: String, to destinationURL: URL) throws
}

public struct NSPasteboardStudioClipboard: StudioClipboardWriting {
    public init()
    public func write(_ text: String)
}

public struct AtomicStudioTextWriter: StudioTextWriting {
    public init()
    public func write(_ text: String, to destinationURL: URL) throws
}

@MainActor
public final class StudioDocumentActions {
    public init(
        client: any StudioOCRClient,
        clipboard: any StudioClipboardWriting,
        textWriter: any StudioTextWriting
    )

    public func copy(_ result: StudioDocumentResult)
    public func suggestedTextFilename(for result: StudioDocumentResult) -> String
    public func suggestedSearchableFilename(for result: StudioDocumentResult) -> String
    public func saveText(_ result: StudioDocumentResult, to destinationURL: URL) throws
    public func createSearchablePDF(
        _ result: StudioDocumentResult,
        at destinationURL: URL,
        progress: @escaping @Sendable (StudioProgress) -> Void
    ) async throws -> URL
}
```

The production clipboard adapter uses `NSPasteboard.general`. The text writer
uses `Data(text.utf8).write(to:options:.atomic)` only after `NSSavePanel`
returns `.OK`. Searchable PDF rejects image results before calling the client.

- [ ] **Step 3: Run focused and full tests**

```bash
swift test --filter LocalOCRStudioKitTests.StudioDocumentActionsTests
swift test
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/LocalOCRStudioKit/StudioDocumentActions.swift \
  tests/LocalOCRStudioKitTests/StudioDocumentActionsTests.swift
git commit -m "feat: add LocalOCR Studio document actions"
```

### Task 4: Build the Focused Canvas SwiftUI interface

**Files:**
- Create: `Sources/LocalOCRStudioKit/LocalOCRStudioView.swift`
- Create: `Sources/LocalOCRStudioKit/StudioDropZoneView.swift`
- Create: `Sources/LocalOCRStudioKit/StudioResultView.swift`
- Create: `Sources/LocalOCRStudioKit/StudioStatusViews.swift`
- Create: `tests/LocalOCRStudioKitTests/StudioViewContractTests.swift`

**Interfaces:**
- Consumes: `StudioViewModel`, `StudioDocumentActions`, `StudioState`
- Produces: `LocalOCRStudioView` and the approved Empty, Processing, Result, and Error surfaces

- [ ] **Step 1: Write failing view-contract tests**

Expose pure presentation values through:

```swift
public struct StudioViewContract: Equatable {
    public let primaryTitle: String
    public let statusText: String
    public let canCopy: Bool
    public let canSaveText: Bool
    public let canCreateSearchablePDF: Bool
    public let canCancel: Bool
    public let canRetry: Bool
}
```

Test one contract for each state. Require the local-processing statement in
Empty and Processing and require searchable PDF only for PDF results.

- [ ] **Step 2: Implement the Focused Canvas**

`LocalOCRStudioView` uses:

```swift
@State private var model: StudioViewModel
```

Its public initializer is:

```swift
public init(model: StudioViewModel, actions: StudioDocumentActions)
```

and renders:

- an empty drop zone with `Open Document`;
- filename plus `ProgressView` and `Cancel` while processing;
- document summary plus `ScrollView { Text(result.text).textSelection(.enabled) }`;
- `Copy`, `Save Text`, and conditional `Create Searchable PDF`; or
- an error card with `Details`, `Retry`, and `Choose Another Document`.

Keep action-specific UI state in the view:

```swift
@State private var actionError: StudioPresentedError?
@State private var isCreatingSearchablePDF = false
```

Map text-save and searchable-PDF failures through
`StudioErrorPresentation.present(_:)` and show them in an alert. Disable
result actions while searchable-PDF creation is active, expose its
`StudioProgress`, and clear the action error when a new document is opened.

The minimum window content size is 760×520 points. Do not add navigation,
history, batch controls, OCR settings, or an MCP setup screen.

- [ ] **Step 3: Add Open and drop handling**

Open uses:

```swift
let panel = NSOpenPanel()
panel.allowsMultipleSelection = false
panel.canChooseDirectories = false
panel.allowedContentTypes = [.pdf, .image]
```

Drop accepts one `UTType.fileURL` provider, rejects a second item, resolves the
file URL, and calls the same `model.open(_:)` path as Open.

- [ ] **Step 4: Add Save dialogs**

Text:

```swift
panel.allowedContentTypes = [.plainText]
panel.nameFieldStringValue = actions.suggestedTextFilename(for: result)
```

Searchable PDF:

```swift
panel.allowedContentTypes = [.pdf]
panel.nameFieldStringValue = actions.suggestedSearchableFilename(for: result)
```

Never default to the source URL itself. If searchable output already exists,
present the service error and leave the source untouched.

- [ ] **Step 5: Add accessibility**

Give the drop zone, progress, result text, details disclosure, and every button
stable accessibility identifiers:

```text
studio.drop-zone
studio.open
studio.progress
studio.result-text
studio.copy
studio.save-text
studio.create-searchable
studio.cancel
studio.retry
studio.choose-another
studio.error-details
```

- [ ] **Step 6: Run tests**

```bash
swift test --filter LocalOCRStudioKitTests.StudioViewContractTests
swift test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LocalOCRStudioKit tests/LocalOCRStudioKitTests/StudioViewContractTests.swift
git commit -m "feat: build LocalOCR Studio focused canvas"
```

### Task 5: Create the real macOS app project and unsigned build

**Files:**
- Create: `project.yml`
- Create: `LocalOCR Studio.xcodeproj/project.pbxproj` via XcodeGen
- Create: `LocalOCR Studio.xcodeproj/xcshareddata/xcschemes/LocalOCR Studio.xcscheme`
- Create: `App/LocalOCRStudioApp.swift`
- Create: `App/LocalOCRStudioUITestSupport.swift`
- Create: `AppUITests/LocalOCRStudioUITests.swift`
- Create: `scripts/build-unsigned-studio-app.sh`
- Create: `tests/contract/test_studio_app_project.py`

**Interfaces:**
- Consumes: `LocalOCRStudioKit`, stable Xcode, release metadata
- Produces: `dist/unsigned-app/LocalOCR Studio.app`

- [ ] **Step 1: Write the failing project contract**

Assert:

- `project.yml`, the shared scheme, app entry point, UI tests, and unsigned
  build script exist;
- bundle ID/version/build/minimum OS/arm64 are exact;
- app target depends on local package product `LocalOCRStudioKit`;
- `ENABLE_HARDENED_RUNTIME` is enabled;
- no network or debug entitlement is configured;
- build script selects stable Xcode and writes only under
  `dist/unsigned-app` and a validated temporary DerivedData directory.

Run:

```bash
.venv/bin/python -m pytest tests/contract/test_studio_app_project.py -q
```

Expected: FAIL because the project does not exist.

- [ ] **Step 2: Create `project.yml`**

Use this source-of-truth shape:

```yaml
name: LocalOCR Studio
options:
  deploymentTarget:
    macOS: "14.0"
packages:
  LocalOCR:
    path: .
targets:
  LocalOCR Studio:
    type: application
    platform: macOS
    sources:
      - path: App
    dependencies:
      - package: LocalOCR
        product: LocalOCRStudioKit
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.rayconsulting.localocr
        PRODUCT_NAME: LocalOCR Studio
        MARKETING_VERSION: 0.2.0
        CURRENT_PROJECT_VERSION: 1
        MACOSX_DEPLOYMENT_TARGET: 14.0
        ARCHS: arm64
        SWIFT_VERSION: 6.0
        ENABLE_HARDENED_RUNTIME: YES
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_CFBundleDisplayName: LocalOCR Studio
        INFOPLIST_KEY_LSApplicationCategoryType: public.app-category.productivity
  LocalOCR StudioUITests:
    type: bundle.ui-testing
    platform: macOS
    sources:
      - path: AppUITests
    dependencies:
      - target: LocalOCR Studio
```

Add a shared scheme that builds the app and runs the UI test target.

- [ ] **Step 3: Add the thin app entry point**

```swift
@main
struct LocalOCRStudioApp: App {
    var body: some Scene {
        WindowGroup {
            LocalOCRStudioRoot.makeView()
        }
        .defaultSize(width: 900, height: 640)
    }
}
```

`LocalOCRStudioRoot.makeView()` constructs one shared `LocalOCRStudioClient`,
`StudioViewModel`, and `StudioDocumentActions` in
`App/LocalOCRStudioApp.swift`:

```swift
@MainActor
enum LocalOCRStudioRoot {
    static func makeView() -> LocalOCRStudioView {
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
```

- [ ] **Step 4: Add DEBUG-only UI fixtures**

Compile UI-test state only under:

```swift
#if DEBUG
```

and require both `XCTestConfigurationFilePath` and
`LOCALOCR_STUDIO_UI_STATE`. Supported values are exactly `empty`, `result`,
and `error`. `LocalOCRStudioRoot.makeView()` delegates to the DEBUG support
only when both values are present; otherwise it constructs the production
client and actions shown above. Release builds contain no environment-driven
state override.

- [ ] **Step 5: Generate and commit the Xcode project**

```bash
xcodegen generate --spec project.yml
git diff --check
```

Expected: generated project and shared scheme use the committed relative local
package reference and contain no user-specific absolute paths.

- [ ] **Step 6: Implement the unsigned build script**

The script:

1. Sources `scripts/release-toolchain.sh`.
2. Calls `select_release_developer_dir` and validates stable Xcode.
3. Creates `mktemp -d /tmp/localocr-studio-build.XXXXXX`.
4. Runs `xcodebuild test` for the shared scheme on `platform=macOS,arch=arm64`.
5. Runs `xcodebuild build -configuration Release` with
   `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ARCHS=arm64`.
6. Copies only the resulting app to
   `dist/unsigned-app/LocalOCR Studio.app`.
7. Validates bundle metadata and the arm64 executable.
8. Cleans only its validated temporary root on exit.

- [ ] **Step 7: Run project, UI, and contract tests**

```bash
xcodegen generate --spec project.yml
xcodebuild test \
  -project "LocalOCR Studio.xcodeproj" \
  -scheme "LocalOCR Studio" \
  -destination "platform=macOS,arch=arm64"
.venv/bin/python -m pytest tests/contract/test_studio_app_project.py -q
scripts/build-unsigned-studio-app.sh
```

Expected: UI smoke tests pass and the unsigned app exists with exact metadata.

- [ ] **Step 8: Commit**

```bash
git add project.yml "LocalOCR Studio.xcodeproj" App AppUITests \
  scripts/build-unsigned-studio-app.sh tests/contract/test_studio_app_project.py
git commit -m "build: add LocalOCR Studio macOS app"
```

### Task 6: Integrate the app with the direct-release policy

**Files:**
- Modify: `tests/contract/test_direct_release_scripts.py`
- Modify: `scripts/stage-direct-release.sh`
- Modify: `README.md`
- Create: `docs/studio.md`

**Interfaces:**
- Consumes: `dist/unsigned-app/LocalOCR Studio.app` and existing release scripts
- Produces: staged app containing only the app executable, `localocr`, and `localocr-mcp`

- [ ] **Step 1: Add failing real-app release contracts**

Test that:

- unsigned build output is outside `dist/direct-release` so staging cleanup
  cannot delete its input;
- the app executable name is exactly `LocalOCR Studio`;
- staging accepts the exact metadata and rejects altered ID/version/build;
- staged `Contents/Helpers` contains exactly `localocr` and `localocr-mcp`;
- the app executable and helpers are arm64 with macOS 14 minimum;
- the app executable has only Apple/system dependencies and allowed RPATHs;
- no app resource contains a private `/Users/` path.

- [ ] **Step 2: Make only the minimal staging changes**

Keep the existing fail-closed cleanup, symlink, xattr, metadata, and helper
policies. Change staging only where the real Xcode app demonstrates a missing
validated resource or executable condition. Do not broaden the nested-code
allowlist beyond:

```text
Contents/MacOS/LocalOCR Studio
Contents/Helpers/localocr
Contents/Helpers/localocr-mcp
```

- [ ] **Step 3: Document the GUI and MCP separation**

`docs/studio.md` must state:

- GUI is single-document and automatic;
- MCP retains batch;
- MCP executable path inside an installed app;
- accepted inputs and local-only behavior;
- Copy, Save Text, and searchable-PDF behavior;
- no history or cloud processing; and
- real beta is not available until release gates pass.

- [ ] **Step 4: Run full verification**

```bash
swift test
.venv/bin/python -m pytest -q
scripts/build-native-tools.sh
scripts/smoke-native-tools.sh
scripts/build-unsigned-studio-app.sh
```

Then run staging with:

```bash
export LOCALOCR_UNSIGNED_APP="$PWD/dist/unsigned-app/LocalOCR Studio.app"
export LOCALOCR_RELEASE_VERSION="0.2.0"
export LOCALOCR_RELEASE_BUILD="1"
export LOCALOCR_EXPECTED_BUNDLE_ID="com.rayconsulting.localocr"
scripts/stage-direct-release.sh
```

Expected: staged unsigned app with two helpers and no mutation to the unsigned
input.

- [ ] **Step 5: Commit**

```bash
git add tests/contract/test_direct_release_scripts.py \
  scripts/stage-direct-release.sh README.md docs/studio.md
git commit -m "test: integrate LocalOCR Studio release candidate"
```

### Task 7: Review and merge the Beta 1 app implementation

**Files:**
- Modify only files required by review findings
- External: private GitHub pull request
- External: MCP MacVision milestone overview and evidence

**Interfaces:**
- Consumes: Tasks 1–6 commits and green verification
- Produces: clean merged release commit on private `main`

- [ ] **Step 1: Run final branch verification**

```bash
swift test
.venv/bin/python -m pytest -q
xcodebuild test \
  -project "LocalOCR Studio.xcodeproj" \
  -scheme "LocalOCR Studio" \
  -destination "platform=macOS,arch=arm64"
scripts/build-native-tools.sh
scripts/smoke-native-tools.sh
scripts/build-unsigned-studio-app.sh
git diff --check origin/main...HEAD
git status --short
```

Expected: every command passes and status is clean.

- [ ] **Step 2: Request whole-branch code review**

Review `origin/main...HEAD` against the approved design and this plan. Require
review of state cancellation, source immutability, output safety, SwiftUI
accessibility, DEBUG-only hooks, project portability, app metadata, release
dependencies/RPATHs, and helper embedding.

- [ ] **Step 3: Fix every Critical and Important finding**

Use one focused TDD fix round per reviewer response, rerun the affected suite,
and request re-review until no Critical or Important finding remains.

- [ ] **Step 4: Push and merge only after owner choice**

Push `feature/localocr-studio-beta1`, create a private pull request targeting
`main`, include exact test counts and the external release gates, then use the
finishing-a-development-branch choice selected by the owner.

- [ ] **Step 5: Update the business milestone record**

Record only the actual merge commit, dated test evidence, and supported costs.
Do not add inferred hours, release URLs, downloads, signing results, or notary
results.

### Task 8: Produce signed and notarized Beta Candidate 1

**Files:**
- Generated only: `dist/unsigned-app/`
- Generated only: `dist/direct-release/`
- External evidence: MCP MacVision milestone folder

**Interfaces:**
- Consumes: clean merged release commit, installed Developer ID certificate, verified notary keychain profile
- Produces: signed, notarized, stapled final ZIP and SHA-256

- [ ] **Step 1: Start from a clean checkout of the exact merged commit**

```bash
git switch main
git pull --ff-only origin main
git status --short
git rev-parse HEAD
```

Save the commit hash in milestone evidence. Stop if the checkout is dirty.

- [ ] **Step 2: Reuse the proven AI Neural Gauge release environment**

Read, before troubleshooting:

```text
/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/ai-neural-gauge/.worktrees/v0.3-swiftui/scripts/build-release.sh
/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/ai-neural-gauge/.worktrees/v0.3-swiftui/scripts/release-toolchain.sh
/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/ai-neural-gauge/.worktrees/v0.3-swiftui/scripts/verify-release.sh
```

Reuse its pattern of a validated stable toolchain, isolated temporary
DerivedData/archive paths, explicit app verification, and confined cleanup.
For LocalOCR, use the already-reviewed helper-first signing and notary scripts;
do not copy AI Neural Gauge’s old ad-hoc signing command.

- [ ] **Step 3: Verify the external credentials**

```bash
security find-identity -v -p codesigning
test -n "${LOCALOCR_NOTARY_PROFILE:-}"
xcrun notarytool history \
  --keychain-profile "$LOCALOCR_NOTARY_PROFILE" \
  --output-format json >/dev/null
```

Require the exact installed identity
`Developer ID Application: John Scott Ray (DZ8B5454ZN)`. Stop without storing
or requesting secrets if the profile is unavailable.

- [ ] **Step 4: Build and stage the real app**

```bash
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export LOCALOCR_RELEASE_VERSION="0.2.0"
export LOCALOCR_RELEASE_BUILD="1"
export LOCALOCR_EXPECTED_BUNDLE_ID="com.rayconsulting.localocr"
scripts/build-unsigned-studio-app.sh
export LOCALOCR_UNSIGNED_APP="$PWD/dist/unsigned-app/LocalOCR Studio.app"
scripts/stage-direct-release.sh
```

Preserve toolchain and pre-signing hashes from the generated evidence.

- [ ] **Step 5: Sign helpers first and app last**

```bash
scripts/sign-direct-release.sh
scripts/verify-direct-release.sh
```

Require all three objects to show the exact authority/team, secure timestamp,
Hardened Runtime, strict signature verification, and complete absence of
`get-task-allow`. Stop on any metadata or xattr error.

- [ ] **Step 6: Notarize, staple, assess, and package**

```bash
scripts/notarize-direct-release.sh
```

Require:

- notary submission ID present;
- status exactly `Accepted`;
- stapler validation passes;
- Gatekeeper assessment passes;
- extracted final ZIP passes all explicit signature, dependency, RPATH,
  helper-version, MCP-initialization, and metadata checks; and
- final SHA-256 validation passes.

- [ ] **Step 7: Preserve candidate evidence**

Copy the final commit, test counts, signature details, submission ID/status,
stapler result, Gatekeeper result, and SHA-256 into the MCP MacVision milestone
record. Record no downloads and no second-Mac PASS yet.

### Task 9: Download-test, second-Mac test, and owner-gated private beta

**Files:**
- Generated external acceptance evidence only
- External: private GitHub prerelease
- External: `MCP-MacVision-Beta-Metrics.csv`
- External: `MCP-MacVision-Feedback-Log.csv`

**Interfaces:**
- Consumes: Beta Candidate 1 ZIP/checksum and merged release commit
- Produces: two-Mac acceptance and, only after owner authorization, private beta

- [ ] **Step 1: Create a draft private prerelease**

Create a draft prerelease targeting the exact merged commit. Upload only:

```text
LocalOCR-Studio-0.2.0-1.zip
LocalOCR-Studio-0.2.0-1.sha256
```

Release notes must state macOS 14+, Apple silicon, local-only processing,
single-document GUI, batch through MCP, known limitations, installation,
checksum verification, and the owner-approved feedback channel.

- [ ] **Step 2: Download and verify on the build Mac**

Download both assets through the intended tester path, then run:

```bash
export LOCALOCR_EXPECTED_BUNDLE_ID="com.rayconsulting.localocr"
export LOCALOCR_RELEASE_VERSION="0.2.0"
export LOCALOCR_RELEASE_BUILD="1"
scripts/test-downloaded-release.sh \
  "$PWD/downloads/LocalOCR-Studio-0.2.0-1.zip" \
  "$PWD/downloads/LocalOCR-Studio-0.2.0-1.sha256"
```

Also launch the downloaded app and manually test:

- native-text PDF;
- image-only PDF;
- one ImageIO-decodable image;
- Copy and Save Text;
- searchable-PDF Save As; and
- source hashes unchanged.

- [ ] **Step 3: Repeat on a second Mac**

Use the same downloaded asset and checksum. Complete a private copy of
`docs/release/second-mac-acceptance.md` with the actual machine and tester
evidence. Do not commit personal machine identifiers without owner approval.

- [ ] **Step 4: Stop for explicit owner publication authorization**

Present the final commit, tag, SHA-256, notary status, build-Mac PASS, and
second-Mac PASS. Do not publish the prerelease until the owner explicitly says
to publish it.

- [ ] **Step 5: Publish and establish the beta baseline**

After explicit approval, publish the private prerelease. Immediately record:

- release tag and URL;
- primary ZIP download count separately from checksum count;
- known internal/test downloads in notes;
- feedback count, responses sent, open bugs, and issue/discussion comments.

Start feedback-log rows only for substantive tester input. Do not represent raw
download counts as unique external testers.

- [ ] **Step 6: Close the milestone record**

Update the project overview and milestone evidence with final merge/release
commits, release URL, checksum, test counts, signing/notary/stapler/Gatekeeper
results, two-Mac results, direct receipts, supported allocations, and only
evidence-reconciled owner time.

---

## Final Acceptance Checklist

- [ ] Focused Canvas handles one document automatically.
- [ ] PDF and ImageIO inputs work; source hashes remain unchanged.
- [ ] Result text is read-only and page ordered.
- [ ] Copy, Save Text, and PDF-only searchable output work safely.
- [ ] No document history, network request, telemetry, or production test hook exists.
- [ ] MCP retains all six tools and batch behavior.
- [ ] App bundle metadata is exactly `com.rayconsulting.localocr`, `0.2.0`, `1`.
- [ ] Stable-Xcode arm64/macOS 14 build passes.
- [ ] Swift, Python, Xcode UI, artifact, and release-contract suites pass.
- [ ] Helpers sign first, app last; all signatures have timestamp and runtime.
- [ ] Dependencies/RPATHs/strings/entitlements meet policy.
- [ ] Notarization is `Accepted`; stapler and Gatekeeper pass.
- [ ] Final downloaded ZIP checksum and extracted-copy verification pass.
- [ ] Build Mac and second Mac acceptance both say PASS.
- [ ] Owner explicitly authorizes publication.
- [ ] Beta metrics and feedback logs begin only after publication.
