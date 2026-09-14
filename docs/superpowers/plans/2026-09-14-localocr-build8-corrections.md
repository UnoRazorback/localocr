# LocalOCR 0.3.1 Build 8 Corrections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a private LocalOCR 0.3.1 build 8 candidate that preserves table associations, safely supports the attested GPT-OSS 120B response shape, and remains locally verified across sustained llama.cpp use.

**Architecture:** Reconstruct row-oriented intelligence text only from valid Vision line geometry while leaving public OCR text unchanged. Bind the GPT-OSS exception to the conjunction of one exact runtime alias and one immutable GGUF fingerprint, and keep all final-schema, identity, locality, and grounding gates. Persist only validated harness-version evidence under the existing private executable-identity cache so repeated helper processes do not relaunch the resident model executable for `--version`.

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

### Task 2: Add the alias-and-fingerprint-bound GPT-OSS response adapter

**Files:**
- Modify: `Sources/LocalOCRModelBridgeKit/LlamaCppBridgeAdapter.swift`
- Modify: `tests/LocalOCRModelBridgeKitTests/LlamaCppBridgeAdapterTests.swift`

**Interfaces:**
- Consumes: the already verified `LocalModelIdentity` returned before generation.
- Produces: `chatContent(_:identity:) -> String?`, which discards only a bounded GPT-OSS `reasoning_content` string for exact alias `gpt-oss-120b-mxfp4` and the approved fingerprint.

- [ ] **Step 1: Add failing identity-specific response tests**

Define a GPT fixture whose alias is exactly `gpt-oss-120b-mxfp4` and fingerprint is exactly `582bd40f6886200101f4c4ed9f25f3fe80cc14c86e9e2b37746cd8904a0c622d`. Require valid `role/content/reasoning_content` plus `finish_reason: stop` to succeed only for that pair while exact-fingerprint/wrong-alias, exact-alias/wrong-fingerprint, and existing generic/Gemma reasoning mutations return `schema_failure`.

Add GPT tests rejecting: non-string reasoning, more than 65,536 UTF-8 bytes, missing or non-stop finish reason, extra message keys, tool calls, multiple choices, response-model mismatch, inline `<think>` content, invalid final JSON, extra final-payload members, and post-generation identity change.

- [ ] **Step 2: Prove the current exact-key parser fails**

```bash
swift test --filter LlamaCppBridgeAdapterTests
```

Expected: the approved GPT fixture fails with `schema_failure` because the current message-key set must equal `role/content`.

- [ ] **Step 3: Implement the narrow adapter**

Add private constants for the approved alias, approved fingerprint, and 65,536-byte limit. Pass `before.identity` to `chatContent`. Accept message keys exactly `role/content` for all identities; accept exactly `role/content/reasoning_content` only when provider is `.llamaCpp`, model alias equals the approved alias, fingerprint equals the approved value, and the reasoning value is a UTF-8-bounded `String`. Never return the reasoning value. Preserve every existing top-level, choice, finish-reason, model, final-payload, identity, metadata, and grounding check.

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

### Task 4: Add synthetic endurance acceptance and advance build metadata

**Files:**
- Create: `tests/LocalOCRIntelligenceTests/Build8EnduranceAcceptanceTests.swift`
- Modify: `project.yml`
- Modify: `LocalOCR Studio.xcodeproj/project.pbxproj`
- Modify: `scripts/build-unsigned-studio-app.sh`
- Modify: `tests/contract/test_studio_app_project.py`
- Modify: `tests/contract/test_direct_release_scripts.py`
- Modify: `tests/contract/test_beta_documentation_alignment.py`
- Modify: `README.md`
- Modify: `BETA_TESTING.md`
- Modify: `docs/studio.md`
- Create: `docs/localocr-build8-acceptance-2026-09-14.md`

**Interfaces:**
- Consumes: Tasks 1-3 and the existing router, qualification, and Local AI Activity test seams.
- Produces: automated twenty-operation/endurance regression coverage and source metadata for LocalOCR `0.3.1` build `8`.

- [ ] **Step 1: Add or extend synthetic acceptance checks before metadata changes**

Add `Build8EnduranceAcceptanceTests` using existing in-process fixture providers, selection/qualification stores, activity reporter, and temporary secure activity store. Require twenty sequential successful generations against one unchanged llama identity, twenty unique ended records, each JSON object containing exactly `LocalAIActivityContract.v1Keys`, and post-sequence selected/available/qualified status. Simulate a monotonic ten-minute interval through an injected clock/test seam without sleeping; reserve the real ten-minute idle for the controlled Pro run. Keep two consecutive six-operation real-model harnesses and both models' consecutive qualifications as target-machine gates.

