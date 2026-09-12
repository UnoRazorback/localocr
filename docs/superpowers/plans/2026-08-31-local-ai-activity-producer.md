# Local AI Activity Producer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a content-free Local AI Activity v1 producer to LocalOCR's shared intelligence layer so Studio, MCP, CLI, and future iOS targets can report only model operations they own through a secure App Group lease ledger.

**Architecture:** `LocalOCRIntelligence` owns a strict, platform-neutral v1 codec and a best-effort actor that writes one lease file per operation into an injected container. `LocalIntelligenceProviderRouter` wraps only selected model invocations, maps the selected provider to an allowlisted runtime family, and receives an explicit producer role from Studio, MCP, or CLI; Vision OCR never crosses this boundary. The production App Group identifier and entitlements remain disabled until Scott separately approves the legal namespace and release-signing gate.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, Foundation, Darwin POSIX file APIs, App Groups, `DistributedNotificationCenter` on macOS, Xcode, XCTest, Python 3/pytest, Developer ID signing, notarization, and future iOS/iPadOS provisioning.

**Spec:** `/Users/scott/Developer/ai-neural-gauge/.worktrees/apple-foundation-monitoring/docs/superpowers/specs/2026-08-31-apple-foundation-model-activity-design.md` at approved commit `2245dab`

## Global Constraints

- Report only activity that LocalOCR owns; do not claim system-wide visibility into nonparticipating apps.
- Version 1 accepts only `foundation_models`, `core_ml`, `mlx`, and `local_runtime` runtime families and only the fixed enum values defined by the approved specification.
- The App Group lease ledger is the sole source of truth; an optional macOS notification may only request a rescan and must carry no payload.
- The macOS wake notification name has no production default; inject it explicitly only after the durable namespace/App Group gate, and otherwise use `NoLocalAIActivityWakeHint`.
- Do not inspect or attribute `aned`, `modelmanagerd`, `modelcatalogd`, `GenerativeExperiencesSafetyInferenceProvider`, or any other Apple service daemon.
- Never write prompts, responses, OCR text, filenames, paths, document identities, requested field names, extracted values, model inputs, model outputs, errors, command arguments, URLs, or user identifiers.
- Keep active leases at 45 seconds, emit heartbeats no more often than every 15 seconds, and retain ended records for at most 24 hours.
- Use directory mode `0700`, record mode `0600`, complete temporary files, and atomic rename; reject symlinks, non-regular files, traversal, oversized files, unknown keys, unknown versions, invalid enum values, and invalid state invariants.
- LocalOCR generation must continue normally when activity reporting is absent, unavailable, unauthorized, malformed, or unable to write; reporting fails closed without a fallback notification claim or daemon heuristic.
- Ordinary Vision OCR is not model activity and must never produce a Local AI Activity record.
- Use a provisioned `group.<durable-reverse-domain>.local-ai-activity` identifier for production, but do not select, register, hard-code, or entitle a production identifier until Scott approves the durable namespace and legal owner.
- Open-source, ad hoc, or differently signed builds may use only an explicitly injected temporary ledger; they must not silently write to or impersonate the official production ledger.
- Keep App Group registration, entitlement application, signing, notarization/TestFlight, installation, merge, publication, and release as separate authorization gates.
- Preserve OCR and searchable PDF output as authoritative; activity reporting must not alter model prompts, responses, grounding, provider selection, or user-visible document results.

---

### Task 1: Define the strict v1 contract and canonical interoperability fixture

**Files:**
- Create: `Sources/LocalOCRIntelligence/LocalAIActivityContract.swift`
- Create: `tests/LocalOCRIntelligenceTests/LocalAIActivityContractTests.swift`
- Create: `tests/LocalOCRIntelligenceTests/Fixtures/LocalAIActivity/v1/localocr-foundation-models-active.json`
- Modify: `Package.swift:105-115` (`LocalOCRIntelligenceTests` resources)

**Interfaces:**
- Consumes: the exact v1 schema and fixed enum values in the approved spec at commit `2245dab`.
- Produces: `LocalAIActivityRecord`, `LocalAIActivityDescriptor`, `LocalAIActivityContract.encode(_:) throws -> Data`, and `LocalAIActivityContract.decode(_:) throws -> LocalAIActivityRecord` for the writer and cross-repository fixture handshake.

- [ ] **Step 1: Add the canonical fixture resource and failing contract tests**

Add the test resource to `Package.swift`:

```swift
.testTarget(
    name: "LocalOCRIntelligenceTests",
    dependencies: [
        "LocalOCRIntelligence",
        "LocalOCRModelCore",
        "LocalOCRModelBridgeProtocol",
        "LocalOCRService",
        "LocalOCRCore"
    ],
    path: "tests/LocalOCRIntelligenceTests",
    resources: [.copy("Fixtures")],
    swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
)
```

Commit this exact one-line canonical JSON fixture, terminated by one newline:

```json
{"activity_id":"11111111-1111-4111-8111-111111111111","ended_at":null,"evidence":"participating_app_reported","expires_at":"2026-08-31T14:00:45Z","heartbeat_at":"2026-08-31T14:00:00Z","operation":"generation","outcome":null,"platform":"macos","producer_id":"com.rayconsulting.localocr","producer_role":"studio","product_task":"summarize","route":"on_device","runtime_family":"foundation_models","runtime_identifier":"SystemLanguageModel.default","schema_version":1,"started_at":"2026-08-31T14:00:00Z","state":"active"}
```

Write tests that load `Bundle.module.url(forResource: "localocr-foundation-models-active", withExtension: "json", subdirectory: "Fixtures/LocalAIActivity/v1")`, decode every exact field, re-encode the record, and assert `encoded == fixtureData`. Add table tests for every allowlisted enum and rejection tests for an extra key, schema version `2`, malformed UUID, path-like runtime identifier, URL-like runtime identifier, non-LocalOCR producer ID, active records with an outcome, and ended records without an outcome.

```swift
@Test func canonicalFixtureDecodesAndReencodesByteForByte() throws {
    let data = try Data(contentsOf: try #require(Bundle.module.url(
        forResource: "localocr-foundation-models-active",
        withExtension: "json",
        subdirectory: "Fixtures/LocalAIActivity/v1"
    )))
    let record = try LocalAIActivityContract.decode(data)
    #expect(record.activityID.uuidString == "11111111-1111-4111-8111-111111111111")
    #expect(record.producerRole == .studio)
    #expect(record.runtimeFamily == .foundationModels)
    #expect(record.runtimeIdentifier == "SystemLanguageModel.default")
    #expect(record.productTask == .summarize)
    #expect(try LocalAIActivityContract.encode(record) == data)
}

@Test func decoderRejectsUnknownKey() throws {
    let bad = Data(#"{"schema_version":1,"unexpected":"content"}"#.utf8)
    #expect(throws: LocalAIActivityContractError.self) {
        try LocalAIActivityContract.decode(bad)
    }
}
```

- [ ] **Step 2: Run the focused test and verify the expected failure**

Run:

```bash
swift test --filter LocalAIActivityContractTests
```

Expected: FAIL at compile time with `cannot find 'LocalAIActivityContract' in scope`.

- [ ] **Step 3: Implement the exact schema types and strict canonical codec**

