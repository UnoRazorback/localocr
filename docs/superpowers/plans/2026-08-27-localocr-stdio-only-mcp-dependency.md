# LocalOCR Stdio-Only MCP Dependency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the monolithic remote MCP Swift SDK dependency with a pinned, audited local stdio-only module while preserving LocalOCR's existing nine-tool MCP behavior.

**Architecture:** Add a closed local `MCPStdio` target containing only JSON-RPC types, lifecycle, tool messages, bounded stdio transport, and server dispatch. Record upstream 0.12.1 provenance and hashes, remove the remote SDK, migrate `LocalOCRMCP`, and make source plus binary policy fail closed on network surfaces.

**Tech Stack:** Swift 6.3.3, Swift Package Manager, Swift Testing, Foundation JSON coding, Darwin/System file descriptors, swift-log, swift-system, Python pytest, Xcode 26.6, `otool`.

**Spec:** `docs/superpowers/specs/2026-08-27-localocr-stdio-only-mcp-dependency-design.md`

## Global Constraints

- Preserve the exact nine-tool catalog, order, schemas, results, errors, consent gate, and stdio behavior.
- Baseline is `mcp-swift-sdk` 0.12.1 commit `a0ae212ebf6eab5f754c3129608bc5557637e605`.
- Limit inbound messages to 1 MiB excluding the newline.
- Use JSON-RPC errors `-32700`, `-32600`, `-32601`, and `-32603` per the spec.
- Protocol output uses stdout; content-free diagnostics use stderr.
- No client, HTTP, OAuth, EventSource, URLSession, socket, CFNetwork, or Network transport code may ship.
- Keep macOS 14.0 and arm64 direct-distribution compatibility.
- Do not move document, OCR, model, path-policy, or consent logic into `MCPStdio`.
- Do not sign, notarize, install, merge, push, tag, publish, or change campaign state.
- Do not alter unrelated or stuck processes without exact renewed authorization.

---

### Task 1: Closed Vendor Boundary

**Files:**
- Modify: `Package.swift`
- Modify: `Package.resolved`
- Create: `Sources/MCPStdio/MCPStdio.swift`
- Create: `Sources/MCPStdio/Upstream/LICENSE`
- Create: `Sources/MCPStdio/Upstream/PROVENANCE.md`
- Create: `Sources/MCPStdio/Upstream/manifest.json`
- Create: `tests/contract/test_mcp_stdio_vendor.py`

**Interfaces:**
- Consumes: pinned upstream checkout as evidence only.
- Produces: local target `MCPStdio` and manifest `{schema_version, upstream, files, adaptations}`.

- [ ] **Step 1: Write failing provenance contracts**

```python
def test_package_uses_local_mcp_stdio() -> None:
    package = (ROOT / "Package.swift").read_text()
    assert 'name: "MCPStdio"' in package
    assert "modelcontextprotocol/swift-sdk" not in package
    assert '.product(name: "MCP", package: "swift-sdk")' not in package

def test_manifest_is_closed_and_pinned() -> None:
    data = json.loads(MANIFEST.read_text())
    assert data["upstream"]["release"] == "0.12.1"
    assert data["upstream"]["commit"] == "a0ae212ebf6eab5f754c3129608bc5557637e605"
    declared = {item["path"] for item in data["files"]}
    actual = {p.relative_to(VENDOR).as_posix() for p in VENDOR.rglob("*.swift")}
    assert declared == actual
```

Require lowercase 64-character hashes, valid upstream origin paths for derived files, explicit `local_only: true` for original LocalOCR files, adaptation records for changed derived files, and the upstream license/provenance files.

- [ ] **Step 2: Confirm RED**

```bash
.venv/bin/python -m pytest tests/contract/test_mcp_stdio_vendor.py -q
```

Expected: missing target, records, and manifest; remote SDK still present.

- [ ] **Step 3: Add the local target and records**

Add explicit `swift-system` and `swift-log` dependencies and:

```swift
.target(
    name: "MCPStdio",
    dependencies: [
        .product(name: "SystemPackage", package: "swift-system"),
        .product(name: "Logging", package: "swift-log"),
    ],
    swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
)
```

