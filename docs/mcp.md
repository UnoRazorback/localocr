# LocalOCR MCP server

`localocr-mcp` is a local stdio MCP server for macOS 14 or later. It processes
the document paths supplied by the MCP client with Apple Vision on the Mac and
makes no network requests. It does not run an HTTP listener, upload documents,
or change client configuration by itself.

## Start and configure it

For the installed Studio beta, configure this absolute helper path:

```text
/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp
```

### Codex

```bash
codex mcp add localocr -- \
  "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp"
codex mcp list
```

Use `/mcp` in Codex to inspect the connected server. The Codex CLI, IDE
extension, and desktop app share MCP configuration on the same Codex host. See
the current [Codex MCP documentation](https://learn.chatgpt.com/docs/extend/mcp).

### Claude Code

```bash
claude mcp add --transport stdio localocr -- \
  "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp"
claude mcp list
```

Use `/mcp` in Claude Code to inspect status. Claude Code defaults to
local/project scope; add `--scope user` only when you intentionally want
LocalOCR available across projects. See the current [Claude Code MCP
documentation](https://code.claude.com/docs/en/mcp).

### Other MCP clients

Use your client's current documentation to configure this generic stdio-server
entry; LocalOCR does not edit client configuration:

```json
{
  "command": "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp",
  "args": []
}
```

See the [advanced MCP setup in the Beta 1 Tester Guide](../BETA_TESTING.md#advanced-mcp-setup)
for the optional installed-app workflow and safe example prompts.

### Source builds for developers

To build local development artifacts, run:

```bash
scripts/build-native-tools.sh
scripts/smoke-native-tools.sh
```

The extension manifest invokes `localocr-mcp` by name. Put the built native
executable on the client's `PATH` before enabling that extension; the
extension does not bundle an executable or a runtime.

The server starts when the client invokes it, communicates through standard
input/output for that session, and exits when the client closes the stdio
connection. It needs the operating system permissions required to read the
local document paths supplied to its tools and to write a requested searchable
PDF destination. Relative document paths are resolved from the server's
working directory; absolute paths avoid that ambiguity.

## Tools

All paths refer to local filesystem files. The server returns structured MCP
tool errors for bad arguments or processing failures and continues serving
later tool calls. It does not terminate merely because an individual tool call
fails.

### `get_pdf_page_count`

Parameters:

| Parameter | Meaning |
| --- | --- |
| `file_path` (required string) | Local PDF path. |

Returns the page count as text. Use it to plan a page range for large PDFs.

### `inspect_pdf`

Parameters:

| Parameter | Meaning |
| --- | --- |
| `file_path` (required string) | Local PDF path. |

Inspects the native text layer without running OCR. Its structured result has
`source_path`, `source_sha256`, `pages`, `searchable_pages`,
`ocr_needed_pages`, `characters`, `fully_searchable`, and per-page
`page_details`.

### `ocr_pdf`

Parameters:

| Parameter | Meaning |
| --- | --- |
| `file_path` (required string) | Local PDF path. |
| `page_range` (optional string) | 1-indexed selection such as `1-5` or `3,7,12`; omit for all pages. |
| `dpi` (optional integer) | PDF rasterization resolution from `72` through `600`; default `250`. |
| `force_ocr` (optional boolean) | OCR native-text pages too; default `false`. |
| `include_lines` (optional boolean) | Include per-line text, confidence, and normalized geometry; default `false`. |

Returns `source_path`, `source_sha256`, page records, `failed_pages`,
`empty_ocr_pages`, and `rotated_ocr_pages`. Pages with usable native text are
returned as `existing_text` unless forced; newly recognized pages are
`vision_ocr`. Page failures are reported without discarding successful pages.

### `ocr_pdf_batch`

Parameters:

| Parameter | Meaning |
| --- | --- |
| `file_paths` (required array of strings) | One or more local PDF paths. |
| `page_range` (optional string) | Same 1-indexed selection as `ocr_pdf`. |
| `dpi` (optional integer) | `72` through `600`; default `250`. |
| `force_ocr` (optional boolean) | Same behavior as `ocr_pdf`; default `false`. |
| `include_lines` (optional boolean) | Same behavior as `ocr_pdf`; default `false`. |

Returns `processed`, `succeeded`, `failed`, and `results`. Each item is either
an OCR response with `status: "ok"` or a per-file `status: "error"` result.
One file's failure does not stop the rest of the batch.

### `ocr_image`

Parameters:

| Parameter | Meaning |
| --- | --- |
| `file_path` (required string) | Local ImageIO-decodable image path. |

Returns recognized text directly. ImageIO-decoded inputs include common PNG,
JPEG, TIFF, and HEIC/HEIF images, with the exact supported set determined by
the installed macOS ImageIO support. The MCP surface does not expose language
or cache options for image OCR.

### `make_searchable_pdf`

Parameters:

| Parameter | Meaning |
| --- | --- |
| `file_path` (required string) | Local source PDF path. |
| `output_path` (optional string) | New local PDF destination. If omitted, LocalOCR chooses a non-existing `<source-name>_searchable.pdf` variant. |
| `dpi` (optional integer) | PDF rasterization resolution from `72` through `600`; default `250`. |
| `force_ocr` (optional boolean) | OCR native-text pages too; default `false`. |

Returns `output_path` and `failed_pages`. The source is left untouched. The
output path must not already exist and must not resolve to the source file;
when `failed_pages` is non-empty, the new output is partial.

## Local behavior and privacy

The server exists only for the client-managed stdio session and accesses local
files only when a tool call supplies their paths. PDF OCR may write local cache
entries at the same default cache location as the CLI,
`~/Library/Caches/com.rayconsulting.localocr/ocr-v1`; set
`LOCALOCR_CACHE_DIR` in the server's environment to use a different local
cache directory. Apart from those local cache writes, its only output write is
a new searchable PDF at a local destination requested by `make_searchable_pdf`.
That destination must not already exist and must not resolve to the source
file. The server itself makes no network requests.
