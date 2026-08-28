# Local Intelligence and Stdio-Only MCP Candidate Acceptance

## Decision

**AUTOMATED SOURCE/BUILD ACCEPTANCE PASSED — physical, live-model, signing,
and distribution gates remain open.**

The post-review candidate passed its full exact-source Swift suite, isolated
Studio UI suite, fresh native and unsigned-app builds, release-artifact policy,
native MCP/CLI smoke, and complete Python matrix. The earlier blocked candidate
at `3b50ef3` remains historical failed evidence and is superseded for automated
source/build acceptance by `e5b7f87`.

This decision does not claim physical/manual Studio acceptance, live Apple
Foundation Models quality, runtime network observation, merge, Developer ID
signing, notarization, stapling, Gatekeeper acceptance, packaging,
downloaded-package testing, second-Mac acceptance, installation, publication,
tagging, or campaign changes.

## Candidate identity

- Source candidate commit: `e5b7f8722823bb4c14bd51160909b360b99d70c8`
- Branch: `feature/local-intelligence-mcp-faq`
- Baseline merge commit: `c2ff3259e190ef5adf037c091a04b34830014131`
- Evidence date: 2026-08-28 Central
- Candidate diff: 107 files, 19,961 insertions, 582 deletions
- Working tree before the evidence edit: clean
- Evidence commit: recorded separately after this file is committed

The acceptance lineage includes final-review fix `76a3440`, temporary-report
cleanup `370a376`, removal of private machine paths from Studio examples at
`dba2a26`, and the timing-safe MCP smoke harness at `e5b7f87`. The last change
is acceptance tooling; it keeps MCP stdin open until the expected response IDs
arrive or a bounded timeout expires.

## Test environment

- Mac: MacBook Air (`Mac17,3`), Apple M5, 24 GB RAM
- Host OS: macOS 27.0, build `26A5421a`
- Xcode: stable `/Applications/Xcode.app`, Xcode 26.6 (`17F113`)
- Deployment target: macOS 14.0, arm64

The macOS 27 run is development evidence, not a promise of support for every
unpublished macOS beta. Live Foundation Models acceptance still requires an
eligible Mac with Apple Intelligence enabled and its on-device model ready.

## Final review and fixes

The whole-branch review found five Important issues and no Critical issues.
They were fixed at `76a3440`: bounded production input buffering,
nonrecursive generic structured-result construction, complete package source
root freezing, whitespace-safe Mach-O path parsing, and literal preservation
of OCR strings resembling data URLs. Focused verification passed 208 tests,
followed by 14 of 14 focused retries. The scoped final re-review found no
remaining or new Critical or Important issue.

The fresh unsigned-app policy then found three hard-coded `/Users/Shared/...`
instruction examples in the Release executable. Commit `dba2a26` replaced
them with neutral `/path/to/...` examples; its focused seven-test suite passed,
and the rebuilt stripped executable contained no `/Users/` marker.

The first post-fix combined smoke run captured no MCP stdout because its fixed
one-second stdin window closed before the server responded under post-Xcode
load. Direct byte capture showed the server emitted only valid newline-delimited
JSON with empty stderr when stdin remained open. A regression test failed first
against the missing timing-safe exchange driver, then passed after `e5b7f87`
added bounded response-ID waiting. The integrated smoke and full matrix passed.

## Exact-source automated matrix

| Gate | Result | Fresh evidence |
|---|---|---|
| Source diff hygiene | PASS | `git diff --check` returned no output. |
| Canonical MCP source policy | PASS | `scripts/validate-mcp-stdio-policy.py` passed before and after native builds. |
| Full Swift package suite | PASS | 452 tests in 37 suites; zero failures. |
| Isolated Studio UI suite | PASS | 20 tests; zero failures; `TEST SUCCEEDED`. |
| Fresh native build | PASS | Both arm64 helpers built with stable Xcode and were atomically published. |
| Fresh unsigned Studio build | PASS | Release build succeeded and published a new unsigned app. |
| Artifact policy | PASS | Mach-O shape, Apple/system dependencies, safe RPATHs, and private/runtime-string restrictions passed. |
| Native smoke | PASS | Real CLI/MCP initialization, exact nine-tool listing, consent blocking/current receipt, OCR fixtures, stdout purity, source immutability, and cleanup passed. |
| MCP delayed-response regression | PASS | The driver kept stdin open beyond 1.2 seconds and returned the exact JSON response with empty stderr. |
| Full Python matrix | PASS | 469 passed, 1 skipped, zero failures in 910.27 seconds. |
| Final repository state | PASS | Candidate source tree was clean before this evidence edit. |

