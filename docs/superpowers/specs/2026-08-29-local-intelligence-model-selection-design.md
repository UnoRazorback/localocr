# LocalOCR Local Intelligence Model Selection Design

**Date:** 2026-08-29
**Status:** Approved in conversation; written specification awaiting owner review
**Release boundary:** Post-current Local Intelligence candidate

## Purpose

Allow LocalOCR to detect and offer compatible models already running locally
through Ollama or LM Studio while preserving Apple Foundation Models as the
built-in system option. One explicit model selection is shared by LocalOCR
Studio, the CLI, and MCP.

This feature does not change OCR. Apple Vision remains the only OCR engine and
its result remains the authoritative document text. Model-generated analysis is
optional, separately labeled, and never overwrites OCR text or the source file.

## Approved product boundaries

- Processing remains on the user's Mac. There is no cloud or Private Cloud
  Compute fallback.
- LocalOCR detects and offers providers; it never silently switches providers
  or models.
- Version 1 supports Apple Foundation Models, Ollama, and LM Studio only. It
  does not accept a generic OpenAI-compatible endpoint.
- External harnesses are limited to fixed loopback endpoints. Non-loopback,
  remote, cloud, relayed, and locality-ambiguous models fail closed with no
  override.
- A discovered external model must pass LocalOCR's synthetic compatibility test
  for all three Local Intelligence actions before it can be selected.
- Studio, CLI, and MCP use one shared selection. MCP may read and use that
  selection but may not change it.
- If the selected provider becomes unavailable or changes identity, LocalOCR
  stops analysis and asks the user what to do. It never silently falls back.
- Existing OCR and already-created OCR results remain available when Local
  Intelligence fails.
- Existing generated results retain the provider and model provenance recorded
  when they were created.
- Signing, notarization, installation, merging, publication, and campaign state
  are separate gates outside this feature's implementation authorization.

## Non-goals

- Downloading, installing, starting, stopping, or configuring Ollama, LM Studio,
  or their models.
- Supporting arbitrary hosts, ports, URLs, remote Macs, containers, relays, or
  network-visible model servers.
- Treating a loopback address alone as proof that a model is local.
- Letting an MCP client select or approve a model.
- Sending a PDF, image, or other source-document bytes to a model harness.
- Letting generated analysis rename, move, modify, or replace a source file.
- Comparing or ranking model quality beyond the pass/fail compatibility gate.
- Maintaining persistent prompt, response, or document-text history.

## Architecture

Apple Vision produces normalized, page-aware text before any Local
Intelligence operation. The model-selection subsystem sits after that boundary:

```text
                                  +-----------------------------+
LocalOCR Studio ----------------->|                             |
localocr CLI -------------------->| Local Intelligence Router   |---> Apple Foundation Models
localocr-mcp -------------------->|                             |
                                  +-------------+---------------+
                                                |
                                                | bounded stdio
                                                v
                                  +-----------------------------+
                                  | localocr-model-bridge       |
                                  | fixed loopback HTTP only    |
                                  +-------------+---------------+
                                                |
                                      +---------+---------+
                                      v                   v
                                   Ollama             LM Studio
```

The shared subsystem contains these focused components:

- `LocalIntelligenceProviderRegistry` exposes the built-in and discovered
  provider/model candidates.
- `LocalModelDiscoveryService` requests only content-free model metadata from
  the two approved loopback harnesses.
- `LocalModelLocalityVerifier` classifies each candidate as verified local,
  blocked, or unverified and records the reason.
- `LocalModelQualificationService` runs and caches the synthetic three-action
  compatibility test.
- `LocalIntelligenceSelectionStore` owns the single approved selection and its
  provider-specific acknowledgment.
- `LocalIntelligenceProviderRouter` resolves that selection for Studio, CLI,
  and MCP and fails closed when it is not usable.
- `AppleFoundationModelsProvider` continues to own direct access to
  `SystemLanguageModel.default`.
