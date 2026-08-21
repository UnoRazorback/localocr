# LocalOCR Studio Desktop Batch Beta 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a signed-candidate-quality LocalOCR Studio `0.3.0-beta.1` desktop batch workflow that accepts files and recursive folders, reviews an immutable queue, processes exactly one document at a time, and writes safe collision-free outputs to a chosen folder.

**Architecture:** Add isolated batch discovery, output-planning, execution, and observable coordination components to `LocalOCRStudioKit`. The coordinator calls the existing native `StudioOCRClient` directly; the single-document view model and the CLI/MCP tool contracts remain intact. SwiftUI receives a dedicated batch workspace, while release metadata and verifier expectations move together to version `0.3.0`, build `2`.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, Observation, AppKit, UniformTypeIdentifiers, Xcode UI Testing, Python `pytest` release-contract tests, existing Developer ID/notarization shell pipeline.

**Spec:** `docs/superpowers/specs/2026-08-21-localocr-desktop-batch-beta2-design.md`

## Global Constraints

- Apple silicon only; deployment target is exactly macOS 14.0 or later.
- Target app/package version is `0.3.0`; build is `2`; prerelease tag is `v0.3.0-beta.1`.
- No document contents, recognized text, filenames, paths, thumbnails, or hashes leave the Mac.
- No telemetry, accounts, cloud processing, HTTP listener, or network entitlement.
- Inputs remain immutable; outputs are separate, confined beneath the chosen output root, and never overwrite existing files.
- Files and recursive folders share one immutable review queue; symbolic links and packages are never traversed.
- Processing concurrency is exactly one.
- PDFs produce `_searchable.pdf`; images produce UTF-8 `.txt`; PDFs do not receive an automatic text sidecar.
- Existing single-document behavior and CLI/MCP request/response shapes remain compatible.
- Publication, release mutation, and public campaign changes are outside this plan and require separate owner authorization.

---

### Task 1: Batch Domain Models and State Contracts

**Files:**
- Create: `Sources/LocalOCRStudioKit/StudioBatchModels.swift`
- Create: `tests/LocalOCRStudioKitTests/StudioBatchModelsTests.swift`

**Interfaces:**
- Consumes: `StudioDocumentKind`, `StudioProgress`, `StudioPresentedError`.
- Produces: `StudioBatchCandidate`, `StudioBatchSkippedInput`, `StudioBatchDiscovery`, `StudioBatchReservation`, `StudioBatchItem`, `StudioBatchItemState`, `StudioBatchPhase`, and `StudioBatchSummary` used by every later task.

- [ ] **Step 1: Write failing model-contract tests**

Create tests that compile against the exact public model surface and prove summary counts:

```swift
import Foundation
@testable import LocalOCRStudioKit
import Testing

@Suite struct StudioBatchModelsTests {
    @Test func summaryCountsEveryTerminalState() {
        let items = [
            item(state: .completed(URL(fileURLWithPath: "/out/a_searchable.pdf"))),
            item(state: .failed(.init(title: "OCR Failed", message: "Could not recognize this file.", details: nil))),
            item(state: .cancelled),
        ]
        let summary = StudioBatchSummary(items: items, skippedCount: 2)

        #expect(summary.completed == 1)
        #expect(summary.failed == 1)
        #expect(summary.cancelled == 1)
        #expect(summary.skipped == 2)
    }

    @Test func onlyFailedItemsAreRetryable() {
        #expect(StudioBatchItemState.failed(.init(title: "Failed", message: "x", details: nil)).isRetryable)
        #expect(!StudioBatchItemState.cancelled.isRetryable)
        #expect(!StudioBatchItemState.queued.isRetryable)
    }
}
```

- [ ] **Step 2: Run the focused tests and confirm the red state**

Run:

```bash
swift test --filter StudioBatchModelsTests
```

Expected: compilation fails because the batch model types do not exist.

- [ ] **Step 3: Implement the exact domain types**

Use these declarations as the stable cross-task contract:

```swift
public struct StudioBatchIssue: Sendable, Equatable {
    public let title: String
    public let message: String
    public let details: String?
}

public struct StudioBatchCandidate: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sourceURL: URL
    public let standardizedSourceURL: URL
    public let kind: StudioDocumentKind
    public let relativePath: String
    public let outputGroupName: String?
}

public struct StudioBatchSkippedInput: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sourceURL: URL
    public let reason: StudioBatchIssue
}

public struct StudioBatchDiscovery: Sendable, Equatable {
    public let candidates: [StudioBatchCandidate]
    public let skipped: [StudioBatchSkippedInput]
    public let duplicateCount: Int
    public let selectedFolderRoots: [URL]
}

public struct StudioBatchReservation: Sendable, Equatable {
    public let finalURL: URL
}

public enum StudioBatchItemState: Sendable, Equatable {
    case queued
    case processing(StudioProgress)
    case completed(URL)
    case skipped(StudioBatchIssue)
    case failed(StudioBatchIssue)
    case cancelled
}

public struct StudioBatchItem: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let candidate: StudioBatchCandidate
    public var reservation: StudioBatchReservation
    public var state: StudioBatchItemState
}

public enum StudioBatchPhase: Sendable, Equatable {
    case empty
    case reviewing
    case processing
    case complete
}
```

