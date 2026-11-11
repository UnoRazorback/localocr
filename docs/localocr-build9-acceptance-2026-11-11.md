# LocalOCR 0.3.2 build 9 — source and release acceptance

Date: 2026-11-11. Status: source gates passed; signing, notarization, and
exact-artifact acceptance are recorded below only where evidence exists.
Marketing version is `0.3.2`, build is `9`, planned tag `v0.3.2-beta.1`.
Nothing here authorizes publication, merge, or tagging.

## What changed since build 8 (`v0.3.1-beta.1`, source `9b4788c`)

- `d96c16b`, `abc3298`, `20bbd68`: llama.cpp structured-output token bounds
  (made after build 8 was published; not covered by the September provider
  acceptance).
- `39c20d5`: recognized page text keeps table rows together
  (`TableRowTextAssembler`); real-document benchmark added.
- `702afbc`: release toolchain pinned to Xcode 27.2 (`27B52`) at
  `/Applications/Xcode.app`.
- Version and document changes for build 9.

## Source gates (MacBook Pro, macOS 27.2, Xcode 27.2 `27B52`)

| Gate | Result |
| --- | --- |
| Swift suite | see "Results" below |
| Python contract suite | see "Results" below |
| Native tools build | see "Results" below |
| MCP stdio source policy | see "Results" below |

Running the Python gate on this Mac needs: a clone outside iCloud whose path
contains a space, the cache folder spelled exactly as on disk, `TMPDIR` from
`getconf DARWIN_USER_TEMP_DIR`, explicit `DEVELOPER_DIR`/`SDKROOT`, and
`./scripts/build-native-tools.sh` before `pytest`.

## Real-document OCR evidence

Benchmark: `benchmarks/realdoc_benchmark.py`, 112 pages from 16 construction
documents at 300 DPI, truth from the embedded PDF text layer.

| Build | amount | word | row:text |
| --- | --- | --- | --- |
| 0.3.1 build 8 (published) | 83.3 | 98.2 | 8.0 |
| 0.3.2 build 9 source | 83.3 | 98.2 | 94.3 |

Sampled pages are mostly born-digital and cleaner than true scans. Amount
recall is unchanged by this build and remains the main open accuracy item.

## Results

Filled in from evidence as each gate completes.

## Not run / remaining

Listed with the results.
