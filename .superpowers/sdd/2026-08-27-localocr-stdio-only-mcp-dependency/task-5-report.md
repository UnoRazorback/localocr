# Task 5 report: LocalOCR migration to MCPStdio

## Status

Implemented the LocalOCR MCP dependency migration. `LocalOCRMCP` and its test
target now depend on and import the local `MCPStdio` module; no LocalOCR source,
test, resolved pin, or Swift package dependency graph entry refers to the
remote `MCP` product or `mcp-swift-sdk`.

The nine-tool catalog, order, schemas, argument decoding, consent-first
ordering, result text, structured content, and error shapes remain unchanged.
The old SDK client/in-memory test fixture was replaced with a test-only raw JSON
transport that exercises the real local server without adding a shipping MCP
client. The Task 5 raw subprocess contract, which was named by the approved
plan but absent from this worktree, was restored against the freshly built
`dist/native-tools/localocr-mcp` artifact.

No client configuration, process registration, signing, installation,
publication, release, campaign, document, consent receipt outside isolated test
homes, or business state was changed.

## TDD and compatibility fixes

- Migration RED: the new package/source contract failed because
  `LocalOCRMCP` and `LocalOCRMCPTests` lacked `MCPStdio` target edges; the Swift
  suite then failed to link its remaining `MCP` references.
- API-boundary RED: LocalOCRMCP runner tests could not compile because the
  intentionally excluded upstream `Client` and `InMemoryTransport` types were
  absent. A test-only raw JSON transport now verifies initialize, list, call,
  cancellation, EOF, and injected-transport behavior through public
  `MCPStdio` APIs.
- Lifecycle RED: two existing runner tests showed that a failed or cancelled
  `MCPStdio.Server.start` clears its transport before `server.stop()` can clean
  it up. The runner now disconnects its idempotent cancellation-latched
  transport on start failure, preserves the original error, and still performs
  exactly one cleanup.
- Structured-result RED: non-scalar dispatcher tests exited with SIGBUS. The
  cause was overload recursion when a non-optional `Value` selected the generic
  `CallTool.Result` initializer. LocalOCR now passes `Optional.some(Value)` to
  select the intended non-generic initializer, preserving identical wire
  content and avoiding any change to the reviewed `MCPStdio` target.
- Carried protocol RED: the raw JSON cancellation-method assertion rejected
  Foundation's valid escaped slash spelling. The test normalizes `\/` to `/`
  before its substring assertion; encoded wire behavior was not changed.
- Subprocess fixture RED: the first restored-contract run used pytest's
  symlinked `/var` temp root, so the consent store correctly rejected the test
  receipt. The isolated home now uses the repository's physical `.build`
  directory with private modes and cleanup, matching the existing security
  contract.

Mutation review covers a returned `import MCP`, a missing `MCPStdio` target
edge, any `MCP`/`swift-sdk` product edge in any target, a returned resolved SDK
pin, wrong tool order, consent bypass, lost structured content, missing
cancellation, non-clean EOF, lifecycle double cleanup, and diagnostic stdout.

## Verification

- `.venv/bin/python -m pytest tests/contract/test_mcp_stdio_vendor.py -q`:
  **39 passed**; five pre-existing SWIG deprecation warnings.
- `swift test --filter ProtocolTypesTests`: **8 passed**.
- `swift test --filter StdioTransportTests`: **18 passed**.
- `swift test --filter ServerTests`: **22 passed**.
- `swift test --filter MCPStdioTests`: **48 passed**.
- `swift test --filter LocalOCRMCPTests`: **32 passed**.
- `./scripts/build-native-tools.sh`: passed and produced a fresh shipping
  helper.
- `.venv/bin/python -m pytest tests/contract/test_mcp_native_subprocess.py -q`:
  passed three consecutive runs. The raw contract verifies initialize, exact
  ordered nine-tool listing, consent blocking before file access, accepted
  scalar and structured calls, active cancellation, a subsequent ping, EOF,
  and clean stdout/stderr.
- After `swift build --product localocr-mcp`,
  `.venv/bin/python -m pytest tests/contract/test_native_mcp_server.py tests/contract/test_native_python_compatibility.py -q`:
  **4 passed, 1 skipped**. The skip is the existing explicit opt-in live
  Foundation Models subprocess test.
- `git diff --check`: passed.
- `swift package show-dependencies --format json` plus source/package searches:
  no remote SDK, `MCP` product, LocalOCR network import, or URL-session symbol
  surface.

## Artifact inspection

Fresh `dist/native-tools/localocr-mcp`:

- SHA-256:
  `6a92929be9cca57175a11653b6b4b6e0b447d43b84cdde2959c614440cc483f6`
- `otool -L`: only approved Apple/system dependencies used by LocalOCR OCR and
  Local Intelligence (System, CoreFoundation/CoreGraphics/CoreText,
  CryptoKit, Foundation/FoundationModels weak, ImageIO, PDFKit, Vision, C++,
  Objective-C, and Swift runtime libraries). No CFNetwork or Network framework.
- `otool -l`: exactly `/usr/lib/swift` for `LC_RPATH`.
- `nm -u | rg 'CFNetwork|Network|NSURLSession'`: no matches.

## Remaining concerns and gates

No Task 5 behavioral or dependency concern remains after self-review. The live
Foundation Models subprocess case was not opted in. Broader adversarial raw
protocol compatibility remains Task 6, and clean exact-commit/manual,
distribution, signing, installation, and release acceptance remain separate
later gates with separate authorization.