Add computed properties for terminal/retryable states and a `StudioBatchSummary.init(items:skippedCount:)` that derives counts rather than accepting mutable counters.
Provide explicit public initializers for every public struct; do not rely on internal synthesized memberwise initializers.

- [ ] **Step 4: Run model tests**

Run:

```bash
swift test --filter StudioBatchModelsTests
```

Expected: all `StudioBatchModelsTests` pass.

- [ ] **Step 5: Commit the domain contract**

```bash
git add Sources/LocalOCRStudioKit/StudioBatchModels.swift tests/LocalOCRStudioKitTests/StudioBatchModelsTests.swift
git commit -m "feat: define Studio batch domain models"
```

---

### Task 2: Safe Mixed File and Recursive Folder Discovery

**Files:**
- Create: `Sources/LocalOCRStudioKit/BatchInputEnumerator.swift`
- Create: `tests/LocalOCRStudioKitTests/BatchInputEnumeratorTests.swift`

**Interfaces:**
- Consumes: `StudioBatchCandidate`, `StudioBatchDiscovery`, `StudioBatchSkippedInput` from Task 1.
- Produces: `StudioBatchInputEnumerating.discover(selections:)` and `BatchInputEnumerator` for the coordinator.

- [ ] **Step 1: Write failing discovery tests using temporary directories**

Cover direct PDFs/images, recursive folders, relative paths, duplicate selections, hidden files, `.app` packages, symbolic links, unsupported files, and unreadable entries. Generate every fixture under a per-test temporary directory and remove it with `defer`.

```swift
@Test func recursiveDiscoveryIsDeterministicAndDoesNotFollowLinks() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appending(path: "invoice.pdf"))
    try FileManager.default.createDirectory(at: root.appending(path: "nested"), withIntermediateDirectories: false)
    try Data().write(to: root.appending(path: "nested/photo.png"))
    try FileManager.default.createSymbolicLink(
        at: root.appending(path: "linked.pdf"),
        withDestinationURL: root.appending(path: "invoice.pdf")
    )

    let discovery = await BatchInputEnumerator().discover(selections: [root])

    #expect(discovery.candidates.map(\.relativePath) == ["invoice.pdf", "nested/photo.png"])
    #expect(discovery.skipped.contains { $0.sourceURL.lastPathComponent == "linked.pdf" })
}
```

- [ ] **Step 2: Run the focused tests and confirm the red state**

```bash
swift test --filter BatchInputEnumeratorTests
```

Expected: compilation fails because `BatchInputEnumerator` is missing.

- [ ] **Step 3: Implement discovery behind a protocol**

```swift
public protocol StudioBatchInputEnumerating: Sendable {
    func discover(selections: [URL]) async -> StudioBatchDiscovery
}
```

Declare `public actor BatchInputEnumerator: StudioBatchInputEnumerating`, store an actor-isolated `FileManager`, provide `public init(fileManager: FileManager = .default)`, and implement the protocol method with the rules below.

Implementation rules:

- Standardize and resolve each selected path for identity checks without following discovered symbolic links.
- Inspect resource keys for `.isRegularFileKey`, `.isDirectoryKey`, `.isSymbolicLinkKey`, `.isPackageKey`, and `.isHiddenKey`.
- Classify `.pdf` case-insensitively as `.pdf`; classify `UTType(filenameExtension:)?.conforms(to: .image) == true` as `.image`.
- Sort accepted and skipped entries by standardized path before returning.
- For selected folders, store the folder root and use the descendant path as `relativePath`; for direct files, use the filename and `outputGroupName == nil`.
- Deduplicate by standardized/resolved source URL and increment `duplicateCount` without creating another item.
- Return skipped issues with explicit titles such as `Unsupported File`, `Symbolic Link Skipped`, `Package Skipped`, and `File Unavailable`.

- [ ] **Step 4: Run the discovery tests**

```bash
swift test --filter BatchInputEnumeratorTests
```

Expected: all discovery tests pass, including deterministic ordering and link/package refusal.

- [ ] **Step 5: Commit safe discovery**

```bash
git add Sources/LocalOCRStudioKit/BatchInputEnumerator.swift tests/LocalOCRStudioKitTests/BatchInputEnumeratorTests.swift
git commit -m "feat: discover safe desktop batch inputs"
```

---

### Task 3: Confined Output Planning and Collision Reservations

