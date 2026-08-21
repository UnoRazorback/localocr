# LocalOCR Studio Desktop Batch Beta 2 Design

**Date:** 2026-08-21
**Status:** Owner-approved design
**Target:** LocalOCR Studio `0.3.0-beta.1`, build `2`

## Purpose

Add desktop batch processing to LocalOCR Studio without weakening the existing
single-document workflow, local-only privacy boundary, or stable CLI and MCP
contracts. Beta 2 accepts individual files and recursively scanned folders,
processes supported documents sequentially, and writes validated results to a
chosen output folder while preserving the input folder structure.

This release does not wait for substantial Beta 1 feedback. Beta evidence remains
an input to product decisions rather than a gate that prevents continued work.

## Product Roadmap Boundary

The approved feature order is:

1. Beta 2: desktop batch processing.
2. Beta 3: guided OCR workflow and options.
3. Beta 4: in-app MCP installation, configuration, and diagnostics.

Beta 2 does not pull guided settings, persistent history, or MCP onboarding
forward from the later releases.

## Compatibility and Privacy

- Apple silicon only.
- Deployment target macOS 14.0 or later.
- All document access, OCR, file paths, recognized text, and output writing stay
  on the Mac.
- No telemetry, accounts, cloud processing, HTTP listener, or network transport.
- Original inputs are immutable and outputs are separate.
- The existing CLI and stdio MCP interfaces retain their current contracts.
- The release is built with stable Xcode. Exact Xcode, Swift, macOS, and beta-build
  provenance is captured from the actual release and acceptance machines.

## User Experience

### Entry and navigation

The current one-document drop/open screen remains the default and keeps its
existing behavior. It gains a secondary **New Batch…** action that opens a
dedicated batch workspace. Before processing begins, the user can return to the
single-document start screen without changing any source or destination file.

### Batch preparation

The workspace provides:

- **Add Files** for one or more supported files;
- **Add Folder** for recursive folder discovery;
- drag-and-drop for files, folders, or a mixture of both;
- a queue showing filename, relative path, detected type, and preparation state;
- a required **Choose Output Folder** action;
- a review summary listing supported, skipped, and duplicate inputs; and
- an explicit **Start Batch** action.

Processing does not start automatically. **Start Batch** remains disabled until
the input snapshot is valid and an allowed output folder has been selected.

### Processing and completion

The queue displays `queued`, `processing`, `completed`, `skipped`, `failed`, and
`cancelled` states. Exactly one item may be processing at a time.

The completion screen shows completed, skipped, failed, and cancelled counts plus
per-file result or error details. It provides:

- **Retry Failed**;
- **Reveal Output Folder**; and
- **Start New Batch**.

The batch session is not stored after the app closes. Persistent history remains
out of scope.

## Input Discovery

`BatchInputEnumerator` creates one immutable queue snapshot before processing.
It accepts PDFs and the image formats macOS exposes through ImageIO and Vision.

Discovery rules are:

- recursively enumerate selected folders;
- accept directly selected supported files;
- deduplicate the same standardized source reached through multiple selections;
- do not follow symbolic links;
- do not descend into application bundles or other file packages;
- skip hidden and system metadata files;
- preserve every skipped item with a reason suitable for display; and
- perform no output writes during discovery or review.

Directly selected files map to the output-folder root. Each selected folder maps
to a top-level output folder bearing its source-folder name. Equal top-level names
receive collision-safe numeric suffixes. Internal relative paths remain intact.

The chosen output folder must be outside every selected input folder. An equal or
nested destination is rejected before **Start Batch** becomes available. This
prevents generated results from becoming inputs on later recursive runs.

## Output Planning

`BatchOutputPlanner` plans and reserves every destination before processing.

- A PDF produces `<stem>_searchable.pdf`.
- An image produces `<stem>.txt` containing recognized text as UTF-8.
- A PDF does not automatically produce a text sidecar in Beta 2.
- Existing files are never overwritten.
- A collision produces the first free numbered name, for example
  `scan_searchable_2.pdf` or `photo_2.txt`.
- Planned destinations must remain confined beneath the chosen output folder,
  including after standardized-path and symbolic-link resolution checks.

Each output is written to a temporary file in the destination filesystem,
validated, and then committed to its reserved final path. A failed or cancelled
item must not expose a partial file as a completed result.

## Architecture

### BatchInputEnumerator

Owns filesystem discovery and normalization. It returns accepted candidates,
skipped entries, duplicate information, and a stable relative-output identity.
It does not run OCR or write outputs.

### BatchOutputPlanner

Transforms the immutable input snapshot and selected output root into confined,
collision-safe output reservations. It owns naming and relative-folder mapping,
but not OCR execution.

### StudioBatchCoordinator

Owns the queue state machine and sequential execution. It calls the existing
native `StudioOCRClient` directly and never launches the CLI or MCP helper. It
publishes state changes on the main actor while OCR and filesystem operations run
off the UI thread.