- `BridgeBackedIntelligenceProvider` invokes the isolated model bridge for
  Ollama and LM Studio work.

All provider adapters implement the existing document-intelligence boundary for
summarize, organize, and extract operations. Prompts, deterministic chunking,
grounding rules, output decoding, and result types remain shared rather than
being reimplemented per harness.

## Isolated model bridge

### Why it exists

Ollama and LM Studio expose local HTTP APIs, but LocalOCR's existing MCP policy
requires `localocr-mcp` to remain a stdio-only MCP server with no HTTP client,
CFNetwork, or Network framework linkage. Adding HTTP separately to Studio, CLI,
and MCP would also duplicate security and privacy enforcement.

Add one executable named `localocr-model-bridge`. It is the only shipping
LocalOCR binary permitted to perform HTTP requests or link the Apple system
network framework needed for those requests.

### Bridge boundary

- Studio, CLI, and MCP launch the bridge as a child process and communicate
  through bounded newline-delimited JSON on stdin and stdout.
- The bridge accepts provider operations, model identifiers, bounded prompts,
  schemas, and timeouts. It does not accept an arbitrary URL, hostname, port,
  HTTP method, header, or credential.
- Provider endpoints are compiled constants for the approved Ollama and LM
  Studio loopback APIs. Address resolution must remain loopback.
- Redirects, proxies, system proxy inheritance, authentication challenges, and
  non-loopback destinations are disabled or rejected.
- Discovery requests contain no document text. Analysis requests contain only
  normalized OCR text, page metadata needed for grounding, and the narrow
  operation contract. Raw PDF and image bytes are forbidden.
- Protocol output goes only to stdout. Content-free diagnostics go only to
  stderr. Diagnostics never contain filenames, paths, OCR text, prompts,
  extracted values, or model output.
- Input, output, concurrency, cancellation, and execution time are bounded.
  Partial or malformed bridge responses are discarded.
- The bridge is stateless between requests and does not persist prompts,
  document text, or model responses.

The bridge depends only on approved Apple/system libraries. It is signed before
the containing app and verified as a nested executable. The CLI/MCP distribution
must place it at a stable path relative to the launching helper rather than
embedding an absolute build-machine path.

### Binary policy exception

The existing no-network artifact rule is narrowed only for this executable:

- `localocr-mcp` remains free of CFNetwork, Network, URLSession, HTTP transport,
  client, listener, and socket code.
- The Studio executable and `localocr` CLI remain free of direct model-network
  code and invoke the bridge through stdio.
- `localocr-model-bridge` may link only the Apple/system framework required for
  outbound HTTP and may contact only approved loopback endpoints.
- No LocalOCR binary exposes an HTTP, SSE, WebSocket, MCP-network, or other
  listening transport.
- Release contracts inspect every binary separately and reject any broader
  exception.

## Discovery and locality verification

Discovery is explicit and content-free. Studio runs it when the user opens
**Manage Local Models** or chooses **Detect**. The CLI runs it for
`localocr intelligence models`. LocalOCR may refresh content-free status when
displaying the active selection, but it does not continuously scan in the
background.

Version 1 probes only:

- Ollama at its approved IPv4 and IPv6 loopback endpoint forms on the default
  port; and
- LM Studio at its approved IPv4 and IPv6 loopback endpoint forms on the
  default port.

The bridge normalizes provider responses into a stable candidate record:

- provider identifier and display name;
- exact harness-reported model identifier;
- model digest or best available immutable identity;
- harness version when available;
- locality classification and reason;
- compatibility status and last test time; and
- current availability.

Locality verification is provider-specific. A candidate is selectable only
when LocalOCR can positively establish that inference is performed by a model
resident on the same Mac. Ollama cloud model forms and any cloud-authenticated
or remote execution path are blocked. LM Studio cloud, LM Link, remote, or
otherwise relayed execution is blocked. Missing or insufficient metadata is
`unverified`, not local.

Blocked and unverified candidates may be shown so the user understands why
they cannot be used, but the selection control remains disabled. Version 1 has
no locality override.