Define all enums as `String, Codable, Sendable, CaseIterable`, keep all 17 schema keys required, and make nullable keys encode as JSON `null` rather than disappear. Decode once into a raw `[String: JSONValue]` solely to compare its keys with `LocalAIActivityContract.v1Keys`, then decode the typed record and validate cross-field invariants.

```swift
public struct LocalAIActivityRecord: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let activityID: UUID
    public let producerID: String
    public let producerRole: LocalAIProducerRole
    public let platform: LocalAIPlatform
    public let runtimeFamily: LocalAIRuntimeFamily
    public let runtimeIdentifier: String?
    public let route: LocalAIRoute
    public let operation: LocalAIOperation
    public let productTask: LocalAIProductTask?
    public let state: LocalAIActivityState
    public let startedAt: Date
    public let heartbeatAt: Date
    public let expiresAt: Date
    public let endedAt: Date?
    public let outcome: LocalAIActivityOutcome?
    public let evidence: LocalAIEvidence
}

public enum LocalAIProducerRole: String, Codable, Sendable, CaseIterable {
    case studio, mcp, cli
    case iosApp = "ios_app"
}
public enum LocalAIPlatform: String, Codable, Sendable, CaseIterable {
    case macos, ios, ipados
}
public enum LocalAIRuntimeFamily: String, Codable, Sendable, CaseIterable {
    case foundationModels = "foundation_models"
    case coreML = "core_ml"
    case mlx
    case localRuntime = "local_runtime"
}
public enum LocalAIRoute: String, Codable, Sendable, CaseIterable {
    case onDevice = "on_device"
    case onDeviceLoopback = "on_device_loopback"
}
public enum LocalAIOperation: String, Codable, Sendable, CaseIterable {
    case generation, inference, embedding, training
    case fineTuning = "fine_tuning"
}
public enum LocalAIProductTask: String, Codable, Sendable, CaseIterable {
    case summarize, organize, extract
}
public enum LocalAIActivityState: String, Codable, Sendable, CaseIterable {
    case active, ended
}
public enum LocalAIActivityOutcome: String, Codable, Sendable, CaseIterable {
    case success, cancelled, failure
}
public enum LocalAIEvidence: String, Codable, Sendable, CaseIterable {
    case participatingAppReported = "participating_app_reported"
}

public struct LocalAIActivityDescriptor: Sendable, Equatable {
    public let producerID: String
    public let producerRole: LocalAIProducerRole
    public let platform: LocalAIPlatform
    public let runtimeFamily: LocalAIRuntimeFamily
    public let runtimeIdentifier: String?
    public let route: LocalAIRoute
    public let operation: LocalAIOperation
    public let productTask: LocalAIProductTask?

    public static func foundationModels(
        role: LocalAIProducerRole,
        platform: LocalAIPlatform = .macos,
        task: LocalAIProductTask
    ) -> Self
}

public enum LocalAIActivityContract {
    public static let schemaVersion = 1
    public static let maximumRecordBytes = 16_384
    public static let localOCRProducerID = "com.rayconsulting.localocr"
    public static let foundationModelsIdentifier = "SystemLanguageModel.default"

    public static func encode(_ record: LocalAIActivityRecord) throws -> Data
    public static func decode(_ data: Data) throws -> LocalAIActivityRecord
}

public enum LocalAIActivityContractError: Error, Sendable, Equatable {
    case oversized
    case malformedJSON
    case unexpectedKeys
    case unsupportedVersion
    case invalidIdentifier
    case invalidEnum
    case invalidTimestamp
    case invalidState
}
```

Use one shared UTC ISO-8601 formatter with whole seconds, `JSONEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`, and append exactly one newline. Reject bytes over `maximumRecordBytes`; producer IDs outside the configured LocalOCR allowlist; `runtimeIdentifier` values other than `SystemLanguageModel.default` for Foundation Models; non-null runtime identifiers for v1's other families; control characters, `/`, `\\`, `:`, or `..` in registered identifiers; and timestamps outside the state invariants from the spec.

- [ ] **Step 4: Run contract and full intelligence tests**

Run:

```bash
swift test --filter LocalAIActivityContractTests
swift test --filter LocalOCRIntelligenceTests
```

Expected: PASS; the canonical fixture round-trips byte-for-byte and all pre-existing intelligence tests remain green.

- [ ] **Step 5: Commit the contract boundary**

```bash
git add Package.swift Sources/LocalOCRIntelligence/LocalAIActivityContract.swift tests/LocalOCRIntelligenceTests/LocalAIActivityContractTests.swift tests/LocalOCRIntelligenceTests/Fixtures/LocalAIActivity/v1/localocr-foundation-models-active.json
git commit -m "feat: define local AI activity v1 contract"
```

### Task 2: Build the secure atomic active/recent ledger writer

**Files:**
- Create: `Sources/LocalOCRIntelligence/LocalAIActivityLedger.swift`
- Create: `Sources/LocalOCRIntelligence/SecureLocalAIActivityFileStore.swift`
- Create: `tests/LocalOCRIntelligenceTests/LocalAIActivityLedgerTests.swift`
- Create: `tests/LocalOCRIntelligenceTests/SecureLocalAIActivityFileStoreTests.swift`

**Interfaces:**
- Consumes: `LocalAIActivityDescriptor` and `LocalAIActivityContract` from Task 1.
- Produces: `LocalAIActivityLedgerWriting.begin(_:) async throws -> UUID`, `heartbeat(_:) async throws`, `end(_:outcome:) async throws`, `cleanupExpired() async`, plus injected `LocalAIActivityClock` and `LocalAIActivityFileStoring` seams.

- [ ] **Step 1: Write failing lifecycle, retention, and concurrency tests with an injected clock and container**

Use `FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)` and a lock-protected mutable test clock conforming to `LocalAIActivityClock`. Assert:

- `begin` writes `LocalAIActivity/v1/active/<uuid>.json` with an expiry exactly 45 seconds after `started_at`;
- a heartbeat at +14 seconds does not rewrite, while one at +15 seconds rewrites `heartbeat_at` and `expires_at`;
- success, cancellation, and failure move an ended record to `recent` with generic outcomes and a 24-hour retention deadline;
- duplicate heartbeat/end is idempotent; an unknown end creates nothing;
- four concurrent operations with roles Studio, MCP, CLI, and iOS have four independent UUID files;
- an abandoned active record becomes invalid after 45 seconds and is removed opportunistically;
- an expired recent record is removed after 24 hours;
- all directories are `0700` and files are `0600`.

```swift
@Test func beginHeartbeatAndSuccessUseExactLeaseWindows() async throws {
    let clock = TestLocalAIActivityClock(now: instant("2026-08-31T14:00:00Z"))
    let container = try temporaryDirectory()
    let ledger = LocalAIActivityLedger(containerURL: container, clock: clock)
    let id = try await ledger.begin(.foundationModels(role: .studio, task: .summarize))
    var active = try decodedRecord(container, directory: "active", id: id)
    #expect(active.expiresAt == clock.now().addingTimeInterval(45))
    clock.advance(by: 15)
    try await ledger.heartbeat(id)
    active = try decodedRecord(container, directory: "active", id: id)
    #expect(active.heartbeatAt == clock.now())
    try await ledger.end(id, outcome: .success)
    #expect(!fileExists(container, directory: "active", id: id))
    #expect(try decodedRecord(container, directory: "recent", id: id).outcome == .success)
}
```

