# Task 8 Report: Exact-Commit Candidate Acceptance and Records

Date: 2026-08-27 Central / 2026-08-28 UTC

## Status

Task 8 evidence capture is complete. The source candidate remains
`3b50ef3afb8ba7dd72505c2a37ae64a52d634763`. No source fix was needed during
the final-diff review.

The candidate is **NOT ACCEPTED** because the mandatory Studio UI runner could
not initialize while system authentication was active, no fresh exact-commit
Studio app was produced, the exact full Python matrix did not pass, and the
physical/manual and live Foundation Models gates were not run.

No merge, push, tag, signing, notarization, stapling, Gatekeeper assessment,
installation, publication, distribution, or campaign mutation was performed.

## Exact final-diff review

The complete `c2ff325...3b50ef3` diff contained 108 changed files, 19,853
insertions, and 572 deletions. Review covered:

- closed vendor inventory, provenance, license, and pinned package records;
- forbidden network/client imports, APIs, filenames, dependencies, and symbols;
- bounded 1 MiB framing and fail-closed overflow;
- request IDs, duplicate admission, cancellation generations, and response
  correlation;
- stdout purity and content-free logging;
- consent-before-file-access ordering and protocol/tool compatibility; and
- build, staging, RPATH, architecture, minimum-OS, and path policy.

The complete diff passed `git diff --check`. The canonical source validator
reported `MCP stdio source policy: PASS`. Forbidden-token search hits were
limited to reviewed manifest exclusions, the upstream origin inventory, and
provenance prose; none was shipping Swift code.

## Automated verification

### Swift package suite

```text
swift test
449 tests in 37 suites passed
```

The prior nondeterministic consent-store baseline failure did not recur.

### Studio scheme gate

The literal plan command named `LocalOCRStudio.xcodeproj`, but the tracked
project is `LocalOCR Studio.xcodeproj`. The corrected command was run:

```text
xcodebuild -project 'LocalOCR Studio.xcodeproj' \
  -scheme 'LocalOCR Studio' \
  -destination 'platform=macOS,arch=arm64' test
```

It reached UI testing and failed closed:

```text
Authentication canceled. System authentication is running.
```

No authentication, UI, or process state was changed.

### Native build and smoke

`./scripts/build-native-tools.sh` passed. It selected the stable Xcode default
Swift toolchain, used immutable package resolution, ran the canonical policy
before and after the build, and atomically published both helpers.

`./scripts/smoke-native-tools.sh` passed against the first fresh pair. The
smoke covered executable shape/dependencies, CLI and MCP behavior, real stdio
initialization, the exact nine-tool catalog, protocol stdout purity, synthetic
OCR fixtures, source immutability, and cleanup.

### Unsigned Studio build

`./scripts/build-unsigned-studio-app.sh` independently reproduced the same
authentication failure at the mandatory UI test. The builder preserved the
prior unsigned app. No stale app was treated as fresh candidate proof.

### Full Python matrix

The first `.venv/bin/python -m pytest -q` attempt stopped during collection
because the migrated worktree's editable `_editable_impl_ocr_service.pth`
concatenated the worktree path and `src` without a slash. This was an
environment defect, not a source change. The exact virtual environment was
repaired with a local wheel and no dependency resolution:

```text
uv pip install --python .venv/bin/python --reinstall --no-deps .
```

`ocr_service` then imported from that `.venv`. The rerun completed with:

```text
389 passed, 1 skipped, 4 failed, 83 errors in 489.93s
```

The fresh-app fixture reproduced the authentication blocker. Repeated Xcode
fixture work then exhausted the APFS data volume, and later failures/errors
cascaded as `No space left on device`. The result is recorded as a failed full
matrix; it was not rerun with a preserved-app reuse variable or reclassified as
passing.

## Artifact evidence

The full Python run rebuilt the native pair again before storage exhaustion.
The final read-only inspection recorded:

