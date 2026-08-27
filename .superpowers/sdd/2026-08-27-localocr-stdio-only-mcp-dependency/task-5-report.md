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

## Fix round 1

- A deterministic suspended-connect regression test reproduced the reviewed
  cancellation race: the prior latch could start and memoize `disconnect()`
  while the underlying `connect()` was suspended, after which `connect()` could
  resume open with no second cleanup. `CancellationLatchedTransport` now tracks
  `notStarted`, `connecting`, and `settled` states. Cancellation records intent
  while connecting; cancellation cleanup and any concurrent explicit
  `disconnect()` wait for connect settlement, then share exactly one memoized
  disconnect task. Existing pre-connect, start-error, open-connection, and
  suspending-disconnect cleanup behavior remains covered.
- The LocalOCR migration import contract no longer relies on a seven-file
  allowlist. It recursively discovers every `.swift` file below both
  `Sources/LocalOCRMCP` and `tests/LocalOCRMCPTests`, rejects direct and
  `@testable` `MCP` imports, and requires `MCPStdio` in files that reference
  MCP protocol types. Adversarial nested source and test fixtures prove that
  both a newly introduced legacy import and newly introduced unimported MCP
  type use fail the contract, while the migrated form passes.

## Fix round 2

- Review found that the first recursive contract's anchored regex did not
  recognize Swift's scoped declaration imports or imports preceded by general
  attributes and access modifiers. The validator now masks nested block and
  line comments plus ordinary, multiline, and raw Swift strings, then matches
  the import declaration core: `import`, an optional Swift declaration kind,
  and the exact module token. This rejects direct or scoped `MCP` imports with
  any preceding attribute/access combination without confusing `MCPStdio` or
  source-like text in comments and strings.
- The adversarial matrix covers all scoped declaration kinds, every applicable
  Swift import access level, `@testable`, `@_exported`, `@preconcurrency`,
  `@_spi`, and `@_implementationOnly`, plus attribute/access/scoped and
  multiline combinations. Nested comments and ordinary, multiline, and raw
  string lookalikes are accepted as non-code.

## Verification

- `.venv/bin/python -m pytest tests/contract/test_mcp_stdio_vendor.py -q -k import_policy_rejects_every_swift_import_form`:
  initially failed on `import struct MCP.Value`, then **1 passed** after the
  lexical matcher change.
- `.venv/bin/python -m pytest tests/contract/test_mcp_stdio_vendor.py -q`:
  **41 passed**; five pre-existing SWIG deprecation warnings.
- `swift test --filter ProtocolTypesTests`: **8 passed**.
- `swift test --filter StdioTransportTests`: **18 passed**.
- `swift test --filter ServerTests`: **22 passed**.
- `swift test --filter MCPStdioTests`: **48 passed**.
- `swift test --filter LocalOCRMCPTests`: **33 passed**.
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
  `bede28cf0a025934963b2aa9b8b422dd1d7a1c248795a70f958d95fbfe32fd3e`
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
