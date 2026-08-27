# Task 3 report: bounded race-safe stdio transport

## Status

Implemented the audited `Transport` protocol and a POSIX `StdioTransport` for
caller-owned file descriptors. Input framing is bounded to 1,048,576 message
bytes excluding LF or CRLF, overflow data is discarded only through the
offending line boundary, and framing then terminates with JSON-RPC parse error
`-32700`. Empty frames remain ignored and unterminated EOF fragments are not
dispatched.

Writes append one LF, retry partial and would-block operations, and use an
explicit FIFO permit so actor reentrancy cannot interleave concurrent frames
while a writer is suspended. Darwin output descriptors use `F_SETNOSIGPIPE`;
broken output finishes the connection with a content-free internal error
instead of terminating the process. Connect/send cancellation, EOF,
disconnect, and concurrent-disconnect paths converge on one guarded stream
completion. Logs contain lifecycle text and byte counts only, never payloads.

The closed manifest now records the exact pinned upstream `Transport.swift`
and `StdioTransport.swift` origins, upstream SHA-256 values, real local
SHA-256 values, and the intentional LocalOCR hardening adaptations.

## TDD and self-review evidence

- RED: the checked `MCPStdioTests` target failed because `Transport` and
  `StdioTransport` did not exist.
- GREEN cycle 1: nine real-pipe tests passed for one/fragmented/multiple
  messages, CRLF, EOF, the exact size boundary, overflow termination, payload
  log exclusion, concurrent sends, partial writes, and broken output.
- RED cycle 2: an already-cancelled connect task connected instead of throwing.
  Adding the pre-mutation cancellation check made the cancellation/lifecycle
  race set pass.
- RED cycle 3 from self-review: two large concurrent sends interleaved under
  forced pipe backpressure because Swift actors are reentrant across the
  would-block sleep. The explicit FIFO write permit fixed the root cause; the
  regression now passes with both complete frames.
- Mutation review covers wrong size bounds, missed CR stripping, yielded
  overflow/following frames, missing write serialization, missing EPIPE
  suppression, ignored cancellation, and payload-bearing logs.

## Verification

- `swift build --target MCPStdioTests`: pass; compiles the checked real test
  target without changing package targets or introducing lifecycle/server
  stubs.
- Exact-source focused runner using symlinks to the checked-in
  `Sources/MCPStdio` and `tests/MCPStdioTests`:
  `swift test --filter StdioTransportTests`: 14 tests passed.
- `.venv/bin/python -m pytest tests/contract/test_mcp_stdio_vendor.py -q`:
  38 passed; five pre-existing SWIG deprecation warnings.
- `git diff --check`: pass.
- Local hashes verified with `shasum -a 256`:
  - `Base/Transport.swift`:
    `d783216e494063e2273291bc15756188ce6607ba6f218b5b8adae5841951bab2`
  - `Base/StdioTransport.swift`:
    `a0290eeea9c2f292e7e3bc3b47c589dbb406fe382cde493a2626aad7fb526b39`

## Carried gates and concern

The root `swift test --filter StdioTransportTests` remains unable to link the
package-wide test product because `LocalOCRMCP` still references the removed
remote `MCP` module. Tasks 4-5 own that migration and the root execution gate;
Task 3 did not add a stub or alter target ordering to bypass it.

An exact-source full focused run also exposed a pre-existing Task 2 test
assertion that searches raw JSON text for `notifications/cancelled`. This
toolchain correctly encodes the method as `notifications\/cancelled`; decode
and round-trip pass, but the raw substring assertion fails. Task 2's binding
source and test were left unchanged. This does not affect the 14 Task 3
transport tests and should be corrected or normalized when the Task 5 root
suite is made runnable.

No LocalOCR tool, consent, document, process, release, signing, installation,
publication, external configuration, or business-record state was changed.

## Fix round 1: bounded delivery and cancellation-aware FIFO

### Corrective changes

- Replaced the default unbounded `AsyncThrowingStream` buffering with an
  explicit `.bufferingOldest(8)` receive capacity. Because each accepted frame
  remains capped at 1 MiB, queued completed input is bounded to eight
  maximum-sized frames. A ninth unconsumed frame makes `yield` report a drop;
  the transport then fails closed with a content-free internal error while the
  eight already-accepted frames remain ordered.
- Replaced anonymous nonthrowing write waiters with FIFO records containing a
  unique waiter ID and outcome continuation. A lock-protected cancellation
  token closes the cancel-before-enqueue race; the actor removes and resumes a
  queued cancelled waiter immediately. If cancellation races with a grant, the
  sender observes cancellation after acquiring and releases the permit through
  its existing `defer`.
- Added a literal 1,048,577-byte framing test rather than relying only on a
  larger synthetic overflow fixture.
- Strengthened the backpressure ordering regression from unordered equality of
  two frames to exact FIFO equality of three separately queued large frames.

Caller-owned descriptor lifetime, Darwin `F_SETNOSIGPIPE`, guarded exact-once
stream completion, and payload-free logging are unchanged. The manifest now
records transport SHA-256
`a0533daa322d0eeaae9698c5f354445f4cf32c8a15a6dd9f191b3d2ebb8260b4`
and the receive-capacity/waiter-removal adaptations.

### TDD and mutation evidence

- RED: `burstWithoutAConsumerFailsClosedAtEightBufferedMessages` returned the
  ninth frame from the former unbounded stream. GREEN: it now receives exactly
  eight ordered frames and then internal error `-32603`.
- RED: `cancellingAQueuedSenderRemovesItsWaiterWithoutWritingLater` did not
  complete within 200 ms while the active writer remained blocked. GREEN: the
  cancelled waiter completes promptly, throws `CancellationError`, and its
  unique `0x7e` payload never appears in the output pipe.
- The literal `maximumMessageBytes + 1` test passed the correct implementation;
  weakening the newline-boundary comparison to permit one extra byte made the
  test fail with the expected missing parse error. The mutation was restored.
- The three-writer FIFO test passed the correct implementation; mutating waiter
  release from `removeFirst()` to `removeLast()` made its literal ordered-array
  assertion fail. The mutation was restored.

### Fix-round verification

- Exact-source focused runner,
  `swift test --filter StdioTransportTests`: 17 tests passed.
- `swift build --target MCPStdioTests`: passed with the checked real test target.
- `.venv/bin/python -m pytest tests/contract/test_mcp_stdio_vendor.py -q`:
  38 passed with the same five pre-existing SWIG deprecation warnings.
- Manifest/local SHA-256 equality and `git diff --check`: passed.
- The root package-wide test link remains intentionally carried to Tasks 4-5;
  no stub, target reordering, or unrelated protocol change was introduced.