- [ ] **Step 2: Run the focused tests and verify the expected failure**

Run:

```bash
swift test --filter LocalAIActivityLedgerTests
swift test --filter SecureLocalAIActivityFileStoreTests
```

Expected: FAIL at compile time with `cannot find 'LocalAIActivityLedger' in scope` and `cannot find 'SecureLocalAIActivityFileStore' in scope`.

- [ ] **Step 3: Implement the injected filesystem boundary with POSIX no-follow operations**

Keep path validation and syscalls out of the lifecycle actor:

```swift
protocol LocalAIActivityFileStoring: Sendable {
    func prepareLedgerDirectories() throws
    func readRecord(id: UUID, from directory: LocalAILedgerDirectory) throws -> Data?
    func atomicallyWrite(_ data: Data, id: UUID, to directory: LocalAILedgerDirectory) throws
    func atomicallyMove(id: UUID, from: LocalAILedgerDirectory, to: LocalAILedgerDirectory) throws
    func remove(id: UUID, from directory: LocalAILedgerDirectory) throws
    func recordIDs(in directory: LocalAILedgerDirectory) throws -> [UUID]
}
```

Open the configured container and each fixed directory component using `openat` plus `O_DIRECTORY | O_NOFOLLOW`; create directories with `mkdirat(..., 0o700)` and verify owner/mode with `fstat`. Create a dot-prefixed UUID temporary file in the destination directory with `O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW` and mode `0o600`, write all bytes, `fsync`, close, then `renameat` to `<uuid>.json`. Accept no caller-supplied path component. Enumerate only exact lowercase UUID `.json` names, ignore all other names, and reject symlinks and non-regular files before reading no more than `maximumRecordBytes + 1` bytes.

After preparing the fixed ledger root, set `URLResourceValues.isExcludedFromBackup = true` on `LocalAIActivity/` and verify the flag in the secure-store tests. A failure to apply the exclusion makes the reporting source unavailable; it must not fall back to a non-App-Group or cloud-synchronized location.

- [ ] **Step 4: Implement the lease actor and fail-closed cleanup**

```swift
public protocol LocalAIActivityLedgerWriting: Sendable {
    func begin(_ descriptor: LocalAIActivityDescriptor) async throws -> UUID
    func heartbeat(_ activityID: UUID) async throws
    func end(_ activityID: UUID, outcome: LocalAIActivityOutcome) async throws
    func cleanupExpired() async
}

public protocol LocalAIActivityClock: Sendable {
    func now() -> Date
    func sleep(for duration: Duration) async throws
}

public actor LocalAIActivityLedger: LocalAIActivityLedgerWriting {
    static let heartbeatInterval: TimeInterval = 15
    static let activeLease: TimeInterval = 45
    static let recentRetention: TimeInterval = 86_400

    public init(containerURL: URL, clock: any LocalAIActivityClock = SystemLocalAIActivityClock())
}
```

For heartbeat/end, decode the existing active file through the strict Task 1 codec and require the matching `activity_id`; malformed or expired data is removed but never rewritten as valid. End writes the complete ended record, then atomically renames the UUID record from `active` to `recent`. Catch and ignore individual cleanup errors so one hostile or malformed file cannot affect other operations.

- [ ] **Step 5: Run secure-store, lifecycle, and full package tests**

Run:

```bash
swift test --filter SecureLocalAIActivityFileStoreTests
swift test --filter LocalAIActivityLedgerTests
swift test
```

Expected: PASS, including symlink escape, traversal, oversized file, mode, expiry, duplicate, and four-writer concurrency cases.

- [ ] **Step 6: Commit the ledger**

```bash
git add Sources/LocalOCRIntelligence/LocalAIActivityLedger.swift Sources/LocalOCRIntelligence/SecureLocalAIActivityFileStore.swift tests/LocalOCRIntelligenceTests/LocalAIActivityLedgerTests.swift tests/LocalOCRIntelligenceTests/SecureLocalAIActivityFileStoreTests.swift
git commit -m "feat: write secure local AI activity leases"
```

### Task 3: Add a best-effort lifecycle reporter and optional macOS wake hint

**Files:**
- Create: `Sources/LocalOCRIntelligence/LocalAIActivityReporter.swift`
- Create: `Sources/LocalOCRIntelligence/LocalAIActivityWakeHint.swift`
- Create: `tests/LocalOCRIntelligenceTests/LocalAIActivityReporterTests.swift`
- Create: `tests/LocalOCRIntelligenceTests/LocalAIActivityWakeHintTests.swift`

**Interfaces:**
- Consumes: `LocalAIActivityLedgerWriting` from Task 2, descriptors/outcomes from Task 1, and an explicitly injected `Notification.Name` only for configured macOS wake hints.
- Produces: `LocalAIActivityReporting.withActivity(_:operation:) async throws -> T`, `DisabledLocalAIActivityReporter`, `NoLocalAIActivityWakeHint`, `DistributedLocalAIActivityWakeHint.init(name:center:clock:)`, and `LocalAIActivityWakeHintPosting.postRescanHint()`.

- [ ] **Step 1: Write failing success, cancellation, failure, heartbeat, and fail-open model-operation tests**

Use a spy ledger and controllable operation. Assert exact begin/end order, heartbeat scheduling for a 31-second operation, task cancellation mapped to `.cancelled`, any other thrown error mapped to `.failure`, and no error from begin/heartbeat/end replacing the model operation's value or error.

For wake hints, assert that the default reporter uses `NoLocalAIActivityWakeHint`, constructing `DistributedLocalAIActivityWakeHint` requires an injected name, the center receives that exact name with `object == nil` and `userInfo == nil`, two hints inside one second produce one post, and no literal production notification name exists in the implementation.

```swift
@Test func reportingFailureNeverBlocksOwnedModelOperation() async throws {
    let reporter = LocalAIActivityReporter(
        ledger: ThrowingLedger(),
        clock: TestLocalAIActivityClock(),
        wakeHint: NoLocalAIActivityWakeHint()
    )
    let value: String = try await reporter.withActivity(
        .foundationModels(role: .mcp, task: .extract)
    ) { "model-result" }
    #expect(value == "model-result")
}

@Test func cancellationEndsWithGenericCancelledOutcome() async {
    let ledger = SpyLedger()
    let reporter = LocalAIActivityReporter(
        ledger: ledger,
        clock: TestLocalAIActivityClock(),
        wakeHint: NoLocalAIActivityWakeHint()
    )
    await #expect(throws: CancellationError.self) {
        try await reporter.withActivity(.foundationModels(role: .studio, task: .organize)) {
            throw CancellationError()
        }
    }
    #expect(await ledger.outcomes == [.cancelled])
}

@Test func distributedHintPostsOnlyTheInjectedNameWithoutPayload() {
    let center = SpyDistributedNotificationCenter()
    let name = Notification.Name("test.local-ai-activity.rescan")
    let hint = DistributedLocalAIActivityWakeHint(name: name, center: center, clock: TestMonotonicClock())
    hint.postRescanHint()
    #expect(center.posts == [.init(name: name, objectWasNil: true, userInfoWasNil: true)])
}
```