## Model qualification

A verified-local external model is not selectable until it passes a
non-sensitive synthetic LocalOCR fixture. The fixture contains no user data and
tests the same shared contracts used in production.

The model must pass all three actions:

1. **Summarize:** produce a concise source-grounded summary without adding
   unsupported facts.
2. **Organize:** return the required title, category, and bounded tag schema.
3. **Extract Fields:** return typed values and page evidence, preserve missing
   fields as null, and avoid guessing.

The test also verifies structured-output decoding, page evidence, deterministic
input bounds, minimum safe context behavior, cancellation, and timeout handling.
A model that passes only some actions remains visible but disabled; version 1
does not expose partially capable selections or vary the MCP tool catalog by
model.

The cached qualification record binds to:

- provider;
- exact model identifier;
- model digest or immutable identity;
- harness identity and version;
- LocalOCR qualification-policy version;
- fixture version; and
- test timestamp and outcome.

A changed digest, harness version, policy version, or fixture version invalidates
the cached result and requires a new test. If an immutable model identity is not
available, the model must be requalified for the current harness session or
remain unselectable; LocalOCR must not treat a mutable display name as proof of
identity.

## Selection and acknowledgment records

There is one per-user selection shared by Studio, CLI, and MCP. The record lives
under LocalOCR's existing application-support directory and uses the same
secure, owner-checked, atomic filesystem principles as the MCP consent store.
It contains metadata only—never document text, prompts, or generated output.

The selection record contains:

- schema and policy versions;
- provider and exact model identifier;
- model and harness qualification identity;
- selection timestamp;
- provider-acknowledgment policy version and acceptance timestamp; and
- sufficient display metadata to explain an unavailable former selection.

Apple Foundation Models can be selected without the external-harness
acknowledgment because it is an in-process Apple system framework. Selecting an
Ollama or LM Studio model requires a one-time confirmation bound to the provider,
model identity, and acknowledgment-policy version.

The confirmation explains:

- OCR text will leave the LocalOCR process but remain on this Mac over loopback;
- the named third-party harness and exact model will receive the text;
- the harness may have its own logs, history, extensions, or settings outside
  LocalOCR's control; and
- the user is responsible for reviewing that harness's local privacy settings.

The confirmation links or points to the relevant installed harness settings but
does not make unverified claims about those settings. A changed model identity,
harness identity, or acknowledgment policy requires confirmation again.

This confirmation is separate from LocalOCR's existing MCP external-data
acknowledgment. The model confirmation governs LocalOCR-to-local-harness data;
the MCP acknowledgment governs data that an MCP client or its agent provider
may transmit outside the Mac. MCP intelligence operations require both receipts
when an external local model is selected.

## Provider routing and analysis data flow

1. LocalOCR validates the source and uses Apple Vision to inspect or OCR it.
2. LocalOCR preserves immutable, page-aware authoritative text.
3. The router reads the shared selection and validates its current provider,
   locality, qualification, and acknowledgment state.
4. Apple Foundation Models work remains in process. Ollama and LM Studio work is
   sent through the model bridge over stdio and then to the selected loopback
   harness.
5. Only normalized OCR text, bounded page metadata, and the operation contract
   cross the bridge. The original file and raw document bytes remain outside it.
6. Shared validators reject malformed, incomplete, ungrounded, or unsupported
   output.
7. A successful result is labeled with provider, exact model identifier,
   processing location, model identity when available, and generation time.
8. The result is presented separately from OCR and cannot mutate the source or
   authoritative text.

Long-document chunking remains deterministic and page-aware. Qualification
establishes the model's minimum safe behavior, but runtime input is still bounded.
If a document cannot be processed safely within the selected model's verified
capacity, the operation fails with an explanation rather than truncating or
guessing.

## Failure behavior

LocalOCR fails closed when a provider or model is no longer exactly the one the
user selected and approved.