**Files:**
- Create: `Sources/LocalOCRStudioKit/BatchOutputPlanner.swift`
- Create: `tests/LocalOCRStudioKitTests/BatchOutputPlannerTests.swift`

**Interfaces:**
- Consumes: `StudioBatchDiscovery`, `StudioBatchItem`, and `StudioBatchReservation`.
- Produces: async `StudioBatchOutputPlanning.makePlan(discovery:outputRoot:)`, `StudioBatchPlan`, and `StudioBatchPlanningError`.

- [ ] **Step 1: Write failing planner tests**

Tests must prove PDF/image naming, direct-file root placement, preserved recursive structure, numbered equal folder names, existing-output numbering, and rejection of equal/nested output roots.

```swift
@Test func existingOutputsReceiveTheFirstFreeNumberedName() async throws {
    let output = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try Data().write(to: output.appending(path: "scan_searchable.pdf"))
    try Data().write(to: output.appending(path: "scan_searchable_2.pdf"))

    let plan = try await BatchOutputPlanner().makePlan(
        discovery: discovery(pdfNamed: "scan.pdf"),
        outputRoot: output
    )

    #expect(plan.items.single.reservation.finalURL.lastPathComponent == "scan_searchable_3.pdf")
}
```

- [ ] **Step 2: Run the planner tests and confirm the red state**

```bash
swift test --filter BatchOutputPlannerTests
```

Expected: compilation fails because planner interfaces do not exist.

- [ ] **Step 3: Implement the planner interfaces and confinement checks**

```swift
public struct StudioBatchPlan: Sendable, Equatable {
    public let outputRoot: URL
    public let items: [StudioBatchItem]
    public let skipped: [StudioBatchSkippedInput]
    public let duplicateCount: Int
}

public protocol StudioBatchOutputPlanning: Sendable {
    func makePlan(
        discovery: StudioBatchDiscovery,
        outputRoot: URL
    ) async throws -> StudioBatchPlan

    func refreshReservation(
        for item: StudioBatchItem,
        outputRoot: URL
    ) async throws -> StudioBatchReservation
}
```

The actor implementation must:

- require the chosen output root to be an existing physical directory rather than a symbolic link;
- reject a destination equal to or nested beneath any `selectedFolderRoots` entry;
- create no directories during planning;
- sanitize relative components by rejecting empty, `.`, and `..` segments;
- preserve folder structure and allocate numbered top-level group names;
- append `_searchable.pdf` to the PDF source stem and `.txt` to the image source stem;
- reserve against both existing paths and earlier reservations in the same plan;
- standardize every candidate final URL and prove it is a strict descendant of the output root; and
- return `StudioBatchPlanningError.unsafeOutputRoot` or `.escapedOutputRoot` rather than a generic string.

- [ ] **Step 4: Run planner tests**

```bash
swift test --filter BatchOutputPlannerTests
```

Expected: all planner tests pass.

- [ ] **Step 5: Commit output planning**

```bash
git add Sources/LocalOCRStudioKit/BatchOutputPlanner.swift tests/LocalOCRStudioKitTests/BatchOutputPlannerTests.swift
git commit -m "feat: plan confined collision-safe batch outputs"
```

---

### Task 4: Atomic PDF and Text Batch Execution

**Files:**
- Create: `Sources/LocalOCRStudioKit/StudioBatchExecutor.swift`
- Create: `tests/LocalOCRStudioKitTests/StudioBatchExecutorTests.swift`

**Interfaces:**
- Consumes: `StudioOCRClient`, `StudioBatchItem`, `StudioBatchReservation`.
- Produces: `StudioBatchItemExecuting.execute(_:progress:)` and `StudioBatchExecutor`.

- [ ] **Step 1: Write failing executor tests**

Cover the exact output mapping, progress forwarding, temporary-file cleanup, no overwrite at commit time, and cancellation cleanup.

```swift
@Test func imageWritesTextThenAtomicallyCommitsTheReservedOutput() async throws {
    let client = RecordingBatchClient(result: imageResult(text: "Café ☕️"))
    let committer = RecordingBatchCommitter()
    let executor = StudioBatchExecutor(client: client, committer: committer)

    let finalURL = try await executor.execute(imageItem()) { _ in }

    #expect(finalURL.lastPathComponent == "photo.txt")
    #expect(await committer.committedText == "Café ☕️")
    #expect(await client.searchableRequests().isEmpty)
}
```

- [ ] **Step 2: Run executor tests and confirm the red state**

```bash
swift test --filter StudioBatchExecutorTests
```

Expected: compilation fails because executor types are missing.

- [ ] **Step 3: Implement atomic execution**

```swift
public protocol StudioBatchItemExecuting: Sendable {
    func execute(
        _ item: StudioBatchItem,
        progress: @escaping @Sendable (StudioProgress) -> Void
    ) async throws -> URL
}
```

