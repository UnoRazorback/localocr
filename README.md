# LocalOCR

**Your documents stay on your Mac.** LocalOCR performs PDF and image OCR with
Apple Vision and the native CLI and MCP server make no network requests.
Document contents, recognized text, paths, and cache entries are processed and
stored locally.

LocalOCR is an open-core project for **macOS 14 or later**. The open-source
core includes the Swift OCR engine, the `localocr` command-line tool, and the
`localocr-mcp` stdio server. The repository also contains the release pipeline
for a directly distributed LocalOCR Studio Mac app. The Beta 2.1 release
candidate is version `0.3.1`, build `4`, with planned tag
`v0.3.1-beta.1`. Signing, notarization, target-Mac acceptance, and publication
remain separate gates; no Beta 2.1 download is being claimed before those
gates pass. See the [Beta Tester Guide](BETA_TESTING.md) for the desktop-first
test, privacy boundary, Local Intelligence providers, and optional MCP setup.

## What it does

- Inspect a PDF's existing text layer before OCR.
- OCR selected PDF pages or ImageIO-decodable images with Apple Vision.
- Create a new searchable PDF with an invisible recognized-text layer.
- Produce temporary, grounded summaries,
  organization suggestions, and requested fields with Apple's on-device
  Foundation Models framework on eligible Macs.
- Expose nine purpose-limited document operations to MCP clients over local
  stdio after explicit external-data acknowledgment.

PDF OCR preserves pages that already have usable native text unless
`--force-ocr` (or `force_ocr`) is selected. Original input files are never
overwritten. A searchable-PDF operation writes a new output file.

## LocalOCR Studio

LocalOCR Studio opens in its one-document-at-a-time workflow. Drop or open one
PDF or image and processing starts automatically on the Mac. After
recognition, the app can copy the text, save it as a text file, create a new
searchable PDF from a PDF source, or select **Process Another Document** to
return immediately to the drop/open screen.

