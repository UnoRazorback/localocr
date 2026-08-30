# LocalOCR Studio Beta 2.1 Tester Guide

The Beta 2.1 release candidate is version `0.3.1`, build `4`, with planned tag
`v0.3.1-beta.1`. It includes the simple one-document desktop flow, an opt-in
reviewed desktop batch, offline Help, Local Intelligence, guided Codex and
Claude connection, and all three native helpers. Do not distribute or install
it as a Beta 2.1 release until signing, notarization, downloaded-package, and
target-Mac acceptance evidence is complete.

## Download and install

After publication, download `LocalOCR-Studio-0.3.1-4.zip` and
`LocalOCR-Studio-0.3.1-4.sha256` from the `v0.3.1-beta.1` prerelease into the
same directory. Verify the download before expanding it:

```bash
shasum -a 256 -c "LocalOCR-Studio-0.3.1-4.sha256"
```

The command must report `OK`. Expand the verified ZIP, move `LocalOCR Studio.app` to `/Applications`, then open it normally. Do not bypass Gatekeeper, remove quarantine attributes, or use an unverified build or staging copy.

## What the desktop app does

Use **Open** or drag and drop to process one document at a time. LocalOCR Studio recognizes text in PDFs and supported images (including PNG, JPEG, TIFF, and HEIC/HEIF where ImageIO supports them) with local Apple Vision and PDFKit. Existing usable PDF text is preserved while pages that need OCR are recognized.

After processing, you can Copy recognized text, Save Text as a plain-text file, or Create Searchable PDF at a new destination. The source document remains unchanged. Select **Process Another Document** to return immediately to the drop/open screen without relaunching.

## Desktop batch workflow

The default remains one document at a time. Select **New
Batch** to add files or folders, choose an output folder, and review the queue
before selecting **Start Batch**. Folders are scanned recursively for supported
PDFs and images. Processing is sequential. PDFs create new searchable PDFs;
images create `.txt` files containing recognized text. Original sources remain
unchanged, and existing output names are never overwritten: a numbered name is
chosen instead.

You can cancel a running batch, retry only failed items after it completes,
reveal the chosen output folder, or select **Start New Batch** to clear the queue.
The published batch uses the same local-only processing boundary as the
single-document flow.

## Local Intelligence and agent connection

Beta 2.1 adds three optional Local Intelligence actions to
the single-document result: summarize, suggest a name/category/tags, and
extract `date`, `total`, and `reference_number`. Results are temporary and
non-destructive, while Batch remains OCR-only.

Apple Foundation Models requires macOS 26 or later, an eligible Mac, Apple
Intelligence enabled, its on-device model ready, and a supported Apple
Intelligence language. Eligible users may instead select a discovered Ollama
or LM Studio model running on verified IPv4 or IPv6 loopback. LocalOCR refuses
remote, relayed, wildcard, and locality-ambiguous endpoints and never silently
switches providers. Before document text is sent to an external local runtime,
the user must read and accept the acknowledgment. LocalOCR uses no Private
Cloud Compute and has no cloud fallback.

Help is built into the app and works offline. The connection guide detects
supported Codex and Claude installations, shows the exact change, and asks for
confirmation before updating that client's local MCP configuration. Generic
MCP clients receive copy-only stdio instructions; LocalOCR does not guess at or
edit an unknown client's configuration.

Development compilation and automated verification use
stable Xcode 26.6 (`17F113`), Swift 6.3.3, and the macOS 26.5 SDK while keeping
the package/app deployment target at macOS 14. This does not replace physical
provider, downloaded-package, or target-Mac acceptance; those release gates
remain open until dated evidence is recorded.

## Five-minute desktop test

Use non-sensitive sample documents and complete these eight steps:

1. Open one PDF and confirm useful recognized text.
2. Create a searchable PDF at a new destination and confirm the original was not replaced.
3. Select **Process Another Document** and confirm the drop/open screen returns without relaunching.
4. Open one supported image and confirm recognized text.
5. Copy or save the text.
6. Select **New Batch**, add at least two supported files or a folder, and choose an output folder.
7. Review supported and skipped items, select **Start Batch**, and confirm the queue processes sequentially without changing the sources.
8. Confirm the new outputs, then select **Start New Batch** and quit and reopen the app normally.

## Privacy

