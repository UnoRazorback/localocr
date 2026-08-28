# Local Intelligence and Stdio-Only MCP Candidate Acceptance

## Decision

**NOT ACCEPTED — the fresh Studio UI/build gate, complete Python matrix, and
physical/manual acceptance gates remain open.**

The stdio-only MCP implementation passed its exact-commit Swift suite, fresh
native build, native smoke, source policy, and read-only native binary
inspection. The mandatory Studio UI runner failed closed because macOS reported
`System authentication is running` and `Authentication canceled`. The unsigned
builder reproduced that result and preserved the prior app. The full Python
suite then exhausted the remaining disk space while repeatedly exercising the
blocked fresh-app fixture; its final result is recorded as failed, not weakened
or reclassified.

This document is implementation evidence only. It does not authorize or claim
merge, signing, notarization, stapling, Gatekeeper acceptance, packaging,
downloaded-package testing, second-Mac acceptance, installation, publication,
tagging, or campaign changes.

## Candidate identity

- Source candidate commit: `3b50ef3afb8ba7dd72505c2a37ae64a52d634763`
- Branch: `feature/local-intelligence-mcp-faq`
- Baseline merge commit: `c2ff3259e190ef5adf037c091a04b34830014131`
- Evidence date: 2026-08-27 Central / 2026-08-28 UTC
- Working tree at the start of review and verification: clean
- Evidence commit: recorded separately after this file is committed

No source fix was made during Task 8, so all automated and artifact results
below refer to the same source commit. The later documentation commit is not a
replacement candidate identity.

## Test environment

- Mac: MacBook Air (`Mac17,3`), Apple M5, 24 GB RAM
- Host OS: macOS 27.0, build `26A5421a`
- Developer Mode: enabled
- Xcode: stable `/Applications/Xcode.app`, Xcode 26.6 (`17F113`)
- Required deployment target: macOS 14.0, arm64

The macOS 27 host run is development evidence, not a claim that an unpublished
macOS beta is supported for end users. Live Foundation Models acceptance still
requires an eligible Mac with Apple Intelligence and the on-device model
available.

## Exact final-diff review

The review covered the complete diff from `c2ff325` through `3b50ef3`: 108
files, 19,853 insertions, and 572 deletions. It inspected the closed vendor
manifest and provenance, transport bounds, server lifecycle and request IDs,
stdout/logging behavior, consent ordering, protocol compatibility, licensing,
build scripts, and binary policy.

```text
git diff "$(git merge-base HEAD c2ff3259e190ef5adf037c091a04b34830014131)"...HEAD --check
Result: PASS

.venv/bin/python scripts/validate-mcp-stdio-policy.py --repo-root .
Result: MCP stdio source policy: PASS
```

The forbidden-token search found only the manifest exclusion list, the pinned
upstream origin inventory, and explanatory provenance text. No shipping Swift
file, shipping target, or source filename contained an HTTP, client, OAuth,
EventSource, URLSession, socket, CFNetwork, or Network transport surface.
MCPStdio logs content-free lifecycle and byte-count metadata only; no payload,
document text, filename, path, prompt, or model output is logged.

## Exact-commit automated matrix

| Gate | Result | Evidence |
|---|---|---|
| Clean start | PASS | `git status --short` produced no output at `3b50ef3`. |
| Full Swift package suite | PASS | `swift test`: 449 tests in 37 suites passed. The prior consent-store baseline flake did not recur. |
| Studio scheme test | BLOCKED / FAIL-CLOSED | The plan command omitted the space in the tracked project filename and failed before testing. The corrected command, `xcodebuild -project 'LocalOCR Studio.xcodeproj' -scheme 'LocalOCR Studio' -destination 'platform=macOS,arch=arm64' test`, reached UI testing and failed because macOS authentication was already running. |
| Fresh native build | PASS | `./scripts/build-native-tools.sh` passed the canonical source policy before and after the stable-Xcode Swift builds and atomically published both helpers. |
| Fresh unsigned Studio build | BLOCKED / FAIL-CLOSED | `./scripts/build-unsigned-studio-app.sh` independently reached the UI runner and received the same authentication failure. The prior unsigned app was preserved and is not fresh evidence. |
| Native smoke | PASS | `./scripts/smoke-native-tools.sh` passed against the first fresh native pair before the full Python run. It verified executable shape, dependencies, stdio initialization, exact nine-tool listing, protocol stdout purity, native OCR fixtures, source immutability, and cleanup. |
| Full Python suite, first attempt | ENVIRONMENT SETUP FAILURE | Collection stopped because the migrated virtual environment had a malformed editable `.pth` path. The repository was reinstalled as a local wheel into the same `.venv` with `uv pip install --python .venv/bin/python --reinstall --no-deps .`; import then resolved from that environment. No source or dependency version changed. |
| Full Python suite after environment repair | FAIL | Exact command result: 389 passed, 1 skipped, 4 failed, 83 errors in 489.93 seconds. The fresh-app fixture reproduced the authentication blocker; repeated Xcode fixture work then filled the APFS data volume, and later failures/errors were `ENOSPC` cascades. This is not a passing complete matrix. |
| Source diff check | PASS before evidence edit | The complete source-candidate diff passed `git diff --check`. The evidence commit is checked separately. |

At the storage failure, `/` reported only 78 MiB available. Normal Xcode and
Swift clean operations could not start, and APFS could not unlink or truncate
the exact Task 8 build outputs. With explicit owner authorization, the parent
workflow later ran `tmutil thinlocalsnapshots / 15000000000 4`; two local
snapshots were removed and 14 GiB became available. No source or user file was
removed. The expensive matrix was not rerun merely to overwrite the honest
failed result.

## Fresh native artifact evidence

