# LocalOCR Studio

LocalOCR Studio is the native Mac interface for LocalOCR. It opens in the
one-document-at-a-time workflow: open one file or drop one file into the
window, and recognition starts automatically. There is no setup wizard,
language picker, or OCR-settings step. Select **New Batch** when you
intentionally want to review a sequential batch before any document starts.

## Documents and processing

The Open panel accepts PDFs and image types that macOS identifies through
ImageIO. That includes common PNG, JPEG, TIFF, and HEIC/HEIF images, with the
exact image formats determined by the macOS version.

For a PDF, Studio first inspects its existing text and then recognizes the
pages that need OCR. Pages with usable native text are preserved. For an image,
Studio recognizes the image directly. Studio verifies that the source has not
changed while it is being processed.

All document access, Apple Vision recognition, and output writing happen
locally on the Mac. Studio does not upload the source, recognized text, file
paths, or outputs, and it does not use cloud OCR. It does not keep a document
or result history. The LocalOCR engine may reuse its local OCR cache at:

```text
~/Library/Caches/com.rayconsulting.localocr/ocr-v1
```

Opening another document replaces the current result. Studio never overwrites
the source document.

## Desktop batch

The desktop batch flow is review-first. Select **New Batch**, then add files
or folders and choose an output folder. Folder selections are scanned
recursively for supported PDFs and images. The queue shows supported items and
items it skipped before **Start Batch** becomes available, so nothing processes
merely because it was added.

Studio processes the reviewed queue sequentially, one item at a time. Every
output stays beneath the output folder you chose: a PDF gets a new searchable
PDF, and an image gets a recognized-text `.txt` file. Source documents remain
unchanged. Studio never overwrites an existing output; it selects a numbered
name when the preferred name is already taken.

You can **Cancel Batch** while it is running. Completed outputs remain in the
chosen output folder; pending work is marked cancelled. After a completed run,
use **Retry Failed** to try only failed items, **Reveal Output Folder** to open
the chosen destination, or **Start New Batch** to clear the review and begin again.
Use **Single Document** to return to the default one-document workflow when no
batch is processing.

## Result actions

- **Copy** places all recognized text on the macOS clipboard.
- **Save Text** writes the displayed text to a local plain-text file selected
  in the save panel.
- **Create Searchable PDF** is available only for a PDF source. It creates a
  new local PDF with an invisible recognized-text layer while leaving the
  source unchanged. Choose a new output path rather than the source path.
- **Process Another Document** immediately returns to the drop/open screen
  without relaunching the app or deleting any saved output.

## Advanced CLI and MCP

The Studio GUI calls the LocalOCR service directly. It does not launch either
bundled helper. The desktop batch flow is the normal batch route for app users.

The `localocr` CLI and MCP server are advanced local-use interfaces. The MCP
server retains automation features, including `ocr_pdf_batch`, so an MCP
client can submit several local PDF paths and receive a result for each without
one file failure stopping the rest. Its transport is local stdio; there is no
HTTP listener or network MCP service.

For an app installed in the normal Applications folder, the MCP executable is:

```text
/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp
```

If the app is installed elsewhere, use:

```text
<installed-app-path>/Contents/Helpers/localocr-mcp
```

as the MCP client's absolute command path. See [the MCP guide](mcp.md) for its
tools and client-configuration shape. The adjacent
`Contents/Helpers/localocr` executable provides the command-line interface.

## Beta status

The published prerelease is
[v0.2.0-beta.1](https://github.com/UnoRazorback/localocr/releases/tag/v0.2.0-beta.1).
Follow the [Beta 1 Tester Guide](../BETA_TESTING.md) to verify
`LocalOCR-Studio-0.2.0-1.zip` with its matching `.sha256` file, then move the
expanded app to `/Applications` and open it normally. Do not use a staging
copy or bypass Gatekeeper. The [Beta 2 candidate notes](release/v0.3.0-beta.1-notes.md)
document the desktop batch candidate separately; they are not a download,
signature, notarization, or acceptance record.

## Compatibility and build provenance

Beta 1 was built with Xcode 26.6 (`17F113`), Swift 6, and arm64, with deployment target macOS 14.0. Downloaded-package and GUI acceptance passed on Apple M5 and Apple M4 Macs tested on macOS 27 beta build `26A5388g`. Later Apple beta
builds may introduce regressions; include the exact macOS version and build
number in feedback.