- [ ] **Step 2: Run the reporter tests and verify the expected failure**

Run:

```bash
swift test --filter LocalAIActivityReporterTests
swift test --filter LocalAIActivityWakeHintTests
```

Expected: FAIL at compile time with `cannot find 'LocalAIActivityReporter' in scope`.

- [ ] **Step 3: Implement the reporter with an unstructured heartbeat task that is always cancelled and awaited**

```swift
public protocol LocalAIActivityReporting: Sendable {
    func withActivity<T: Sendable>(
        _ descriptor: LocalAIActivityDescriptor,
        operation: @Sendable () async throws -> T
    ) async throws -> T
}

public actor LocalAIActivityReporter: LocalAIActivityReporting {
    public init(
        ledger: any LocalAIActivityLedgerWriting,
        clock: any LocalAIActivityClock,
        wakeHint: any LocalAIActivityWakeHintPosting = NoLocalAIActivityWakeHint()
    ) {
        self.ledger = ledger
        self.clock = clock
        self.wakeHint = wakeHint
    }

    public func withActivity<T: Sendable>(
        _ descriptor: LocalAIActivityDescriptor,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        guard let id = try? await ledger.begin(descriptor) else { return try await operation() }
        wakeHint.postRescanHint()
        let heartbeat = Task { [ledger, wakeHint] in
            while !Task.isCancelled {
                try await clock.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                try? await ledger.heartbeat(id)
                wakeHint.postRescanHint()
            }
        }
        do {
            let value = try await operation()
            heartbeat.cancel(); _ = await heartbeat.result
            try? await ledger.end(id, outcome: .success); wakeHint.postRescanHint()
            return value
        } catch {
            heartbeat.cancel(); _ = await heartbeat.result
            let outcome: LocalAIActivityOutcome = error is CancellationError ? .cancelled : .failure
            try? await ledger.end(id, outcome: outcome); wakeHint.postRescanHint()
            throw error
        }
    }
}
```

The disabled implementation calls `operation()` directly. It writes no diagnostic details and never catches or transforms the model error.

- [ ] **Step 4: Implement an injected-name, payload-free, rate-limited macOS hint**

```swift
public protocol LocalAIActivityWakeHintPosting: Sendable {
    func postRescanHint()
}

public struct NoLocalAIActivityWakeHint: LocalAIActivityWakeHintPosting {
    public init() {}
    public func postRescanHint() {}
}

#if os(macOS)
public final class DistributedLocalAIActivityWakeHint: LocalAIActivityWakeHintPosting, @unchecked Sendable {
    private let name: Notification.Name
    private let center: any LocalAIActivityDistributedNotificationPosting
    private let clock: any LocalAIActivityMonotonicClock
    private let lock = NSLock()
    private var lastPost: Duration?

    public init(
        name: Notification.Name,
        center: any LocalAIActivityDistributedNotificationPosting,
        clock: any LocalAIActivityMonotonicClock
    ) {
        self.name = name
        self.center = center
        self.clock = clock
    }

    public func postRescanHint() {
        let now = clock.now()
        let shouldPost = lock.withLock { () -> Bool in
            if let lastPost, now - lastPost < .seconds(1) { return false }
            lastPost = now
            return true
        }
        guard shouldPost else { return }
        center.post(
            name: name,
            object: nil,
            userInfo: nil,
            deliverImmediately: false
        )
    }
}
#endif
```

Define `LocalAIActivityDistributedNotificationPosting` as the narrow injectable wrapper around `DistributedNotificationCenter.post`; its system implementation is macOS-only. Put rate limiting behind the injected monotonic clock and allow at most one post per second per process. Do not provide a convenience initializer, static notification name, Info.plist fallback, environment-variable fallback, or reverse-domain literal. On every platform, the default is `NoLocalAIActivityWakeHint`; iOS/iPadOS compile no distributed implementation. Tests must prove the injected name is used exactly, `userInfo == nil`, duplicate hints are bounded, and a hint carries no activity ID or state.

- [ ] **Step 5: Run focused and full intelligence tests**

Run:

```bash
swift test --filter LocalAIActivityReporterTests
swift test --filter LocalAIActivityWakeHintTests
swift test --filter LocalOCRIntelligenceTests
```

Expected: PASS; failure injection proves LocalOCR output and errors are unchanged.

- [ ] **Step 6: Commit the reporting lifecycle**

```bash
git add Sources/LocalOCRIntelligence/LocalAIActivityReporter.swift Sources/LocalOCRIntelligence/LocalAIActivityWakeHint.swift tests/LocalOCRIntelligenceTests/LocalAIActivityReporterTests.swift tests/LocalOCRIntelligenceTests/LocalAIActivityWakeHintTests.swift
git commit -m "feat: report model operation lifecycle"
```

### Task 4: Instrument the shared intelligence router without reporting Vision OCR

**Files:**
- Modify: `Sources/LocalOCRIntelligence/LocalIntelligenceProviderRouter.swift:5-73`
- Modify: `Sources/LocalOCRIntelligence/LocalIntelligenceEnvironment.swift:3-72`
- Modify: `Sources/LocalOCRIntelligence/LocalModelQualificationService.swift:35-205`
- Modify: `tests/LocalOCRIntelligenceTests/LocalIntelligenceProviderRouterTests.swift:1-370`
- Modify: `tests/LocalOCRIntelligenceTests/LocalModelQualificationServiceTests.swift:1-220`
- Create: `tests/LocalOCRIntelligenceTests/LocalAIActivityIntegrationTests.swift`

**Interfaces:**
- Consumes: `LocalAIActivityReporting` and `LocalAIActivityDescriptor` from Task 3; existing `LocalIntelligenceSelectionStoring` and `DocumentIntelligenceProviding`.
- Produces: `LocalIntelligenceProviderRouter(..., activityReporter:producerRole:platform:)` and `LocalIntelligenceEnvironment.live(bridgeLocator:producerRole:)`; Studio/MCP router calls and CLI-triggered external-model qualification calls traverse the same reporter exactly once.

- [ ] **Step 1: Write failing router tests for product-task, runtime, route, and no-activity boundaries**

Extend the router fixture with a spy reporter. Prove:

- selected Apple summarize/organize/extract maps to `foundation_models`, `SystemLanguageModel.default`, `on_device`, `generation`, and the corresponding `summarize`/`organize`/`extract` product task;
- selected Ollama or LM Studio maps to `local_runtime`, null runtime identifier, `on_device_loopback`, and does not leak model names or endpoint URLs;
- `localocr intelligence test` qualification maps each owned summarize, organize, and extract probe to its own `local_runtime` lease with CLI provenance, while model discovery, selection, and receipt-cache reads emit none;
- availability checks, model discovery, selection changes, qualification receipt/cache access, OCR text loading, and ordinary Vision OCR generate no record;
- chunked Foundation Models work still produces one operation lease per user-owned summarize/organize/extract call, not one record per chunk;
- injected reporting failure leaves the provider's exact result/error unchanged.

