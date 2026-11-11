# LocalOCR 0.3.2 build 10 — source and release acceptance

Date: 2026-11-11. Status: signed, notarized, stapled candidate built from
`6c3ae1390889aba3847a38eb3882dd1a6e1821ad`; downloaded-package verification and
OCR acceptance on the exact artifact passed. Not published, not tagged, not
merged. Local-model provider acceptance was not run (see "Not run").

Marketing version `0.3.2`, build `10`, planned tag `v0.3.2-beta.1`.

## What changed since build 9 (source `c73d1a6`, signed and accepted, not published)

- `d36d0d6`: scanned pages that carry a little embedded text are read;
  thousands commas misread as periods are restored; picture input gets
  row-joined text; benchmark tools and findings.
- `6c3ae13`: build number and documents for build 10.

Build 9's record is `localocr-build9-acceptance-2026-11-11.md`.

## Source gates (MacBook Pro, macOS 27.2 `26B123`, Xcode 27.2 `27B52`)

| Gate | Result |
| --- | --- |
| Swift suite at `6c3ae13` | 945 tests passed |
| Python contract suite at `d36d0d6` | 501 passed, 1 opt-in live-model skip, 0 failed |
| Python contract suite at `6c3ae13` | 501 passed, 1 opt-in live-model skip, 0 failed |
| Native tools build | exit 0 |
| MCP stdio source policy | PASS (source inventory re-attested for two new files) |

## Release build (MacBook Air M5, user `scott`, macOS 27.3, Xcode 27.2 `27B52`)

Clean detached checkout of `6c3ae13` from GitHub in
`~/LocalOCR Release 0.3.2-10/localocr`; numbered logs in `../logs`, first
attempt in `../logs-attempt1`.

| Step | Result |
| --- | --- |
| Clone and exact-commit clean checkout | exit 0 |
| `build-native-tools.sh` | exit 0 |
| `smoke-native-tools.sh` | attempt 1 exit 1, attempt 2 exit 0 (see below) |
| `build-unsigned-studio-app.sh` | exit 0 |
| `stage-direct-release.sh` | exit 0 |
| `sign-direct-release.sh` | exit 0 — satisfies its Designated Requirement |
| `notarize-direct-release.sh` | exit 0 — Apple status **Accepted**, stapled, packaged |
| `test-downloaded-release.sh` on the final ZIP | exit 0 — Gatekeeper accepted, source Notarized Developer ID |

Signing and notarization ran in Scott's logged-in session on the MacBook Air.
At his instruction the script was started remotely with `open`, which runs it
in a visible Terminal window in that session; the login keychain stays locked
to SSH itself.

**Known flaky check.** The first smoke attempt failed with
`printf: write error: Broken pipe` followed by "native MCP server did not
complete initialization". The script pipes a response into `grep -q` under
`pipefail`; when `grep` exits on its first match the writer can be killed and
the pipeline reports failure although the server answered correctly. The
unchanged script passed on the next run. To be fixed in the script.

- Final artifact: `LocalOCR-Studio-0.3.2-10.zip`
- SHA-256: `3db38fb48c72776fb2d5bc4881aebc58b6f1fd41c8c685fc126191a0a01dc7ad`
- Notarization submission: `7f6997c7-c962-4d15-b3d4-abb89df3aee6` (Accepted)
- Signing authority: Developer ID Application: John Scott Ray (`DZ8B5454ZN`),
  Hardened Runtime.
- Downloaded-release evidence file on the MacBook Air:
  `dist/direct-release/final/localocr-downloaded-release-evidence-20261111T143138Z-15748.txt`

## Exact-artifact acceptance on the target Mac (MacBook Pro, macOS 27.2 `26B123`, arm64)

ZIP copied over the verified SSH link, checksum checked, extracted to
`/private/tmp`.

| Check | Result |
| --- | --- |
| Checksum file matches ZIP | PASS |
| Bundle identity | `com.rayconsulting.localocr`, 0.3.2 (10) |
| App signature, strict and deep | PASS |
| Gatekeeper | PASS — Notarized Developer ID |
| Stapled ticket | PASS |
| Helpers `localocr`, `localocr-mcp`, `localocr-model-bridge` | present, signatures valid, arm64 only |
| CLI and MCP server version | 0.3.2; MCP lists nine tools |
| MCP `ocr_pdf`, forced OCR, two pages of a real COR package | no failed or empty pages; scanned table page 49 text rows, 22 row-joined |
| Full 222-page real COR package, default settings | exit 0; 208 pages native text, 14 pages Vision OCR, 0 failed, 0 empty |

Real-document benchmark with the signed CLI (112 pages, 16 documents, 300 DPI):

| Build | amount | word | row:text |
| --- | --- | --- | --- |
| 0.3.1 build 8 (published) | 83.3 | 98.2 | 8.0 |
| 0.3.2 build 9 (signed) | 83.3 | 97.4 | 94.3 |
| 0.3.2 build 10 (signed) | 91.9 | 98.2 | 90.5 |

`row:text` counts only amounts that were found; build 10 finds 304 more, which
changes that population. Counting every label and amount pair in the truth,
found or not, the share that is both found and on the right row is 81.5 for
build 9 and 84.5 for build 10.

Scanned pages that carry a little embedded text (20 such pages among 318
full-page scans in 22 files), default settings:

| Build | Result |
| --- | --- |
| 0.3.2 build 9 | 16 of the 20 returned only their embedded text, 0 to 5 words each, including the certified cover pages of two pay applications |
| 0.3.2 build 10 | 19 of 20 read by OCR in the scan, 47 to 379 words each; the remaining page was read by OCR in every rerun (see the finding below) |

## Finding: one transient low read during acceptance

In the first scan of those pages with the signed build 10, one certified cover
page was returned as its 5 embedded words. Run directly at that moment, build
10 recognized 75 characters on the page; an unsigned build of the same source
recognized 2,250 seconds later. After the Mac had been offline and
reconnected, build 9, build 10, the unsigned build, and a freshly re-signed
copy all recognized 2,701 characters on that page in every one of several
alternating runs, and build 10's default path used OCR each time. The low read
therefore followed the state of the Mac at that moment, not the build. Its
cause is not known. Because the sparse-text check keeps embedded text when
recognition returns little, a transient low read shows up as a short page
rather than an error. Treat an unexpectedly short page as a reason to rerun.

## Not run

- Local-model provider acceptance, endurance, real idle, and AI Neural Gauge
  acceptance (deferred by Scott on 2026-11-11). The llama.cpp token-bound
  commits have automated coverage only.
- Desktop app launch and interactive UI walk-through on the signed build.
- Second-Mac install, publication, tag, merge.

## Open work

- Find the cause of transient low reads and add a guard (for example, rerun
  when a full-page image yields very little text).
- `inspect_pdf` still lists a scanned page with a little embedded text as
  searchable, although `ocr_pdf` now reads it.
- Remaining amount misses, about 8% on the benchmark pages.
- The flaky smoke-script check above.
