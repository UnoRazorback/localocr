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

## Beta 2.1 Local Intelligence

After one document finishes OCR, Beta 2.1 can use a selected local model to
**Summarize**, **Suggest Name & Tags**, or **Extract
Fields** (`date`, `total`, and `reference_number`). These are separate actions
in the single-document result view. They use the recognized page text, retain
page citations or evidence, and do not send the original PDF or image bytes to
the model.

The Local Intelligence card identifies the active provider and exact identity
available from that harness. Apple Foundation Models uses
`SystemLanguageModel.default`; Apple chooses the installed system model and
does not expose its specific model name or version through the public API.
**Manage Local Models** can detect qualified Ollama and LM Studio models on
verified loopback. LocalOCR refuses remote, relayed, wildcard, and
locality-ambiguous endpoints and never silently switches providers.

Local Intelligence results are temporary and non-destructive. They remain in
the current result view only until you process another document, switch
workspaces, or close the window. LocalOCR does not rename, move, rewrite, or
automatically save the source based on a suggestion. Copy or save anything you
want to retain, and keep the original document because OCR and model output can
contain errors.

Batch remains OCR-only: it never invokes Local Intelligence. Apple Foundation
Models requires macOS 26 or later, an eligible Mac, Apple Intelligence enabled,
the on-device model ready, and a supported Apple Intelligence language. Ollama
or LM Studio requires an already-running supported local harness, a qualified
model, explicit selection, and the displayed acknowledgment. When the selected
provider is unavailable, normal single-document and batch OCR continue to work.

Apple Foundation Models stays inside LocalOCR and Apple's on-device framework;
it does not use Private Cloud Compute or a cloud fallback. A selected Ollama or
LM Studio route sends OCR text only to that acknowledged harness over loopback
on this Mac. The harness may keep its own logs or history. Studio Local
Intelligence does not require MCP consent because no external agent is involved;
the local-runtime acknowledgment and MCP acknowledgment are separate choices.

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

as the MCP client's absolute command path. See the canonical
[advanced MCP setup and FAQ](mcp.md#advanced-setup) for all nine tools,
external-provider risk, consent, and current client-configuration examples.
The adjacent `Contents/Helpers/localocr` executable provides the command-line
interface.

## Beta 2.1 status

The release candidate is version `0.3.1`, build `4`, with planned tag
`v0.3.1-beta.1`. Follow the [Beta Tester Guide](../BETA_TESTING.md) for the
desktop-first acceptance path. The planned assets are
`LocalOCR-Studio-0.3.1-4.zip` and its matching `.sha256` file. Do not use a
staging copy or bypass Gatekeeper. Signing, notarization, downloaded-package,
and target-Mac acceptance remain separate gates, so no published Beta 2.1
download is claimed before their evidence exists.

## Compatibility and build provenance

The candidate uses stable Xcode 26.6 (`17F113`), Swift 6, arm64, and deployment
target macOS 14.0. Final signing, notarization, Gatekeeper, download, and
target-Mac facts will be added from completed evidence. Future Apple beta
compatibility is not guaranteed; include the exact macOS version and build
number in feedback.
