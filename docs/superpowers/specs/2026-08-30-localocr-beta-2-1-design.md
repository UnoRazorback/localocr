# LocalOCR Studio Beta 2.1 Design

**Date:** 2026-08-30
**Status:** Owner-approved design
**Product name:** LocalOCR Studio Beta 2.1
**App version:** `0.3.1`
**Build:** `4`
**Release tag:** `v0.3.1-beta.1`

## Purpose

Beta 2.1 turns the existing Local Intelligence candidate into a coherent,
testable LocalOCR release. It combines the published desktop OCR and reviewed
batch workflows with optional local model analysis, complete offline Help, and
an explicit agent-connection experience. It must remain approachable for a
nontechnical Mac user without weakening LocalOCR's local-processing or source
document guarantees.

Apple Vision OCR remains the authoritative document text. Local Intelligence
may summarize, organize, or extract fields from that recognized text, but it
never replaces OCR, silently edits a document, renames a source, or overwrites
an original. Model output is labeled, temporary, reviewable, and
non-authoritative.

## Release Scope

Beta 2.1 includes:

- the published single-document and sequential desktop batch workflows;
- the branded app icon and current visual system;
- Apple Foundation Models through `SystemLanguageModel.default`;
- detected, tested, and explicitly selected local Ollama and LM Studio models;
- a local-model manager that identifies the provider and selected model;
- three Local Intelligence actions: **Summarize**, **Suggest Name & Tags**, and
  **Extract Fields**;
- nine MCP tools: six existing OCR/PDF tools and three Local Intelligence
  tools;
- an offline Help Center available from the standard Help menu;
- guided Codex and Claude MCP connection and disconnection through those
  clients' official command-line interfaces;
- copyable setup for other stdio MCP clients;
- explicit external-agent and external-local-model acknowledgments;
- accurate availability, privacy, model-provenance, and troubleshooting text;
  and
- signed, notarized, stapled, Gatekeeper-accepted direct distribution.

Beta 2.1 does not include:

- a guided OCR settings or language wizard;
- persistent document, model-output, or batch history;
- automatic software updates;
- cloud OCR, remote model providers, Private Cloud Compute fallback, or a
  generic OpenAI-compatible endpoint;
- an HTTP or network MCP listener;
- automatic agent configuration without an explicit user action;
- Intel Mac, Windows, or Linux support; or
- App Store distribution.

## Compatibility and Availability

The app and six OCR/PDF MCP tools continue to support Apple silicon Macs on
macOS 14.0 or later. Local Intelligence requires macOS 26 or later.

Apple Foundation Models additionally requires an Apple Intelligence-eligible
Mac, Apple Intelligence enabled, the on-device system model ready, a supported
region, and a supported language. LocalOCR checks
`SystemLanguageModel.default.availability` and distinguishes at least:

- available;
- Apple Intelligence not enabled;
- device not eligible; and
- model not ready.

If Local Intelligence is unavailable, normal single-document OCR, desktop
batch, searchable-PDF creation, the CLI, and the six OCR/PDF MCP tools continue
to work. No failure may silently select a different provider.

## Local Intelligence Architecture

The existing `LocalOCRIntelligence` subsystem remains separate from
`LocalOCRCore` and `LocalOCRService`. The OCR service produces authoritative
page text. A document-intelligence provider receives only the required page
text and page markers, not the source PDF or image bytes.

`LocalIntelligenceProviderRegistry` discovers supported providers.
`LocalModelQualificationService` tests an external model before selection.
`LocalIntelligenceProviderRouter` selects exactly one verified provider and
fails closed if its identity, locality, availability, or qualification state
changes. Provider selection and qualification receipts are stored locally.

Every intelligence result records:

- provider name;
- model identifier when the provider exposes one;
- the verified processing path;
- whether processing was on device or verified loopback on the same Mac; and
- page citations or exact evidence where the result type supports them.

### Apple Foundation Models

Apple Foundation Models is the default provider when available. LocalOCR uses
`SystemLanguageModel.default` directly through Apple's Foundation Models
framework. No API key, local server, network request, or user-selected Apple
model version is required. Apple chooses and updates the installed system
model; LocalOCR must not claim a more specific model name or version than the
public API exposes.

Apple output stays inside the LocalOCR process boundary. It does not require
the external-agent acknowledgment unless the action is invoked through MCP.

### Ollama and LM Studio

Ollama and LM Studio are optional alternatives. LocalOCR may offer them only
after detecting the actual local runtime, binding the process and executable
identity, enumerating a concrete local model, and running the qualification
suite against that exact provider/model identity.

External local models use verified loopback communication on the same Mac.
The app must reject remote, relayed, wildcard, non-loopback, or
locality-ambiguous endpoints. It must not accept a generic
OpenAI-compatible endpoint merely because it responds on a URL.

Selection requires an explicit acknowledgment that the user is choosing a
third-party local runtime and understands that the runtime controls its own
data handling. No external local provider is selected silently, and a provider
identity change invalidates the prior qualification and selection.

