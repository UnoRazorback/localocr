# LocalOCR 0.3.2 build 11 — source and release acceptance

Date: 2026-11-17. Status: source prepared and gated. Not yet signed, not
published, not tagged, not merged. Local-model provider acceptance was not
run (see "Not run").

Marketing version `0.3.2`, build `11`, planned tag `v0.3.2-beta.2`.

## What changed since build 10 (source `6c3ae13`, published as `v0.3.2-beta.1`)

- `a9da4fa`, `69a9cc3`, `a0f195d`: opt-in amount check (`verify_amounts`,
  `--verify-amounts`); the native/Python parity check accepts it as a
  native-only option; survey of true scans.
- `77322b8`: garbled amounts finished from a second look at the line; Vision
  stall guard; cache version `ocr-processor-v4`; references re-measured.
- `0544c15`, `b24b943`, `deeadf0`, `dd4f721`: tool descriptions and documents.
- `5504326`, `f90eb1a`, `847d202`: benchmark tools and findings; smoke-script
  pipefail fix.
- Build number and release notes for build 11 (this commit).

## Source gates (MacBook Pro, Xcode 27.2 `27B52`)

| Gate | Result |
| --- | --- |
| Swift suite at `77322b8` | 973 tests passed |
| Python contract suite at `77322b8` | 506 passed, 1 opt-in live-model skip, 0 failed |
| MCP stdio source policy | PASS (source inventory re-attested for the new files) |

Gates on the build 11 commit itself, the release build, signing,
notarization, downloaded-package verification and OCR acceptance on the
signed artifact are recorded below once run.

## Measurements carried by this build

- 112 benchmark pages at 300 DPI: amount 91.9 to 95.1, word 97.5 to 98.3,
  row:all 84.5 to 86.8; garbled amounts 134 to 6; clean-but-wrong amounts 10
  before and after.
- 80 scanned PDFs (291 pages): garbled amounts 183 to 18; no failed pages.
- Vision stall: installed build 10 froze on 4 of 25 reads of one scanned
  file; the guarded build finished 60 of 60. No live freeze occurred during
  the guarded run, so the guard's rescue is covered by unit tests only.

## Not run

Local-model provider acceptance (Apple Foundation Models, Ollama, LM Studio,
llama.cpp), endurance, real idle, AI Neural Gauge, and the controlled macOS 27
GR target run.
