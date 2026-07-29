# LocalOCR

**Your documents stay on your Mac.** LocalOCR performs PDF and image OCR with
Apple Vision and the native CLI and MCP server make no network requests.
Document contents, recognized text, paths, and cache entries are processed and
stored locally.

LocalOCR is an open-core project for **macOS 14 or later**. The open-source
core includes the Swift OCR engine, the `localocr` command-line tool, and the
`localocr-mcp` stdio server. The repository also contains the release pipeline
for a directly distributed LocalOCR Studio Mac app. No private beta has been
published yet, and development or controlled-test artifacts must not be
represented as signed, notarized releases.

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

## Private beta distribution

**Status: not yet published.** The private beta remains blocked until one exact
release commit and its final downloaded assets pass every release gate:

- the complete Swift, Python, artifact-policy, and direct-release contract
  suites pass;
- the app and both nested helpers have timestamped Developer ID signatures
  with Hardened Runtime;
- Apple notarization is `Accepted`, the ticket is stapled and validates, and
  Gatekeeper accepts the app extracted from the final ZIP;
- the published SHA-256 matches a freshly downloaded ZIP;
- the downloaded-copy workflow passes on the build Mac and a second Mac; and
- the owner explicitly authorizes the private prerelease.

Implementing or passing controlled release-script tests does not satisfy these
gates. A private prerelease may contain only the final stapled ZIP and its
SHA-256 file, targeted at the exact approved release commit.

### Install a future authorized beta

The owner will give approved testers access to a specific private prerelease.
Download both the LocalOCR Studio ZIP and its matching `.sha256` file into the
same directory. Do not use a ZIP copied from a build or staging directory.

From Terminal, change to the download directory and verify the asset before
opening it:

```bash
shasum -a 256 -c "LocalOCR-Studio-<version>-<build>.sha256"
```

Continue only if the command reports `OK`. Double-click the verified ZIP, move
`LocalOCR Studio.app` to Applications, and open the app normally. A valid
authorized beta should open without bypassing Gatekeeper; testers should not
use `xattr`, disable Gatekeeper, or choose an override for an unverified app.

Release operators and second-Mac testers must also run the repository's
downloaded-copy verifier against absolute paths before a beta is published or
promoted:

```bash
export LOCALOCR_RELEASE_VERSION="<approved-version>"
scripts/test-downloaded-release.sh \
  "$PWD/LocalOCR-Studio-<version>-<build>.zip" \
  "$PWD/LocalOCR-Studio-<version>-<build>.sha256"
```

The private release notes will identify the approved version, exact release
commit, installation steps, known limitations, and the owner-approved feedback
URL. Until those notes and assets exist, there is no supported beta download or
feedback endpoint.

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

## Scope and next milestone

LocalOCR currently targets local, on-device PDF and image OCR. It does not
provide cloud OCR, cloud document storage, automatic client configuration, or
cross-platform support. The next milestone is to satisfy the real signing,
notarization, downloaded-copy, and two-Mac gates and, only with owner
authorization, publish the private LocalOCR Studio beta.
