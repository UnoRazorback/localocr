# LocalOCR 0.3.1 Build 8 Corrections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a private LocalOCR 0.3.1 build 8 candidate that preserves table associations, safely supports the attested GPT-OSS 120B response shape, and remains locally verified across sustained llama.cpp use.

**Architecture:** Reconstruct row-oriented intelligence text only from valid Vision line geometry while leaving public OCR text unchanged. Bind the GPT-OSS exception to one immutable GGUF fingerprint and keep all final-schema, identity, locality, and grounding gates. Persist only validated harness-version evidence under the existing private executable-identity cache so repeated helper processes do not relaunch the resident model executable for `--version`.

**Tech Stack:** Swift 6, Swift Testing, Apple Vision/CoreGraphics, SwiftPM, CryptoKit, Darwin, existing LocalOCR bridge and activity contracts, shell/Python acceptance harnesses.

**Spec:** `docs/superpowers/specs/2026-09-14-localocr-build8-corrections.md`

## Global Constraints

- Base source is commit `0a62c1a64aad490fb467ac745a79d877c74f7ee6`; work only in the isolated `codex/localocr-build8` worktree.
- Preserve strict local-only behavior: no remote endpoint, relay, fallback, model download, document identifier, OCR text, filename, path, thumbnail, or hash may leave the Mac.
- Do not use company documents. Acceptance inputs are synthetic except Scott's separately reported content-free real-document timings.
- Do not weaken non-GPT response rejection, final JSON schema validation, grounding, qualification identity, listener/process/file attestation, or pre/post generation verification.
- Build 8 remains private. Signing and notarization are authorized; public publication, shared-branch merge/push, target installation, and Pro model-server lifecycle changes are not.
- Every production change begins with a failing regression test and ends with a focused commit plus independent task review.

---

### Task 1: Reconstruct Vision OCR table rows for intelligence

**Files:**
- Create: `Sources/LocalOCRIntelligence/OCRLayoutTextAssembler.swift`
- Modify: `Sources/LocalOCRIntelligence/LocalOCRDocumentTextLoader.swift`
- Modify: `tests/LocalOCRIntelligenceTests/LocalOCRDocumentTextLoaderTests.swift`
- Create: `tests/LocalOCRIntelligenceTests/OCRLayoutTextAssemblerTests.swift`

**Interfaces:**
- Consumes: `OCRPageResponse.method`, `OCRPageResponse.lines`, and `OCRLineResponse` normalized geometry.
- Produces: `OCRLayoutTextAssembler.text(for:fallback:) -> String`, used only for `.visionOCR` intelligence pages.

- [ ] **Step 1: Add failing geometry regressions**

Add tests with the supplied synthetic row coordinates. Require the output to contain exactly `Equipment | Lift and delivery | $2,000.00`, preserve top-to-bottom row order and left-to-right cell order, keep vertically separated lines on different rows, reject non-finite/out-of-bounds geometry by returning the fallback string, and keep native-text pages unchanged.

- [ ] **Step 2: Prove the old loader fails**

Run:

```bash
swift test --filter 'OCRLayoutTextAssemblerTests|LocalOCRDocumentTextLoaderTests'
```

Expected: FAIL because `OCRLayoutTextAssembler` does not exist and the loader requests `includeLines == false`.

- [ ] **Step 3: Implement bounded deterministic assembly**

Implement `OCRLayoutTextAssembler` as a stateless enum. Validate every geometry component with `isFinite`, require positive width/height and each rectangle to stay within normalized `0...1`, sort by descending vertical midpoint then ascending `x`, join a candidate to a row only when its vertical intersection is at least half the smaller line height, sort each row by `x`, join cells with ` | `, and join rows with newline. If any line is invalid or assembly is empty, return `fallback` unchanged.

Change `LocalOCRDocumentTextLoader` to request `PDFOCRRequest(fileURL:sourceURL, includeLines:true)`. For `.visionOCR` pages with nonempty lines, pass the lines to the assembler; for `.existingText`, absent lines, and images, preserve existing text behavior.

- [ ] **Step 4: Run focused and module tests**

```bash
swift test --filter 'OCRLayoutTextAssemblerTests|LocalOCRDocumentTextLoaderTests|GroundedDocumentIntelligenceProviderTests|IntelligenceGroundingValidatorTests'
```

Expected: PASS, including the synthetic equipment row and unchanged grounding rules.

- [ ] **Step 5: Commit**

```bash
git add Sources/LocalOCRIntelligence/OCRLayoutTextAssembler.swift Sources/LocalOCRIntelligence/LocalOCRDocumentTextLoader.swift tests/LocalOCRIntelligenceTests/OCRLayoutTextAssemblerTests.swift tests/LocalOCRIntelligenceTests/LocalOCRDocumentTextLoaderTests.swift
git commit -m "Preserve OCR table rows for local intelligence"
```

---

### Task 2: Add the fingerprint-bound GPT-OSS response adapter