Remove `swift-sdk`, resolve the package, copy its license verbatim, and record repository, release, commit, retrieval date, selection rule, exclusions, and hash command in provenance.

Make the new target immediately buildable with a local-only identity file:

```swift
public enum MCPStdioBuild {
    public static let upstreamRelease = "0.12.1"
    public static let upstreamCommit = "a0ae212ebf6eab5f754c3129608bc5557637e605"
}
```

List this file in the manifest as `local_only: true` with its real local SHA-256 and no upstream origin/hash.

- [ ] **Step 4: Add adversarial manifest cases**

Using temporary copied trees, reject unlisted/missing sources, malformed hashes, origin paths outside `Sources/MCP`, unrecorded adaptations, and forbidden names such as `HTTPClientTransport.swift`.

- [ ] **Step 5: Verify and commit**

```bash
swift package resolve
.venv/bin/python -m pytest tests/contract/test_mcp_stdio_vendor.py -q
git diff --check
git add Package.swift Package.resolved Sources/MCPStdio tests/contract/test_mcp_stdio_vendor.py
git commit -m "build: establish audited MCP stdio vendor boundary"
```

---

### Task 2: JSON-RPC and MCP Tool Types

**Files:**
- Create: `Sources/MCPStdio/Base/ID.swift`
- Create: `Sources/MCPStdio/Base/Value.swift`
- Create: `Sources/MCPStdio/Base/Error.swift`
- Create: `Sources/MCPStdio/Base/Messages.swift`
- Create: `Sources/MCPStdio/Base/Lifecycle.swift`
- Create: `Sources/MCPStdio/Base/Versioning.swift`
- Create: `Sources/MCPStdio/Base/Ping.swift`
- Create: `Sources/MCPStdio/Base/Cancellation.swift`
- Create: `Sources/MCPStdio/Server/Tools.swift`
- Create: `tests/MCPStdioTests/ProtocolTypesTests.swift`
- Modify: `Package.swift`
- Modify: `Sources/MCPStdio/Upstream/manifest.json`

**Interfaces:**
- Produces public `ID`, `Value`, `MCPError`, `Method`, `Notification`, `Request`, `Response`, `Initialize`, `InitializedNotification`, `Ping`, `CancelledNotification`, `Tool`, `ListTools`, and `CallTool`.

- [ ] **Step 1: Add the test target and failing round-trip tests**

```swift
@Test func initializeRequestRoundTrips() throws {
    let data = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#.utf8)
    let request = try JSONDecoder().decode(Request<Initialize>.self, from: data)
    #expect(request.id == .int(1))
    #expect(try JSONDecoder().decode(Request<Initialize>.self, from: JSONEncoder().encode(request)) == request)
}
```

Cover integer/string IDs, null, all `Value` cases, initialize capabilities, tool annotations/schemas, call arguments/results, ping, cancellation, and exact error encoding.

- [ ] **Step 2: Confirm RED**

```bash
swift test --filter ProtocolTypesTests
```

- [ ] **Step 3: Adapt the minimum upstream types**

Preserve encoding and initializer behavior used by LocalOCR. Remove URL elicitation, HTTP context, clients, resources, prompts, completions, logging-control, and sampling. Keep public values `Sendable`.

- [ ] **Step 4: Record actual hashes**

Each manifest file entry includes `path`, upstream `origin`, `upstream_sha256`, and `local_sha256`. Add a concrete adaptation reason whenever hashes differ; generate hashes from the pinned checkout.

- [ ] **Step 5: Verify and commit**

```bash
swift test --filter ProtocolTypesTests
.venv/bin/python -m pytest tests/contract/test_mcp_stdio_vendor.py -q
git diff --check
git add Package.swift Sources/MCPStdio tests/MCPStdioTests tests/contract/test_mcp_stdio_vendor.py
git commit -m "feat: vendor minimal MCP protocol types"
```

---

### Task 3: Bounded Stdio Transport