```swift
@Test func appleSummaryReportsOneContentFreeOwnedOperation() async throws {
    let reporter = SpyLocalAIActivityReporter()
    let router = task6Router(
        selection: .selected(.appleSystemDefault),
        apple: Task6FixtureProvider(),
        reporter: reporter,
        role: .studio
    )
    _ = try await router.summarize(task6Document)
    #expect(await reporter.descriptors == [
        .init(
            producerID: LocalAIActivityContract.localOCRProducerID,
            producerRole: .studio,
            platform: .macos,
            runtimeFamily: .foundationModels,
            runtimeIdentifier: LocalAIActivityContract.foundationModelsIdentifier,
            route: .onDevice,
            operation: .generation,
            productTask: .summarize
        )
    ])
}
```

- [ ] **Step 2: Run the focused test and verify the expected failure**

Run:

```bash
swift test --filter LocalIntelligenceProviderRouterTests
swift test --filter LocalAIActivityIntegrationTests
```

Expected: FAIL because `LocalIntelligenceProviderRouter` has no `activityReporter`, `producerRole`, or `platform` parameters.

- [ ] **Step 3: Resolve an instrumented provider descriptor and wrap each public model operation once**

Change `resolvedProvider()` to return an internal value containing both the provider and fixed activity metadata. Do not derive metadata from OCR text, requested extraction names, external model names, fingerprints, endpoints, or eventual result provenance.

```swift
private struct ResolvedProvider: Sendable {
    let provider: any DocumentIntelligenceProviding
    let runtimeFamily: LocalAIRuntimeFamily
    let runtimeIdentifier: String?
    let route: LocalAIRoute
}

public func summarize(_ document: IntelligenceDocument) async throws -> ProvenancedIntelligenceResult<IntelligenceSummary> {
    let resolved = try await resolvedProvider()
    return try await activityReporter.withActivity(
        descriptor(for: resolved, productTask: .summarize)
    ) {
        try await resolved.provider.summarize(document)
    }
}
```

Repeat the explicit wrapper for organize and extract. Keep availability and provider discovery outside reporting. The router is the lifecycle boundary for selected model use; do not add reporting to `LanguageModelSession`, the model bridge, Studio view model, MCP dispatcher, command parser, text loader, `LocalOCRService`, or Vision recognizer.

The one additional model-owning boundary is `LocalModelQualificationService.qualify(_:)`, which directly invokes an external provider instead of the router. Wrap its three existing fixture probes with the same reporter using `.summarize`, `.organize`, and `.extract`; do not report provider discovery, cache lookup, receipt validation, or selection. The provider factory already supplies the exact external provider identity, but the descriptor records only `local_runtime`, null runtime identifier, and `on_device_loopback`.

- [ ] **Step 4: Add role-aware environment construction with a disabled default**

```swift
public static func live(
    bridgeLocator: any ModelBridgeExecutableLocating,
    producerRole: LocalAIProducerRole,
    activityReporter: any LocalAIActivityReporting = DisabledLocalAIActivityReporter()
) -> LocalIntelligenceEnvironment
```

Pass the role/reporter into both the router and `LocalModelQualificationService`. Preserve a test-only overload with injected selection store, Apple factory, reporter, role, platform, and clock. Do not resolve a production App Group identifier in this task.

- [ ] **Step 5: Run router, integration, MCP, Studio, and CLI tests**

Run:

```bash
swift test --filter LocalIntelligenceProviderRouterTests
swift test --filter LocalModelQualificationServiceTests
swift test --filter LocalAIActivityIntegrationTests
swift test --filter MCPToolDispatcherTests
swift test --filter StudioIntelligenceViewModelTests
swift test --filter CLIApplicationTests
```

Expected: PASS; there is one lease per model operation and zero leases for Vision-only paths.

- [ ] **Step 6: Commit shared-path instrumentation**

```bash
git add Sources/LocalOCRIntelligence/LocalIntelligenceProviderRouter.swift Sources/LocalOCRIntelligence/LocalIntelligenceEnvironment.swift Sources/LocalOCRIntelligence/LocalModelQualificationService.swift tests/LocalOCRIntelligenceTests/LocalIntelligenceProviderRouterTests.swift tests/LocalOCRIntelligenceTests/LocalModelQualificationServiceTests.swift tests/LocalOCRIntelligenceTests/LocalAIActivityIntegrationTests.swift
git commit -m "feat: instrument shared local intelligence operations"
```

### Task 5: Wire exact Studio, MCP, and CLI roles through the shared environment

**Files:**
- Modify: `App/LocalOCRStudioApp.swift:162-203`
- Modify: `Sources/LocalOCRMCPExecutable/main.swift:1-24`
- Modify: `Sources/LocalOCRCLIExecutable/main.swift:1-43`
- Modify: `tests/LocalOCRStudioKitTests/StudioViewContractTests.swift`
- Modify: `tests/LocalOCRMCPTests/MCPToolDispatcherTests.swift`
- Modify: `tests/LocalOCRCommandKitTests/CLIApplicationTests.swift`
- Create: `tests/contract/test_local_ai_activity_target_wiring.py`

**Interfaces:**
- Consumes: `LocalIntelligenceEnvironment.live(bridgeLocator:producerRole:activityReporter:)` from Task 4.
- Produces: exact `.studio`, `.mcp`, and `.cli` provenance at each executable composition root; future iOS roots can pass `.iosApp` without changing the contract.

- [ ] **Step 1: Add failing composition-root and target-coverage tests**

Add a Python source contract that parses the three composition roots and requires these exact arguments:

```python
def test_each_official_target_declares_one_exact_producer_role():
    assert "producerRole: .studio" in read("App/LocalOCRStudioApp.swift")
    assert "producerRole: .mcp" in read("Sources/LocalOCRMCPExecutable/main.swift")
    assert "producerRole: .cli" in read("Sources/LocalOCRCLIExecutable/main.swift")
```

Add Swift tests using injected temporary ledgers that invoke the shared router under Studio and MCP roles and `localocr intelligence test` under the CLI role, then assert independent active/recent UUID files. The CLI qualification command must create exactly three sequential generic leases—summarize, organize, and extract—without recording its synthetic fixture text, requested field names, model name, or qualification failures. Assert CLI `models`, `select`, `status`, and `reset` emit zero records. For MCP and Studio, retain their current view-model/dispatcher tests and assert reporting failures do not change results.

- [ ] **Step 2: Run the target wiring tests and verify the expected failure**

Run:

```bash
.venv/bin/python -m pytest -q tests/contract/test_local_ai_activity_target_wiring.py
swift test --filter LocalAIActivityIntegrationTests
```

Expected: FAIL because none of the three composition roots supplies an exact producer role.

- [ ] **Step 3: Pass exact roles and keep unconfigured production reporting disabled**

```swift
// Studio
LocalIntelligenceEnvironment.live(
    bridgeLocator: RelativeModelBridgeExecutableLocator(),
    producerRole: .studio
)

// localocr-mcp
LocalIntelligenceEnvironment.live(
    bridgeLocator: RelativeModelBridgeExecutableLocator(),
    producerRole: .mcp
)

// localocr
LocalIntelligenceEnvironment.live(
    bridgeLocator: RelativeModelBridgeExecutableLocator(),
    producerRole: .cli
)
```

Until the later identifier/entitlement gate, the default reporter remains `DisabledLocalAIActivityReporter`. Tests and development probes opt in only by injecting a temporary-container reporter. Do not use an environment variable or guessed group name as a silent production fallback.

