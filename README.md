# LocalOCR

**Your documents stay on your Mac.** LocalOCR performs PDF and image OCR with
Apple Vision and the native CLI and MCP server make no network requests.
Document contents, recognized text, paths, and cache entries are processed and
stored locally.

LocalOCR is an open-core project for **macOS 14 or later**. The open-source
core includes the Swift OCR engine, the `localocr` command-line tool, and the
`localocr-mcp` stdio server. The repository also contains the release pipeline
for a directly distributed LocalOCR Studio Mac app. The current private
prerelease is [v0.2.0-beta.1](https://github.com/UnoRazorback/localocr/releases/tag/v0.2.0-beta.1)
for invited testers with repository access. See the [Beta 1 Tester Guide](BETA_TESTING.md)
for the verified download, installation, privacy, and optional MCP setup.

## What it does

- Inspect a PDF's existing text layer before OCR.
- OCR selected PDF pages or ImageIO-decodable images with Apple Vision.
- Create a new searchable PDF with an invisible recognized-text layer.
- Expose the same operations to MCP clients over local stdio.

PDF OCR preserves pages that already have usable native text unless
`--force-ocr` (or `force_ocr`) is selected. Original input files are never
overwritten. A searchable-PDF operation writes a new output file.

## LocalOCR Studio

LocalOCR Studio is the one-document-at-a-time Mac interface. Drop or open one
PDF or image and processing starts automatically on the Mac; there is no
configuration wizard or batch queue. After recognition, the app can copy the
text, save it as a text file, create a new searchable PDF from a PDF source,
or select **Process Another Document** to return immediately to the drop/open
screen.

Batch PDF OCR remains available through the local MCP server rather than the
Studio interface. See [the Studio guide](docs/studio.md) for the exact GUI/MCP
boundary, installed helper path, supported inputs, and current beta status.

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

## Private beta distribution

The current private prerelease is
[v0.2.0-beta.1](https://github.com/UnoRazorback/localocr/releases/tag/v0.2.0-beta.1).
It is available only to invited testers with private-repository access. Its
release identity is version `0.2.0`, build `1`, source commit
`2cb03cc9684ed9bb4b449a0f7d79f0588fb7ae38`, and verified ZIP SHA-256
`3a6a1c754ee369ab9a8ffe01bcc96e7f4927ac44eb1f82b410f538aee901c0d5`.
It was built with Xcode 26.6 (`17F113`), Swift 6, and arm64, with deployment target macOS 14.0; acceptance covered Apple M5 and Apple M4 Macs tested on macOS 27 beta build `26A5388g`.

Download `LocalOCR-Studio-0.2.0-1.zip` and
`LocalOCR-Studio-0.2.0-1.sha256` into the same directory and verify them before
expanding the ZIP:

```bash
shasum -a 256 -c "LocalOCR-Studio-0.2.0-1.sha256"
```

Continue only if the command reports `OK`. Move the expanded `LocalOCR
Studio.app` to `/Applications` and open it normally. Do not bypass Gatekeeper
or use an unverified build or staging copy. The [Beta 1 Tester Guide](BETA_TESTING.md)
contains the complete install, five-minute desktop test, compatibility, and
feedback instructions.

### Beta limitations

- macOS 14 or later on Apple silicon is required.
- OCR, recognized text, cache data, and document paths remain local; there is
  no cloud OCR, cloud storage, or network MCP transport.
- The MCP server uses local stdio and client configuration remains manual.
- Windows, Linux, and Intel Macs are not supported.
- Beta behavior and file-format results may change; keep original documents
  and report substantive issues through the feedback URL in the private
  release notes.

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

## Scope and beta operations

LocalOCR currently targets local, on-device PDF and image OCR. It does not
provide cloud OCR, cloud document storage, automatic client configuration, or
cross-platform support. During Beta 1, collect desktop and advanced-MCP
feedback, preserve local-only behavior, and use that evidence to choose the
Beta 2 scope.
