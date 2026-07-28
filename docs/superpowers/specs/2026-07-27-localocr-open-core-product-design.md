# LocalOCR Open-Core Product Design

**Date:** 2026-07-27  
**Status:** Approved design  
**Working name:** LocalOCR Studio

## Product Summary

LocalOCR Studio is a privacy-first macOS document utility that turns scanned
PDFs and images into searchable PDFs and AI-readable text entirely on the
user's Mac. It serves two audiences:

1. Mac users who need private, dependable OCR without uploading documents.
2. Developers and AI-agent users who need a local OCR engine exposed through
   a CLI or Model Context Protocol (MCP) server.

The core promise is:

> Turn private scanned documents into searchable, AI-readable files entirely
> on your Mac.

Document contents, OCR text, filenames, thumbnails, and content hashes never
leave the Mac. Optional update checks and opt-in crash reporting may use the
network, but their payloads must not include document-derived data.

## Product Model

LocalOCR uses an open-core model.

### Open-source core

- Shared native Swift OCR engine
- Command-line interface
- Standalone MCP server for any compatible client
- Basic Mac app capabilities:
  - Add PDFs and macOS-decodable image files
  - Inspect PDF text layers
  - Run OCR
  - Export plain text
  - Create searchable PDFs
  - View completed results and reveal them in Finder

### Commercial workflow layer

- Persistent and large batch queues with enhanced retry controls
- Watched folders
- Reusable processing presets
- One-click Codex and Claude connection management
- Automatic application updates
- Priority support

The free experience must remain independently useful. Paid features sell
workflow automation, convenience, and support rather than OCR accuracy or
privacy.

## Version-One Experience

The app is a persistent local OCR workflow studio rather than a single
conversion dialog.

### Navigation

- **Inbox:** Documents waiting, processing, paused, or requiring attention
- **Completed:** Successfully generated outputs
- **History:** Local record of prior jobs and their outcomes
- **Watched Folders:** Paid automation feature
- **MCP Connections:** Paid connection manager for Codex and Claude
- **Settings:** Storage, cache, recognition, update, privacy, and license
  controls

### Primary workflow

1. The user drops files anywhere in the window or chooses them with an open
   panel.
2. The app adds the documents to the Inbox and inspects them locally.
3. For PDFs, the app reports total pages and which pages already contain
   usable native text.
4. The user chooses searchable PDF, plain text, or both, plus destination and
   optional recognition settings.
5. The app processes the queue with per-file and per-page progress.
6. Results move to Completed, where the user can preview metadata, reveal the
   output in Finder, copy text, or process again with different settings.
7. Partial or failed results remain visible with specific recovery actions.

The default settings should work without explanation: automatic recognition
languages, 250 DPI PDF rendering, skip pages with usable native text, write
outputs beside originals, and never overwrite originals.

## Supported Inputs and Outputs

### Inputs

- PDFs
- Image types macOS can decode and Apple Vision can recognize, including
  common PNG, JPEG, TIFF, and HEIC inputs

Unsupported inputs fail with a clear message. Version one does not add
third-party format converters, camera capture, clipboard monitoring, or a
cloud OCR fallback.

### Outputs

- UTF-8 plain text with page boundaries
- Searchable PDF that preserves original page appearance and adds an invisible
  recognized-text layer
- Structured MCP responses containing page text, method, failures, empty
  pages, orientation, and optional line geometry and confidence

Original input files are immutable. Every transformed document is written as
a new output file.

## Architecture

The Python/PyObjC implementation is the behavioral reference during migration.
The production architecture is native Swift with one shared engine and thin
interfaces.

```text
SwiftUI Mac App ──────┐
CLI ──────────────────┼── LocalOCR Engine ── Apple Vision
MCP Server ───────────┘         │             PDFKit/Core Graphics
                               └── Local cache and job metadata
```

### LocalOCR Engine

An open-source Swift package owns all document-processing behavior:

- Input validation and file-type detection
- PDF inspection and native-text detection
- Page selection and range parsing
- PDF page rasterization
- Apple Vision text recognition
- Rotation handling and recognition-language hints
- Per-line text, confidence, and normalized geometry
- Searchable-PDF text overlay generation
- Content-addressed caching
- Progress, cancellation, and resumability
- Structured errors and partial results

The engine must not depend on app UI, licensing, MCP, or client-configuration
code.

### SwiftUI Mac App

The sandboxed app owns:

- Library, Inbox, Completed, and History presentation
- Queue scheduling and persistence
- Security-scoped file-access bookmarks
- Output and recognition settings
- Watched folders and presets
- Cache and history controls
- Licensing and paid-feature gating
- Update and opt-in crash-reporting preferences
- Connection Manager presentation and explicit approvals

### MCP Server

The open-source MCP executable uses stdio transport and calls the shared
engine. Its initial tool surface retains the existing behavior:

- `get_pdf_page_count`
- `inspect_pdf`
- `ocr_pdf`
- `ocr_pdf_batch`
- `ocr_image`
- `make_searchable_pdf`

Tool schemas may gain additive fields, but version-one migration must not
silently change existing parameter meaning or result semantics.

### CLI

The open-source CLI supports inspection, PDF OCR, image OCR, detailed
line-level output, searchable-PDF creation, page selection, forced OCR, and
cache bypass. It is both a user tool and a diagnostic surface for testing the
shared engine independently of the app and MCP server.