Define `StudioBatchOutputCommitting: Sendable` with methods to create a same-filesystem temporary URL, write UTF-8 text, atomically commit without replacement, and discard a temporary path. Implement it as `AtomicStudioBatchOutputCommitter`. Before creating a temporary file, create the reserved parent directories one component at a time, refusing symbolic-link ancestors and rechecking confinement beneath the physical output root. Commit with Darwin `renamex_np` and `RENAME_EXCL` so a race cannot replace an externally created final file. Implement `public actor StudioBatchExecutor: StudioBatchItemExecuting` with an injected `StudioOCRClient` and committer. For a PDF, call `processDocument` first, call `makeSearchablePDF` with the temporary URL, validate that a regular non-symlink PDF exists, then commit. For an image, atomically write `result.text` to the temporary URL, validate UTF-8 readability, then commit. Use `defer` to discard the temporary path on every failure or cancellation. If the final reservation became occupied, throw `LocalOCRError.outputExists`; never replace it.

The committer protocol surface is:

```swift
public protocol StudioBatchOutputCommitting: Sendable {
    func temporaryURL(for finalURL: URL) async throws -> URL
    func writeText(_ text: String, to temporaryURL: URL) async throws
    func commit(_ temporaryURL: URL, to finalURL: URL) async throws
    func discard(_ temporaryURL: URL) async
}
```

- [ ] **Step 4: Run executor and existing action tests**

```bash
swift test --filter StudioBatchExecutorTests
swift test --filter StudioDocumentActionsTests
```

Expected: both suites pass.

- [ ] **Step 5: Commit atomic batch execution**

```bash
git add Sources/LocalOCRStudioKit/StudioBatchExecutor.swift tests/LocalOCRStudioKitTests/StudioBatchExecutorTests.swift
git commit -m "feat: execute batch outputs atomically"
```

---

### Task 5: Sequential Coordinator, Cancellation, and Retry

**Files:**
- Create: `Sources/LocalOCRStudioKit/StudioBatchCoordinator.swift`
- Create: `tests/LocalOCRStudioKitTests/StudioBatchCoordinatorTests.swift`

**Interfaces:**
- Consumes: `StudioBatchInputEnumerating`, `StudioBatchOutputPlanning`, `StudioBatchItemExecuting`, and all batch models.
- Produces: observable `StudioBatchCoordinator` methods used by the SwiftUI workspace.

- [ ] **Step 1: Write failing coordinator tests**

Tests must prove review-before-start, exactly-one active execution, continue-after-failure, cancellation state transitions, late-result rejection, retry-failed-only, external collision refresh, and reset.

```swift
@Test @MainActor func processingNeverExceedsOneActiveItem() async throws {
    let executor = ConcurrencyRecordingExecutor()
    let coordinator = configuredCoordinator(itemCount: 3, executor: executor)

    coordinator.start()
    await executor.completeAllInOrder()
    await coordinator.waitUntilIdleForTesting()

    #expect(await executor.maximumActiveCount == 1)
    #expect(coordinator.summary.completed == 3)
}
```

- [ ] **Step 2: Run coordinator tests and confirm the red state**

```bash
swift test --filter StudioBatchCoordinatorTests
```

Expected: compilation fails because the coordinator is missing.

- [ ] **Step 3: Implement the observable coordinator**

```swift
@MainActor
@Observable
public final class StudioBatchCoordinator {
    public private(set) var phase: StudioBatchPhase = .empty
    public private(set) var discovery: StudioBatchDiscovery?
    public private(set) var outputRoot: URL?
    public private(set) var items: [StudioBatchItem] = []
    public private(set) var actionError: StudioBatchIssue?

    public var canStart: Bool { phase == .reviewing && !items.isEmpty && outputRoot != nil }
    public var summary: StudioBatchSummary {
        StudioBatchSummary(
            items: items,
            skippedCount: discovery?.skipped.count ?? 0
        )
    }

    public func addSelections(_ urls: [URL])
    public func chooseOutputRoot(_ url: URL)
    public func start()
    public func cancel()
    public func retryFailed()
    public func startNewBatch()
}
```

Use one owned `Task<Void, Never>` and a generation UUID. Iterate item indices with `for index in items.indices`, awaiting `executor.execute` before advancing. Translate errors through `StudioErrorPresentation.present(_:)` into `StudioBatchIssue`; treat `CancellationError` and `LocalOCRError.cancelled` as cancellation, not failure. On cancel, invalidate the generation, cancel the task, preserve completed items, mark the active and queued items cancelled, and ignore late progress/results. On retry, refresh reservations only for failed items and run those indices sequentially.

Add `@_spi(Testing) public func waitUntilIdleForTesting() async` that awaits the currently owned processing task without exposing it to the production UI. The test target imports `@_spi(Testing) @testable import LocalOCRStudioKit` and uses this helper instead of sleeps.

