# LocalOCR Studio Beta 1 Design

## Purpose

LocalOCR Studio Beta 1 gives nontechnical Mac users a native, privacy-first
desktop interface for processing one document at a time. It packages the
existing native CLI and MCP server in the same signed application so terminal
and MCP users retain the full LocalOCR tool surface, including batch PDF OCR.

The desktop app is intentionally narrower than the MCP server. Beta 1 focuses
on a dependable single-document workflow; guided options, recent-document
history, batch UI, and MCP setup screens are deferred until tester feedback
justifies them.

## Approved product boundary

- Desktop app: one PDF or image at a time.
- MCP server: all existing six tools, including batch PDF processing.
- Automatic smart processing after a file is opened or dropped.
- No guided wizard in Beta 1.
- No recent-document list or stored result history.
- Recognized text is read-only.
- Searchable PDF output uses a Save As dialog and never overwrites the source.
- The original document remains unchanged.
- OCR and document handling stay local to the Mac.

## Release metadata

- Product name: `LocalOCR Studio`
- Bundle identifier: `com.rayconsulting.localocr`
- Marketing version: `0.2.0`
- Build number: `1`
- Minimum system: macOS 14
- Supported architecture: Apple silicon (`arm64`)

These values must match the direct-release environment inputs and the built
application's `Info.plist`. A mismatch blocks staging, signing, notarization,
and downloaded-copy acceptance.

## Architecture

The repository gains a native macOS SwiftUI app target named
`LocalOCR Studio`. The target links the existing `LocalOCRService` library and
calls it directly. The GUI does not launch the CLI or MCP server as a
subprocess.

The distribution app embeds these existing executables:

```text
LocalOCR Studio.app/
  Contents/
    MacOS/
      LocalOCR Studio
    Helpers/
      localocr
      localocr-mcp
```

The desktop app, CLI, and MCP server share the same native OCR engine and
response behavior. The MCP server remains a local stdio server with the
existing six-tool contract. MCP clients may be configured to execute
`LocalOCR Studio.app/Contents/Helpers/localocr-mcp`.

The app makes no network requests. No cloud OCR, HTTP server, analytics,
telemetry, account system, or automatic update mechanism is included in
Beta 1.

## User experience

The approved layout is **Focused Canvas**. It presents one obvious document
drop zone and an Open button. After processing, it shows a compact document
summary beside a large recognized-text result.

The interface has four primary states:

1. **Empty:** Drop zone, Open button, supported-file guidance, and
   “Processed locally on this Mac.”
2. **Processing:** Filename, determinate page progress when available,
   cancellation, and a clear local-processing message.
3. **Result:** Document summary, read-only text, and the actions Copy,
   Save Text, and Create Searchable PDF.
4. **Error:** Plain-language message, optional technical details, Retry, and
   Choose Another Document.

Opening or dropping another document cancels current work before starting the
new request. Closing the document or quitting clears the visible result.

## Input and processing behavior

The desktop app accepts:

- PDF documents supported by PDFKit.
- Image formats decoded by ImageIO and supported by the existing native image
  OCR service.

For a PDF, the app first inspects the existing text layer. Pages with usable
native text retain it; only pages that need OCR are sent to Apple Vision.
Results appear in page order with visible page separators. For an image, the
app runs the existing native image OCR path directly.

The default OCR settings use the service's production defaults. Beta 1 does
not expose language, DPI, page-range, force-OCR, or orientation controls in
the GUI. Those options remain available through the CLI and MCP interfaces.

## Result actions

### Copy

Copies the exact read-only recognized text to the macOS pasteboard.

### Save Text

Opens a Save dialog with a suggested name based on the source filename and a
`.txt` extension. Text is written as UTF-8. An existing file is replaced only
after the user confirms through the standard macOS dialog.

### Create Searchable PDF

Available only for PDF inputs. It opens a Save As dialog suggesting
`<original>_searchable.pdf`. The operation uses the existing searchable-PDF
service and writes a separate file. The source file is never overwritten.

For image inputs, the searchable-PDF action is unavailable in Beta 1; Copy and
Save Text remain available.

