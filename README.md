# ocr-service — local MCP OCR server (macOS)

Local MCP server that OCRs scanned/image-only PDFs and images using Apple's
Vision framework (`VNRecognizeTextRequest`), so any document-review workflow
can call OCR as a tool instead of one-off scripting. macOS only — Vision is
an Apple framework with no equivalent on other platforms.

## How it works

1. PyMuPDF (`fitz`) rasterizes each requested PDF page to a PNG at 250–300 DPI.
2. The PNG bytes are handed to `Vision.VNRecognizeTextRequest` with
   `recognitionLevel = .accurate` and `usesLanguageCorrection = true`.
3. Results are cached to disk per (file content hash, page number, DPI), so
   re-running OCR on a file already processed doesn't redo the work — even
   across different `page_range` values on the same file.

## Requirements

The Apple system Python on this Mac is 3.9, but the official `mcp` SDK needs
Python ≥3.10. This project uses [`uv`](https://github.com/astral-sh/uv) (installed
to `~/.local/bin`, no admin/sudo, no Homebrew) to provision an isolated
Python 3.12 without touching system Python:

```bash
export PATH="$HOME/.local/bin:$PATH"
export UV_SYSTEM_CERTS=1   # needed on this network; TLS intercept otherwise fails cert validation
cd "/Users/scottray/Claude Code/ocr-mcp"
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python --only-binary :all: -e .
```

`--only-binary :all:` forces prebuilt wheels for every dependency
(`mcp`, `PyMuPDF`, `pyobjc-core`, `pyobjc-framework-Vision`,
`pyobjc-framework-Quartz`, `pyobjc-framework-Cocoa`, `pyobjc-framework-CoreML`)
so nothing tries to compile from source against newer Xcode toolchains.
All dependencies are pinned to exact versions in `pyproject.toml` (not
`>=` ranges) so a fresh install reproduces the same environment this was
built and tested against. To also run the test suite, install the `dev`
extra: `uv pip install --python .venv/bin/python --only-binary :all: -e ".[dev]"`.

## Tools

| Tool | Signature | Notes |
|---|---|---|
| `get_pdf_page_count` | `(file_path) -> int` | Call first on large files to plan a `page_range`. |
| `inspect_pdf` | `(file_path) -> {"source_path", "source_sha256", "pages", "searchable_pages", "ocr_needed_pages", "characters", "fully_searchable", "page_details": [{"page","characters","searchable"}]}` | No OCR at all — just checks each page's native text layer. Use this to decide up front whether `ocr_pdf` is even needed, or which pages need it. |
| `ocr_pdf` | `(file_path, page_range=None, dpi=250, force_ocr=False, include_lines=False) -> {"source_path", "source_sha256", "pages": [{"page","text","method","lines"?}], "failed_pages", "empty_ocr_pages", "rotated_ocr_pages"}` | `page_range` is 1-indexed: `"1-5"`, `"3,7,12"`, or omit for all pages. Pages are rasterized and OCR'd one at a time (not all loaded into memory at once), so a 250+ page backup package only costs what you actually request. `failed_pages` lists pages that raised an error (corrupt, undecodable) without aborting the rest; `empty_ocr_pages` lists pages that OCR'd successfully but found no text (e.g. a blank or photo-only page) — a distinct, non-error outcome; `rotated_ocr_pages` lists pages where the source content wasn't upright (`{"page","orientation"}`). Pages with an existing native text layer (≥20 characters) are returned as-is (`method: "existing_text"`) instead of re-OCR'd — pass `force_ocr=True` to override. `include_lines=True` adds a `lines` array per page with per-line `text`/`confidence`/`x`/`y`/`width`/`height` (normalized 0-1 bounding box). |
| `ocr_pdf_batch` | `(file_paths, page_range=None, dpi=250, force_ocr=False, include_lines=False) -> {"processed","succeeded","failed","results": [<ocr_pdf result + "status":"ok"> \| {"source_path","status":"error","error"}]}` | Same as `ocr_pdf` but over multiple files in one call. One file's failure (missing file, corrupt PDF) doesn't abort the batch. |
| `ocr_image` | `(file_path) -> str` | OCRs PNG/JPG/HEIC/etc. directly, no PDF rendering. Retries at rotated orientations if the upright pass scores low (handles pages scanned sideways). |
| `make_searchable_pdf` | `(file_path, output_path=None, dpi=250, force_ocr=False) -> {"output_path", "failed_pages"}` | Writes a new PDF with recognized text as an invisible (`render_mode=3`) layer positioned from each line's Vision bounding box, so the page looks identical but becomes searchable/selectable in Preview/Acrobat. Pages that already have native text are left untouched unless `force_ocr=True`. Default output is `<name>_searchable.pdf`. |