- [ ] **Step 2: Run the new checks against pre-build-8 metadata**

Run:

```bash
swift test --filter 'Build8EnduranceAcceptanceTests|OCRLayoutTextAssemblerTests|LlamaCppBridgeAdapterTests|LlamaCppProcessProbeTests|LlamaCppQualificationTests'
```

Expected before adding the new endurance fixture: FAIL because `Build8EnduranceAcceptanceTests` does not exist or its twenty-record/status requirements are not met. After the test seam is complete and before metadata changes, functional tests pass while Python metadata guards still report build 7.

- [ ] **Step 3: Advance only the build number and document scope**

Keep marketing version `0.3.1`; change every current private-candidate build number from `7` to `8` in the project, generated Xcode project, unsigned-build script, exact contract constants, README, Beta guide, and Studio guide. Preserve the existing planned tag without publishing it. Document the exact source commits, synthetic fixture hashes, test commands, baseline flake reruns, provider boundaries, stable Xcode toolchain, macOS 27 GR target gate, and remaining target-machine gates. Do not claim Gemma/GPT acceptance from fixtures or build output.

- [ ] **Step 4: Run focused Swift and metadata tests**

```bash
swift test --filter 'Build8EnduranceAcceptanceTests|OCRLayoutTextAssemblerTests|LlamaCppBridgeAdapterTests|LlamaCppProcessProbeTests|LlamaCppQualificationTests'
python3 -m pytest -q tests/contract/test_studio_app_project.py tests/contract/test_direct_release_scripts.py tests/contract/test_beta_documentation_alignment.py
```

Expected: PASS with build 8 aligned everywhere and no activity-record content beyond the approved 17-key contract.

- [ ] **Step 5: Commit**

```bash
git add tests/LocalOCRIntelligenceTests/Build8EnduranceAcceptanceTests.swift project.yml 'LocalOCR Studio.xcodeproj/project.pbxproj' scripts/build-unsigned-studio-app.sh tests/contract/test_studio_app_project.py tests/contract/test_direct_release_scripts.py tests/contract/test_beta_documentation_alignment.py README.md BETA_TESTING.md docs/studio.md docs/localocr-build8-acceptance-2026-09-14.md
git commit -m "Prepare LocalOCR 0.3.1 build 8 acceptance"
```

---

### Task 5: Verify, sign, and notarize the private Build 8 candidate

**Files:**
- Modify: `scripts/release-toolchain.sh`
- Modify: `tests/contract/test_direct_release_scripts.py`
- Modify: `README.md`
- Modify: `BETA_TESTING.md`
- Modify: `docs/studio.md`
- Modify: `docs/mcp.md`
- Create: `work/localocr-build8-acceptance/` evidence through existing scripts; keep machine evidence outside source commits.
- Modify: `docs/localocr-build8-acceptance-2026-09-14.md` only with content-free final outcomes and durable evidence locations.

**Interfaces:**
- Consumes: Task 4 HEAD and the existing native build, release staging, signing, notarization, download-test, privacy, and policy workflows.
- Produces: a signed/notarized/stapled private ZIP, SHA-256 file, exact source commit, notarization UUID, and extracted-artifact verification.

- [ ] **Step 1: Write a failing stable-release-toolchain contract test**

Change the release-toolchain contract fixtures to require `/Applications/Xcode.app/Contents/Developer` and exact `xcodebuild -version` output `Xcode 26.6\nBuild version 17F113`. Keep rejection tests for symlinked/missing developer directories, mismatched builds, PATH shims, changed loaded code, and absolute tool paths. Run the focused test before implementation and require failure on the old Xcode 27 RC pin.

- [ ] **Step 2: Align the release workflow to stable Xcode 26.6**

Change only the release developer-directory and exact-version pins plus corresponding user-facing current toolchain copy. Preserve descriptor-pinned execution, loaded-code checks, Swift backend flags, SDK derivation from the pinned Xcode, and all rejection paths. Rerun the focused release-toolchain tests and require PASS.

- [ ] **Step 3: Record the stable toolchain and clean source identity**

Record `git status --short`, `git rev-parse HEAD`, `xcode-select -p`, `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version`, `sw_vers`, and the Developer ID identity inventory into the Build 8 evidence directory. Require a clean tracked source tree and Xcode 26.6 build `17F113` or stop and document the new stable version instead of silently switching toolchains.

