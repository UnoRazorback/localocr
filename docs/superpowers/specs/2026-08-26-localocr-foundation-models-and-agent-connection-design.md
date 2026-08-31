# LocalOCR Local Intelligence and Agent Connection Design

**Date:** 2026-08-26
**Status:** Approved design; implementation not started
**Release boundary:** Post-`v0.3.0-beta.1` candidate

## Purpose

Add two related capabilities without weakening LocalOCR's local-first product
boundary:

1. Optional document intelligence powered by Apple's on-device Foundation
   Models framework in both LocalOCR Studio and the MCP server.
2. Clear, safe instructions for connecting the bundled MCP server to Codex,
   Claude Code, and other stdio MCP clients.

The desktop workflow remains the primary experience. MCP remains an advanced,
manual setup path. LocalOCR does not modify an agent's configuration.

## Non-negotiable product boundaries

- OCR and Local Intelligence processing are local to the Mac.
- LocalOCR makes no cloud request for OCR or Foundation Models work.
- There is no Private Cloud Compute fallback, third-party model, API key,
  bundled model, or network MCP transport.
- Foundation Models is optional. Every existing OCR, CLI, Studio, and MCP
  capability continues to work when it is unavailable.
- The macOS deployment target remains macOS 14.
- The published `v0.3.0-beta.1` release and its evidence are immutable.
- Local Intelligence is single-document only in Studio for this release.
  Desktop batch remains OCR/export only.
- Intelligence results are temporary. LocalOCR does not retain an intelligence
  history or silently alter source documents.
- Documents and OCR text are untrusted evidence, never instructions to the
  model or application.

## User experience

### LocalOCR Studio

After a single document finishes OCR, its result screen adds a **Local
Intelligence** section with three actions:

- **Summarize** produces a factual summary grounded in the document.
- **Suggest Name & Tags** proposes a title, a category, and up to five tags.
- **Extract Fields** returns editable values for date, total, and reference
  number by default.

The actions appear automatically when Apple's system model is available. The
user does not need to enable a separate LocalOCR setting. The source document
is never renamed, moved, or overwritten. Suggestions remain non-destructive
until the user copies or saves them outside the intelligence session.

Results belong to the currently processed document. They disappear when the
user processes another document or leaves the result state unless the user has
copied or saved them. There is no persistent prompt, response, or document-text
history.

Desktop Local Intelligence does not require the external-data acknowledgment
described below because it does not send content to an MCP client or external
provider.

### Availability states

On macOS 26 or later, LocalOCR maps
`SystemLanguageModel.default.availability` into plain-language states:

- **Available:** show the three actions.
- **Mac not eligible:** explain that this Mac cannot run Apple Intelligence.
- **Apple Intelligence off:** point the user to the relevant macOS setting.
- **Model preparing:** explain that macOS is still making the model ready and
  that the user can try again later.
- **Unsupported language:** explain that the current document language is not
  supported for this operation.

On macOS 14 through 25, the Local Intelligence section explains that macOS 26
or later and an Apple Intelligence-capable Mac are required. OCR remains fully
functional in every unavailable state.

The UI must not claim that LocalOCR downloaded, installed, enabled, or updated
Apple's model. Model eligibility and readiness belong to macOS.

### Help: Connect to Your Agent

Studio adds **Help > Connect to Your Agent**. This screen is an instructional
guide, not a connection manager. It contains:

1. A concise explanation of local stdio MCP and the external-provider risk.
2. The actual installed helper path, detected from the running app bundle.
3. Copyable Codex setup and verification commands.
4. Copyable Claude Code setup and verification commands.
5. Generic stdio JSON for other MCP clients.
6. The external-data acknowledgment and local consent controls.
7. A list of all nine tools and safe example prompts.
8. Troubleshooting for path, permission, consent, availability, and client
   configuration problems.

The detected path supports both `/Applications` and `~/Applications` and is
never represented by a hard-coded installation assumption. The screen may copy
commands to the clipboard but never runs them or edits Codex, Claude, or another
client's files.

The repository guide at `docs/mcp.md` mirrors the same explanation and command
shapes for standalone/open-core users. Documentation must identify which steps
belong to the MCP client and which belong to LocalOCR.

## Shared architecture

Add a `LocalOCRIntelligence` Swift package library between LocalOCR's surfaces
and Apple's Foundation Models framework:

```text
LocalOCR Studio ───────┐
                      ├── LocalOCRIntelligence ── FoundationModels
localocr-mcp ─────────┘             │
                                    └── grounded OCR text from LocalOCRService
```

`LocalOCRStudioKit` and `LocalOCRMCP` depend on this shared target. Neither
surface duplicates prompts, availability mapping, chunking, grounding,
structured-output decoding, or safety rules.

