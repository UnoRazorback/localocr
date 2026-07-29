# LocalOCR

**Your documents stay on your Mac.** LocalOCR performs PDF and image OCR with
Apple Vision and the native CLI and MCP server make no network requests.
Document contents, recognized text, paths, and cache entries are processed and
stored locally.

LocalOCR is an open-core project for **macOS 14 or later**. The open-source
core includes the Swift OCR engine, the `localocr` command-line tool, and the
`localocr-mcp` stdio server. The Mac app and signed installer are the next
milestone; the artifacts produced here are not represented as signed or
notarized installers.

## What it does

- Inspect a PDF's existing text layer before OCR.
- OCR selected PDF pages or ImageIO-decodable images with Apple Vision.
- Create a new searchable PDF with an invisible recognized-text layer.
- Expose the same operations to MCP clients over local stdio.

PDF OCR preserves pages that already have usable native text unless
`--force-ocr` (or `force_ocr`) is selected. Original input files are never
overwritten. A searchable-PDF operation writes a new output file.

## Quick start from source

Install a current Swift toolchain on macOS 14+, then build the package:

```bash
git clone <repository-url> localocr
cd localocr
swift build
swift run localocr inspect /path/to/document.pdf --json
```

Start the server directly when testing the MCP transport:

```bash
swift run localocr-mcp
```

It waits for JSON-RPC messages on standard input. Do not type normal shell
commands into that process.

## Native artifact quick start

Create standalone local artifacts and check them before use:

```bash
scripts/build-native-tools.sh
scripts/smoke-native-tools.sh
./dist/native-tools/localocr ocr /path/to/document.pdf --pages 1-3 --json
```

The resulting executables are `dist/native-tools/localocr` and
`dist/native-tools/localocr-mcp`. The build script creates local development
artifacts only; it does not sign, notarize, install, or publish them.

## CLI

`localocr` writes requested results to standard output. OCR progress and
human-readable per-file failures go to standard error, so use `--json` when a
program will consume the result. See [the full CLI reference](docs/cli.md).

```bash
./dist/native-tools/localocr page-count /path/to/document.pdf
./dist/native-tools/localocr inspect /path/to/document.pdf --json
./dist/native-tools/localocr image /path/to/scan.heic --json
./dist/native-tools/localocr searchable /path/to/document.pdf --output /path/to/document_searchable.pdf
```

## MCP server

`localocr-mcp` exposes the following local tools:

| Tool | Purpose |
| --- | --- |
| `get_pdf_page_count` | Return a PDF's page count. |
| `inspect_pdf` | Inspect its native text layer without OCR. |
| `ocr_pdf` | OCR one PDF, optionally selecting pages. |
| `ocr_pdf_batch` | OCR several PDFs without one failure stopping the batch. |
| `ocr_image` | OCR one ImageIO-decodable image. |
| `make_searchable_pdf` | Create a new PDF with an invisible searchable-text layer. |

Read [manual MCP setup and tool parameters](docs/mcp.md) before configuring a
client. The server reads only the local paths a client supplies and has no
HTTP listener or network transport.

## Testing

Run the native Swift tests, Python compatibility tests, and artifact checks:

```bash
swift test
.venv/bin/python -m pytest -v
scripts/build-native-tools.sh
scripts/smoke-native-tools.sh
```

The Python suite remains a behavioral compatibility check during the native
Swift migration; the native executables do not require Python, PyObjC,
PyMuPDF, Homebrew, or a network service at runtime.

## Scope and next milestone

LocalOCR currently targets local, on-device PDF and image OCR. It does not
provide cloud OCR, cloud document storage, automatic client configuration, or
cross-platform support. A Mac app and signed installer are the next milestone.