- [ ] **Step 4: Run target, package, and app-build tests**

Run:

```bash
.venv/bin/python -m pytest -q tests/contract/test_local_ai_activity_target_wiring.py
swift test --filter LocalAIActivityIntegrationTests
swift test --filter MCPToolDispatcherTests
swift test --filter CLIApplicationTests
swift test --filter StudioViewContractTests
xcodebuild -project 'LocalOCR Studio.xcodeproj' -scheme 'LocalOCR Studio' -configuration Debug build
```

Expected: PASS; exact roles are wired, the app builds, and no production App Group is selected.

- [ ] **Step 5: Commit target role wiring**

```bash
git add App/LocalOCRStudioApp.swift Sources/LocalOCRMCPExecutable/main.swift Sources/LocalOCRCLIExecutable/main.swift tests/LocalOCRStudioKitTests/StudioViewContractTests.swift tests/LocalOCRMCPTests/MCPToolDispatcherTests.swift tests/LocalOCRCommandKitTests/CLIApplicationTests.swift tests/contract/test_local_ai_activity_target_wiring.py
git commit -m "feat: identify local AI activity producers"
```

### Task 6: Prove privacy, fail-closed behavior, and absence of Vision-only events

**Files:**
- Modify: `Sources/LocalOCRIntelligence/LocalAIActivityContract.swift`
- Modify: `Sources/LocalOCRIntelligence/LocalAIActivityReporter.swift`
- Modify: `Sources/LocalOCRIntelligence/LocalIntelligenceProviderRouter.swift:5-73`
- Modify: `Sources/LocalOCRIntelligence/LocalModelQualificationService.swift:164-215`
- Create: `tests/LocalOCRIntelligenceTests/LocalAIActivityPrivacyTests.swift`
- Modify: `tests/LocalOCRStudioKitTests/StudioIntelligenceViewModelTests.swift`
- Modify: `tests/LocalOCRMCPTests/MCPToolDispatcherTests.swift`
- Modify: `tests/LocalOCRCommandKitTests/CLIApplicationTests.swift`
- Modify: `tests/LocalOCRServiceTests/LocalOCRServiceTests.swift`

**Interfaces:**
- Consumes: the strict codec, ledger, reporter, and target roles from Tasks 1-5.
- Produces: executable proof that no content-bearing field or Vision-only operation reaches disk and all unavailable/malformed reporting paths leave LocalOCR behavior intact.

- [ ] **Step 1: Write failing privacy and negative-path tests**

Use distinctive canaries for every forbidden category:

```swift
let forbidden = [
    "SECRET OCR TEXT", "/Users/scott/private.pdf", "invoice.pdf",
    "prompt-canary", "response-canary", "total", "$9,999.00",
    "https://example.invalid", "model-error-canary"
]
```

Run Studio summarize, MCP extract, and a router operation against fixtures whose documents/results/errors contain all canaries; then recursively read every temporary-ledger byte and assert none appears. Under `@testable import LocalOCRIntelligence`, assert `LocalAIActivityContract.v1Keys` equals the spec's exact 17-key set and every encoded object has exactly that set. Run `LocalOCRService.ocrPDF`, `ocrImage`, batch OCR, and searchable-PDF paths with a spy reporter and assert zero begins. Inject unavailable container, permission denial, malformed prior active record, unknown schema, and reporter cancellation; assert exact pre-report LocalOCR values and stable public errors.

- [ ] **Step 2: Run privacy tests and verify the expected failure**

Run:

```bash
swift test --filter LocalAIActivityPrivacyTests
```

Expected: FAIL because the privacy suite and coding-key audit do not exist.

- [ ] **Step 3: Enforce the structural privacy boundary in the contract, reporter, router, and qualification service**

In `LocalAIActivityContract.swift`, expose this exact internal testable set and keep `LocalAIActivityDescriptor` memberwise construction internal. Provide only two production factories: `foundationModels(role:platform:task:)`, which fixes the Foundation Models family, identifier, on-device route, and generation operation; and `localRuntime(role:platform:task:)`, which fixes null runtime identifier, loopback route, and generation operation. Neither factory accepts a model name, endpoint, document value, field name, prompt, result, or error text.

```swift
static let v1Keys: Set<String> = [
    "schema_version", "activity_id", "producer_id", "producer_role", "platform",
    "runtime_family", "runtime_identifier", "route", "operation", "product_task",
    "state", "started_at", "heartbeat_at", "expires_at", "ended_at", "outcome",
    "evidence"
]

public static func foundationModels(
    role: LocalAIProducerRole,
    platform: LocalAIPlatform,
    task: LocalAIProductTask
) -> LocalAIActivityDescriptor

public static func localRuntime(
    role: LocalAIProducerRole,
    platform: LocalAIPlatform,
    task: LocalAIProductTask
) -> LocalAIActivityDescriptor
```

In `LocalAIActivityReporter.swift`, accept only `LocalAIActivityDescriptor`; preserve the owned operation's exact returned value or thrown error, while the record outcome collapses to this generic mapping and records no error payload:

```swift
private func reportedOutcome(for error: any Error) -> LocalAIActivityOutcome {
    if error is CancellationError { return .cancelled }
    if let intelligenceError = error as? IntelligenceError, intelligenceError == .cancelled {
        return .cancelled
    }
    return .failure
}
```

In `LocalIntelligenceProviderRouter.swift`, construct descriptors only with those two factories immediately around `summarize`, `organize`, and `extract`. In `LocalModelQualificationService.swift`, do the same around only its three owned fixture model calls. Do not add a reporter parameter, import, stored property, or callback to `LocalOCRService`, `OCRProcessor`, `VisionTextRecognizer`, `StudioOCRClient`, the MCP OCR cases, or CLI OCR commands; the negative tests must fail if any Vision path gains one. Do not redact after writing—content-bearing values must be structurally impossible to pass into the codec.

- [ ] **Step 4: Run privacy and regression suites**

Run:

```bash
swift test --filter LocalAIActivityPrivacyTests
swift test --filter LocalOCRServiceTests
swift test --filter LocalOCRIntelligenceTests
swift test --filter LocalOCRMCPTests
swift test --filter LocalOCRCommandKitTests
swift test --filter LocalOCRStudioKitTests
```

Expected: PASS; canaries never appear on disk and every Vision-only path records zero activity.

- [ ] **Step 5: Commit privacy acceptance**

```bash
git add Sources/LocalOCRIntelligence/LocalAIActivityContract.swift Sources/LocalOCRIntelligence/LocalAIActivityReporter.swift Sources/LocalOCRIntelligence/LocalIntelligenceProviderRouter.swift Sources/LocalOCRIntelligence/LocalModelQualificationService.swift tests/LocalOCRIntelligenceTests/LocalAIActivityPrivacyTests.swift tests/LocalOCRStudioKitTests/StudioIntelligenceViewModelTests.swift tests/LocalOCRMCPTests/MCPToolDispatcherTests.swift tests/LocalOCRCommandKitTests/CLIApplicationTests.swift tests/LocalOCRServiceTests/LocalOCRServiceTests.swift
git commit -m "test: enforce local AI activity privacy boundary"
```

### Task 7: Document user controls, disclosure, and the explicit production entitlement gate