- [ ] **Step 4: Run coordinator tests**

```bash
swift test --filter StudioBatchCoordinatorTests
```

Expected: all coordinator tests pass and the concurrency spy reports exactly one.

- [ ] **Step 5: Commit coordinator behavior**

```bash
git add Sources/LocalOCRStudioKit/StudioBatchCoordinator.swift tests/LocalOCRStudioKitTests/StudioBatchCoordinatorTests.swift
git commit -m "feat: coordinate sequential desktop batches"
```

---

### Task 6: Batch Workspace, Panels, Drop Handling, and Accessibility

**Files:**
- Create: `Sources/LocalOCRStudioKit/BatchWorkspaceView.swift`
- Create: `Sources/LocalOCRStudioKit/BatchStatusViews.swift`
- Create: `tests/LocalOCRStudioKitTests/BatchViewContractTests.swift`
- Modify: `Sources/LocalOCRStudioKit/LocalOCRStudioView.swift`
- Modify: `Sources/LocalOCRStudioKit/StudioDropZoneView.swift`
- Modify: `App/LocalOCRStudioApp.swift`
- Modify: `App/LocalOCRStudioUITestSupport.swift`
- Modify: `AppUITests/LocalOCRStudioUITests.swift`
- Modify: `tests/contract/test_studio_app_project.py`

**Interfaces:**
- Consumes: `StudioBatchCoordinator` from Task 5.
- Produces: `BatchWorkspaceView(coordinator:onReturnToSingle:)`, `StudioWorkspaceMode`, accessibility identifiers, and debug-only UI fixtures.

- [ ] **Step 1: Write failing pure view-contract tests**

Create a `BatchViewContract` that derives copy and control availability from coordinator phase and counts. Test exact titles, summary strings, and enabled states without launching SwiftUI.

```swift
@Test func reviewRequiresOutputBeforeStart() {
    let contract = BatchViewContract(
        phase: .reviewing,
        acceptedCount: 3,
        skippedCount: 1,
        hasOutputRoot: false
    )
    #expect(contract.primaryTitle == "Review Batch")
    #expect(contract.canStart == false)
    #expect(contract.summaryText == "3 supported • 1 skipped")
}
```

- [ ] **Step 2: Add failing UI fixture and UI tests**

Extend `FixtureState` with `batchReview`, `batchProcessing`, and `batchComplete`. Add UI tests requiring these identifiers:

```text
studio.new-batch
studio.batch.workspace
studio.batch.add-files
studio.batch.add-folder
studio.batch.choose-output
studio.batch.start
studio.batch.cancel
studio.batch.retry-failed
studio.batch.reveal-output
studio.batch.copy-diagnostics
studio.batch.new
studio.batch.return-single
studio.batch.row.00000000-0000-0000-0000-000000000001
```

Run:

```bash
scripts/release-toolchain.sh
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project "LocalOCR Studio.xcodeproj" -scheme "LocalOCR Studio" \
  -destination 'platform=macOS,arch=arm64' test
```

Expected: UI fixture contract tests fail because the new fixture states and controls are absent.

- [ ] **Step 3: Implement workspace navigation without altering the single-document default**

Add `StudioWorkspaceMode { case single, batch }` state to `LocalOCRStudioView`. Add `onNewBatch` to `StudioDropZoneView` and render a secondary **New Batch…** button. Inject a `StudioBatchCoordinator` into `LocalOCRStudioView`; production construction in `LocalOCRStudioRoot.makeView()` must share the same `LocalOCRStudioClient` between single-document actions and `StudioBatchExecutor`.

The root transition rules are:

```swift
case .single:
    // Render the existing Studio state switch unchanged.
case .batch:
    BatchWorkspaceView(
        coordinator: batchCoordinator,
        onReturnToSingle: { workspaceMode = .single }
    )
```

Returning to single mode is allowed only before processing or after completion; while processing, the user must cancel first.

- [ ] **Step 4: Implement file/folder panels, drag-and-drop, queue rows, and completion controls**

- **Add Files:** `NSOpenPanel` with `allowsMultipleSelection = true`, `canChooseFiles = true`, `canChooseDirectories = false`, and allowed PDF/image types.
- **Add Folder:** `NSOpenPanel` with files disabled, directories enabled, and multiple folder selection allowed.
- **Choose Output Folder:** directory-only `NSOpenPanel` passed to `chooseOutputRoot`.
- **Drag-and-drop:** accept one or more file URLs and forward them as one selection array after all providers resolve for the current input generation.
- **Reveal Output Folder:** call `NSWorkspace.shared.activateFileViewerSelecting([outputRoot])` only when the coordinator has a valid output root.
- Render skipped/failed details without including OCR text. **Copy Diagnostics** writes a local summary containing version/build, counts, item state, error category/message, and the user-visible source path; it excludes OCR text, document contents, hashes, cache keys, and environment values.
- Apply stable accessibility labels/identifiers and expose state text independently of color.

