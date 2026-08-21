# LocalOCR Studio Beta Tester Guide

The published prerelease is Beta 1. The separate
[Beta 2 candidate notes](docs/release/v0.3.0-beta.1-notes.md) describe the
next desktop batch workflow; that candidate is not yet published and has no
downloadable archive, signing, notarization, or acceptance claim here.

## Download and install

Download `LocalOCR-Studio-0.2.0-1.zip` and `LocalOCR-Studio-0.2.0-1.sha256` from the [v0.2.0-beta.1 release](https://github.com/UnoRazorback/localocr/releases/tag/v0.2.0-beta.1) into the same directory. Verify the download before expanding it:

```bash
shasum -a 256 -c "LocalOCR-Studio-0.2.0-1.sha256"
```

The command must report `OK`. Expand the verified ZIP, move `LocalOCR Studio.app` to `/Applications`, then open it normally. Do not bypass Gatekeeper, remove quarantine attributes, or use an unverified build or staging copy.

## What the desktop app does

Use **Open** or drag and drop to process one document at a time. LocalOCR Studio recognizes text in PDFs and supported images (including PNG, JPEG, TIFF, and HEIC/HEIF where ImageIO supports them) with local Apple Vision and PDFKit. Existing usable PDF text is preserved while pages that need OCR are recognized.

After processing, you can Copy recognized text, Save Text as a plain-text file, or Create Searchable PDF at a new destination. The source document remains unchanged. Select **Process Another Document** to return immediately to the drop/open screen without relaunching.

## Beta 2 candidate: desktop batch workflow

The default remains one document at a time. In the candidate, select **New
Batch** to add files or folders, choose an output folder, and review the queue
before selecting **Start Batch**. Folders are scanned recursively for supported
PDFs and images. Processing is sequential. PDFs create new searchable PDFs;
images create `.txt` files containing recognized text. Original sources remain
unchanged, and existing output names are never overwritten: a numbered name is
chosen instead.

You can cancel a running batch, retry only failed items after it completes,
reveal the chosen output folder, or select **Start New Batch** to clear the queue.
This candidate uses the same local-only processing boundary as Beta 1.

## Five-minute desktop test

Use a non-sensitive sample document and complete these six steps:

1. Open one PDF and confirm useful recognized text.
2. Create a searchable PDF at a new destination and confirm the original was not replaced.
3. Select **Process Another Document** and confirm the drop/open screen returns without relaunching.
4. Open one supported image and confirm recognized text.
5. Copy or save the text.
6. Quit and reopen the app normally.

## Privacy

Recognition uses Apple Vision and PDFKit locally. LocalOCR does not upload documents, recognized text, filenames, paths, thumbnails, hashes, cache entries, or outputs. It provides no cloud OCR, cloud storage, HTTP MCP listener, or network MCP service. Local cache entries may be written at `~/Library/Caches/com.rayconsulting.localocr/ocr-v1`; there is no history of documents or results.

## Compatibility and build provenance

The published Beta 1 build (version `0.2.0`) was made with stable Xcode 26.6 (`17F113`), Swift 6, and arm64, with deployment target macOS 14.0. It is Developer ID signed with Hardened Runtime, Apple notarized, stapled, and Gatekeeper accepted. Complete downloaded-package and GUI acceptance passed on Apple M5 and Apple M4 Macs tested on macOS 27 beta build `26A5388g`.

Release provenance: version `0.2.0` build `1` comes from source commit `2cb03cc9684ed9bb4b449a0f7d79f0588fb7ae38`; the verified ZIP SHA-256 is `3a6a1c754ee369ab9a8ffe01bcc96e7f4927ac44eb1f82b410f538aee901c0d5`.

Later Apple beta builds may introduce regressions; report the exact macOS version and build number.

## Known limitations

- Apple silicon only; macOS 14 or later is required.
- No Intel, Windows, or Linux support.
- The default desktop workflow is one document at a time. The Beta 2 batch
  candidate has no run history, language/settings wizard, or guided MCP setup.
- MCP setup is manual and uses local stdio.
- Beta output behavior may change; retain your original documents.

## Report feedback

Use the repository [beta feedback form](https://github.com/UnoRazorback/localocr/issues/new/choose), backed by [`.github/ISSUE_TEMPLATE/beta-feedback.yml`](.github/ISSUE_TEMPLATE/beta-feedback.yml). Please use non-sensitive samples for issue reproduction. Never attach confidential source documents or recognized text to a public or broadly shared channel.

---

## Advanced: MCP setup

This optional path is separate from the desktop flow. The published Beta 1 app
processes one document at a time; the Beta 2 candidate keeps that flow as the
default and adds reviewed desktop batches. Its bundled local stdio MCP server
exposes the six tools below, including batch PDF OCR. The installed helper is:

```text
/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp
```

### Codex

```bash
codex mcp add localocr -- \
  "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp"
codex mcp list
```

Use `/mcp` in Codex to inspect the connected server. The Codex CLI, IDE extension, and desktop app share MCP configuration on the same Codex host. See the [Codex MCP documentation](https://learn.chatgpt.com/docs/extend/mcp).

### Claude Code

```bash
claude mcp add --transport stdio localocr -- \
  "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp"
claude mcp list
```

Use `/mcp` in Claude Code to inspect status. Claude Code defaults to local/project scope; add `--scope user` only when you intentionally want LocalOCR available across projects. See the [Claude Code MCP documentation](https://code.claude.com/docs/en/mcp).

### Other MCP clients

Use your client's current documentation to configure this generic stdio server; LocalOCR does not edit client configuration:

```json
{
  "command": "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp",
  "args": []
}
```

The available tools are `get_pdf_page_count`, `inspect_pdf`, `ocr_pdf`, `ocr_pdf_batch`, `ocr_image`, and `make_searchable_pdf`. macOS and the MCP client continue to enforce filesystem permissions.

Safe example prompts, using fictional non-sensitive fixtures:

- “Use `ocr_pdf` for `/Users/your-name/Documents/LocalOCR-Test/sample.pdf`.”
- “Use `ocr_image` for `/Users/your-name/Documents/LocalOCR-Test/receipt.jpg`.”
- “Use `ocr_pdf_batch` for `/Users/your-name/Documents/LocalOCR-Test/one.pdf` and `/Users/your-name/Documents/LocalOCR-Test/two.pdf`.”

See [the complete MCP tool schema](docs/mcp.md) for parameters and results.