- [ ] **Step 4: Run complete source verification sequentially**

With `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and the matching SDK, run full `swift test`, the full Python suite, native helper build and smoke scripts, style/privacy/policy inventories, and Studio project tests sequentially. Rerun any baseline-only flaky cleanup test separately and record both outcomes without rewriting the original full-run result.

- [ ] **Step 5: Build and stage the unsigned app**

Use the existing build/stage scripts with `LOCALOCR_RELEASE_VERSION=0.3.1` and `LOCALOCR_RELEASE_BUILD=8`. Verify exact bundle version/build, app identifier, three-helper inventory, architecture, Hardened Runtime configuration, and absence of prohibited entitlements before signing.

- [ ] **Step 6: Sign nested code first and containing app last**

Use Developer Team `DZ8B5454ZN` and the installed Developer ID Application identity. Run `scripts/sign-direct-release.sh`; verify each of `localocr`, `localocr-mcp`, `localocr-model-bridge`, the main executable, and the containing app with strict codesign checks and required activity entitlements only on the approved producer binaries.

- [ ] **Step 7: Notarize, staple, and verify a fresh archive**

Use the existing Air `localocr-notary` Keychain profile with `scripts/notarize-direct-release.sh`. Preserve the submission UUID and Accepted result, staple the ticket, run `spctl`, reject absolute Xcode RPATHs and non-Apple/non-system helper dependencies, create `LocalOCR-Studio-0.3.1-8.zip` plus `.sha256`, extract a fresh copy, and rerun signature, ticket, Gatekeeper, helper-inventory, dependency, RPATH, and checksum verification.

- [ ] **Step 8: Append source review evidence and commit the content-free acceptance record**

Append exact commands/outcomes, source commit, ZIP hash, notarization UUID, and limitations to `docs/localocr-build8-acceptance-2026-09-14.md`. Do not include credentials, document text, paths to private models, or claim real-model qualification. Commit only that tracked acceptance-doc update.

---

### Task 6: Deliver to the Pro and close controlled acceptance

**Files:**
- Modify: `docs/localocr-build8-acceptance-2026-09-14.md` with content-free Pro results after receipt.
- Modify: sibling `reports/mcp-macvision/MCP-MacVision-Time-and-Cost-Log.csv` and project overview only from dated evidence after the milestone closes.

**Interfaces:**
- Consumes: Task 5 signed/notarized archive, SHA-256, source commit, and acceptance instructions.
- Produces: authenticated Pro receipt, target macOS 27 GR qualification/harness/endurance evidence, and reconciled milestone records.

- [ ] **Step 1: Send the candidate to the verified Pro task**

Send the signed/notarized ZIP, SHA-256, source commit, and content-free acceptance instructions directly to task `01a08b26-fb24-7391-9450-b0ff52d240b7`. Do not bypass the changed SSH host key. The Pro owner controls model-server launch and the macOS 27 GR upgrade/reboot.

- [ ] **Step 2: Require exact post-upgrade environment evidence**

Require the Pro to record `sw_vers`, machine architecture, installed app version/build, ZIP checksum, codesign/ticket/Gatekeeper results, and three-helper inventory after the macOS 27 GR upgrade. An upgrade statement or build success is not target acceptance.

- [ ] **Step 3: Run the controlled real-model gates**

Require two consecutive Gemma Q8 qualifications, two consecutive GPT-OSS 120B qualifications, two consecutive six-operation synthetic harnesses, equipment `$2,000.00` page 1, twenty sequential operations, a real ten-minute idle, unchanged PID/alias/fingerprint/listener, post-idle selected/available/qualified status, and exactly one readable 17-key activity record per generation. Preserve only synthetic results and content-free real-document timing/SHA evidence.

- [ ] **Step 4: Record the receipt without overstating failures**

Record each gate PASS/FAIL separately. A failing model gate leaves Build 8 unaccepted even if signing, OCR, or other model operations pass. Do not rerun with company documents, weaken qualification, or infer that an unchanged listener proves all locality fields.

- [ ] **Step 5: Reconcile evidence and records, then commit source documentation**

Update the time-and-cost log and project overview from dated command/test/notary receipts only; leave unsupported hours or costs blank. Commit tracked acceptance documentation and recordkeeping changes, leaving private model paths, document content, credentials, and machine-specific raw evidence out of the source tree.