- [ ] **Step 5: Update debug-only fixtures and contract guards**

Construct deterministic batch coordinators in `LocalOCRStudioUITestSupport` without reading real user files. Update `test_studio_app_project.py` so the exact allowed fixture-state set includes the three batch states and asserts that batch fixtures remain guarded by both `#if DEBUG` and `LOCALOCR_STUDIO_UI_TEST_SESSION`.

- [ ] **Step 6: Run Swift, contract, and UI tests**

```bash
swift test --filter BatchViewContractTests
.venv/bin/python -m pytest -v tests/contract/test_studio_app_project.py
scripts/release-toolchain.sh
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project "LocalOCR Studio.xcodeproj" -scheme "LocalOCR Studio" \
  -destination 'platform=macOS,arch=arm64' test
```

Expected: batch view contract, project contract, all existing UI tests, and new batch UI tests pass.

- [ ] **Step 7: Commit the complete desktop workflow**

```bash
git add Sources/LocalOCRStudioKit/BatchWorkspaceView.swift Sources/LocalOCRStudioKit/BatchStatusViews.swift Sources/LocalOCRStudioKit/LocalOCRStudioView.swift Sources/LocalOCRStudioKit/StudioDropZoneView.swift App/LocalOCRStudioApp.swift App/LocalOCRStudioUITestSupport.swift AppUITests/LocalOCRStudioUITests.swift tests/LocalOCRStudioKitTests/BatchViewContractTests.swift tests/contract/test_studio_app_project.py
git commit -m "feat: add accessible desktop batch workspace"
```

---

### Task 7: Version Alignment and Candidate Documentation

**Files:**
- Modify: `Sources/LocalOCRService/LocalOCRRuntime.swift`
- Modify: `project.yml`
- Regenerate: `LocalOCR Studio.xcodeproj/project.pbxproj`
- Modify: `scripts/build-unsigned-studio-app.sh`
- Modify: `scripts/smoke-native-tools.sh`
- Modify: `extension/manifest.json`
- Modify: `tests/LocalOCRMCPTests/MCPServerRunnerTests.swift`
- Modify: `tests/contract/test_extension_manifest.py`
- Modify: `tests/contract/test_release_artifacts.py`
- Modify: `tests/contract/test_studio_app_project.py`
- Create: `docs/release/v0.3.0-beta.1-notes.md`
- Modify: `README.md`
- Modify: `docs/studio.md`
- Modify: `BETA_TESTING.md`
- Create: `tests/contract/test_beta2_candidate_documentation.py`

**Interfaces:**
- Consumes: completed Beta 2 feature and release design.
- Produces: synchronized app/helper/extension version `0.3.0`, build `2`, candidate documentation, and unchanged CLI/MCP schema contracts.

- [ ] **Step 1: Write failing version-alignment tests**

Update exact expectations to `0.3.0` and build `2`. Add a candidate-doc contract that requires:

```python
def test_beta2_candidate_identity_and_boundaries_are_explicit():
    notes = (ROOT / "docs/release/v0.3.0-beta.1-notes.md").read_text()
    assert "v0.3.0-beta.1" in notes
    assert "not yet published" in notes
    assert "Desktop batch" in notes
    assert "one document at a time" in notes
    assert "100% local" in notes
    assert "macOS 14.0+" in notes
```

Run:

```bash
swift test --filter MCPServerRunnerTests
.venv/bin/python -m pytest -v \
  tests/contract/test_extension_manifest.py \
  tests/contract/test_release_artifacts.py \
  tests/contract/test_studio_app_project.py \
  tests/contract/test_beta2_candidate_documentation.py
```

Expected: failures show the old `0.2.0` / `1` identity and missing candidate notes.

- [ ] **Step 2: Change version sources together**

- Set `LocalOCRRuntime.version = "0.3.0"` so CLI and MCP report the package version expected by the release verifier without changing request or response shapes.
- Set `MARKETING_VERSION: 0.3.0` and `CURRENT_PROJECT_VERSION: 2` in `project.yml`.
- Regenerate the checked-in Xcode project with `/opt/homebrew/bin/xcodegen generate --spec project.yml` and verify the project contains only relative local package paths.
- Set `studio_release_version="0.3.0"` and `studio_release_build="2"` in `build-unsigned-studio-app.sh`.
- Update smoke tests, MCP version tests, extension manifest, and release-artifact contracts to the same version.
- Do not rewrite historical Beta 1 release notes, old plans, old evidence, or old asset names.

- [ ] **Step 3: Write candidate documentation without claiming publication**

