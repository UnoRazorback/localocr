# LocalOCR macOS Visual Extension

## Status

Approved extension of the 2026-08-24 LocalOCR iPhone/iPad visual system.

## Shared identity

- Use the same Corner mark, bone/olive/ink palette, dark appearance, ruled-paper motif, semantic status colors, and `On device` privacy language as iOS.
- Keep native macOS typography, focus rings, menus, keyboard shortcuts, window resizing, drag and drop, and accessibility behavior.
- Do not transplant the iPhone tab layout or camera-oriented hierarchy to macOS.

## Desktop structure

- Preserve single-document and batch modes and every existing engine/CLI/MCP boundary.
- Present a desktop-native workspace with a clear header/toolbar, source or queue context, central document/progress/result content, and persistent local-processing provenance.
- Empty state emphasizes drag and drop plus Open Document and New Batch.
- Processing exposes document name, deterministic progress, and Cancel.
- Results preserve Copy Text, Save Text, Create Searchable PDF, and Process Another Document.
- Batch retains file/folder intake, output selection, review, progress, retry, reveal, diagnostics, and cancellation.

## Privacy and accessibility

- `On device` is status text, never a button.
- No document content, OCR text, filenames, hashes, or document-derived diagnostics are added to decorative caches, telemetry, or remote resources.
- Use semantic colors, 44 pt-equivalent comfortable targets where appropriate, keyboard focus, VoiceOver labels, Increase Contrast, Reduce Motion, and dark appearance.
- Preserve current content-free diagnostics and error presentation.