`ocr_pdf`/`ocr_pdf_batch` also return `source_sha256` (the input file's content
hash) for an audit trail, and cache entries store the full per-page record
(text, orientation, per-line detail) so a cache hit still serves
`include_lines=True` requests.

Recognition uses `recognitionLevel = .accurate` (not `.fast`) and
`usesLanguageCorrection = true`. 250–300 DPI resolves small print in
financial documents correctly — verified against real construction pay
applications and a combined status report this session (see Testing below).

**Rotation retry is text-only.** `ocr_pdf`/`ocr_image` retry rotated
orientations and pick whichever scores best, so sideways-scanned pages still
read correctly. `make_searchable_pdf` always OCRs upright only — a non-upright
orientation's bounding boxes are in a rotated coordinate space relative to
the original page, and re-deriving the transform back wasn't worth the
complexity for an invisible, approximate text layer. A genuinely sideways
page will get a low-quality invisible text layer from `make_searchable_pdf`
rather than being retried or skipped; use `ocr_pdf` on that page if you need
accurate text.

## Registering with Claude Code / Cowork

```bash
claude mcp add ocr-service -s user -- "/Users/scottray/Claude Code/ocr-mcp/.venv/bin/python" -m ocr_service.server
```

`-s user` registers it for all your projects (use `-s local` to scope it to
just this workspace). Equivalent config JSON (e.g. for a `.mcp.json` or
Cowork config):

```json
{
  "mcpServers": {
    "ocr-service": {
      "command": "/Users/scottray/Claude Code/ocr-mcp/.venv/bin/python",
      "args": ["-m", "ocr_service.server"]
    }
  }
}
```

This was **not** run automatically — registering a server edits Claude
Code's persistent config, so it's left for you to run (or ask me to run)
explicitly.

## CLI (no MCP client needed)

```bash
# OCR specific pages, print JSON to stdout
.venv/bin/python -m ocr_service "<file.pdf>" --pages 1-5 --dpi 250

# Check for an existing text layer only, no OCR
.venv/bin/python -m ocr_service "<file.pdf>" --inspect

# Include per-line confidence and bounding-box detail
.venv/bin/python -m ocr_service "<file.pdf>" --detail

# OCR a standalone image
.venv/bin/python -m ocr_service "<file.png>"

# Write a searchable PDF
.venv/bin/python -m ocr_service "<file.pdf>" --searchable [output.pdf]

# Skip the disk cache
.venv/bin/python -m ocr_service "<file.pdf>" --no-cache

# Force OCR even on pages that already have native text
.venv/bin/python -m ocr_service "<file.pdf>" --force-ocr
```

`ocr_pdf_batch` (multiple files in one call) is MCP-only — there's no CLI
flag for it; call it directly if you need to script it (`from ocr_service
import core`).

## Related tool: `bucees-ocr` (Codex-built) — consolidated into this project

A separate OCR MCP server, `bucees-ocr`, was also built (by ChatGPT/Codex) at
`tools/bucees-ocr-mcp`, using a different architecture: a compiled Swift
binary calling Vision via subprocess, plus `pdftoppm` (Poppler) for page
rendering. As of 2026-07-22 it does **not** work on this Mac — it depends on
`pdftoppm`, which isn't installed (no Poppler, no Homebrew here), so its
`ocr_pdf`/`ocr_pdf_batch` fail immediately; only its text-layer-only
`inspect_pdf` works. It also rebuilds every OCR'd page as a re-compressed
JPEG in the output PDF (lossy, vs. this project's invisible-overlay approach
that leaves the original page content untouched).

Codex independently reviewed both and recommended consolidating on
`ocr-service` as the single implementation, porting over `bucees-ocr`'s good
ideas. That's been done: `inspect_pdf`, `ocr_pdf_batch`, per-line
confidence/bbox detail, source hashes, and empty/rotated-page reporting are
all now part of `ocr-service` (see the Tools table above), plus a real
automated test suite (`tests/`) and pinned dependencies.

Current state: `ocr-service` is registered in both Claude Code (`claude mcp
list`) and Codex (`~/.codex/config.toml`, `enabled = true`). `bucees-ocr` is
still registered (and shows "Connected") in both Claude Code and Codex —
Codex has it as `enabled = false` in its own config (it had already disabled
its own broken tool before this consolidation), but Claude Code has no
equivalent per-server enable flag, so it stays listed there. It hasn't been
unregistered or deleted anywhere yet — that's a deliberate last step,
pending a final validation pass on the known construction packages Scott
reviews, per Codex's own recommendation to retire it only after that.

## Known limitations

