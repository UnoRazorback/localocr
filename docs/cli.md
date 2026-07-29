# LocalOCR CLI reference

`localocr` is the native, local command-line interface for macOS 14 or later.
It performs document processing on the Mac with Apple Vision; it makes no
network requests. It reads only the file paths supplied on the command line
and never overwrites an input file.

Build it from source with `swift build`, run it during development with
`swift run localocr`, or create a local native artifact with
`scripts/build-native-tools.sh` and run `./dist/native-tools/localocr`.

## Syntax

```text
localocr <command> [options]
```

Available commands are `page-count`, `inspect`, `ocr`, `batch`, `image`, and
`searchable`. `localocr --help` (or `-h`) lists commands,
`localocr <command> --help` (or `-h`) shows command usage, and
`localocr --version` (or `-V`) prints the version.

All PDF page selections are 1-indexed. A page specification accepts a range
such as `1-5`, individual pages such as `3,7,12`, or a combination such as
`1-3,7`. Omitting `--pages` processes every page.

## Commands

### `page-count <file> [--json]`

Return the number of pages in a local PDF.

```bash
localocr page-count /path/to/document.pdf
localocr page-count /path/to/document.pdf --json
```

Plain output is one integer. JSON output is `{"pages": <integer>}`.

### `inspect <file> [--json]`

Inspect a local PDF's native text layer without running OCR.

```bash
localocr inspect /path/to/document.pdf
localocr inspect /path/to/document.pdf --json
```

Plain output reports total pages, searchable pages, pages that need OCR, and
the native-text character count. JSON includes `source_path`,
`source_sha256`, `pages`, `searchable_pages`, `ocr_needed_pages`,
`characters`, `fully_searchable`, and a per-page `page_details` array.

### `ocr <file> [options]`

OCR one local PDF. Pages with usable native text are returned as
`existing_text` unless `--force-ocr` is given; newly recognized pages use
`vision_ocr`.

```bash
localocr ocr /path/to/document.pdf --pages 1-3 --dpi 300 --json
```

Options:

| Option | Meaning |
| --- | --- |
| `--pages <spec>` | Optional 1-indexed page selection. |
| `--dpi <72...600>` | PDF rasterization resolution; default `250`. |
| `--force-ocr` | OCR pages even when they have usable native text. |
| `--detail` | Include line text, confidence, and normalized `x`, `y`, `width`, and `height` in JSON. |
| `--no-cache` | Do not read or write the OCR cache for this operation. |
| `--json` | Emit the structured response as JSON. |

Without `--json`, standard output contains one `--- Page N ---` section per
returned page. With it, the response includes `source_path`, `source_sha256`,
`pages`, `failed_pages`, `empty_ocr_pages`, and `rotated_ocr_pages`. A page
may be reported in `failed_pages` without discarding successful pages.

### `batch <files...> [options]`

OCR one or more local PDFs. It accepts the same `--pages`, `--dpi`,
`--force-ocr`, `--detail`, `--no-cache`, and `--json` options as `ocr`.

```bash
localocr batch /path/to/one.pdf /path/to/two.pdf --pages 1-2 --json
```

JSON output contains `processed`, `succeeded`, `failed`, and `results`. A
result is either the normal PDF OCR response with `status: "ok"`, or
`{"source_path": ..., "status": "error", "error": ...}`. One unreadable
file does not stop the rest of the batch. Without `--json`, successful page
text goes to standard output and individual file errors go to standard error.

### `image <file> [options]`

OCR one image directly, without PDF rendering.

```bash
localocr image /path/to/scan.heic --language en-US --json
```

| Option | Meaning |
| --- | --- |
| `--language <bcp47>` | Recognition-language hint; repeat the option for multiple hints. |
| `--no-language-correction` | Disable Vision language correction. |
| `--json` | Emit `{"text": ...}` instead of plain text. |

Inputs must be decodable by macOS ImageIO and usable by Apple Vision. Common
examples include PNG, JPEG, TIFF, HEIC/HEIF, GIF, BMP, APNG, and WebP when the
installed macOS ImageIO support can decode them. An unsupported or corrupt
image fails locally with an error.

### `searchable <file> [options]`

Create a new searchable PDF from a local PDF. LocalOCR preserves the input
and writes recognized text as an invisible layer in the new PDF.

```bash
localocr searchable /path/to/document.pdf --output /path/to/document_searchable.pdf --json
```

| Option | Meaning |
| --- | --- |
| `--output <file>` | Destination PDF. If omitted, the default is `<source-name>_searchable.pdf`, choosing a non-existing numbered variant when needed. |
| `--dpi <72...600>` | PDF rasterization resolution; default `250`. |
| `--force-ocr` | OCR pages even when they have usable native text. |
| `--no-cache` | Do not read or write the OCR cache for this operation. |
| `--json` | Emit `{"output_path": ..., "failed_pages": [...]}`. |

The destination must be a different path from the source, its parent directory
must exist, and LocalOCR will not overwrite an existing destination. A result
can name an output while listing `failed_pages`; treat that output as partial.

## Output streams and exit codes

Successful requested data is written to standard output. Normal OCR progress
(`inspecting`, `recognizing`, `assembling`, and `completed`) is written to
standard error. `--json` keeps the requested JSON response on standard output,
but progress still uses standard error.

| Exit code | Meaning |
| --- | --- |
| `0` | Completed without a partial failure. |
| `1` | Operational failure, such as a missing, unreadable, unsupported, or invalid file/destination. The diagnostic is on standard error. |
| `2` | Invalid command-line syntax or option value. |
| `3` | Partial result: one or more PDF pages or batch files failed, while other output may be available. |
| `4` | The operation was cancelled. A batch can still have a JSON response describing items completed before cancellation. |

## Cache

By default, PDF OCR caches page recognition results in:

```text
~/Library/Caches/com.rayconsulting.localocr/ocr-v1
```

Set `LOCALOCR_CACHE_DIR` to a local directory path (with `~` expansion
supported) to use a different cache location:

```bash
LOCALOCR_CACHE_DIR=/path/to/localocr-cache localocr ocr /path/to/document.pdf --json
```

Cache entries are private local files and include recognition data keyed by
source content, page, and recognition settings. `--no-cache` bypasses that
cache for a single `ocr`, `batch`, or `searchable` request.