Recognition uses Apple Vision and PDFKit locally. LocalOCR does not upload documents, recognized text, filenames, paths, thumbnails, hashes, cache entries, or outputs. It provides no cloud OCR, cloud storage, HTTP MCP listener, or network MCP service. Local cache entries may be written at `~/Library/Caches/com.rayconsulting.localocr/ocr-v1`; there is no history of documents or results. If you separately connect an MCP client, that client or its AI provider may transmit paths, text, and tool results outside your Mac; local stdio is not a provider privacy guarantee.

## Compatibility and candidate provenance

The Beta 2.1 candidate uses stable Xcode 26.6 (`17F113`), Swift 6, arm64, and
deployment target macOS 14.0. Final Developer ID, Hardened Runtime,
notarization, staple, Gatekeeper, download, and exact-build target-Mac facts
will be added only from completed release evidence.

Candidate provenance: version `0.3.1`, build `4`, planned tag
`v0.3.1-beta.1`. The exact release commit and verified ZIP SHA-256 are pending
the immutable release build.

Future Apple beta compatibility is not guaranteed. Report the exact macOS
version and build number with any problem.

## Known limitations

- Apple silicon only; macOS 14 or later is required.
- No Intel, Windows, or Linux support.
- The default desktop workflow is one document at a time. The opt-in batch has
  no run history or language/settings wizard.
- MCP uses local stdio. Guided configuration supports detected Codex and Claude
  installations; other clients use copy-only instructions.
- Beta output behavior may change; retain your original documents.

## Report feedback

Use the repository [beta feedback form](https://github.com/UnoRazorback/localocr/issues/new/choose), backed by [`.github/ISSUE_TEMPLATE/beta-feedback.yml`](.github/ISSUE_TEMPLATE/beta-feedback.yml). Please use non-sensitive samples for issue reproduction. Never attach confidential source documents or recognized text to a public or broadly shared channel.

---

## Advanced: MCP setup

This optional advanced path is separate from the desktop flow. Start with the
desktop app unless you need agent automation. Beta 2.1 has nine local stdio
tools and requires explicit external-data consent. Follow the
[canonical MCP FAQ](docs/mcp.md#advanced-setup)
for the complete disclosure, consent flow, tool parameters, source-build path,
generic stdio configuration, permissions, and troubleshooting.

For an app installed in `/Applications`, the bundled helper is:

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
claude mcp add --transport stdio --scope local localocr -- \
  "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp"
claude mcp list
```

Use `/mcp` in Claude Code to inspect status. Claude Code defaults to local
scope for the current project; add `--scope user` only when you intentionally
want LocalOCR available across projects. See the [Claude Code MCP
documentation](https://code.claude.com/docs/en/mcp).

### Other MCP clients

Use your client's current documentation to configure this generic stdio server; LocalOCR does not edit client configuration:

```json
{
  "command": "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp",
  "args": []
}
```

The nine Beta 2.1 tools are `get_pdf_page_count`, `inspect_pdf`, `ocr_pdf`,
`ocr_pdf_batch`, `ocr_image`, `make_searchable_pdf`, `summarize_document`,
`organize_document`, and `extract_document_fields`. The last three require an
available, explicitly selected, qualified Apple Foundation Models, Ollama, or
LM Studio provider; the six OCR/PDF tools remain available without one. All
nine require the external-data acknowledgment because the MCP
client or provider may handle their arguments and results. macOS and the MCP
client continue to enforce filesystem permissions. LocalOCR does not
automatically edit either client's configuration.

Safe example prompts, using fictional non-sensitive fixtures:

- “Use `ocr_pdf` for `/Users/your-name/Documents/LocalOCR-Test/sample.pdf`.”
- “Use `ocr_image` for `/Users/your-name/Documents/LocalOCR-Test/receipt.jpg`.”
- “Use `ocr_pdf_batch` for `/Users/your-name/Documents/LocalOCR-Test/one.pdf` and `/Users/your-name/Documents/LocalOCR-Test/two.pdf`.”
- “Use `summarize_document` for `/Users/your-name/Documents/LocalOCR-Test/letter.pdf` and return three factual bullets.”

Keep original documents and use non-sensitive fixtures for a first connection.
Codex, Claude Code, and other clients control their own configuration, account
privacy, retention, training, and provider behavior; consult their current
authoritative documentation before sharing sensitive material.