Document the desktop batch user flow, PDF/image output defaults, recursive-folder safety, no-overwrite numbering, cancellation/retry behavior, single-document regression path, and local-only promise. Keep `v0.2.0-beta.1` identified as the currently published release until a separate publication action occurs. Mark `v0.3.0-beta.1` as a candidate that is not yet published.

- [ ] **Step 4: Run version and documentation contracts**

```bash
swift test --filter MCPServerRunnerTests
.venv/bin/python -m pytest -v \
  tests/contract/test_extension_manifest.py \
  tests/contract/test_release_artifacts.py \
  tests/contract/test_studio_app_project.py \
  tests/contract/test_beta2_candidate_documentation.py
```

Expected: all focused version and candidate-doc contracts pass.

- [ ] **Step 5: Commit synchronized candidate identity**

```bash
git add Sources/LocalOCRService/LocalOCRRuntime.swift project.yml "LocalOCR Studio.xcodeproj/project.pbxproj" scripts/build-unsigned-studio-app.sh scripts/smoke-native-tools.sh extension/manifest.json tests/LocalOCRMCPTests/MCPServerRunnerTests.swift tests/contract/test_extension_manifest.py tests/contract/test_release_artifacts.py tests/contract/test_studio_app_project.py tests/contract/test_beta2_candidate_documentation.py docs/release/v0.3.0-beta.1-notes.md README.md docs/studio.md BETA_TESTING.md
git commit -m "chore: align LocalOCR 0.3.0 beta candidate identity"
```

---

### Task 8: Full Regression, Privacy, and Artifact Verification

**Files:**
- Modify only when a failing test exposes a Beta 2 defect in an already-touched file.
- Create: `reports/beta2-pre-release-verification.txt` only from the final successful verification run.

**Interfaces:**
- Consumes: all completed implementation tasks.
- Produces: fresh test/build evidence; no public release or external mutation.

- [ ] **Step 1: Run the full Swift suite**

```bash
swift test
```

Expected: every Swift suite passes with zero failures.

- [ ] **Step 2: Run the full Python compatibility and contract suite**

```bash
.venv/bin/python -m pytest -v
```

Expected: every Python compatibility and contract test passes with zero failures.

- [ ] **Step 3: Build and smoke native CLI/MCP tools**

```bash
scripts/build-native-tools.sh
scripts/smoke-native-tools.sh
```

Expected: arm64 tools build, CLI reports `0.3.0`, MCP initializes as `0.3.0`, and only Apple/system dependencies are present.

- [ ] **Step 4: Run the complete Studio scheme and unsigned bundle checks**

```bash
scripts/release-toolchain.sh
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project "LocalOCR Studio.xcodeproj" -scheme "LocalOCR Studio" \
  -destination 'platform=macOS,arch=arm64' test
scripts/build-unsigned-studio-app.sh
```

Expected: all UI tests pass; the unsigned app validates as arm64, macOS 14.0+, version `0.3.0`, build `2`, Hardened Runtime configured, and no absolute user path in the project or artifact.

- [ ] **Step 5: Run artifact and dependency contracts**

```bash
.venv/bin/python -m pytest -v \
  tests/contract/test_release_artifacts.py \
  tests/contract/test_direct_release_scripts.py \
  tests/contract/test_native_python_compatibility.py
```

Expected: all artifact, release-script, and Python-to-Swift compatibility contracts pass.

- [ ] **Step 6: Capture a secret-free verification transcript**

Write `reports/beta2-pre-release-verification.txt` from the final command outputs only. Include date, branch, exact commit, toolchain path/version, suite counts, and PASS/FAIL results. Exclude environment secrets, notarization credentials, document paths outside test fixtures, and OCR text.

- [ ] **Step 7: Commit verification evidence**

```bash
git add reports/beta2-pre-release-verification.txt
git commit -m "test: record Beta 2 pre-release verification"
```

---

### Task 9: Review, Merge, Signed Candidate, and Two-Mac Acceptance

**Files:**
- Create under business records: `../reports/mcp-macvision/MCP-MacVision-Beta-2-Candidate-Evidence.md`; record the actual completion date inside the document.
- Modify: `../reports/mcp-macvision/MCP-MacVision-Time-and-Cost-Log.csv`
- Modify: `../reports/mcp-macvision/README.md`

**Interfaces:**
- Consumes: reviewed green feature branch, existing fail-closed release scripts, Developer ID team `DZ8B5454ZN`, and keychain profile `localocr-notary`.
- Produces: merged source and a signed/notarized candidate acceptance record; publication remains excluded.

- [ ] **Step 1: Request specification and code-quality review of the complete diff**

Review against the approved spec and require no unresolved Important or Critical findings. Verify every finding technically, apply changes through focused tests, rerun the complete suites from Task 8, and preserve review evidence in the pull request.