**Files:**
- Create: `Sources/MCPStdio/Base/Transport.swift`
- Create: `Sources/MCPStdio/Base/StdioTransport.swift`
- Create: `tests/MCPStdioTests/StdioTransportTests.swift`
- Modify: `Sources/MCPStdio/Upstream/manifest.json`

**Interfaces:**
- Consumes: newline-delimited JSON-RPC `Data` and `MCPError`.
- Produces: `Transport` and `StdioTransport.maximumMessageBytes == 1_048_576`.

- [ ] **Step 1: Write failing pipe-based tests**

Use dedicated `FileDescriptor` pipes, never process stdin/stdout. Cover one message, fragmented reads, multiple messages, CRLF, EOF, concurrent sends, partial writes, broken output, and the exact size boundary.

```swift
@Test func oversizedMessageTerminatesFraming() async throws {
    let harness = try PipeTransportHarness()
    let transport = StdioTransport(input: harness.input, output: harness.output)
    try await transport.connect()
    try harness.write(Data(repeating: 0x61, count: 1_048_577) + Data("\n{}\n".utf8))
    var iterator = await transport.receive().makeAsyncIterator()
    await #expect(throws: MCPError.self) { try await iterator.next() }
}
```

Assert the oversized and following lines are never yielded, payload bytes never enter logs, and sends append exactly one newline.

- [ ] **Step 2: Confirm RED**

```bash
swift test --filter StdioTransportTests
```

- [ ] **Step 3: Implement bounded transport**

Adapt upstream stdio I/O using Swift System and Darwin POSIX. Bound buffering, normalize one CR before LF, serialize writes actor-isolated, finish the stream once, treat zero-byte reads as EOF, and make disconnect idempotent. A framing overflow ends the connection with parse error.

- [ ] **Step 4: Add race and cancellation coverage**

Test cancellation before connect, during temporarily unavailable read/partial write, simultaneous EOF/disconnect, and concurrent disconnect calls.

- [ ] **Step 5: Verify and commit**

```bash
swift test --filter StdioTransportTests
.venv/bin/python -m pytest tests/contract/test_mcp_stdio_vendor.py -q
git diff --check
git add Sources/MCPStdio tests/MCPStdioTests
git commit -m "feat: add bounded MCP stdio transport"
```

---

### Task 4: Minimal Server Lifecycle and Dispatch

**Files:**
- Create: `Sources/MCPStdio/Server/Server.swift`
- Create: `Sources/MCPStdio/Server/RequestRegistry.swift`
- Create: `tests/MCPStdioTests/ServerTests.swift`
- Modify: `Sources/MCPStdio/Upstream/manifest.json`

**Interfaces:**
- Consumes: `Transport`, protocol types, tools, ping, and cancellation.
- Produces: `Server.init(name:version:capabilities:configuration:)`, `withMethodHandler`, `start(transport:)`, `waitUntilCompleted()`, and `stop()`.

- [ ] **Step 1: Write failing lifecycle tests**

Use a test-only in-memory transport. Cover strict initialization, initialize response, initialized notification, ping, list/call tools, unknown method, malformed JSON, invalid request, notification silence, and EOF.

```swift
@Test func unknownMethodReturnsMethodNotFound() async throws {
    let harness = ServerHarness()
    try await harness.start()
    await harness.send(#"{"jsonrpc":"2.0","id":7,"method":"files/delete","params":{}}"#)
    let response = try await harness.nextResponse()
    #expect(response.error?.code == -32601)
    #expect(response.id == .int(7))
    #expect(await harness.toolCallCount == 0)
}
```

- [ ] **Step 2: Confirm RED**

```bash
swift test --filter ServerTests
```

- [ ] **Step 3: Implement only the required server**

Adapt handler registration and lifecycle, excluding clients, HTTP context, resources, prompts, completion, OAuth, and logging-control. Decode a small envelope before method-specific payloads. Never log raw input.

- [ ] **Step 4: Add request-registry tests**

Reject duplicate active IDs with `-32600` without replacing the first request. Test distinct out-of-order completion, cancellation before/during/after work, repeated cancellation, and exactly one terminal response.

- [ ] **Step 5: Add failure-containment tests**

