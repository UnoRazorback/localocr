# Task 4 report: minimal server lifecycle and dispatch

## Status

Implemented the closed inbound MCP server slice in `MCPStdio`. The server now
supports strict `initialize` / `notifications/initialized` lifecycle,
negotiated initialize responses, ping, typed `tools/list` and `tools/call`
handlers, unsupported-method errors, cancellation, concurrent correlated
responses, EOF/explicit stop, and content-free lifecycle diagnostics.

`RequestRegistry` reserves active IDs before handler work, rejects a duplicate
with `-32600` without replacing the original, assigns only one terminal path,
makes repeated/late cancellation silent, suppresses late handler completion,
and cancels outstanding work during teardown. Handler throws return `-32603`;
malformed UTF-8/JSON returns `-32700` with a null ID; structurally invalid
requests return `-32600`; invalid typed parameters return `-32602`; unknown
methods return `-32601`. Unsupported and malformed notifications emit no
response. Response-encoding and transport-output failures stop the affected
connection safely.

No Task 2-3 public protocol type or `Transport` implementation changed. No MCP
client, batch, HTTP context, HTTP/OAuth/EventSource/URLSession/socket transport,
resource, prompt, sampling, elicitation, roots, completion, logging-control, or
network surface was added.

## TDD evidence

- Initial RED: `swift build --target MCPStdioTests` failed because `Server` did
  not exist. The first implementation then compiled the real checked test
  target.
- Lifecycle GREEN: the exact-source focused runner passed initialization,
  initialized gating, ping, tool list/call, unknown method, malformed input,
  notification silence, EOF, duplicate IDs, out-of-order completion,
  before/during/after cancellation, thrown handlers, payload-free logs, and
  output failure.
- Cancellation RED: a handler suspended on an arbitrary continuation did not
  resume merely because its Swift task was cancelled. The registry now
  atomically claims cancellation, cancels work, and lets the server emit the
  single terminal error; late completion cannot emit a second response.
- Encoding RED: the server returned `-32603` and remained connected when a
  handler result could not encode. Handler exceptions and response-encoding
  failures are now distinct, so only the latter closes the connection.
- Invalid-request RED: a valid JSON object with neither `id` nor `method` was
  incorrectly treated as a silent notification. Only an object that actually
  has a string method and lacks an ID is notification-shaped; other invalid
  objects receive `-32600` with null ID.
- Final focused run: 14 `ServerTests` passed. Mutation review covers wrong
  lifecycle state, wrong response ID, missing duplicate reservation, registry
  replacement, cancellation double-response, late EOF response, unknown-method
  dispatch, payload-bearing logs, and failure to close on encoding/pipe errors.

## Exact-source focused runner

The focused Swift package at
`/private/tmp/localocr-stdio-task3-tests.7D8pfq` uses filesystem symlinks for
both `Sources/MCPStdio` and `tests/MCPStdioTests` back to this checked worktree;
it contains no copied source and no production stubs. This durable report plus
the checked `ServerTests.swift` records the exact command and outcome:

```text
swift test --filter ServerTests
Test run with 14 tests in 1 suite passed.
```

## Verification

- `swift build --target MCPStdioTests`: passed against the checked real target.
- Exact-source focused `swift test --filter ServerTests`: 14 passed.
- `.venv/bin/python -m pytest tests/contract/test_mcp_stdio_vendor.py -q`:
  38 passed with five pre-existing SWIG deprecation warnings.
- Manifest JSON parse, local SHA-256 equality, and `git diff --check`: passed.
- Upstream `Server.swift` provenance was verified at exact commit
  `a0ae212ebf6eab5f754c3129608bc5557637e605`, SHA-256
  `61cd2439525e73a417cbc36711b7e0340a2442f14acbb1631915ee3d792962f3`.
- Local hashes:
  - `Server/Server.swift`:
    `0d711da5daad108a332be7a3f44e394ca6d202635f6c9378a607e3992b3a30b3`
  - `Server/RequestRegistry.swift`:
    `f37506b1ebffd27716241f713ce6f024651ba18bb8bf9332b9f21d1037a70d5b`

## Carried gate and concerns

The root package-wide `swift test` execution remains intentionally owned by
Task 5 because `LocalOCRMCP` still imports the removed remote `MCP` module and
has not yet been migrated to depend on `MCPStdio`. Task 4 compiled the checked
MCP target and executed its exact-source server suite without changing target
order or adding a production stub.

Task 5 must perform the module/dependency migration and run the root Swift and
subprocess compatibility gates. No document, consent, signing, installation,
process, release, publication, external configuration, or business state was
changed.