The target compiles with stable Xcode 26.6 and keeps the package deployment
target at macOS 14. All Foundation Models references are guarded with
`@available(macOS 26.0, *)`; the shipped binaries must remain launchable on
macOS 14 through 25. Release inspection must confirm that any framework linkage
is weak/availability-safe and does not introduce a non-system dependency.

### Core abstractions

The implementation should expose protocol-driven boundaries so most behavior
is testable without invoking the live system model:

- `DocumentIntelligenceProviding` defines summarize, organize, and extract
  operations.
- `SystemModelAvailabilityProviding` maps Apple availability to LocalOCR's
  stable domain states.
- `FoundationModelsIntelligenceProvider` is the macOS 26+ live adapter.
- `UnavailableIntelligenceProvider` returns stable errors on earlier systems.
- `DocumentChunker` creates deterministic, page-aware bounded input.
- `IntelligenceGroundingValidator` rejects unsupported or malformed output.
- `ExternalDataConsentStore` owns the content-free MCP consent receipt.

Studio and MCP receive these dependencies rather than constructing live model
sessions throughout presentation or transport code.

## Intelligence data flow

1. Validate that the input is a supported local PDF or image.
2. Use `LocalOCRService` to inspect or OCR it as needed.
3. Preserve page boundaries in the normalized text representation.
4. Select deterministic, bounded chunks for the requested operation.
5. Mark document text explicitly as untrusted quoted material.
6. Ask the system model for the narrow operation's structured result.
7. Validate the result against source evidence and the output schema.
8. Return a value or a stable structured error; never fall back to cloud work.

Raw PDF or image bytes are not passed to Foundation Models in this version.
The model receives only the OCR/text representation and minimal page metadata.

### Bounded context and long documents

Chunking is deterministic and page-aware. It uses explicit character/token
budgets and never silently truncates in the middle of a page without recording
that the page was split. Long documents use a bounded map/reduce flow:

- create grounded per-chunk intermediate results;
- combine only those results in a final bounded pass; and
- preserve source-page references internally for validation.

Cancellation stops pending work promptly and discards partial results unless a
tool's documented response explicitly represents a partial result. No model
session is kept after the operation completes.

## Operation contracts

### Summarize

Output is a concise factual summary. It must not add diagnoses, legal advice,
financial conclusions, intent, or other unsupported interpretation. Every
claim must be supportable from the supplied document text. If grounding cannot
be established, the operation fails instead of presenting invented content.

### Organize

Output contains only:

- suggested title;
- suggested category; and
- zero to five suggested tags.

The result is advisory. It never triggers a filesystem operation.

### Extract fields

The caller supplies a bounded list of field names. Studio defaults to `date`,
`total`, and `reference_number`. MCP callers may request other fields within
the documented count and name-length limits. Each result contains the requested
field name, an optional value, and optional page evidence. Unsupported or
absent fields return `null`; the model must not guess.

## MCP contract

The server retains its existing six tools and adds three focused tools:

- `summarize_document`
- `organize_document`
- `extract_document_fields`

Each new tool accepts one local PDF or image path. The server performs OCR when
needed, then runs the shared local intelligence operation. It does not accept a
free-form system prompt, expose model tool calling, browse the web, or permit
the model to choose an application action.

The tool catalog therefore contains nine tools:

1. `get_pdf_page_count`
2. `inspect_pdf`
3. `ocr_pdf`
4. `ocr_pdf_batch`
5. `ocr_image`
6. `make_searchable_pdf`
7. `summarize_document`
8. `organize_document`
9. `extract_document_fields`

The server may initialize and list tools before consent. Every document tool,
including the existing six, fails closed with the stable error
`external_data_acknowledgment_required` until the MCP external-data
acknowledgment is current.

Other stable intelligence errors include:

- `local_intelligence_requires_macos_26`
- `local_intelligence_device_not_eligible`
- `apple_intelligence_not_enabled`
- `local_intelligence_model_not_ready`
- `local_intelligence_language_not_supported`
- `local_intelligence_invalid_input`
- `local_intelligence_generation_failed`
- `local_intelligence_output_not_grounded`

Errors must explain that ordinary OCR remains available when the failure is
specific to Foundation Models.

## External-data acknowledgment

### Why the gate exists

LocalOCR's own work is local, but an MCP client or the provider behind an agent
may transmit filenames, paths, OCR text, summaries, extracted fields, tool
arguments, or tool results outside the Mac. LocalOCR cannot control that
provider's retention, training, logging, or data-handling policy.

The user must make an informed choice before any document tool can be invoked
through MCP.

### Disclosure