**Files:**
- Modify: `README.md:16-68,140-205`
- Modify: `docs/studio.md:60-110`
- Modify: `docs/mcp.md:321-438`
- Modify: `docs/cli.md:160-205`
- Create: `docs/release/local-ai-activity-entitlement-gate.md`
- Modify: `tests/contract/test_beta_documentation_alignment.py`
- Modify: `tests/contract/test_direct_release_scripts.py`

**Interfaces:**
- Consumes: the user-visible and signing requirements in the approved spec.
- Produces: truthful help/privacy language and an evidence checklist that cannot be mistaken for authorization to register, entitle, sign, notarize, install, merge, publish, or release.

- [ ] **Step 1: Write failing documentation and release-gate contracts**

Require the docs to state all of the following exact truths:

```python
required_truths = [
    "App reported",
    "Nonparticipating apps are not visible",
    "No per-app Neural Engine utilization metric is available",
    "Activity sharing is content-free",
    "Vision OCR does not create a Local AI Activity record",
    "Active leases expire after 45 seconds",
    "Recent activity expires within 24 hours",
    "iOS background delivery is opportunistic, not continuous",
]
```

Require the entitlement-gate document to enumerate LocalOCR Studio, `Contents/Helpers/localocr-mcp`, `Contents/Helpers/localocr`, future iOS/iPadOS targets, and sandbox/distribution probes. Add a negative test that rejects any literal matching `group\.[A-Za-z0-9.-]+\.local-ai-activity` outside the approved spec and gate document, rejects Team-ID-only group identifiers in source, project, entitlement, or release-script files, and rejects a hard-coded `Notification.Name` containing `local-ai-activity` in production source.

- [ ] **Step 2: Run documentation contracts and verify the expected failure**

Run:

```bash
.venv/bin/python -m pytest -q tests/contract/test_beta_documentation_alignment.py tests/contract/test_direct_release_scripts.py
```

Expected: FAIL because the disclosure and explicit entitlement gate are absent.

- [ ] **Step 3: Add content-free sharing and limitation disclosures**

Explain that participating LocalOCR model operations can share only role, runtime family, generic task, timing, and outcome; no document or model content is shared. State that operations continue when sharing is unavailable, users can clear recent activity in the reader, and open-source/ad hoc builds use injected development ledgers rather than the official group. For future iOS/iPadOS targets, state that the reader reconstructs the ledger on foreground entry and system-granted background opportunities, background delivery is opportunistic rather than continuous, and nonparticipating apps remain invisible. Preserve the existing warning that MCP clients may separately transmit LocalOCR inputs/results to their own provider; do not imply the content-free ledger changes MCP-client privacy.

- [ ] **Step 4: Write the later production gate as a non-executing checklist**

The gate document must require, in this order and each with fresh approval:

1. Scott approves the durable reverse-domain namespace, legal owner, Apple team, and exact `group.*` identifier.
2. Apple App Group registration is performed and recorded.
3. The exact App Group identifier and the approved macOS wake-notification name are injected through build configuration and applied to Studio, `localocr-mcp`, `localocr`, and applicable probes; neither value has a guessed or hard-coded fallback, and the wake implementation remains `NoLocalAIActivityWakeHint` until both values are approved.
4. Each nested helper is independently provisioned/signed and its entitlement/runtime validation is inspected before the containing app is sealed.
5. Focused sandbox probes and cross-app temporary-ledger acceptance pass.
6. Developer ID signing, Hardened Runtime, notarization, stapling, Gatekeeper, archive extraction, and second-Mac verification run as a separate gate.
7. Future iOS/iPadOS profiles contain the same group and foreground/recent reconstruction passes before any TestFlight gate.
8. Installation, merge, publication, and release each require separate authorization.

Do not create an entitlement file, change the Xcode project, call Apple services, or alter a release script in this task.

- [ ] **Step 5: Run documentation and placeholder scans**

Run:

```bash
.venv/bin/python -m pytest -q tests/contract/test_beta_documentation_alignment.py tests/contract/test_direct_release_scripts.py
rg -n 'group\.[A-Za-z0-9.-]+\.local-ai-activity|DZ8B5454ZN\.' App Sources Package.swift 'LocalOCR Studio.xcodeproj' scripts --glob '!**/Fixtures/**'
rg -n 'Notification\.Name\("[^"]*local-ai-activity' Sources
```

Expected: tests PASS and both `rg` commands exit 1 with no production identifier, Team-ID-only group, or hard-coded wake-notification name match.

- [ ] **Step 6: Commit documentation and the release gate**

```bash
git add README.md docs/studio.md docs/mcp.md docs/cli.md docs/release/local-ai-activity-entitlement-gate.md tests/contract/test_beta_documentation_alignment.py tests/contract/test_direct_release_scripts.py
git commit -m "docs: explain local AI activity sharing gate"
```

### Task 8: Complete the cross-repository golden-fixture handshake and coordinated acceptance

**Files:**
- Verify: `tests/LocalOCRIntelligenceTests/Fixtures/LocalAIActivity/v1/localocr-foundation-models-active.json`
- Modify: `tests/LocalOCRIntelligenceTests/LocalAIActivityIntegrationTests.swift`
- Verify in reader worktree: `/Users/scott/Developer/ai-neural-gauge/.worktrees/apple-foundation-monitoring/AI Neural GaugeTests/Fixtures/LocalAIActivity/v1/localocr-foundation-models-active.json`
- Create: `scripts/verify-local-ai-activity-interoperability.sh`
- Create: `tests/contract/test_local_ai_activity_interoperability_script.py`

**Interfaces:**
- Consumes: producer canonical bytes and decoder from Task 1; the ANG reader mirror fixture and strict reader decoder from coordinated Plan A.
- Produces: one exact cross-repository handshake: byte-for-byte `cmp`, producer re-encode equality, reader exact-field decode, and an injected temporary-ledger end-to-end operation.

- [ ] **Step 1: Write the failing interoperability-script contract**

Require the script to accept `ANG_WORKTREE` explicitly, refuse an empty/non-directory path, compare the two exact fixture paths, run the focused producer and reader suites, and run only injected temporary-container integration tests.

```python
import os
from pathlib import Path

def test_interoperability_script_has_exact_handshake():
    path = Path("scripts/verify-local-ai-activity-interoperability.sh")
    script = path.read_text()
    assert os.access(path, os.X_OK)
    assert "cmp --" in script
    assert "localocr-foundation-models-active.json" in script
    assert "swift test --filter LocalAIActivityContractTests" in script
    assert "mktemp -d" in script
    assert "trap 'rm -rf -- \"$acceptance_root\"' EXIT" in script
    assert "LOCAL_AI_ACTIVITY_ACCEPTANCE_CONTAINER" in script
    assert "LOCAL_AI_ACTIVITY_ACCEPTANCE_EXPECTATION" in script
    assert "LOCAL_AI_ACTIVITY_ACCEPTANCE_NOW" in script
    for phase in ["active", "success", "cancelled", "failure", "expired_recent"]:
        assert f'run_phase "{phase}"' in script
    for expectation in ["active", "recent_success", "recent_cancelled", "recent_failure", "expired_recent"]:
        assert f'"{expectation}"' in script
    assert "LocalAIActivityCrossAppProducerTests" in script
    assert "LocalAIActivityCrossAppIntegrationTests" in script
```

