# LocalOCR 0.3.2 build 9 — source and release acceptance

Date: 2026-11-11. Status: signed, notarized, stapled candidate built from
`c73d1a655d493861c501491d89f325e819e3094a`; downloaded-package verification and
OCR acceptance on the exact artifact passed. Not published, not tagged, not
merged, and not installed over build 8. Local-model provider acceptance was
not run for this build (see "Not run").

Marketing version `0.3.2`, build `9`, planned tag `v0.3.2-beta.1`.

## What changed since build 8 (`v0.3.1-beta.1`, source `9b4788c`)

- `d96c16b`, `abc3298`, `20bbd68`: llama.cpp structured-output token bounds,
  made after build 8 was published.
- `39c20d5`: recognized page text keeps table rows together
  (`TableRowTextAssembler`); real-document benchmark added.
- `702afbc`: release toolchain pinned to Xcode 27.2 (`27B52`) at
  `/Applications/Xcode.app`.
- `c73d1a6`: version, build, and documents for build 9.

## Source gates at `c73d1a6` (MacBook Pro, macOS 27.2 `26B123`, Xcode 27.2 `27B52`)

| Gate | Result |
| --- | --- |
| Swift suite | 939 tests passed |
| Python contract suite | 501 passed, 1 opt-in live-model skip, 0 failed (11m19s) |
| Native tools build (`build-native-tools.sh`) | exit 0 |
| MCP stdio source policy | PASS |

Running the Python gate on this Mac needs: a clone outside iCloud whose path
contains a space, the cache folder spelled exactly as on disk, `TMPDIR` from
`getconf DARWIN_USER_TEMP_DIR`, explicit `DEVELOPER_DIR`/`SDKROOT`, and
`./scripts/build-native-tools.sh` before `pytest`. Three earlier runs failed
only for those setup reasons; their logs are kept beside the passing one.

## Release build (MacBook Air M5, user `scott`, macOS 27.3, Xcode 27.2 `27B52`)

Clean detached checkout of `c73d1a6` from GitHub in
`~/LocalOCR Release 0.3.2-9/localocr`; numbered logs in `../logs`.

| Step | Result |
| --- | --- |
| Clone and exact-commit clean checkout | exit 0 |
| `build-native-tools.sh` | exit 0 |
| `smoke-native-tools.sh` | exit 0 |
| `build-unsigned-studio-app.sh` | exit 0 |
| `stage-direct-release.sh` | exit 0, status pass |
| `sign-direct-release.sh` | exit 0 — helpers first, app last, valid on disk, satisfies its Designated Requirement |
| `notarize-direct-release.sh` | exit 0 — Apple status **Accepted**, stapled, packaged |
| `test-downloaded-release.sh` on the final ZIP | exit 0 — valid on disk, staple validate worked, Gatekeeper accepted, source Notarized Developer ID |

Signing and notarization were started by Scott from his logged-in session on
the MacBook Air, because the login keychain is locked to SSH sessions
(`errSecInternalComponent`). No keychain workaround was used.

- Final artifact: `LocalOCR-Studio-0.3.2-9.zip`
- SHA-256: `43057873272df33856fbbbd76e1b3d0909b07b9e787ed57e1f3ad73af12c34ff`
- Notarization submission: `a5b2992a-77cc-4efc-87c9-456623919303` (Accepted)
- Signing authority: Developer ID Application: John Scott Ray (`DZ8B5454ZN`),
  Hardened Runtime.
- Downloaded-release evidence file on the MacBook Air:
  `dist/direct-release/final/localocr-downloaded-release-evidence-20261111T131410Z-63187.txt`

## Exact-artifact acceptance on the target Mac (MacBook Pro, macOS 27.2 `26B123`, arm64)

The ZIP was copied over the verified SSH link, its checksum checked, and
extracted to `/private/tmp` (not a synced folder).

| Check | Result |
| --- | --- |
| Checksum file matches ZIP | PASS |
| Bundle identity | `com.rayconsulting.localocr`, 0.3.2 (9) |
| App signature, strict and deep | PASS |
| Gatekeeper | PASS — Notarized Developer ID |
| Stapled ticket | PASS |
| Helpers `localocr`, `localocr-mcp`, `localocr-model-bridge` | present, signatures valid, arm64 only |
| CLI and MCP server version | 0.3.2; MCP lists nine tools |
| MCP `ocr_pdf`, forced OCR, two pages of a real COR package | no failed or empty pages; a scanned table page returned 49 text rows, 22 of them row-joined (build 8: 91 lines, none joined) |
| Full 222-page real COR package, default settings | exit 0; 208 pages native text, 14 pages Vision OCR, 0 failed, 0 empty |

Real-document benchmark with the signed CLI (112 pages, 16 documents, 300 DPI):

| Build | amount | word | row:text | row:rows |
| --- | --- | --- | --- | --- |
| 0.3.1 build 8 (published) | 83.3 | 98.2 | 8.0 | 94.5 |
| 0.3.2 build 9 (signed artifact) | 83.3 | 97.4 | 94.3 | 94.5 |

## Finding: label-word recognition varies between runs (all builds)

Word recall moved between runs on three dense pay-application pages while
their amounts and line geometry scores stayed identical. One page scored 100%
in two runs on 2026-11-10 and 36.3% in runs on 2026-11-11. Repeating the same
document minutes apart gave 88.5% with the unsigned build and 95.0% with the
published build 8, so the variation is not caused by build 9. On the low
runs every word in the returned lines is present in the page text; Apple
Vision itself returned fewer label words. Cause not yet known. Sampled pages
are mostly born-digital, so treat all scores as an upper bound for true scans.

## Corrections found after acceptance

- In the build 9 artifact, row-joined text applies to PDF pages
  (`localocr ocr`, `ocr_pdf`, `ocr_pdf_batch`, desktop PDF results). Picture
  input (`localocr image`, `ocr_image`, desktop image results) still returns
  one Vision line per text line. The build 9 documents say pictures are
  covered; that is true only from the next build.
- The run-to-run word variation above was traced to the PDF renderer on
  forced OCR of born-digital pages with non-embedded fonts, not to Vision and
  not to build 9. See `benchmarks/README.md`.
- Build 9 skips OCR on scanned pages that carry 20 or more characters of
  embedded text, such as a signing-envelope ID. Fixed after build 9.

## Not run

- Local-model provider acceptance (Apple Foundation Models, Gemma, GPT-OSS,
  Ollama, LM Studio), endurance, real idle, and AI Neural Gauge acceptance.
  Scott deferred local-model work on 2026-11-11. The three llama.cpp
  token-bound commits in this build therefore have automated coverage only.
- Desktop app launch and interactive UI walk-through on the signed build.
- Installation over build 8, a second-Mac install, publication, tag, merge.

## Open accuracy work

- Amount recall (83.3 overall; 91.6 on born-digital pages): split, missing,
  and misread amounts.
- Run-to-run variation in label-word recognition, above.