| Artifact | Size | Local mtime | SHA-256 |
|---|---:|---|---|
| `dist/native-tools/localocr` | 2,764,264 | 2026-08-27T21:14:24-0500 | `8a3663490c6ae96bed477a0ff2761a6e2ebcf7682f27ef64bc7b155eb35b5a5c` |
| `dist/native-tools/localocr-mcp` | 2,815,640 | 2026-08-27T21:14:29-0500 | `e24b3588d71e8f7bbda14a4e4e1952c6949cfa0c56832790fa9501f29d78c398` |

Both are arm64 Mach-O executables with exactly one platform-1 macOS
`LC_BUILD_VERSION`, minimum OS 14.0, and only `/usr/lib/swift` as RPATH. All
install names are approved `/System/Library` or `/usr/lib` paths. No CFNetwork,
Network, `_nw_*`, URL-session, private-user, Xcode, Homebrew, DerivedData,
`.build`, `.worktrees`, or `.venv` path hit was found.

The preserved Studio executable predates the candidate:

```text
SHA-256 142787b539c67d1bf397f053c034cfb9a45a713b7c89c24fe26d7dd933757740
mtime    2026-08-27T06:35:46-0500
```

It has no bundled CLI or MCP helper and is rejected as candidate evidence. No
fresh Studio or bundled-helper hash exists for Task 8.

## Synthetic versus physical evidence

The 449-test Swift run and native smoke provide deterministic automated
evidence for intelligence-unavailable behavior, summarize/organize/extract
with test providers, grounding, Process Another state reset, batch OCR-only
behavior, help/agent guidance, consent state and ordering, all nine MCP tools,
cancellation/correlation, and source immutability.

They do not establish live Foundation Models availability, model quality,
physical Studio interaction, physical consent acceptance/revocation, manual
agent-client cancellation, or live runtime network observation. Those gates
remain NOT RUN. No personal document was used.

## Storage incident and retained generated data

At the full-suite failure, `/` had 78 MiB available. Xcode/Swift clean
operations, unlink, truncate, and even a one-line evidence write all failed
with `ENOSPC`.

Before owner authorization, cleanup attempts were scoped to this worktree's
ignored `.build` and the named LocalOCR Studio DerivedData tree. APFS rejected
the attempted operations. After space recovery, the following were confirmed
retained:

- `.build`: 326 MiB;
- `/Users/scott/Library/Developer/Xcode/DerivedData/LocalOCR_Studio-cbxikxegkezrqyazhwkhykllrzkg`:
  564 MiB;
- the two Task 8 UI failure payloads in
  `Test-LocalOCR Studio-2026.08.27_21-04-47--0500.xcresult`: 46,253,226 and
  46,789,131 bytes; and
- the preserved unsigned app and fresh native artifacts listed above.

No Task 8 file deletion was confirmed. The owner then authorized snapshot
thinning. The parent workflow ran:

```text
tmutil thinlocalsnapshots / 15000000000 4
```

It reported that two local snapshots were removed and recovered 14 GiB. No
source or user file was removed. The exact snapshot names were not included in
the delegated evidence, so none is invented here.

## Business-record result

The candidate milestone is recorded from dated repository, test, and artifact
evidence only. Hours, Direct Cost, and Shared Cost Allocation remain blank
because no dated owner-hour, receipt, or allocation amount was supplied. Beta
metrics and feedback logs were not changed because no beta was published and
no new feedback was received.

## Open gates

- corrected Studio scheme test from an eligible interactive console;
- fresh exact-commit unsigned Studio app and bundled-helper inspection;
- complete exact-commit Python matrix without preserved-app reuse;
- physical synthetic-document and consent matrix;
- live Foundation Models availability/quality and runtime network observation;
- final candidate acceptance;
- merge authorization;
- Developer ID signing, notarization, stapling, and Gatekeeper;
- downloaded-package and second-Mac acceptance;
- installation, tag, publication, distribution, and campaign authorization.

## Final lightweight validation

After evidence edits, the CSV validator confirmed 23 rows and verified that the
final row's Hours, Direct Cost, and Shared Cost Allocation fields are blank.
Focused consent/intelligence and tester-documentation contracts passed:

```text
16 passed, 5 existing SWIG deprecation warnings in 0.02s
```