- A stopped harness, removed model, changed digest, changed harness version,
  failed locality check, expired qualification, or stale acknowledgment pauses
  analysis.
- Studio offers **Retry**, **Choose Another Local Model**, and **Use Apple System
  Model** when Apple Foundation Models is available. Choosing is always explicit.
- CLI and MCP return the equivalent structured state and corrective actions.
- Timeouts, invalid JSON, invalid schemas, insufficient context, bridge protocol
  errors, and failed grounding discard partial generated output.
- Existing OCR and prior intelligence results remain available.
- Switching providers affects only future operations. Existing results retain
  their original provenance.
- Discovery failure never revokes a valid selection solely because a harness is
  temporarily stopped; it marks the selection unavailable. Identity or locality
  changes invalidate qualification and acknowledgment as specified above.

Stable error categories include:

- no model selected;
- selected provider unavailable;
- selected model unavailable;
- model locality unverified or blocked;
- model qualification required or failed;
- provider acknowledgment required;
- bridge unavailable or invalid;
- generation timeout or failure;
- context limit exceeded; and
- output malformed or not grounded.

MCP exposes these as structured errors rather than silently removing tools or
returning an empty result.

## Studio experience

The Local Intelligence section always identifies its active model:

- **Apple Foundation Models — system default** for Apple's public
  `SystemLanguageModel.default`; or
- the exact harness and model identifier for Ollama or LM Studio.

Apple's public API does not expose an exact underlying model name or version, so
Studio explains that macOS selects the installed system model rather than
inventing a more specific identity.

Studio adds **Manage Local Models**, containing:

- the active model and its current status;
- **Detect** to probe the approved local harnesses;
- discovered candidates grouped by provider;
- plain-language local, blocked, unverified, needs testing, qualified, and
  unavailable states;
- **Test** or **Recheck** for the synthetic qualification fixture; and
- **Select** for qualified candidates, followed by the provider confirmation
  when required.

LocalOCR does not offer install, pull, download, delete, start, or server-setup
buttons in version 1.

## CLI experience

The CLI adds:

```text
localocr intelligence models
localocr intelligence test <provider> <model>
localocr intelligence select <provider> <model>
localocr intelligence status
localocr intelligence reset
```

`models` performs content-free detection and reports locality, compatibility,
and availability. `test` runs only the synthetic fixture. `select` requires an
interactive terminal for any external-provider confirmation and rejects
non-interactive bypass flags. `status` is content-free. `reset` removes the
selection and provider acknowledgment without changing the separate MCP consent
receipt.

Commands support machine-readable output only where that does not bypass an
interactive acknowledgment. Exit codes distinguish invalid arguments,
unavailable harnesses, failed locality, failed qualification, required consent,
and operational errors.

## MCP experience and contract

MCP uses the shared selection and cannot discover, test, select, reset, or
approve a model. This prevents an agent or document from changing the user's
privacy choice.

The three existing intelligence tools remain stable and consistently available
in the tool catalog. Before an intelligence call, the dispatcher validates:

1. the existing MCP external-data acknowledgment;
2. a current shared model selection;
3. provider availability and verified locality;
4. current all-actions qualification; and
5. external-provider acknowledgment when applicable.

Every successful intelligence response includes:

```json
{
  "local_model": {
    "provider": "Ollama",
    "model": "exact-harness-model-identifier",
    "processing": "on_device_loopback",
    "identity": "provider-supplied-immutable-identity-when-available",
    "qualified_at": "ISO-8601 timestamp"
  }
}
```

Apple responses continue to identify `Apple Foundation Models` and
`SystemLanguageModel.default` with `processing` set to `on_device`. Fields that
cannot be known are omitted or null according to the published schema; LocalOCR
does not fabricate model names, versions, or digests.

## Testing and acceptance

### Unit and contract tests