The Python warnings were five existing SWIG/PyMuPDF deprecation warnings; they
did not fail the suite. Xcode repeatedly reported a debugger-version-store
warning for a connected passcode-protected Apple device, but all Mac UI tests
completed successfully.

## Fresh artifact evidence

| Artifact | Size | Local mtime | SHA-256 |
|---|---:|---|---|
| `dist/native-tools/localocr` | 2,764,264 bytes | 2026-08-28 09:12:04 -0500 | `b4e5ab9e9665830b11bab80b1540c9e2052c76c16312392d73466efb6e57abb9` |
| `dist/native-tools/localocr-mcp` | 2,854,088 bytes | 2026-08-28 09:12:07 -0500 | `2ee7e8110728506cd3d85a2f0b0a7d00d221247e5df347b2da1cd8a229f898be` |
| `dist/unsigned-app/LocalOCR Studio.app/Contents/MacOS/LocalOCR Studio` | 3,223,640 bytes | 2026-08-28 09:05:41 -0500 | `501af4b1fece0140fe5d453d6d3782b17b71d14f68b7642cf2b73b17ffb6af1b` |

All three are arm64 Mach-O executables and contain no `/Users/` marker. The
native helper policy accepted only Apple/system install names and safe system
Swift RPATHs; the MCP helper has no shipping CFNetwork or Network dependency.
Foundation Models remains a weak Apple system-framework dependency. Vision OCR
remains authoritative, and intelligence output remains separately labeled.

The unsigned app intentionally contains only its GUI executable. Release
staging, which has not been authorized or run for this candidate, is the step
that copies `localocr` and `localocr-mcp` into `Contents/Helpers` before nested
signing.

## Automated versus physical evidence

| Gate | Result | Boundary |
|---|---|---|
| Intelligence unavailable states | AUTOMATED PASS | Swift service, CLI/MCP mapping, and Studio UI fixture coverage. |
| Summarize, organize, extract | AUTOMATED PASS WITH TEST PROVIDERS | Structured provider, grounding, Studio, CLI, and MCP tests; not live-model quality. |
| Process Another clears temporary intelligence | AUTOMATED UI PASS | Isolated UI test returned to the drop screen and removed prior results. |
| Batch remains OCR-only | AUTOMATED UI PASS | Batch screens exposed no Local Intelligence actions. |
| Agent setup and acknowledgment UI | AUTOMATED UI PASS | Help window reuse and both acknowledgment controls passed. |
| Exact nine MCP tools | NATIVE PASS | Real stdio helper returned exactly nine tools. |
| Raw source immutability | AUTOMATED/NATIVE PASS | Contract and native smoke hash checks passed. |
| Runtime LocalOCR network observation | NOT RUN | Static source, symbol, dependency, and policy evidence passed; live observation remains open. |
| Live Foundation Models availability/quality | NOT RUN | No claim is inferred from test providers or synthetic UI fixtures. |
| Physical/manual Studio matrix | NOT RUN | Requires owner interaction with synthetic documents. |

No personal document was used for this acceptance run.

## Release and distribution gates

| Gate | Result |
|---|---|
| Implementation and final scoped review | COMPLETE |
| Automated exact-source/build acceptance | PASS |
| Physical/manual candidate acceptance | NOT RUN |
| Live Foundation Models acceptance | NOT RUN |
| Runtime network observation | NOT RUN |
| Merge | NOT PERFORMED |
| Developer ID signing | NOT RUN |
| Notarization, stapling, Gatekeeper | NOT RUN |
| Downloaded-package and second-Mac acceptance | NOT RUN |
| Installation, tag, push, publication, campaign mutation | NOT PERFORMED |

## Remaining acceptance work

1. Run the physical synthetic-document Studio matrix, including consent,
   Process Another, batch isolation, and failure recovery.
2. Run live Foundation Models availability and grounded-quality checks on an
   eligible Mac without treating generated output as authoritative OCR.
3. Observe the running app and MCP helper for unexpected network activity.
4. Obtain separate owner authorization before merge or any signing,
   notarization, installation, publication, or campaign step.
