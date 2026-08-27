# LocalOCR Stdio-Only MCP Dependency Design

## Status

Approved in conversation on 2026-08-27. This specification replaces only the
MCP transport dependency boundary. It does not change LocalOCR's nine-tool
surface, consent policy, document behavior, signing state, or release status.

## Problem

LocalOCR uses only the stdio transport from `mcp-swift-sdk` 0.12.1, but that
package exposes stdio, HTTP, OAuth, EventSource, URLSession, and Network
transports through one Swift target. The resulting `localocr-mcp` executable
links Apple's CFNetwork and Network frameworks even though LocalOCR does not
request a network transport.

The approved candidate policy rejects any shipping LocalOCR helper that links
CFNetwork or Network. Current candidate builds therefore fail closed. LocalOCR
needs a smaller, auditable MCP dependency that preserves its stdio behavior
without compiling or linking unused network functionality.

## Goals

- Preserve the observable MCP behavior of the current nine-tool stdio server.
- Vendor a minimal, audited source snapshot directly in the LocalOCR repository.
- Remove the remote `mcp-swift-sdk` package dependency.
- Exclude HTTP, OAuth, EventSource, URLSession, and Network transport code.
- Keep MCP protocol mechanics separate from LocalOCR document and consent logic.
- Make the vendored source set, provenance, licensing, and future updates
  reproducible and reviewable.
- Produce helpers that depend only on approved Apple/system libraries and do not
  link CFNetwork or Network.

## Non-goals

- Adding an HTTP, SSE, WebSocket, socket, or other network MCP transport.
- Implementing an MCP client.
- Expanding or renaming LocalOCR's nine tools.
- Changing the external-data acknowledgment or consent receipt.
- Moving OCR, model, file, or business logic into the transport layer.
- Automatically updating vendored code from upstream.
- Signing, notarizing, installing, merging, pushing, publishing, tagging, or
  changing campaign state as part of this implementation.

## Upstream provenance and licensing

The initial source is derived from `mcp-swift-sdk` release `0.12.1`, exact git
commit `a0ae212ebf6eab5f754c3129608bc5557637e605`.

The repository will include:

- the applicable upstream license text;
- a provenance document naming the upstream repository, release, commit, date,
  and the LocalOCR module name;
- a manifest listing every imported or adapted upstream source file and its
  upstream SHA-256 hash;
- a manifest entry for each intentional LocalOCR adaptation; and
- an update procedure that requires a fresh source audit, hash refresh,
  compatibility matrix, dependency inspection, and review.

Vendored source must remain attributable. License and provenance files are
shipping-source records and may not be removed by build scripts.

## Architecture

### Package boundary

Add a local Swift target named `MCPStdio`. `LocalOCRMCP` and its tests depend on
this target and import `MCPStdio`. Remove the `mcp-swift-sdk` package declaration
and every `.product(name: "MCP", package: "swift-sdk")` dependency from
`Package.swift` and `Package.resolved`.

The local target contains only:

- JSON-RPC identifiers, values, messages, errors, and protocol-version types;
- server lifecycle and handler dispatch needed by LocalOCR;
- tool definitions and `tools/list` / `tools/call` messages;
- ping and cancellation messages;
- the transport protocol; and
- the stdio transport.

It must not contain client, HTTP, OAuth, EventSource, URLSession, socket, or
Network transport code. It must not import CFNetwork or Network. If selected
upstream server code references an HTTP-only context or type, that reference is
removed in the vendored adaptation rather than importing the HTTP subsystem.

The module may retain audited non-network dependencies only when they are
needed by the selected stdio implementation. Any retained dependency must be
declared explicitly, included in the provenance record, and pass the final
binary policy.

### Ownership boundary

`MCPStdio` owns wire-format parsing, request correlation, lifecycle dispatch,
and stdout response encoding. It knows nothing about documents, file paths,
OCR, Foundation Models, consent receipts, or LocalOCR tool semantics.

`LocalOCRMCP` continues to own the tool catalog, argument decoding, consent
gate, file access, dispatcher, and result construction. The current order stays
unchanged: validate the request, verify consent, then open or process a file.

### Compatibility boundary

The migration may change Swift module names and internal adapters, but must not
change observable stdio protocol behavior. Existing clients must still be able
to initialize the server, list the same nine tools in the same order, call each
tool with the same schemas, receive the same result/error shapes, send ping and
cancellation messages, and shut down through EOF.

## Protocol and data flow

1. An MCP client launches `localocr-mcp` with stdin, stdout, and stderr pipes.
2. `MCPStdio` reads one bounded UTF-8 JSON-RPC message per line from stdin.
3. The server decodes and dispatches initialization, initialized notification,
   ping, `tools/list`, `tools/call`, and cancellation messages.