**Files:**
- Modify: `Sources/LocalOCRModelBridgeKit/LlamaCppBridgeAdapter.swift`
- Modify: `tests/LocalOCRModelBridgeKitTests/LlamaCppBridgeAdapterTests.swift`

**Interfaces:**
- Consumes: the already verified `LocalModelIdentity` returned before generation.
- Produces: `chatContent(_:identity:) -> String?`, which discards only an approved bounded GPT-OSS `reasoning_content` string.

- [ ] **Step 1: Add failing identity-specific response tests**

Define a GPT fixture whose fingerprint is exactly `582bd40f6886200101f4c4ed9f25f3fe80cc14c86e9e2b37746cd8904a0c622d`. Require valid `role/content/reasoning_content` plus `finish_reason: stop` to succeed for that fixture while the existing generic/Gemma reasoning mutation still returns `schema_failure`.

Add GPT tests rejecting: non-string reasoning, more than 65,536 UTF-8 bytes, missing or non-stop finish reason, extra message keys, tool calls, multiple choices, response-model mismatch, inline `<think>` content, invalid final JSON, extra final-payload members, and post-generation identity change.

- [ ] **Step 2: Prove the current exact-key parser fails**

```bash
swift test --filter LlamaCppBridgeAdapterTests
```

Expected: the approved GPT fixture fails with `schema_failure` because the current message-key set must equal `role/content`.

- [ ] **Step 3: Implement the narrow adapter**

Add private constants for the approved fingerprint and 65,536-byte limit. Pass `before.identity` to `chatContent`. Accept message keys exactly `role/content` for all identities; accept exactly `role/content/reasoning_content` only when provider is `.llamaCpp`, fingerprint equals the approved value, and the reasoning value is a UTF-8-bounded `String`. Never return the reasoning value. Preserve every existing top-level, choice, finish-reason, model, final-payload, identity, metadata, and grounding check.

- [ ] **Step 4: Run focused bridge and qualification tests**

```bash
swift test --filter 'LlamaCppBridgeAdapterTests|LlamaCppQualificationTests|LocalIntelligenceProviderRouterTests'
```

Expected: PASS; non-GPT reasoning remains rejected.

- [ ] **Step 5: Commit**

```bash
git add Sources/LocalOCRModelBridgeKit/LlamaCppBridgeAdapter.swift tests/LocalOCRModelBridgeKitTests/LlamaCppBridgeAdapterTests.swift
git commit -m "Accept bounded attested GPT OSS reasoning metadata"
```

---

### Task 3: Cache attested llama.cpp version evidence across helpers

**Files:**
- Modify: `Sources/LocalOCRModelBridgeKit/LlamaCppProcessProbe.swift`
- Modify: `Sources/LocalOCRModelBridgeKit/LlamaCppBridgeAdapter.swift`
- Modify: `tests/LocalOCRModelBridgeKitTests/LlamaCppProcessProbeTests.swift`
- Modify: `tests/LocalOCRModelBridgeKitTests/LlamaCppBridgeAdapterTests.swift`

**Interfaces:**
- Consumes: `PinnedLocalFile.Identity` for the exact executable and the existing private hash-cache directory.
- Produces: `cachedVersion(_:) async throws -> String`, backed by `<identity-key>.version`, and explicit mapping of `LMStudioCLIProbeError.timedOut` to `generation_timed_out`.

- [ ] **Step 1: Add failing sustained-cache and error-mapping tests**

Inject a version loader that counts executions. Call `cachedVersion` twenty times using the unchanged pinned executable identity and require one loader call and twenty identical validated results. Recreate the pinned file with changed bytes/identity and require a new loader call. Add invalid-size, malformed, symlink, wrong-mode, and wrong-owner where testable cache cases that fail closed without following or rewriting unsafe targets. Add an adapter mapping test requiring `LMStudioCLIProbeError.timedOut` to produce `generation_timed_out`, not `locality_unverified`.

- [ ] **Step 2: Prove repeated calls currently execute every time**

```bash
swift test --filter 'LlamaCppProcessProbeTests|LlamaCppBridgeAdapterTests'
```

Expected: FAIL because there is no cross-helper version cache and the CLI timeout falls through to `locality_unverified`.

- [ ] **Step 3: Implement the secure version cache**

Add a sendable injected version-loader closure whose production implementation invokes the existing bounded suspended-process runner against the pinned executable descriptor. Compute the cache key from the sorted JSON encoding of `PinnedLocalFile.Identity`, use the existing owner-only cache directory checks, read only a regular owner-only non-hardlinked `.version` file with a 512-byte ceiling, validate it through `validVersion`, and revalidate the pinned file before returning. On `ENOENT`, run and validate the loader, revalidate the file, publish through an owner-only unique temporary file plus `fsync`, `renameat`, and directory `fsync`. Do not use a cached value after any identity mismatch or unsafe cache observation.