The full Python run rebuilt the native pair again before storage exhaustion.
The following current files are exact-source-commit artifacts. They were
inspected read-only after the failed Python run.

| Artifact | Size | Local mtime | SHA-256 |
|---|---:|---|---|
| `dist/native-tools/localocr` | 2,764,264 bytes | 2026-08-27 21:14:24 -0500 | `8a3663490c6ae96bed477a0ff2761a6e2ebcf7682f27ef64bc7b155eb35b5a5c` |
| `dist/native-tools/localocr-mcp` | 2,815,640 bytes | 2026-08-27 21:14:29 -0500 | `e24b3588d71e8f7bbda14a4e4e1952c6949cfa0c56832790fa9501f29d78c398` |

Both helpers are arm64 Mach-O executables with exactly one macOS
`LC_BUILD_VERSION`, platform `1`, minimum OS `14.0`, and only
`/usr/lib/swift` as `LC_RPATH`. Every install name shown by `otool -L` is under
`/System/Library` or `/usr/lib`. `localocr-mcp` no longer links CFNetwork or
Network and has no `_nw_*`, `NSURLSession`, `NSURLConnection`, CFNetwork, or
Network symbol hit. Neither helper contains an Xcode, user-home, Homebrew,
`/usr/local`, DerivedData, `.build`, `.worktrees`, or `.venv` path hit.

Foundation Models is a weak Apple system-framework dependency in both helpers;
Vision OCR remains authoritative, and intelligence results remain separately
labeled local output.

## Rejected preserved Studio artifact

The builder preserved this prior app after the mandatory UI gate failed:

| Artifact | Local mtime | SHA-256 | Acceptance use |
|---|---|---|---|
| `dist/unsigned-app/LocalOCR Studio.app/Contents/MacOS/LocalOCR Studio` | 2026-08-27 06:35:46 -0500 | `142787b539c67d1bf397f053c034cfb9a45a713b7c89c24fe26d7dd933757740` | REJECTED as stale candidate evidence |

That preserved app predates `3b50ef3` and contains no bundled `localocr` or
`localocr-mcp` helpers. No Studio or bundled-helper hash is claimed for the
candidate. Contract tests may inspect a preserved app only when explicitly
labeled reused; this task did not use it as fresh acceptance proof.

## Synthetic and manual candidate matrix

The results below distinguish deterministic automated evidence from physical
interaction and live-model evidence.

| Gate | Result | Evidence boundary |
|---|---|---|
| OCR behavior when intelligence is unavailable | AUTOMATED PASS | Swift service, unavailable-provider, CLI/MCP mapping, and Studio view-model contracts passed inside the 449-test run. No physical app interaction was performed. |
| Summarize, organize, and extract | AUTOMATED PASS WITH TEST PROVIDERS | Foundation Models provider contracts, grounding, Studio view-model, CLI, and MCP dispatcher tests passed. This is not a live on-device model accuracy result. |
| Evidence grounding | AUTOMATED PASS | Grounding validator and provider contract suites passed with synthetic fixtures. |
| Process Another clears results/intelligence state | AUTOMATED PASS | Studio lifecycle and intelligence view-model contracts passed. UI interaction remains blocked. |
| Batch remains OCR-only | AUTOMATED PASS | Batch view/coordinator contracts and Studio lifecycle tests passed. UI interaction remains blocked. |
| Help and agent-connection guidance | AUTOMATED PASS | Agent guide model and CLI help contracts passed in Swift. Python documentation contracts were partly exercised, but the complete Python matrix failed overall. |
| Consent in Studio, CLI, and MCP | AUTOMATED PASS | Consent-store, CLI, MCP dispatcher/runner, and Studio model contracts passed in Swift. No physical accept/revoke interaction was performed. |
| Exact nine MCP tools | AUTOMATED PASS | Native smoke initialized the real stdio helper and observed the exact catalog. |
| Cancellation and request correlation | AUTOMATED PASS | MCPStdio transport/server and LocalOCRMCP runner/dispatcher suites passed in Swift; no agent-client manual cancellation was performed. |
| Raw source immutability | AUTOMATED PASS | Searchable-PDF/service contracts and native smoke hash checks passed with project fixtures. |
| No runtime LocalOCR network connection | NOT RUN | Source, symbol, dependency, entitlement, and path inspection passed, but no live runtime connection observation was completed. |
| Live Foundation Models availability/quality | NOT RUN | No eligible live-model acceptance was inferred from test providers. |
| Physical/manual Studio matrix | NOT RUN | The UI test runner could not initialize while system authentication was active. |

No personal document was used for this acceptance attempt.

## Release and distribution gates

| Gate | Result |
|---|---|
| Implementation at source candidate | COMPLETE, independently reviewed before Task 8 |
| Exact automated candidate acceptance | NOT COMPLETE |
| Physical/manual candidate acceptance | NOT RUN |
| Developer ID signing | NOT RUN |
| Notarization and stapling | NOT RUN |
| Gatekeeper assessment | NOT RUN |
| Downloaded-package verification | NOT RUN |
| Second-Mac acceptance | NOT RUN |
| Installation | NOT RUN |
| Merge, tag, push, publication, distribution, campaign mutation | NOT PERFORMED |

## Remaining acceptance work

1. Complete the macOS system-authentication condition through normal owner/UI
   interaction, without bypassing or manipulating it.
2. From one clean exact source commit, rerun the corrected Studio scheme test,
   unsigned Studio builder, native build/smoke, and full Python suite without
   the reuse variable.
3. Hash and inspect the fresh Studio executable and both bundled helpers.
4. Complete the physical synthetic-document matrix, live Foundation Models
   availability/quality checks, and runtime network observation.
5. Obtain separate owner authorization before any merge or distribution step.