Select **New Batch** only when you want a reviewed, sequential run. Add files
or folders, choose an output folder, inspect the planned queue, then start it.
Folders are scanned recursively for supported PDFs and images; sources are
never overwritten. PDFs receive new searchable-PDF outputs and images receive
text-file outputs. Existing output names are preserved by choosing a numbered
name instead of overwriting. You can cancel, retry failed items, reveal the
chosen output folder, or start a new batch. See [the Studio guide](docs/studio.md)
for the full desktop flow and [the v0.3 release notes](docs/release/v0.3.0-beta.2-notes.md)
for the previous published release boundary. MCP and CLI remain advanced,
local-use interfaces.
Start with the desktop app; configure an agent only if you need automation, and
then follow the canonical [advanced MCP setup and FAQ](docs/mcp.md#advanced-setup).

### Beta 2.1 Local Intelligence

For a single processed document, Beta 2.1 adds three
optional actions: summarize, suggest a name/category/tags, and extract `date`,
`total`, and `reference_number`. The results are temporary and non-destructive;
they clear when the document/workspace/window changes and never rename or move
the source. Desktop batch remains OCR-only.

Apple Foundation Models requires macOS 26 or later, an eligible Mac, Apple
Intelligence enabled, its on-device model ready, and a supported Apple
Intelligence language. Beta 2.1 can also detect verified loopback Ollama and
LM Studio installations and offer their local models. It never silently
switches providers, refuses remote or locality-ambiguous endpoints, and
requires explicit acknowledgment before document text is sent to an external
local runtime. LocalOCR uses no Private Cloud Compute and has no cloud fallback.

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

The resulting executables are `dist/native-tools/localocr`,
`dist/native-tools/localocr-mcp`, and
`dist/native-tools/localocr-model-bridge`. The build script creates local development
artifacts only; it does not sign, notarize, install, or publish them.

## Beta 2.1 release candidate

The candidate identity is version `0.3.1`, build `4`, planned tag
`v0.3.1-beta.1`, and planned assets `LocalOCR-Studio-0.3.1-4.zip` and
`LocalOCR-Studio-0.3.1-4.sha256`. The exact release commit, ZIP SHA-256,
notarization submission, downloaded-package verification, and target-Mac
results must be filled from evidence after those gates pass. Development uses
stable Xcode 26.6 (`17F113`), Swift 6, arm64, and deployment target macOS 14.0.
Future Apple beta compatibility is not guaranteed.

After the release is published, download `LocalOCR-Studio-0.3.1-4.zip` and
`LocalOCR-Studio-0.3.1-4.sha256` into the same directory and verify them before
expanding the ZIP:

```bash
shasum -a 256 -c "LocalOCR-Studio-0.3.1-4.sha256"
```

Continue only if the command reports `OK`. Move the expanded `LocalOCR
Studio.app` to `/Applications` and open it normally. Do not bypass Gatekeeper
or use an unverified build or staging copy. The [Beta Tester Guide](BETA_TESTING.md)
contains the complete install, five-minute desktop test, compatibility, and
feedback instructions.

Release operators and second-Mac testers must use a clean checkout at the
exact approved release commit. From that checkout's repository root, run the
downloaded-copy verifier with absolute paths to both downloaded assets before
an unpublished candidate is released or a published prerelease is promoted:

```bash
cd /path/to/localocr
export LOCALOCR_EXPECTED_BUNDLE_ID="<approved-bundle-id>"
export LOCALOCR_RELEASE_VERSION="<approved-version>"
export LOCALOCR_RELEASE_BUILD="<approved-build>"
scripts/test-downloaded-release.sh \
  "/absolute/path/to/LocalOCR-Studio-<version>-<build>.zip" \
  "/absolute/path/to/LocalOCR-Studio-<version>-<build>.sha256"
```

The private release workflow identifies the approved version, exact release
commit, installation steps, known limitations, and owner-approved feedback
URL before publication. The published prerelease notes identify the
corresponding facts for the available build.

### Beta limitations

- macOS 14 or later on Apple silicon is required.
- LocalOCR's OCR, cache, Foundation Models, and stdio-server processing remain
  local; there is no cloud OCR, cloud storage, or network MCP transport. A
  connected client/provider may separately transmit MCP arguments and results.
- The MCP server uses local stdio. Beta 2.1 provides guided setup for detected
  Codex and Claude installations; other clients receive copy-only instructions.
- All nine MCP document tools require the external-provider acknowledgment.
- Windows, Linux, and Intel Macs are not supported.
- Beta behavior and file-format results may change; keep original documents
  and report substantive issues through the feedback URL in the published
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

Beta 2.1 `localocr-mcp` exposes the following local tools after the current
external-data acknowledgment is accepted:

| Tool | Purpose |
| --- | --- |
| `get_pdf_page_count` | Return a PDF's page count. |
| `inspect_pdf` | Inspect its native text layer without OCR. |
| `ocr_pdf` | OCR one PDF, optionally selecting pages. |
| `ocr_pdf_batch` | OCR several PDFs without one failure stopping the batch. |
| `ocr_image` | OCR one ImageIO-decodable image. |
| `make_searchable_pdf` | Create a new PDF with an invisible searchable-text layer. |
| `summarize_document` | Produce a grounded summary with page citations using on-device Local Intelligence. |
| `organize_document` | Suggest a grounded title, category, and tags without changing the source. |
| `extract_document_fields` | Extract only requested named fields with optional page evidence. |

Read the canonical [advanced MCP setup and FAQ](docs/mcp.md#advanced-setup)
before configuring a client. The server reads only the local paths a client
supplies and has no HTTP listener or network transport. LocalOCR itself makes
no network request, but a connected MCP client or its AI provider may transmit
paths, document text, and tool results outside the Mac; review that product's
current privacy and retention terms before accepting.

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

LocalOCR targets local, on-device PDF and image OCR. It does not provide cloud
OCR, cloud document storage, remote MCP transport, or cross-platform support.
Beta 2.1 combines the default single-document desktop flow, reviewed sequential
desktop batches, offline Help, guided Codex/Claude connection, nine local stdio
tools, and explicitly selected local-model providers. Release verification and
publication remain evidence-backed gates.