The in-app and interactive CLI flow present this statement:

> LocalOCR and Apple Foundation Models process documents locally on this Mac,
> and LocalOCR does not upload them. When you connect LocalOCR to an agent
> through MCP, that MCP client or its AI provider may send filenames, paths,
> document text, summaries, extracted fields, and tool results to an outside
> service. Transmission, retention, model training, and other handling are
> controlled by the agent and provider, not LocalOCR. Review their privacy and
> data policies, and only continue if you are authorized to share the data.

The user must affirm two unchecked statements:

1. **I understand that my MCP client or agent may transmit LocalOCR inputs and
   results to an outside provider.**
2. **I confirm that I am authorized to share this data and choose to enable
   LocalOCR MCP document tools.**

Consent is never implied by installing or launching LocalOCR, connecting a
client, or listing tools.

### Receipt and enforcement

Store a content-free receipt at a stable per-user Application Support location,
shared by the bundled app and standalone MCP executable. The receipt contains
only:

- receipt schema version;
- disclosure policy version;
- acceptance timestamp; and
- the two affirmative choices.

It contains no document path, prompt, OCR text, result, client identity, or
provider identity. Write it atomically with user-only permissions and reject a
symlinked, malformed, unknown-version, or outdated receipt.

The MCP dispatcher checks the receipt immediately before dispatching every
document tool. Missing, invalid, revoked, or outdated consent returns
`external_data_acknowledgment_required` without opening the document.

The Studio Help screen can revoke consent. Standalone/open-core users receive
an interactive `localocr mcp-consent` CLI flow with show, accept, and revoke
operations. Acceptance requires an interactive terminal; automation cannot
silently pass a flag to manufacture consent.

A material disclosure change increments the policy version and requires fresh
acceptance. Wording-only corrections that do not change meaning may retain the
current version and must be documented in the implementation review.

## Privacy and security controls

- Foundation Models input is limited to required OCR text and page markers.
- The live model receives an instruction to treat document content as quoted,
  untrusted data and to ignore embedded commands or requests.
- Prompt-injection fixtures cover instructions embedded in invoices, letters,
  forms, and OCR noise.
- There is no arbitrary-prompt MCP tool.
- There is no model tool calling, shell execution, filesystem action, web
  access, or client-configuration mutation.
- Logging contains operation type, availability state, timing, and content-free
  error categories only. It excludes paths, filenames, document text, prompts,
  generated output, and extracted values.
- Temporary intermediate text and generation results remain in memory and are
  released when an operation completes or is cancelled.
- Existing local cache behavior must not be expanded to intelligence prompts
  or results.

## Documentation requirements

`docs/mcp.md` becomes the canonical agent-connection FAQ and the in-app Help
screen presents an approachable subset. Both must cover:

- what MCP is and what remains local;
- the external-provider disclosure and consent requirement;
- locating the bundled helper under `/Applications` or `~/Applications`;
- Codex CLI connection, scope, inspection, and removal;
- Claude Code connection, scope, inspection, and removal;
- generic stdio JSON for other compatible clients;
- all nine tools and which three require Foundation Models;
- safe example prompts that name explicit local files and narrow tasks;
- permissions and path troubleshooting;
- Foundation Models eligibility/readiness troubleshooting; and
- how to revoke and re-accept MCP consent.

Commands must match current official client syntax at implementation and
release time. Client-specific behavior is documentation, not a LocalOCR
guarantee. The FAQ must not imply that Codex, Claude, or another provider keeps
data local merely because the LocalOCR helper uses stdio.

## Compatibility and release toolchain

- Minimum supported OS remains macOS 14 for OCR, Studio, CLI, and MCP.
- Local Intelligence requires macOS 26 or later and an eligible Apple
  Intelligence-capable Mac.
- Release builds use stable Xcode 26.6 (build 17F113), Swift 6.3.3, and the
  stable macOS SDK—not an Xcode beta.
- Compatibility acceptance covers both macOS 26 and macOS 27, including macOS
  27 betas used during development.
- Because Apple updates the system model through macOS, Local Intelligence
  smoke tests must be repeated on supported major OS updates even when LocalOCR
  code is unchanged.
- The CLI and MCP release binaries may depend only on Apple/system libraries.
  Absolute Xcode paths, Homebrew paths, repository paths, and private `/Users/`
  paths are forbidden.

Apple references:

- [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
- [Meet the Foundation Models framework](https://developer.apple.com/videos/play/wwdc2025/286/)
- [Foundation Models updates](https://developer.apple.com/documentation/Updates/FoundationModels)

## Testing strategy

### Unit and contract tests

- Fake-model tests for summarize, organize, and extract contracts.
- Availability mapping for eligible, ineligible, disabled, preparing,
  unsupported-OS, and unsupported-language states.
- Deterministic page-aware chunking at all boundaries.
- Cancellation before, during, and between model passes.
- Grounding validation, refusals, malformed structured output, and null fields.
- Prompt-injection fixtures proving document instructions are ignored.
- MCP catalog and schema tests for all nine tools.
- Existing six-tool compatibility tests remain unchanged except for the
  intentional pre-dispatch consent gate.
- Consent tests for absent, accepted, revoked, malformed, symlinked, outdated,
  and permission-invalid receipts.
- Tests prove consent rejection occurs before a document is opened.
- Content-free logging tests reject paths, OCR text, prompts, and results.

### Studio and documentation tests

- UI states for available and every unavailable reason.
- Single-document actions and temporary-result reset behavior.
- Batch UI remains unchanged and exposes no intelligence action.
- Organize suggestions never mutate a source file.
- Help screen uses the actual running app path.
- Codex, Claude Code, and generic snippets contain the resolved helper path.
- Disclosure text, both unchecked acknowledgments, revoke flow, and receipt
  status are present and accessible.
- Repository documentation matches the tool catalog, privacy boundary, and
  current client command syntax.

### Release acceptance

1. Run the complete Swift suite.
2. Generate debug and release native products, then run all Python/contract,
   CLI, MCP, Studio, and release-script suites.
3. Run one real Foundation Models smoke on an eligible Mac without mocks.
4. Test supported availability failures without weakening OCR behavior.
5. Build with stable Xcode 26.6 and record the exact version and SDK.
6. Inspect every shipped binary for dependencies, RPATHs, and private paths.
7. Sign nested helpers first and the containing app last with Developer ID
   Application team `DZ8B5454ZN` and Hardened Runtime.
8. Verify every signature, notarize with `notarytool`, staple, and verify with
   `spctl`.
9. Test the downloaded package on a second Mac, including MCP initialization,
   consent, one OCR tool, and eligible Local Intelligence where available.
10. Record macOS 26 and macOS 27 compatibility evidence separately.

No release is accepted from a locked-screen or otherwise contended UI-test
run. UI acceptance evidence must identify the console state and exact Xcode/OS
combination.

## Business and release records

At the implementation milestone and every later release milestone, update the
records under:

`/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/reports/mcp-macvision`

Use dated evidence only. Record direct and reasonably allocated costs without
inventing amounts. Reconcile provisional time rows when the milestone closes,
preserve final commit/test/signing/notarization/release evidence, and update the
project overview. When a beta is published, establish the download baseline
and begin the beta metrics and feedback logs.

## Alternatives considered

### Foundation Models only in Studio

Rejected because advanced users need the same bounded local intelligence from
agents, and duplicate implementations would drift.

### One generic intelligence MCP tool

Rejected because arbitrary prompts would weaken safety, make consent and
grounding harder to explain, and produce an unstable contract. Three narrow
tools are easier to test and safer to expose.

### Automatic agent configuration

Rejected for this release. Client configuration is external state with
client-specific scope and privacy implications. Copyable instructions preserve
user control.

### Consent only for the three intelligence tools

Rejected because existing OCR tools can also return document content to an MCP
client or provider. The external-data risk applies to all document tools.

### Cloud fallback when Apple's model is unavailable

Rejected because it violates the local-only boundary and would create a second
privacy, credential, reliability, and cost model.

## Explicitly out of scope

- Desktop intelligence for batch jobs.
- Persistent intelligence history or saved conversations.
- A guided agent-configuration wizard or automatic config edits.
- Network MCP transport.
- Arbitrary prompts, chat, model tool calling, or agent actions.
- Automatic file naming, moving, tagging, renaming, or overwrite.
- Private Cloud Compute or any third-party model fallback.
- An App Store release or changes to the current seller-identity gate.

## Completion criteria

The implementation is ready for release review only when:

- Studio offers all three single-document Local Intelligence actions on an
  eligible Mac and explains every unavailable state without affecting OCR.
- The shared intelligence module is used by both Studio and MCP.
- The MCP catalog exposes nine tools and all document calls enforce current
  external-data acknowledgment before opening input.
- Consent can be accepted interactively, inspected, revoked, and renewed after
  a policy change without storing content.
- In-app and repository FAQs accurately cover Codex, Claude Code, and generic
  stdio clients without modifying their configuration.
- All automated suites and real-device/manual gates pass on the exact candidate
  commit.
- Stable-Xcode signing, notarization, Gatekeeper, downloaded-package, and
  second-Mac evidence are complete.
- Milestone business records have been reconciled from dated evidence.