For a PDF, the coordinator uses the existing inspection and OCR behavior, then
creates a searchable PDF at the reserved destination. For an image, it uses the
existing recognition behavior and writes the recognized text through an atomic
text-output abstraction.

### BatchWorkspaceView

Renders preparation, review, processing, and completion states. It delegates
discovery, planning, and execution to the focused components above rather than
embedding filesystem or OCR behavior in SwiftUI views.

### Queue item model

Each item records:

- stable item identifier;
- source URL and standardized identity;
- source kind;
- relative input path;
- planned output URL when accepted;
- current batch state;
- current OCR progress when processing;
- committed result URL when completed; and
- structured, privacy-safe error details when skipped or failed.

## Execution, Cancellation, and Retry

Execution is strictly sequential. The coordinator must prove that maximum active
OCR concurrency is exactly one.

One item failure does not stop later items. Unsupported or unsafe inputs remain
visible as skipped rather than disappearing from the queue.

When the user cancels:

- the active task receives cancellation;
- any uncommitted temporary output is removed;
- untouched queued items become cancelled;
- already committed outputs remain completed and valid; and
- the UI does not report cancellation as successful completion.

**Retry Failed** retries only items in the failed state. If the earlier attempt
did not commit an output, the item may reuse its reservation. If an external file
now occupies that path, the planner reserves a new numbered destination. Skipped,
cancelled, and completed items are not retried by this action.

## Error Presentation and Diagnostics

Each row shows a concise actionable explanation. Full local diagnostic details
may be copied by the user, but they must not contain document contents or
recognized text. Paths are displayed only in the local UI and are never sent or
logged remotely.

Errors distinguish at least:

- unsupported format;
- symbolic link or package skipped;
- unreadable or inaccessible source;
- invalid or unsafe output destination;
- OCR or PDF-generation failure;
- output validation or commit failure; and
- cancellation.

## Accessibility

All controls, queue rows, status changes, progress, error details, and summary
counts receive stable accessibility labels and identifiers. Status is not
communicated by color alone. Keyboard users can add inputs, choose a destination,
start or cancel processing, inspect failures, reveal outputs, retry, and begin a
new batch.

## Testing

### Unit and integration tests

- Recursive enumeration of supported PDFs and Vision-compatible images.
- Direct-file and folder combinations.
- Standardized-path deduplication.
- Hidden files, packages, symbolic links, unreadable paths, and unsupported files.
- Rejection of equal or nested output folders.
- Preserved relative paths and numbered top-level-folder collisions.
- Searchable-PDF and text-output naming, confinement, and numbered collisions.
- Temporary-output cleanup and atomic commit behavior.
- Strict sequential execution with a measured maximum concurrency of one.
- Continue-after-failure behavior.
- Cancellation before, during, and between items.
- Retry-failed reservation reuse and external-collision recovery.

### UI and regression tests

- Enter and leave the batch workspace without affecting single-document behavior.
- Add files, add a recursive folder, and use mixed drag-and-drop.
- Review supported, skipped, and duplicate inputs before start.
- Require a safe output folder and explicit **Start Batch**.
- Observe sequential progress and per-row terminal states.
- Cancel, retry failed items, reveal the output folder, and start a new batch.
- Preserve the complete existing single-document PDF and image workflow.

### Release verification

Before publication, run the complete Swift, Python compatibility, CLI, MCP,
artifact, dependency, RPATH, signature, notarization, stapling, Gatekeeper, and
downloaded-package acceptance suites. Test the exact downloaded artifact on the
build Mac and a second Mac. Record all results from dated evidence and do not
infer tester uptake from downloads or owner installations.

## Out of Scope

- Parallel or adaptive processing.
- Automatic processing immediately after selection.
- Overwriting existing outputs.
- Output folders inside selected input folders.
- PDF text sidecars by default.
- Persistent batch or document history.
- Editable OCR text.
- Guided OCR settings or language selection.
- In-app MCP installation, configuration, or diagnostics.
- Automatic updates.
- Intel Mac, Windows, or Linux support.
- Telemetry, accounts, or cloud processing.

## Acceptance Criteria

Beta 2 is implementation-complete only when:

1. The existing one-document flow remains operational and is the default.
2. Files and recursively scanned folders form one immutable, reviewable queue.
3. Output-folder safety, relative structure, and collision-safe naming pass.
4. Exactly one document processes at a time.
5. PDFs produce searchable PDFs and images produce text files using existing
   native behavior.
6. Failure, cancellation, retry, and atomic-output guarantees pass automated and
   UI acceptance.
7. CLI and MCP compatibility suites remain green without contract changes.
8. Privacy and accessibility requirements pass.
9. The exact signed and notarized downloaded artifact passes on two Macs.
10. Publication remains a separate owner-authorized action.