- [ ] **Step 2: Open and merge the feature pull request only after the branch is clean and green**

```bash
git status --short
git log --oneline origin/main..HEAD
gh pr create --repo UnoRazorback/localocr \
  --base main \
  --head feature/desktop-batch-beta2 \
  --title "Add LocalOCR Studio desktop batch processing" \
  --body-file /tmp/localocr-beta2-pr-body.md
```

The PR body must list the approved spec, exact test commands/results, privacy boundary, version/build, and remaining limitations. Merge only after required review and checks pass; record the merge commit.

- [ ] **Step 3: Build, sign, notarize, staple, and package from the exact merged commit**

Use stable Xcode and the existing release scripts rather than ad hoc commands:

```bash
export LOCALOCR_RELEASE_VERSION="0.3.0"
export LOCALOCR_RELEASE_BUILD="2"
export LOCALOCR_NOTARY_PROFILE="localocr-notary"
export LOCALOCR_UNSIGNED_APP="$PWD/dist/unsigned-app/LocalOCR Studio.app"
export LOCALOCR_EXPECTED_BUNDLE_ID="com.rayconsulting.localocr"

scripts/build-native-tools.sh
scripts/build-unsigned-studio-app.sh
scripts/stage-direct-release.sh
scripts/sign-direct-release.sh
scripts/verify-direct-release.sh
scripts/notarize-direct-release.sh
```

Expected: nested helpers are signed first, the containing app last, Hardened Runtime and timestamps are present, notarization returns `Accepted`, stapling validates, Gatekeeper accepts the app, checksum matches, RPATHs are safe, and CLI/MCP binaries depend only on Apple/system libraries.

- [ ] **Step 4: Verify the exact packaged candidate on the build Mac**

```bash
scripts/test-downloaded-release.sh \
  "$PWD/dist/direct-release/final/LocalOCR-Studio-0.3.0-2.zip" \
  "$PWD/dist/direct-release/final/LocalOCR-Studio-0.3.0-2.sha256"
```

Exercise one individual PDF, one individual image, a mixed batch, nested folder discovery, a collision that creates a numbered name, cancellation, retry, reveal-output, privacy-safe copied diagnostics, and return to single-document mode. Use only non-sensitive test fixtures.

- [ ] **Step 5: Transfer the exact checksum-verified candidate to the second Mac and repeat acceptance**

Use the established SSH installation checklist. Verify checksum before extraction, archive safety, nested signatures, app signature, staple, Gatekeeper, arm64 architecture, macOS 14.0 target, dependencies, RPATHs, CLI `0.3.0`, MCP initialization `0.3.0`, batch outputs, single-document regression, launch, and clean quit. Do not infer installation from transfer alone and do not count the owner machine as a beta tester.

- [ ] **Step 6: Record candidate and business evidence without inventing amounts**

The candidate evidence must include exact source/merge commit, test counts, toolchain, certificate identity, notary submission ID/status, artifact names/sizes/SHA-256, verifier results, both Mac models and exact macOS builds, batch acceptance results, known limitations, and publication status `not published`.

Append a dated time-and-cost row with hours/direct/shared costs blank unless dated evidence supplies them. Update the project overview to distinguish implemented, merged, signed, installed, and published states.

- [ ] **Step 7: Stop at the publication gate**

Do not create or publish `v0.3.0-beta.1`, replace assets, edit the live release, post campaign content, or count downloads until the owner explicitly approves the exact release tag, commit, notes, ZIP, checksum, and SHA-256 values.

---

## Final Acceptance Checklist

- [ ] The one-document workflow remains the default and passes all prior tests.
- [ ] Mixed files and recursive folders produce one deterministic review queue.
- [ ] Symbolic links, packages, hidden/system files, duplicates, and unsupported files are handled exactly as specified.
- [ ] The chosen output root is outside input folders and all outputs remain confined beneath it.
- [ ] Existing outputs receive unique numbered names and are never overwritten.
- [ ] PDFs create searchable PDFs; images create UTF-8 text files; no PDF sidecars are created by default.
- [ ] Maximum active processing count is exactly one.
- [ ] Failure, cancellation, retry, late-result, and temporary-output cleanup tests pass.
- [ ] Batch UI is keyboard- and VoiceOver-accessible and never communicates state by color alone.
- [ ] App, CLI, MCP, extension, scripts, and verifier expectations agree on `0.3.0`; app build is `2`.
- [ ] CLI/MCP schemas remain compatible and all Python-to-Swift contracts pass.
- [ ] Full Swift, Python, Xcode UI, artifact, dependency, and release-script suites pass from fresh runs.
- [ ] Exact signed/notarized packaged candidate passes on the build Mac and second Mac.
- [ ] Business records contain dated evidence with no invented time or costs.
- [ ] No public release or campaign mutation occurs without separate explicit approval.