### Connection Manager

The paid app detects supported local installations of Codex and Claude.
Before changing configuration, it shows:

- The detected client and configuration path
- The exact server command and arguments
- Whether the operation adds, updates, or removes a connection
- A preview of the configuration change

Configuration is only written after explicit user approval. Other MCP clients
receive documented manual configuration instructions in version one.

## Processing and Data Flow

1. **Authorize:** The app obtains file access and stores a security-scoped
   bookmark when a job must survive an app restart.
2. **Identify:** The engine validates the input and records stable local
   metadata.
3. **Inspect:** PDFs are checked page-by-page for usable native text before
   OCR begins.
4. **Plan:** Only selected pages lacking usable text are scheduled unless
   force-OCR is enabled.
5. **Recognize:** Pages are rasterized and recognized incrementally with
   bounded memory. Native-text pages pass through unchanged.
6. **Cache:** Page results are keyed by content hash, page, relevant engine
   settings, and the macOS/Vision compatibility version.
7. **Assemble:** Text output or an invisible searchable-PDF overlay is built.
8. **Validate:** The output is reopened and checked before completion.
9. **Commit:** A temporary output is atomically moved to the chosen
   destination.
10. **Record:** Local job metadata is updated and the result appears in
    Completed or as a partial failure requiring attention.

Users can pause or cancel work. Restarted jobs resume from valid cached page
results rather than repeating completed OCR.

## Local Data and Privacy

The app stores job metadata, bookmarks, preferences, and caches under its
macOS application container or Application Support directory. Users can clear
OCR caches separately from history and can clear all local application data
from Settings.

Network code must be isolated from document-processing code. Update checks,
licensing, and opt-in crash reports must operate on an explicit allowlist of
fields. Document paths, filenames, text, images, thumbnails, page counts,
hashes, and recognition settings are excluded.

No analytics are required for version one. If analytics are considered later,
they require a separate privacy design and must remain opt-in.

## Error Handling

- A corrupt file or page does not stop unrelated queue items.
- Page-level failures preserve completed page results.
- Unsupported formats, lost file access, insufficient disk space, invalid
  destinations, malformed page ranges, and output validation failures use
  distinct human-readable errors.
- Low-confidence OCR is a warning, not a silent success or automatic failure.
- A searchable PDF containing failed pages is labeled incomplete.
- Interrupted jobs can resume from valid cache entries.
- The MCP server returns structured errors and partial results without
  terminating the process.
- Temporary files are cleaned up after handled failures and on the next launch
  after an unexpected termination.
- Users can retry a file, retry failed pages, choose another destination, or
  reveal the source in Finder when those actions apply.

## Quality and Testing

The existing Python tests and real-world observations define the migration
baseline. The Swift port adds:

- Unit tests for page ranges, output naming, cache keys, native-text
  thresholds, rotation decisions, language settings, and error mapping
- Integration tests for searchable PDFs, image-only PDFs, mixed PDFs, common
  image types, corrupt pages, partial results, output validation, cancellation,
  and resume
- Contract tests for every MCP tool and CLI command
- Queue-persistence and security-scoped bookmark tests for the Mac app
- Comparison tests that run representative fixtures through Python and Swift
  during migration
- Accuracy and performance benchmarks using synthetic, public, or explicitly
  donated fixtures only
- Clean-machine installation, sandbox, code-signing, notarization, and update
  tests before public release

OCR numbers and currency symbols must be treated as recognition results rather
than authoritative financial data. The product warns about low confidence and
does not promise penny-level numeric accuracy.

## Migration Strategy

Migration proceeds capability-by-capability while the Python implementation
remains runnable:

1. Freeze existing MCP behavior with contract tests and fixtures.
2. Implement the shared Swift engine's inspection and range parsing.
3. Add image and PDF recognition with rotation and cache behavior.
4. Add searchable-PDF generation and validate output fidelity.
5. Add the Swift CLI and run Python-versus-Swift comparisons.
6. Add the MCP executable and pass contract tests.
7. Build the free workflow-studio app around the proven engine.
8. Add paid watched-folder, preset, and connection-manager features.
9. Validate signing, notarization, installation, privacy boundaries, and
   performance before public distribution.

The Python implementation is retired only after the Swift CLI and MCP server
meet the behavioral baseline. It remains tagged in version control as a
reference release.

## Version-One Non-Goals

- Windows or Linux support
- Cloud OCR or cloud document storage
- Collaborative libraries or account synchronization
- Document editing beyond adding an invisible searchable text layer
- Handwriting-specific accuracy guarantees
- Table reconstruction or semantic document parsing
- Mobile apps
- Broad automatic configuration for every MCP client
- Automatic overwrite of source files
- Usage analytics

## Success Criteria

Version one is ready for external users when:

- A new user can install the signed/notarized app and create a searchable PDF
  without installing Python, Homebrew, or command-line dependencies.
- Files and document-derived data remain local under automated privacy tests
  and code review.
- Codex and Claude can call the installed MCP server after an explicit,
  previewed connection flow.
- All current MCP capabilities have Swift equivalents with passing contract
  tests.
- Interrupted multi-file jobs resume without reprocessing valid cached pages.
- Partial failures are visible and recoverable.
- The free tier is useful without payment, while paid automation features are
  clearly differentiated.