- **macOS only.** `platform_guard.ensure_macos()` fails fast with a clear
  message on any other OS instead of a cryptic pyobjc import error.
- **Digit/`$` confusion is possible.** On the real 91-page Ruston pay
  application tested this session, Vision correctly read most dollar
  figures (e.g. `$57,508,601.00`) but misread the `$` glyph as `5` on a few
  lines (`51,685,496.94` instead of `$1,685,496.94`). Treat OCR'd numbers as
  needing verification, not ground truth — don't feed them straight into
  penny-level math without a sanity pass (this matches how the
  `payapp-audit` engine already treats OCR'd source data).
- **`make_searchable_pdf` alignment is approximate.** Text is placed and
  sized from each line's Vision bounding box (width-fit via
  `fitz.get_text_length` ratio), not true glyph-for-glyph positioning. It's
  invisible, so this only matters for click-to-select / copy behavior, not
  visual appearance.

## Automated tests

```bash
.venv/bin/python -m pytest
```

26 tests in `tests/`, all against synthetic PDFs built with pure PyMuPDF (no
Pillow/font dependency needed — `insert_text` draws real vector text,
`get_pixmap` rasterizes it to PNG for "image-only" fixtures, and
`page.set_rotation` bakes an actual rotation into the rendered pixels for the
sideways-page fixture):

- **Native-text PDF** — `ocr_pdf` returns it as `method: "existing_text"`
  without touching Vision; `inspect_pdf` reports `fully_searchable: True`.
- **Image-only PDF** — OCR'd via Vision, recovers the exact dollar figure.
- **Mixed PDF** (one native page, one image-only page) — correct `method`
  per page.
- **Sideways page** (genuinely rotated 90°, verified by inspecting the
  rendered PNG) — text still recovered correctly. Note: real-world testing
  showed Apple's Vision framework is already fairly rotation-robust on its
  own even without the retry logic, so this integration test alone doesn't
  prove the retry *mechanism* works — see the next point.
- **Rotation-retry logic itself** — a separate unit test (`test_vision_ocr.py`)
  fakes the low-level Vision call with controlled per-orientation scores and
  asserts `ocr_image_lines_best_orientation` actually picks the highest-scoring
  orientation, including a case where "up" is correctly kept despite
  scoring low elsewhere first.
- **Photo-only page** (visible content, no text at all) — lands in
  `empty_ocr_pages`, not `failed_pages` — a successful OCR call that found
  nothing, distinct from an error.
- **Large page-range request** — a 20-page all-image PDF, requesting pages
  1-2; a monkeypatched `rasterize_page` confirms only those 2 pages were
  ever rasterized, not all 20.
- **Cache-hit avoidance** — a monkeypatched Vision call confirms a second
  `ocr_pdf` call on the same file is served entirely from cache (0 further
  Vision calls).
- **`force_ocr`** override, **batch** per-file failure isolation,
  **`include_lines`** confidence/bbox detail, and `parse_page_range`/
  `sha256_file`/`inspect_pdf` edge cases.
- **Searchable-PDF visual comparison** — rasterizes the input and output
  pages to PNG at the same DPI and asserts the pixels are byte-identical
  (invisible text contributes nothing to the raster), then confirms
  `page.search_for(...)` finds the recognized text.
- **Real MCP calls** — the actual server subprocess, driven over real stdio
  JSON-RPC by the official `mcp` Python client, not a mocked transport.

## Manual real-file validation (2026-07-22/23)

- CLI: OCR'd a real scanned 4-page lien waiver (dollar figures read
  correctly), full-doc run, and a cache-hit rerun (~1.0s → ~0.2s).
- `make_searchable_pdf`: verified the output PDF's `page.get_text()` and
  `page.search_for("110,997.96")` both return correct, plausibly-positioned
  results — original scanned image untouched, invisible text layer aligned.
- `ocr_image`: OCR'd a standalone rasterized PNG directly.
- Error handling: nonexistent file exits with a clear message and non-zero
  status.
- Scale/streaming: ran `--pages 1-3,26` against a real 26-page combined
  status report and `--pages 1-3` against a real 91-page (164MB) scanned pay
  application — only the requested pages were rasterized/OCR'd, not the
  whole document.
- `inspect_pdf` on that same real 91-page pay app correctly reported a mixed
  document (`ocr_needed_pages: 86` of 91 — a handful of pages already carry
  native text).
- Full MCP wiring: drove the server over real stdio JSON-RPC with the
  official `mcp` Python client (`ClientSession` + `stdio_client`), confirmed
  `tools/list` returns all 6 tools and `tools/call` on every new tool
  (`inspect_pdf`, `ocr_pdf_batch`) returns correct results.