Require thrown handlers to produce `-32603`, malformed UTF-8/JSON to produce `-32700` with null ID, unsupported notifications to produce no output, and encoding/pipe failure to stop safely.

- [ ] **Step 6: Verify and commit**

```bash
swift test --filter MCPStdioTests
.venv/bin/python -m pytest tests/contract/test_mcp_stdio_vendor.py -q
git diff --check
git add Sources/MCPStdio tests/MCPStdioTests
git commit -m "feat: add minimal MCP stdio server"
```

---

### Task 5: Migrate LocalOCR to MCPStdio

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/LocalOCRMCP/MCPArgumentDecoder.swift`
- Modify: `Sources/LocalOCRMCP/MCPServerRunner.swift`
- Modify: `Sources/LocalOCRMCP/MCPToolCatalog.swift`
- Modify: `Sources/LocalOCRMCP/MCPToolDispatcher.swift`
- Modify: `tests/LocalOCRMCPTests/MCPArgumentDecoderTests.swift`
- Modify: `tests/LocalOCRMCPTests/MCPServerRunnerTests.swift`
- Modify: `tests/LocalOCRMCPTests/MCPToolDispatcherTests.swift`
- Modify: `tests/contract/test_mcp_native_subprocess.py`
- Modify: `tests/contract/test_mcp_stdio_vendor.py`

**Interfaces:**
- Consumes: `MCPStdio` public API.
- Produces: unchanged LocalOCR nine-tool server with no remote MCP product.

- [ ] **Step 1: Add failing migration contracts**

Require LocalOCR MCP sources/tests to import `MCPStdio`; reject `import MCP`, all `swift-sdk` resolution entries, and any dependency-graph product named `MCP` from that package.

- [ ] **Step 2: Confirm RED**

```bash
.venv/bin/python -m pytest tests/contract/test_mcp_stdio_vendor.py -q
swift test --filter LocalOCRMCPTests
```

- [ ] **Step 3: Switch dependencies and imports**

Make `LocalOCRMCP` and its tests depend on `MCPStdio`. Add only narrow adapters for deliberate local API differences. Do not change catalog definitions, dispatcher ordering, consent behavior, or result shapes.

- [ ] **Step 4: Verify Swift behavior**

```bash
swift test --filter LocalOCRMCPTests
swift test --filter MCPStdioTests
```

- [ ] **Step 5: Build and run real subprocess contracts**

```bash
./scripts/build-native-tools.sh
.venv/bin/python -m pytest tests/contract/test_mcp_native_subprocess.py -q
```

Require initialize, exact nine-tool listing, consent blocking, accepted compatibility calls, structured results, cancellation, and EOF.

- [ ] **Step 6: Inspect the helper**

```bash
otool -L dist/native-tools/localocr-mcp
otool -l dist/native-tools/localocr-mcp | sed -n '/LC_RPATH/,+3p'
nm -u dist/native-tools/localocr-mcp | rg 'CFNetwork|Network|NSURLSession' || true
```

Expected: no network framework/install name or URL-session symbol; only approved system dependencies and `/usr/lib/swift` RPATH.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Package.resolved Sources/LocalOCRMCP tests/LocalOCRMCPTests tests/contract
git commit -m "refactor: move LocalOCR MCP to stdio-only module"
```

---

### Task 6: Black-Box Protocol Compatibility

**Files:**
- Create: `tests/contract/test_mcp_stdio_protocol.py`
- Modify: `tests/contract/test_mcp_native_subprocess.py`
- Modify: `scripts/smoke-native-tools.sh`
- Modify: `docs/mcp.md`

**Interfaces:**
- Consumes: built `dist/native-tools/localocr-mcp`.
- Produces: black-box proof of client compatibility and bounded failure behavior.

- [ ] **Step 1: Write failing adversarial subprocess tests**

Launch the helper with isolated `HOME`. Send raw lines and correlate responses. Cover malformed UTF-8/JSON, unknown methods, notifications, duplicate IDs, cancellation, exact 1 MiB input, 1 MiB plus one, EOF, and stdout JSON purity.