- [ ] **Step 2: Run the script contract and verify the expected failure**

Run:

```bash
.venv/bin/python -m pytest -q tests/contract/test_local_ai_activity_interoperability_script.py
```

Expected: FAIL because `scripts/verify-local-ai-activity-interoperability.sh` does not exist.

- [ ] **Step 3: Implement the exact, read-only cross-repository handshake**

```bash
#!/bin/bash
set -euo pipefail
: "${ANG_WORKTREE:?set ANG_WORKTREE to the clean AI Neural Gauge reader worktree}"
test -d "$ANG_WORKTREE/.git" || test -f "$ANG_WORKTREE/.git"
producer_fixture="tests/LocalOCRIntelligenceTests/Fixtures/LocalAIActivity/v1/localocr-foundation-models-active.json"
reader_fixture="$ANG_WORKTREE/AI Neural GaugeTests/Fixtures/LocalAIActivity/v1/localocr-foundation-models-active.json"
cmp -- "$producer_fixture" "$reader_fixture"
swift test --filter LocalAIActivityContractTests
swift test --filter LocalAIActivityIntegrationTests
(cd "$ANG_WORKTREE" && xcodebuild test -project 'AI Neural Gauge.xcodeproj' -scheme 'AI Neural Gauge' -only-testing:'AI Neural GaugeTests/LocalAIActivityContractTests')
acceptance_root="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-activity-acceptance.XXXXXX")"
trap 'rm -rf -- "$acceptance_root"' EXIT

run_phase() {
    local phase="$1" producer_test="$2" expectation="$3" now="$4" reader_test="$5"
    export LOCAL_AI_ACTIVITY_ACCEPTANCE_CONTAINER="$acceptance_root/$phase"
    export LOCAL_AI_ACTIVITY_ACCEPTANCE_EXPECTATION="$expectation"
    export LOCAL_AI_ACTIVITY_ACCEPTANCE_NOW="$now"
    mkdir -p -- "$LOCAL_AI_ACTIVITY_ACCEPTANCE_CONTAINER"
    swift test --filter "LocalAIActivityCrossAppProducerTests/$producer_test"
    (cd "$ANG_WORKTREE" && xcodebuild test \
        -project 'AI Neural Gauge.xcodeproj' \
        -scheme 'AI Neural Gauge' \
        -destination 'platform=macOS' \
        -only-testing:"AI Neural GaugeTests/LocalAIActivityCrossAppIntegrationTests/$reader_test")
}

run_phase "active" "writeActiveFoundationModelsLease" "active" "2026-08-31T14:00:10Z" "readsActiveFoundationModelsLease"
run_phase "success" "writeEndedSuccessLease" "recent_success" "2026-08-31T14:01:00Z" "readsRecentSuccess"
run_phase "cancelled" "writeEndedCancelledLease" "recent_cancelled" "2026-08-31T14:01:00Z" "readsRecentCancellation"
run_phase "failure" "writeEndedFailureLease" "recent_failure" "2026-08-31T14:01:00Z" "readsRecentFailure"
run_phase "expired_recent" "writeExpiredRecentLease" "expired_recent" "2026-09-01T14:00:01Z" "ignoresExpiredRecentLease"
```

After creating the file, run `chmod 0755 scripts/verify-local-ai-activity-interoperability.sh`; the contract test must also assert `os.access(path, os.X_OK)`.

The producer contract test must generate exactly the committed canonical bytes; the ANG reader mirror must decode the same exact fields. Do not use a guessed or deferred SHA-256 value. `cmp` plus both strict codecs is the version-1 interoperability handshake.

- [ ] **Step 4: Add phase-specific producer fixtures for the script-owned temporary ledger**

Create a `LocalAIActivityCrossAppProducerTests` suite in `tests/LocalOCRIntelligenceTests/LocalAIActivityIntegrationTests.swift`. Each named test must require all three environment variables, refuse a non-temporary or pre-existing nonempty container, parse the fixed acceptance clock, invoke the real codec/ledger/reporter around a fake content-free operation, and leave one deterministic state on disk after the test process exits:

```swift
@Suite(.serialized) struct LocalAIActivityCrossAppProducerTests {
    @Test func writeActiveFoundationModelsLease() async throws
    @Test func writeEndedSuccessLease() async throws
    @Test func writeEndedCancelledLease() async throws
    @Test func writeEndedFailureLease() async throws
    @Test func writeExpiredRecentLease() async throws
}
```

The active phase calls the ledger's `begin` directly so the lease remains active after the test exits. Success, cancellation, and failure phases use `LocalAIActivityReporter.withActivity` so lifecycle mapping is exercised. The expired-recent phase writes a valid ended record whose retention deadline precedes `LOCAL_AI_ACTIVITY_ACCEPTANCE_NOW`; it does not run producer cleanup before ANG reads it. After each producer test exits, the ANG phase reads the exact same `LOCAL_AI_ACTIVITY_ACCEPTANCE_CONTAINER` and injected `LOCAL_AI_ACTIVITY_ACCEPTANCE_NOW`, accepts only the exact expectation values `active`, `recent_success`, `recent_cancelled`, `recent_failure`, and `expired_recent`, asserts the corresponding active/recent/absent state, and never infers activity from the environment variable itself. No process remains blocked across test commands. No App Group entitlement, notification payload, daemon process, real model, real document, or production container is used.

- [ ] **Step 5: Run focused producer, full LocalOCR, and coordinated reader acceptance**

Run:

```bash
ANG_WORKTREE=/Users/scott/Developer/ai-neural-gauge/.worktrees/apple-foundation-monitoring \
  scripts/verify-local-ai-activity-interoperability.sh
swift test
.venv/bin/python -m pytest -q tests/contract
xcodebuild -project 'LocalOCR Studio.xcodeproj' -scheme 'LocalOCR Studio' -configuration Debug build
git diff --check
```

Expected: both fixtures are byte-identical; both strict codecs accept the fixture; active/recent reconstruction passes through one injected temporary ledger; all Swift, Python contract, and Debug app-build tests pass; no production entitlement or identifier is required.

- [ ] **Step 6: Commit the interoperability verifier**

```bash
git add scripts/verify-local-ai-activity-interoperability.sh tests/contract/test_local_ai_activity_interoperability_script.py tests/LocalOCRIntelligenceTests/LocalAIActivityIntegrationTests.swift
git commit -m "test: verify local AI activity interoperability"
```

- [ ] **Step 7: Stop at the coordinated implementation acceptance gate**

Record the LocalOCR commit, ANG commit, commands, fixture `cmp` result, focused/full test results, and temporary-ledger end-to-end result. Then stop. The following remain separate authorization gates and are not performed by this plan:

1. production App Group namespace/legal-owner approval;
2. Apple App Group registration;
3. Studio/helper/iOS entitlement and provisioning changes;
4. Developer ID signing or iOS distribution signing;
5. notarization, stapling, Gatekeeper, TestFlight, or App Store processing;
6. installation on any Mac, iPhone, or iPad;
7. branch merge;
8. publication, announcement, or release creation.

No gate is implied by green tests, an accepted fixture, or a successful temporary-ledger probe.
