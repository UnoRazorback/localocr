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

## Fix round 1: structured params, terminal ownership, and bounded admission

### Corrective changes

- The envelope now rejects a present `params` value unless it is an object or
  array. Invalid requests receive `-32600`; invalid notifications remain
  silent. `notifications/initialized` additionally requires omitted or
  object-shaped params, because the notification has no positional form. Null,
  scalar, and array params therefore cannot transition the server to ready.
  A generic method whose Swift parameter type is `Value` can no longer bypass
  the JSON-RPC structured-params rule with a scalar.
- Every response-bearing request is reserved before lifecycle or method
  dispatch. Registry entries now have explicit `executing` and `sending`
  phases. Success, typed errors, and cancellation atomically claim the sending
  phase; the ID remains reserved until `Transport.send` succeeds. A send or
  encoding failure closes the connection and clears the registry. Duplicate
  input during a blocked terminal send is rejected without invoking a second
  handler, and cancellation retains the same terminal ownership rule.
- `Server.maximumInFlightRequests` is fixed at **8** per connection. The count
  includes both executing and terminal-sending requests. A distinct request
  beyond the limit receives deterministic JSON-RPC server error `-32000`,
  `Server error: too many in-flight requests`, and starts no handler work.
  Duplicate detection takes precedence over overload detection.

### In-flight limit rationale for the decision ledger

Eight is the smallest non-arbitrary bound already supported by an audited
adjacent resource boundary: `StdioTransport` buffers at most eight completed
one-MiB input frames. Reusing that bound prevents the server from creating a
larger tier of concurrent, potentially document-heavy LocalOCR work than the
transport can queue, while preserving the approved concurrent-request and
out-of-order response behavior. A limit of one would contradict that
concurrency requirement; choosing two or four would impose a new stricter
client throttle without an existing protocol or transport basis. The limit is
fixed rather than configurable so the shipping resource policy remains
auditable and deterministic.

### TDD and self-review evidence

- RED: null, scalar, and empty-array initialized notifications all unlocked the
  server; a scalar reached a registered `Value` handler. GREEN: all malformed
  initialized variants remain silent and a following ping stays lifecycle
  gated, while scalar generic params return `-32600` before handler entry.
- RED: while an original response was blocked in the transport, its ID had
  already been removed and a second handler with the same ID ran successfully.
  GREEN: the duplicate returns `-32600`, the original handler remains the only
  handler invoked, and the original response is delivered after output resumes.
- RED: the registry had no cancellation terminal state. GREEN: direct registry
  coverage proves cancellation changes `executing` to `sending`, duplicate
  reservation remains rejected, and release occurs only after terminal finish.
- RED: there was no fixed in-flight bound. GREEN: eight suspended requests fill
  the registry, the ninth receives exact overload code/message without handler
  entry, successful completion reopens one slot, and delivered cancellation
  independently reopens one slot.
- Mutation review covers accepting null/scalar params, allowing array-shaped
  initialized params, releasing IDs before send, omitting cancellation's
  sending state, admitting a ninth handler, returning the wrong overload code,
  and failing to reopen capacity after terminal delivery.

### Fix-round verification

- Exact-source focused `swift test --filter ServerTests`: 20 tests passed,
  including three parameterized malformed-initialized cases.
- `.venv/bin/python -m pytest tests/contract/test_mcp_stdio_vendor.py -q`:
  38 passed with the same five pre-existing SWIG deprecation warnings.
- Updated local SHA-256 values:
  - `Server/Server.swift`:
    `ee7f094e3da99539f7c036f5faa503113ea14048b891cd1a586525a3bbb604dc`
  - `Server/RequestRegistry.swift`:
    `98cebcb2348760c599d68f7a906c9e5c577f50914780878c231b103d22cc3f9d`

Task 2-3 protocol types and transport remain unchanged. The Task 5 root-suite
and module-migration gate remains carried; no production stub or unrelated
process, document, consent, release, signing, publication, or external-state
change was introduced.

## Fix round 2: generation leases, execution accounting, and initialize claim

### Corrective changes

- Every accepted request now receives a monotonic, connection-local lease.
  Registry mutations that can terminate or release a request validate both its
  JSON-RPC ID and lease. A cancelled handler from an earlier generation can
  therefore neither claim the terminal path nor release a later reservation
  that reused the same ID.
- Protocol reservations and live handler tasks now use separate ledgers, each
  bounded at `Server.maximumInFlightRequests` (**8**). Successful delivery of a
  cancellation error may release the protocol ID, but the execution slot stays
  occupied until that exact handler task exits. Requests admitted while all
  eight cancellation-insensitive handlers remain live receive the same
  deterministic `-32000` overload response without starting handler work.
- Initialization atomically transitions from `awaitingInitialize` to an
  explicit `initializing` state before response construction or output can
  suspend. A second initialize request cannot acquire the lifecycle claim,
  including while the first initialize response is blocked in the transport.
  An invalid initialize releases the claim only after its error is delivered.

The original limit rationale remains unchanged: eight matches the adjacent
eight-frame completed-input queue and is the smallest audited bound compatible
with concurrent request handling. The separate live-handler ledger closes a
distinct resource-accounting gap; cancellation cannot be used to recycle IDs
into more than eight executing handler tasks.

### TDD and regression evidence

- ABA RED: after cancellation delivery and same-ID reuse, resuming the old
  cancellation-insensitive handler produced an internal error for the reused
  ID and suppressed the replacement result. GREEN: the old lease is rejected;
  the replacement result survives and the two observed terminal responses are
  exactly the old cancellation and the replacement success.
- Execution-capacity RED: cancelling eight suspended handlers and repeatedly
  reusing capacity started eight additional handlers even though none of the
  originals had exited. GREEN: all replacement attempts receive `-32000`, the
  invocation count remains eight, and exactly one slot reopens only after an
  original handler records task completion.
- Initialize regression: with the first initialize output deliberately blocked,
  a second different ID receives `-32600`; both IDs receive exactly one
  response and only the first response is successful. The lifecycle claim is
  set before the first await.
- Mutation review covers ID-only terminal transitions, ID-only finish, stale
  handler cleanup, freeing execution capacity on cancellation delivery,
  attaching after cancellation, admitting a ninth live handler, and delaying
  the initialize state transition until after response delivery.

### Fix-round verification

- Exact-source focused `swift test --filter ServerTests`: 22 tests passed,
  including the same-ID cancellation ABA, cancellation-insensitive saturation,
  and blocked-initialize regressions.
- `swift build --target MCPStdioTests`: passed against the checked real target.
- `.venv/bin/python -m pytest tests/contract/test_mcp_stdio_vendor.py -q`:
  38 passed with the same five pre-existing SWIG deprecation warnings; this
  includes manifest closure, provenance, and local-hash checks.
- Updated local SHA-256 values:
  - `Server/Server.swift`:
    `8645db96398be8ddbf4cb960f87b2f504622b65d003c8c21641028f9bf9693c5`
  - `Server/RequestRegistry.swift`:
    `8233f56a170b4aec91eabb14645537c55a3ed6beb363c7c79622db018ae2f26e`

Task 2-3 public types and transport remain unchanged. Root-suite ownership
remains with Task 5 after module migration. No production stub, client,
resource, prompt, HTTP/OAuth/network surface, process, release, publication, or
external-state action was introduced.