```python
def test_unknown_method_never_reaches_dispatcher(mcp_process):
    mcp_process.send({"jsonrpc": "2.0", "id": 81, "method": "files/delete", "params": {}})
    response = mcp_process.receive(id=81)
    assert response["error"]["code"] == -32601
    assert response["id"] == 81
```

- [ ] **Step 2: Confirm RED**

```bash
.venv/bin/python -m pytest tests/contract/test_mcp_stdio_protocol.py -q
```

- [ ] **Step 3: Correct protocol mismatches only**

Keep fixes inside `MCPStdio`. Do not weaken message-size, network, consent, or stdout policy.

- [ ] **Step 4: Verify client handshakes without editing configuration**

Use generic MCP JSON and the initialization protocol versions/capabilities observed from the currently installed Codex and Claude clients. Run the helper directly; do not add/remove client registrations.

- [ ] **Step 5: Update smoke and documentation**

Extend smoke to require nine tools and clean EOF. Document that LocalOCR vendors an audited stdio-only subset while the external agent provider remains governed by its own privacy and retention terms.

- [ ] **Step 6: Verify and commit**

```bash
.venv/bin/python -m pytest tests/contract/test_mcp_stdio_protocol.py tests/contract/test_mcp_native_subprocess.py tests/contract/test_mcp_consent_and_intelligence_documentation.py -q
./scripts/smoke-native-tools.sh
git diff --check
git add tests/contract scripts/smoke-native-tools.sh docs/mcp.md
git commit -m "test: verify stdio-only MCP compatibility"
```

---

### Task 7: Supply-Chain and Release Policy Closure

**Files:**
- Modify: `tests/contract/test_mcp_stdio_vendor.py`
- Modify: `tests/contract/test_release_artifacts.py`
- Modify: `tests/contract/test_direct_release_scripts.py`
- Modify: `tests/contract/test_studio_app_project.py`
- Modify: `scripts/build-native-tools.sh`
- Modify: `scripts/build-unsigned-studio-app.sh`
- Modify: `scripts/stage-direct-release.sh`
- Modify: `scripts/verify-direct-release.sh`

**Interfaces:**
- Consumes: closed manifest and newly built artifacts.
- Produces: fail-closed source, build, stage, and verification policy.

- [ ] **Step 1: Add adversarial source/package mutations**

Reject extra/missing vendored files, hash/adaptation mismatches, forbidden network/client imports and API tokens, remote SDK/fork reintroduction, transitive `MCP` package products, and license/provenance removal.

- [ ] **Step 2: Add artifact mutations**

Prove policy rejects direct and arbitrary canonical-version CFNetwork/Network paths, URL-session symbols where supported, unsafe RPATHs, and non-system dependencies.

- [ ] **Step 3: Confirm RED**

```bash
.venv/bin/python -m pytest tests/contract/test_mcp_stdio_vendor.py tests/contract/test_release_artifacts.py tests/contract/test_direct_release_scripts.py tests/contract/test_studio_app_project.py -q
```

- [ ] **Step 4: Centralize enforcement**

Reuse release-toolchain canonical path validation. Run closed-manifest/dependency checks before long builds; retain network rejection before artifact replacement, in unsigned-app validation, staging, and final verification.

- [ ] **Step 5: Build fresh artifacts and verify**

```bash
./scripts/build-native-tools.sh
./scripts/build-unsigned-studio-app.sh
.venv/bin/python -m pytest tests/contract/test_mcp_stdio_vendor.py tests/contract/test_release_artifacts.py tests/contract/test_direct_release_scripts.py tests/contract/test_studio_app_project.py -q
```

- [ ] **Step 6: Inspect all shipping executables**

Inspect CLI, MCP, Studio, and both bundled helpers with `otool -L`, RPATH/build-version checks, architecture inspection, and symbol scans. Require macOS 14.0, arm64, approved system libraries, only `/usr/lib/swift` RPATH, and no network/user/build paths.

- [ ] **Step 7: Commit**

```bash
git add scripts tests/contract
git commit -m "test: enforce stdio-only MCP release policy"
```

---

