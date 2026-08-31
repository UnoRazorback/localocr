# MCPStdio provenance

`MCPStdio` is a closed, repository-local source boundary for the LocalOCR
stdio-only MCP dependency migration.

## Upstream snapshot

- Repository: `https://github.com/modelcontextprotocol/swift-sdk`
- Release: `0.12.1`
- Commit: `a0ae212ebf6eab5f754c3129608bc5557637e605`
- Retrieved: `2026-08-27`
- Local module: `MCPStdio`

The pinned checkout is evidence for review only. It is not a package dependency
and must not be reintroduced as one.

## Selection rule

Only source necessary for LocalOCR's newline-delimited stdio server lifecycle,
JSON-RPC/MCP tool messages, ping, cancellation, and transport protocol may be
copied from the pinned `Sources/MCP` tree. Every Swift source in `MCPStdio` is
listed in `manifest.json`; unlisted source is rejected by contract tests.

This initial boundary intentionally contains only the local `MCPStdioBuild`
identity. Later reviewed tasks add each selected upstream source with its
origin, upstream SHA-256, local SHA-256, and an adaptation record when changed.
`origin-inventory.json` is the checked-in complete `Sources/MCP` Swift-source
inventory and SHA-256 record for this exact upstream snapshot. Contract tests
validate derived origins and upstream hashes against that inventory, so normal
CI does not need the upstream checkout.

## Exclusions

Do not vendor clients; HTTP, OAuth, EventSource, URLSession, socket, Network,
or CFNetwork transports; prompts; resources; sampling; completion; or logging
control. Shipping Swift also forbids renamed client implementations and
Foundation remote-loading/request surfaces, including `Data` or `String`
`contentsOf:` initializers, `URL.openConnection`, and legacy `NSURLConnection`
or `NSURLRequest` constructors. In particular, `HTTPClientTransport.swift` and
`NetworkTransport.swift` are forbidden source names.

## Dependencies

`swift-system` and `swift-log` are declared explicitly because the selected
stdio implementation is expected to need `SystemPackage` and `Logging`. Both
are provisional and remain subject to final artifact policy; no conclusion
about their shipping acceptability is made by this record.

## Hash procedure and update rule

Compute hashes with `shasum -a 256 <file>`. An upstream update is a reviewed
dependency change: select an exact release and commit, audit the diff and
license state, refresh every origin and hash, record compatibility and
adaptations, inspect dependencies, then complete independent review before a
candidate can be accepted.