- Provider registry and exact model-identity normalization.
- Fixed-endpoint discovery with no document content.
- IPv4 and IPv6 loopback acceptance and non-loopback rejection.
- Ollama cloud-model and LM Studio remote/cloud/LM Link rejection.
- Ambiguous locality remains unverified and disabled.
- All-three-actions qualification and every invalidation key.
- Secure, atomic, owner-checked selection and acknowledgment storage.
- Explicit routing and absence of silent fallback.
- Studio, CLI, and MCP report one consistent selection and model provenance.
- Generated output remains separate from Vision OCR and source files.
- MCP cannot mutate model selection or consent.

### Bridge tests

- Bounded newline-delimited stdio protocol and stdout purity.
- Fixed provider endpoints; arbitrary URL, host, port, header, and method inputs
  are impossible or rejected.
- Proxy, redirect, authentication, and non-loopback escape attempts fail closed.
- Raw document bytes and file paths are rejected at the bridge boundary.
- Timeouts, cancellation, malformed JSON, oversized messages, concurrent
  requests, broken pipes, and harness errors are deterministic.
- Logs and stderr contain no document or model content.
- Source and binary inspection allow HTTP/network symbols only in the bridge.
- `localocr-mcp` remains compliant with the vendored stdio-only MCP policy.

### Integration and physical acceptance

- Controlled mock Ollama and LM Studio servers exercise discovery, locality,
  qualification, generation, and failure paths.
- Live locally installed Ollama and LM Studio models pass the synthetic fixture
  and all three document operations.
- The live matrix covers a stopped server, removed or changed model, changed
  harness version, context overflow, malformed structured output, and retry.
- Packet/socket inspection confirms discovery and analysis contact only
  loopback and that discovery sends no document text.
- Studio acceptance covers model visibility, confirmation, selection, switching,
  provenance, and recovery choices.
- CLI acceptance covers all five commands and interactive-confirmation rules.
- MCP acceptance covers shared selection, both consent layers, structured
  errors, exact tool catalog, and model metadata.
- Regression coverage includes Apple Foundation Models, unavailable systems,
  ordinary OCR, searchable PDF creation, desktop batch, MCP stdio protocol, and
  the existing MCP acknowledgment.

## Release evidence and distribution boundary

Candidate evidence records:

- exact source commit and clean-tree state;
- macOS and stable Xcode versions;
- Ollama and LM Studio harness versions;
- exact tested model identifiers and immutable identities/digests when exposed;
- qualification fixture and policy versions;
- automated test counts and physical acceptance results;
- per-binary dependencies, RPATHs, symbols, hashes, and architectures;
- proof that only the model bridge has the narrow HTTP/network dependency;
- proof that all runtime connections are loopback-only; and
- signature, notarization, stapling, Gatekeeper, and second-Mac results when
  those later gates are separately authorized.

Nested release artifacts are signed from the inside out, including the model
bridge before its containing app. Hardened Runtime, signature verification,
notarization, stapling, Gatekeeper verification, and downloaded-package testing
follow the project's established direct-distribution process. None of those
steps, nor merge or publication, is authorized merely by approving this design.

At the implementation milestone, the project overview and time-and-cost records
are reconciled from dated evidence only. Beta download and feedback baselines
change only when a beta is actually published.

## Success criteria

- Users can detect qualified, verified-local Ollama and LM Studio models and
  deliberately choose one instead of Apple Foundation Models.
- No user document content is sent during discovery or qualification.
- No cloud, remote, relayed, non-loopback, or ambiguous model is selectable.
- One exact selection is honored consistently by Studio, CLI, and MCP.
- External harness use requires informed, model-bound confirmation.
- Every external model passes all three Local Intelligence actions before use.
- Provider failures preserve OCR and never trigger silent fallback.
- Every generated result reports truthful provider/model provenance.
- Apple Vision OCR remains authoritative and immutable.
- The isolated bridge is the only network-capable LocalOCR binary, communicates
  only with approved loopback harnesses, and does not broaden MCP transport.
- Existing OCR, batch, searchable-PDF, Apple-model, MCP, consent, release, and
  signing behavior remains correct.