## Studio Experience

The default launch screen remains the one-document workflow. Desktop batch
remains an explicit secondary action and processes sequentially. Local
Intelligence appears only after a single document has completed OCR; batch is
OCR-only in Beta 2.1.

The result view presents Local Intelligence in a separately bordered card. It
shows the active provider and model disclosure before the user invokes an
action. Each action runs independently and displays its own progress, result,
or bounded error. Processing another document, switching workspace, or closing
the window clears temporary intelligence output.

The local-model manager presents Apple Foundation Models, Ollama, and LM
Studio in a stable order. It shows detection, qualification, availability, and
selection state without implying that an unavailable or untested model is
ready. External-model confirmation identifies the provider, model, local path,
and acknowledgment before selection.

## Offline Help Center

The current macOS fallback that reports "No help is available" is a release
defect. Beta 2.1 replaces that dead end with an app-owned, offline Help Center.
The standard Help menu contains at least:

- **LocalOCR Studio Help**;
- **Connect to Your Agent**; and
- **Report Beta Feedback**.

The Help Center is a native SwiftUI window with searchable or clearly
navigable sections for:

1. Getting Started;
2. Single Document;
3. Desktop Batch;
4. Searchable PDFs and Saved Text;
5. Local Intelligence;
6. Apple Foundation Models;
7. Ollama and LM Studio;
8. Connect to Your Agent;
9. Privacy and Data Boundaries;
10. Troubleshooting;
11. FAQ; and
12. Version and Build Information.

Core help content ships inside the signed app and works without a network
connection. An explicitly labeled feedback action may open the public GitHub
feedback page after the user selects it. The Help window is reused rather than
duplicated, and its content is selectable and accessible by keyboard and Voice
Over.

Release tests inspect the packaged app, not only source, to prove that the Help
menu action and offline content exist in the distributed bundle.

## Guided Agent Connection

**Connect to Your Agent** uses the actual running app bundle to derive:

```text
<running-app-path>/Contents/Helpers/localocr-mcp
```

It never assumes `/Applications` when the app is installed in
`~/Applications` or another folder.

The connection window shows:

- the detected helper path;
- MCP helper version and initialization status;
- external-agent acknowledgment status;
- tabs for Codex, Claude Code, and other stdio clients;
- current connection status when the client can be inspected;
- explicit Connect and Disconnect actions for supported local clients;
- copyable commands and generic stdio JSON; and
- safe non-sensitive first-test prompts.

### Codex and Claude actions

LocalOCR discovers a usable Codex or Claude executable through a bounded set of
installed-app locations and the user's executable search path. It displays the
resolved executable before any mutation.

Connect and Disconnect invoke the client's own command-line interface with an
executable URL and an argument array. LocalOCR does not invoke a shell, compose
an interpolated shell command, or edit Codex or Claude configuration files
directly.

For Codex, the intended operations are equivalent to:

```text
codex mcp add localocr -- <detected-helper-path>
codex mcp get localocr
codex mcp remove localocr
```

For Claude Code, the UI requires an explicit scope choice supported by that
client, defaults to the current local/project scope, and performs add, inspect,
or remove through the Claude CLI. A user-scope connection is never chosen
silently.

Before Connect runs, the UI shows the exact client, scope, and helper path and
requires confirmation. Disconnect remains available without accepting new
data-sharing terms. After either operation, LocalOCR reinspects the client and
shows success or a bounded, sanitized error. If a client is not installed or
its current CLI cannot be safely identified, the UI falls back to copyable
instructions and does not change configuration.

The app explains that the client must be restarted or reloaded before a new
server becomes visible. It never force-quits an agent that may have active
work.

## MCP Consent and Privacy Boundary

The LocalOCR MCP server is a local stdio process started by the MCP client. It
opens no listener and makes no network connection. This local transport does
not guarantee that the client or its configured AI provider keeps document
data on the Mac.

Before document tools are enabled, the user must accept both approved
statements acknowledging that:

1. the MCP client or agent may transmit LocalOCR inputs and results to an
   outside provider; and
2. the user is authorized to share the data and chooses to enable LocalOCR MCP
   document tools.

The acknowledgment is versioned, locally stored, revocable, and invalidated
when its approved text or policy version changes. Without a current receipt,
the server may initialize and describe the consent requirement but refuses all
nine document tools. Revocation takes effect for subsequent tool calls.

The connection UI does not represent acknowledgment as proof that a particular
agent provider is private, local, compliant, or configured not to train. Those
claims remain the responsibility of the client provider and the user's account
settings.

## MCP Tool Contract

Beta 2.1 exposes exactly these nine tools over local stdio:

1. `get_pdf_page_count`;
2. `inspect_pdf`;
3. `ocr_pdf`;
4. `ocr_pdf_batch`;
5. `ocr_image`;
6. `make_searchable_pdf`;
7. `summarize_document`;
8. `organize_document`; and
9. `extract_document_fields`.