4. Tool calls cross into `LocalOCRMCP`, where existing argument, consent, file,
   OCR, and intelligence behavior applies.
5. `MCPStdio` encodes exactly one correlated response for each request that
   requires a response.
6. Protocol output goes only to stdout. Content-free diagnostics go only to
   stderr.
7. EOF stops the server cleanly and cancels outstanding work.

The transport never opens a network endpoint, constructs a URL request, or
receives access to LocalOCR document bytes outside structured tool arguments
and results already handled by `LocalOCRMCP`.

## Failure and resource policy

- Input is limited to 1 MiB per newline-delimited message, including JSON but
  excluding the line terminator. Oversized input is rejected before request
  dispatch, and the reader drains only through that message's line boundary.
- Input must be one complete JSON-RPC message per line. Malformed UTF-8,
  malformed JSON, trailing protocol data, and unsupported messages return the
  appropriate deterministic protocol error when a response is permitted.
- Unknown methods do not reach the LocalOCR dispatcher.
- Duplicate active request IDs are rejected or otherwise handled
  deterministically without replacing the original request.
- Cancellation is idempotent and cannot create a second result after a request
  has completed.
- Concurrent requests preserve response IDs and never interleave encoded JSON
  bytes on stdout.
- An output encoding or pipe failure stops the affected connection safely.
- Diagnostics contain no document text, filenames, paths, extracted values,
  prompts, or model output.
- No failure path bypasses the existing consent check or opens a document before
  consent is validated.

Malformed UTF-8 or JSON uses JSON-RPC parse error `-32700`; structurally invalid
requests and duplicate active IDs use invalid request `-32600`; unsupported
methods use method not found `-32601`; unexpected server failures use internal
error `-32603`. Notifications never receive responses. A broken output pipe
stops the connection because no reliable protocol response can be delivered.

## Audit and update procedure

The vendored directory is closed by default: every source file must appear in
the provenance manifest, and every manifest entry must resolve to a real file.
Contracts reject unlisted files, missing files, changed upstream hashes without
an adaptation record, and forbidden imports or API tokens.

An upstream update is a reviewed dependency change, not a mechanical version
bump. It requires:

1. selecting and recording an exact upstream release and commit;
2. reviewing the upstream diff and license state;
3. selecting only the required stdio/server files;
4. recording source hashes and LocalOCR adaptations;
5. rerunning protocol compatibility and adversarial tests;
6. rebuilding all shipping artifacts;
7. verifying dependency, RPATH, symbol, and network-framework policy; and
8. completing independent review before candidate acceptance.

## Verification

### Protocol compatibility

Existing LocalOCRMCP Swift tests and Python subprocess contracts remain the
behavioral baseline. Additional tests cover:

- initialize and initialized lifecycle;
- exact nine-tool listing and schemas;
- successful and failing tool calls;
- ping;
- cancellation before and during work;
- malformed UTF-8 and JSON;
- unsupported methods;
- EOF and broken-pipe behavior;
- duplicate request IDs;
- message-size boundaries;
- concurrent requests and response correlation; and
- stdout purity.

### Supply-chain and source policy

Contracts verify:

- the exact upstream repository, release, and commit;
- every vendored source hash and adaptation record;
- bidirectional agreement between the manifest and filesystem;
- presence of the required license and provenance records;
- absence of the remote `mcp-swift-sdk` package dependency;
- absence of client, HTTP, OAuth, EventSource, URLSession, socket, CFNetwork,
  and Network source or dependency surfaces; and
- absence of unapproved files in the vendored target.

### Artifact and release readiness

From one clean exact commit:

- run the full Swift test suite;
- run the Xcode Studio test suite with an unlocked console and Developer Mode;
- build native helpers and the unsigned Studio app;
- run native smoke and full Python contract suites;
- confirm the app bundles both helpers and lists exactly nine MCP tools;
- inspect every shipping binary with `otool` and symbol/source policy checks;
- require no CFNetwork or Network framework linkage;
- require only approved Apple/system dependencies and RPATHs;
- record fresh hashes for exact-commit artifacts; and
- run the synthetic manual and live Foundation Models candidate matrix.

Task 13 remains not accepted until these gates pass. Distribution gates remain
separate and require later owner authorization.

## Success criteria

- `Package.swift` no longer depends on `mcp-swift-sdk`.
- LocalOCR builds against the local `MCPStdio` target.
- Existing clients observe no intended protocol or tool-contract change.
- The vendored source set is license-compliant, pinned, hashed, closed, and
  independently reviewable.
- Shipping helpers and the Studio executable contain no CFNetwork or Network
  dependency attributable to the removed SDK target.
- The complete exact-commit automated and manual candidate matrices pass.
- No release or external state change occurs without a separate authorization.