### Task 8: Exact-Commit Candidate Acceptance and Records

**Files:**
- Modify: `docs/release/local-intelligence-candidate-acceptance.md`
- Create: `.superpowers/sdd/2026-08-27-localocr-stdio-only-mcp-dependency/task-8-report.md`
- Modify after dated evidence: `/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/reports/mcp-macvision/MCP-MacVision-Time-and-Cost-Log.csv`
- Modify after dated evidence: `/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/reports/mcp-macvision/README.md`
- Create after closure: `/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/reports/mcp-macvision/MCP-MacVision-Local-Intelligence-Candidate-Evidence-2026-08-27.md`

**Interfaces:**
- Consumes: exact final code commit, test results, hashes, manual evidence, and review.
- Produces: evidence-backed candidate decision and dated business records; no release mutation.

- [ ] **Step 1: Review the exact final diff**

Audit vendored files against origin/manifest and inspect for network/client surfaces, unbounded allocation, ID races, stdout contamination, payload logs, consent bypass, protocol drift, and license gaps.

```bash
git diff "$(git merge-base HEAD c2ff3259e190ef5adf037c091a04b34830014131)"...HEAD --stat
rg -n 'URLSession|NWConnection|import (Network|CFNetwork)|OAuth|EventSource|HTTPClientTransport|NetworkTransport' Sources Package.swift Package.resolved
```

Shipping Swift hits are rejected; allowed provenance text must be explained.

- [ ] **Step 2: Commit review fixes before acceptance**

Run focused tests for each fix and commit it. The resulting source commit is the acceptance identity; earlier runs are not final evidence.

- [ ] **Step 3: Run the clean exact-commit matrix**

```bash
git status --short
swift test
xcodebuild -project LocalOCRStudio.xcodeproj -scheme 'LocalOCR Studio' -destination 'platform=macOS,arch=arm64' test
./scripts/build-native-tools.sh
./scripts/build-unsigned-studio-app.sh
./scripts/smoke-native-tools.sh
.venv/bin/python -m pytest -q
git diff --check
git status --short
```

Require unlocked console and Developer Mode for UI automation. Record unavailable gates as not run and keep the candidate unaccepted; never weaken tests.

- [ ] **Step 4: Record fresh artifact evidence**

Compute SHA-256 for CLI, MCP, Studio, and bundled helpers. Record `otool`, RPATH, build-version, architecture, and symbol results from exact-commit artifacts. Reject stale artifacts.

- [ ] **Step 5: Run the synthetic manual matrix**

Verify OCR with intelligence unavailable; summarize/organize/extract when available; grounding; Process Another reset; batch OCR-only; Help; consent across Studio/CLI/MCP; nine client tools; cancellation; source hash immutability; and no runtime LocalOCR connection. Do not infer unavailable live-model results.

- [ ] **Step 6: Commit candidate evidence**

Record exact source commit, dates, commands, counts, hashes, inspection, manual results, skips, and limitations. Name the later evidence commit separately.

```bash
git add docs/release/local-intelligence-candidate-acceptance.md
git commit -m "docs: record stdio-only candidate acceptance"
```

- [ ] **Step 7: Update business records from evidence only**

Append supported milestone rows. Leave Hours, Direct Cost, and Shared Cost Allocation blank without dated owner/receipt/allocation evidence. Do not estimate from elapsed time. Update overview/evidence; do not change beta metrics or feedback logs solely for a candidate.

- [ ] **Step 8: Validate records and stop at release authorization**

```bash
python3 - <<'PY'
import csv
from pathlib import Path
p = Path('/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/reports/mcp-macvision/MCP-MacVision-Time-and-Cost-Log.csv')
with p.open(newline='') as f:
    rows = list(csv.DictReader(f))
assert rows and all(rows[-1].get(k) is not None for k in ['Date', 'Workstream', 'Work Item', 'Evidence Link or Commit'])
print(f'validated {len(rows)} time-and-cost rows')
PY
git status --short
```

Report implementation, automated, manual, signing, notarization, downloaded-package, second-Mac, installation, and publication separately. Request new authorization before distribution.