The first six retain their published parameter and result contracts. The three
intelligence tools invoke OCR first, then use the selected verified provider.
They never return generated text as authoritative OCR. Batch remains OCR-only;
there is no batch intelligence tool.

`make_searchable_pdf` writes a separate destination and refuses to overwrite
the source or an existing file. The remaining tools do not mutate source
documents.

## Packaging and Security

The release bundle contains the GUI executable and exactly three nested helper
executables: `localocr`, `localocr-mcp`, and `localocr-model-bridge`. No unsigned,
debug, development, temporary, or unrelated executable may ship. The model
bridge exists only for verified local Ollama and LM Studio communication; Apple
Foundation Models runs directly inside the app or MCP process and does not use
the bridge.

All shipped executables are arm64, target macOS 14.0, use safe relative or
system Swift runtime search paths, and depend only on Apple/system libraries.
The Foundation Models framework remains a weak system-framework dependency so
the OCR surfaces continue to launch on macOS 14 and 15.

The release is built with stable Xcode. Nested executables are signed first and
the containing app last with Developer ID, Hardened Runtime, secure timestamps,
and no `get-task-allow`. Every signature is verified before notarization. The
final ZIP is submitted with `notarytool`, accepted, stapled, verified with
`spctl`, checksummed, downloaded again, and retested from the public artifact.

## Testing and Acceptance

Implementation acceptance requires fresh evidence for:

- the complete Swift suite;
- isolated Studio UI tests;
- Python compatibility and release-contract suites;
- all six existing OCR/PDF MCP contracts;
- all three Local Intelligence MCP contracts;
- consent required, accepted, current, revoked, and policy-version changes;
- Apple Foundation Models availability mapping and live synthetic-document
  output;
- grounded summary, organization, and field extraction;
- no generated result replacing authoritative OCR;
- detected Ollama and LM Studio qualification and fail-closed behavior;
- rejection of remote and locality-ambiguous endpoints;
- helper-path derivation for `/Applications`, `~/Applications`, spaces, quotes,
  and nonstandard locations;
- Codex and Claude client discovery, connect, inspect, disconnect, fallback,
  cancellation, and sanitized failures;
- no direct client-config editing and no shell-based command execution;
- offline Help menu, Help window reuse, section content, keyboard access, and
  packaged resources;
- single-document, Process Another, desktop batch, cancellation, retry, output
  collision, and source-immutability regression coverage;
- exact nine-tool MCP listing and clean stdio protocol output;
- no unexpected LocalOCR network activity during live Studio and MCP tests;
- system-only dependencies and safe RPATHs;
- strict signatures, Hardened Runtime, notarization, stapling, Gatekeeper, and
  checksum;
- exact downloaded-package acceptance on the build Mac; and
- installed-app launch and synthetic acceptance on the MacBook Pro and Mac
  mini.

Live Apple Foundation Models acceptance uses synthetic, non-sensitive fixtures
and records cold and warm behavior separately. A passing generated response is
not accepted unless grounded values, citations, omissions, and unsupported
claims are reviewed against authoritative OCR text.

Ollama or LM Studio release claims are limited to runtimes and exact model
identities actually detected, qualified, and evidenced. Absence of a runtime
does not become a claim that it was tested.

## Release Gates and Records

Implementation, review, merge, signing, notarization, publication, installation,
and release acceptance remain distinct gates. Passing source tests does not
authorize a public release, and a notarized artifact does not prove target-Mac
acceptance.

Before publication, the release record captures:

- exact source commit and immutable tag;
- app version and build;
- stable Xcode, Swift, SDK, deployment target, Mac model, and macOS builds;
- full test counts and dated logs;
- shipped executable inventory, dependencies, RPATHs, entitlements, signature
  identities, and hashes;
- notarization submission ID and accepted result;
- staple and Gatekeeper results;
- final ZIP name, size, SHA-256, and public URL;
- downloaded-package acceptance;
- build-Mac, MacBook Pro, and Mac mini installation evidence; and
- live website and tester-guide version alignment.

The business-record folder at
`reports/mcp-macvision` is updated from dated evidence only. Direct and
reasonably allocated costs are recorded without invented amounts. Time rows may
remain provisional until the milestone closes. Publication establishes a new
download baseline and begins a distinct Beta 2.1 metrics and feedback period.

## Success Criteria

Beta 2.1 succeeds when a nontechnical tester can:

1. open the app normally through Gatekeeper;
2. find working offline Help from the Help menu;
3. OCR one document or run a reviewed sequential batch without changing an
   original;
4. see whether Apple Foundation Models is available and which local provider
   is active;
5. run grounded Local Intelligence actions without confusing model output with
   OCR;
6. discover the bundled MCP server inside the app;
7. understand the external-agent data boundary;
8. explicitly connect or disconnect Codex or Claude without manually finding
   the app bundle or editing a configuration file;
9. confirm the `localocr` server in the agent after restarting it; and
10. use exactly nine consent-gated tools while LocalOCR itself remains local,
    fail-closed, and source-preserving.
