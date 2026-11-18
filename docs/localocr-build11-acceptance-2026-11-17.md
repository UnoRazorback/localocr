# LocalOCR 0.3.2 build 11 — source and release acceptance

Date: 2026-11-17 (US Central; 2026-11-18 UTC). Status: signed, notarized,
stapled build from `ccfcfe582a78aa9d874176d73c026ff064710012`; downloaded-package
verification and OCR acceptance on the exact artifact passed; published as the
prerelease `v0.3.2-beta.2` and installed on the MacBook Pro. Local-model
provider acceptance was not run (see "Not run").

Marketing version `0.3.2`, build `11`, tag `v0.3.2-beta.2`.

## What changed since build 10 (source `6c3ae13`, published as `v0.3.2-beta.1`)

- `a9da4fa`, `69a9cc3`, `a0f195d`: opt-in amount check (`verify_amounts`,
  `--verify-amounts`); the native/Python parity check accepts it as a
  native-only option; survey of true scans.
- `77322b8`: garbled amounts finished from a second look at the line; Vision
  stall guard; cache version `ocr-processor-v4`; references re-measured.
- `0544c15`, `b24b943`, `deeadf0`, `dd4f721`: tool descriptions and documents.
- `5504326`, `f90eb1a`, `847d202`: benchmark tools and findings; smoke-script
  pipefail fix.
- `ccfcfe5`: build number and release notes for build 11.

## Source gates (MacBook Pro, Xcode 27.2 `27B52`)

| Gate | Result |
| --- | --- |
| Swift suite at `77322b8` | 973 tests passed |
| Python contract suite at `77322b8` | 506 passed, 1 opt-in live-model skip, 0 failed |
| Swift suite at `ccfcfe5` | 973 tests passed |
| Python contract suite at `ccfcfe5` | 506 passed, 1 opt-in live-model skip, 0 failed |
| MCP stdio source policy | PASS (source inventory re-attested for the new files) |

## Release build (MacBook Air M5, user `scott`, Xcode 27.2 `27B52`)

Clean detached checkout of `ccfcfe5` from GitHub in
`~/LocalOCR Release 0.3.2-11/localocr`; numbered logs in `../logs`.

| Step | Result |
| --- | --- |
| Clone and exact-commit clean checkout | exit 0 |
| `build-native-tools.sh` | exit 0 |
| `smoke-native-tools.sh` | exit 0 |
| `build-unsigned-studio-app.sh` | exit 0 |
| `stage-direct-release.sh` | exit 0 |
| `sign-direct-release.sh` | exit 0 (three runs, see below) |
| `notarize-direct-release.sh` | attempts 1 and 2 exit 1, attempt 3 exit 0 |
| `test-downloaded-release.sh` | exit 0, `source=Notarized Developer ID` |

Notarization attempt 1 was refused by Apple with HTTP 403, "A required
agreement is missing or has expired"; the owner accepted the pending
developer agreement. Attempt 2 stopped before submitting because attempt 1
had left `dist/direct-release/evidence` behind. The staged output of both
attempts was moved aside (`direct-release-attempt1`, `attempt2`), the unsigned
app was staged again, and attempt 3 signed and notarized that fresh stage.
Signing ran in the owner's logged-in session on the Air, started over SSH
with his approval.

- Notarization submission `585f8b40-80d3-4a8e-bc63-2753da6f8e0b`: Accepted.
- `LocalOCR-Studio-0.3.2-11.zip` SHA-256
  `d49128b2e5ea566d379735dfff0270c91e615de5bb42f12a54e16c392c4b10a1`.

## Acceptance of the exact artifact (MacBook Pro, macOS 27.2.1 `26B131`)

App extracted from the ZIP into `/private/tmp`; log in the project's
`releases/0.3.2-11/acceptance.log`.

| Check | Result |
| --- | --- |
| Checksum file matches ZIP | PASS |
| Version `0.3.2` build `11`, bundle `com.rayconsulting.localocr` | PASS |
| App signature strict/deep, Hardened Runtime, team `DZ8B5454ZN` | PASS |
| Gatekeeper accepts (Notarized Developer ID) | PASS |
| Stapled ticket validates | PASS |
| Helpers `localocr`, `localocr-mcp`, `localocr-model-bridge` signed, arm64 | PASS |
| MCP server from the signed helper: 9 tools, OCR of two scanned pages | no error, no failed or empty pages |
| 222-page package, default settings | exit 0; 208 pages existing text, 14 recognized; none failed or empty |
| Amount check on two scanned pages | exit 0; `amount_check` present, 0 marked, no unchecked pages |
| Real-document benchmark with the signed CLI (112 pages) | amount 95.1, word 98.3, row:all 86.8 |

## Publication and installation

- Published 2026-11-18T01:30:20Z as prerelease `v0.3.2-beta.2`, tag at
  `ccfcfe5`; GitHub reports the ZIP digest
  `sha256:d49128b2e5ea566d379735dfff0270c91e615de5bb42f12a54e16c392c4b10a1`.
- Installed to `~/Applications/LocalOCR Studio.app` on the MacBook Pro;
  signature, Gatekeeper and stapler checks passed on the installed copy.
  Build 10 kept beside it as `LocalOCR Studio.build10-backup-20261117.app`.

## Measurements carried by this build

- 112 benchmark pages at 300 DPI: amount 91.9 to 95.1, word 97.5 to 98.3,
  row:all 84.5 to 86.8; garbled amounts 134 to 6; clean-but-wrong amounts 10
  before and after.
- 80 scanned PDFs (291 pages): garbled amounts 183 to 18; no failed pages.
- Vision stall: installed build 10 froze on 4 of 25 reads of one scanned
  file; the guarded build finished 60 of 60. No live freeze occurred during
  the guarded run, so the guard's rescue is covered by unit tests only.

## Provider and Gauge acceptance after publication

Apple Foundation Models, llama.cpp (Gemma 4 26B Q4_0) and AI Neural Gauge
were accepted on the installed build after publication; LM Studio and Ollama
were not run. See
[the provider acceptance record](localocr-build11-provider-acceptance-2026-11-17.md).

## Not run at release time

Local-model provider acceptance (Apple Foundation Models, Ollama, LM Studio,
llama.cpp), endurance, real idle, AI Neural Gauge, and the controlled macOS 27
GR target run.