## Privacy and local state

- Documents, recognized text, paths, and cache entries remain on the Mac.
- The app stores no document history and no persistent recognized-text
  results.
- The existing OCR cache may be used to accelerate repeat processing and is
  restricted to the current macOS user.
- The app includes no telemetry or analytics SDK.
- User-facing evidence never records document content or document paths.
- The app and both helpers must contain no `get-task-allow` entitlement in the
  distribution build.

## Errors and cancellation

Service and filesystem failures are mapped to plain-language categories:

- unsupported file type;
- missing or unreadable document;
- permission denied;
- invalid or damaged PDF/image;
- OCR failure;
- cancellation;
- invalid or existing output destination; and
- searchable-PDF creation failure.

The main message remains concise. A disclosure section may show sanitized
technical details for beta troubleshooting. It must not expose credentials,
unrelated local paths, or document content.

Cancellation is cooperative. A new document, explicit Cancel action, or
window closure cancels active work and prevents stale results from replacing
newer state.

## App build and distribution

A stable-Xcode macOS app project produces an unsigned Release app for the
existing direct-distribution pipeline. The pipeline:

1. Validates bundle identifier, version, and build.
2. Rebuilds and embeds `localocr` and `localocr-mcp`.
3. Rejects unexpected code, unsafe dependencies, RPATHs, strings, metadata,
   entitlements, and path/symlink escapes.
4. Signs both helpers first and the containing app last with Developer ID,
   Hardened Runtime, and secure timestamps.
5. Verifies each signature and then performs strict deep verification.
6. Submits to Apple notarization, requires `Accepted`, staples the ticket,
   validates it, and requires Gatekeeper acceptance.
7. Creates the final ZIP and SHA-256 only after all earlier gates pass.
8. Verifies a freshly extracted and subsequently downloaded copy.

The app target must not add a dependency or RPATH outside the existing
Apple/system-only release policy.

## Testing

### Unit and state tests

- Accepted and rejected file types.
- PDF inspection chooses existing text versus OCR correctly.
- Image input uses the image OCR service.
- Page-ordered read-only result formatting.
- Progress updates and cancellation.
- Stale-result suppression when a second document is opened.
- Plain-language mapping for every supported error category.
- Copy and UTF-8 text export.
- Searchable-PDF availability only for PDFs.
- Suggested output names and no source overwrite.
- Visible-result clearing without persistent document history.

### Integration tests

- Open and drag-and-drop paths produce the same request.
- PDF with native text, image-only PDF, mixed PDF, rotated OCR fixture, and
  ImageIO-decodable image.
- Searchable output preserves source bytes and page appearance.
- App bundle metadata matches the approved release inputs.
- Release build contains only the expected app executable and two helpers.

### UI smoke tests

- Empty, processing, result, and error states render.
- Copy, Save Text, Create Searchable PDF, Retry, Cancel, and Choose Another
  Document enable only when appropriate.
- Keyboard and VoiceOver labels exist for the drop zone and primary actions.

### Release acceptance

- Full Swift, Python, artifact, and direct-release suites pass.
- A downloaded candidate passes the automated verifier on the build Mac and a
  second Mac.
- Manual acceptance covers one native-text PDF, one image-only PDF, one
  supported image, and searchable-PDF creation.
- Original input hashes remain unchanged.

## Deferred work

- Guided OCR options wizard.
- Desktop batch processing.
- Recent-document or result history.
- Editable OCR text.
- In-app MCP installation, configuration, or diagnostics.
- Automatic updates.
- Intel Mac, Windows, or Linux support.
- Telemetry, accounts, or cloud processing.

## Success criteria

Beta 1 is ready for separately authorized private publication only when:

- the approved app behavior is implemented and reviewed;
- the exact release commit is clean and pushed;
- all automated suites pass;
- the containing app and both helpers pass real Developer ID, Hardened
  Runtime, notarization, stapling, Gatekeeper, dependency, RPATH, entitlement,
  and checksum gates;
- a freshly downloaded copy passes on the build Mac and a second Mac; and
- the owner explicitly authorizes publication.