Map `LMStudioCLIProbeError.timedOut` to `.generationTimedOut`, cancellation to `.cancelled`, output overflow/malformed execution to `.providerResponseInvalid` or `.providerUnavailable` as appropriate, and loaded-code identity mismatch to `.modelIdentityChanged` or `.localityBlocked`; never translate a command-operational failure into a claim that locality changed.

- [ ] **Step 4: Run focused sustained and safety tests**

```bash
swift test --filter 'LlamaCppProcessProbeTests|LlamaCppBridgeAdapterTests|LocalIntelligenceProviderRegistryTests|LocalIntelligenceProviderRouterTests'
```

Expected: PASS; twenty warm calls execute the version loader once, changed identity misses the cache, and unsafe cache states fail closed.

- [ ] **Step 5: Commit**

```bash
git add Sources/LocalOCRModelBridgeKit/LlamaCppProcessProbe.swift Sources/LocalOCRModelBridgeKit/LlamaCppBridgeAdapter.swift tests/LocalOCRModelBridgeKitTests/LlamaCppProcessProbeTests.swift tests/LocalOCRModelBridgeKitTests/LlamaCppBridgeAdapterTests.swift
git commit -m "Stabilize repeated llama locality attestation"
```

---

### Task 4: Build 8 acceptance instrumentation and private release candidate

**Files:**
- Modify: `Sources/LocalOCRService/LocalOCRRuntime.swift`
- Modify: Studio project/build metadata file selected by the existing build-number guard
- Create: `docs/localocr-build8-acceptance-2026-09-14.md`
- Create: `work/localocr-build8-acceptance/` evidence through existing scripts (kept outside source commits when policy requires)
- Modify: `../reports/mcp-macvision/MCP-MacVision-Time-and-Cost-Log.csv` and project overview only from dated evidence after the milestone closes

**Interfaces:**
- Consumes: Tasks 1-3 and the existing build-7 qualification, activity, packaging, signing, and notarization workflows.
- Produces: LocalOCR `0.3.1` build `8`, a signed/notarized/stapled private ZIP, checksums, an acceptance manifest, and a Pro handoff containing no document content.

- [ ] **Step 1: Add or extend synthetic acceptance checks before metadata changes**

Require two consecutive six-operation harness passes, equipment `$2,000.00` on page 1, twenty sequential generations, exact 17-key ended activity records with one unique record per generation, and a post-sequence status check. Use a clock abstraction or bounded test seam for the ten-minute idle in automated tests; reserve the real ten-minute idle for the controlled Pro run.

- [ ] **Step 2: Run the new checks against pre-build-8 metadata**

Run the focused acceptance entry points documented by the existing harness. Expected: functional tests pass after Tasks 1-3, while metadata guards still report build 7.

- [ ] **Step 3: Advance only the build number and document scope**

Keep marketing version `0.3.1`; change the guarded app build number from `7` to `8`. Document the exact source commits, synthetic fixture hashes, test commands, baseline flake reruns, provider boundaries, and remaining target-machine gates. Do not claim Gemma/GPT acceptance from fixtures or build output.

- [ ] **Step 4: Run complete source and package verification sequentially**

Use stable `/Applications/Xcode.app` after recording `xcodebuild -version`. Run `swift test`, the full Python suite, native helper build and smoke scripts, style/privacy/policy inventories, Studio project tests, unsigned app build, and release staging sequentially. Rerun any baseline-only flaky cleanup test separately and record both outcomes without rewriting the original full-run result.

- [ ] **Step 5: Sign, notarize, staple, and verify the private candidate**

Use Developer Team `DZ8B5454ZN` and the existing Air `localocr-notary` Keychain profile. Build with stable Xcode, sign nested helpers/binaries first and the app last with Hardened Runtime, verify every signature, reject absolute Xcode RPATHs and non-Apple/non-system shipped dependencies, submit with `notarytool`, staple, verify the ticket, run `spctl`, extract a fresh copy, and repeat signature/helper/checksum verification. Preserve the notarization UUID and all command logs.

- [ ] **Step 6: Send the candidate to the Pro for controlled acceptance**

Send the signed/notarized ZIP, SHA-256, source commit, and content-free acceptance instructions directly to task `01a08b26-fb24-7391-9450-b0ff52d240b7`. The Pro owner controls model-server launch. Require: two consecutive Gemma Q8 qualifications, two consecutive GPT-OSS 120B qualifications, two consecutive six-operation harnesses, equipment `$2,000.00` page 1, twenty operations, a real ten-minute idle, unchanged process identity, and exactly one readable 17-key activity record per generation. Do not bypass the changed Pro SSH host key.

- [ ] **Step 7: Reconcile evidence and records, then commit source metadata/docs**

Update the time-and-cost log and project overview from dated command/test/notary receipts only; leave unsupported hours or costs blank. Commit tracked metadata and documentation, leaving private model paths, document content, credentials, and machine-specific evidence out of the public source tree.

