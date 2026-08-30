# LocalOCR Studio Beta 2.1 Implementation Plan

> **For agentic workers:** Follow this plan task by task. Use test-driven development for every behavior change, preserve the local-only privacy boundary, and do not cross a merge, signing, installation, or publication gate without the authorization stated in that task.

**Goal:** Ship LocalOCR Studio Beta 2.1 as version 0.3.1 build 4 with offline Help, guided MCP connection for Codex and Claude, the existing Local Intelligence provider work, and a release bundle that contains all three native helpers.

**Architecture:** Vision OCR remains authoritative. Local Intelligence consumes a copy of OCR text through an explicitly selected on-device provider. The app discovers supported agent clients from bounded local locations and invokes their official CLIs with `Process(executableURL:arguments:)`; it never edits client configuration directly or uses a shell. Release assembly signs nested helpers before the containing app and proves the exact artifact through notarization, Gatekeeper, downloaded-package, and target-Mac evidence.

**Tech Stack:** Swift 6, SwiftUI, Swift Package Manager, XcodeGen/Xcode, XCTest, Python 3/pytest, Apple Vision, Apple Foundation Models, MCP over stdio, Hardened Runtime, `codesign`, `notarytool`, `spctl`, GitHub Releases, Cloudflare Pages.

**Approved specification:** `docs/superpowers/specs/2026-08-30-localocr-beta-2-1-design.md`

## Global constraints

- Treat OCR text and searchable PDFs as authoritative output; AI results remain separately labeled and cannot overwrite them.
- Permit no remote, relayed, wildcard, or locality-ambiguous model endpoint. Apple Foundation Models, qualified Ollama loopback, and qualified LM Studio loopback are the only model providers in this release.
- Keep the MCP catalog at exactly nine documented tools and require current consent where a tool sends OCR text to an external local runtime.
- Use stable Xcode. Reject absolute Xcode runtime paths and non-Apple dynamic dependencies in shipped executables.
- Preserve unrelated worktree changes. Record acceptance evidence from the exact commit and dated commands only.
- Stop at each separately named merge, signing, installation, and publication gate unless the user has explicitly authorized that gate after reviewing its evidence.

### Task 1: Reconcile the Local Intelligence candidate with published Beta 2

**Files:**
- Modify only conflict files selected by `git merge main`
- Verify `Package.swift`
- Verify `project.yml`
- Verify `LocalOCRStudio.xcodeproj/project.pbxproj`

**Step 1: Capture the exact starting state**

Run:

```bash
git status --short --branch
git rev-parse HEAD
git log --oneline --left-right HEAD...main
```

Expected: branch `feature/local-intelligence-mcp-faq`, clean worktree, and both candidate-only and main-only commits visible.

**Step 2: Run a focused pre-merge baseline**

Run:

```bash
swift test --filter AgentConnectionGuideModelTests
swift test --filter StudioLocalModelManagerViewModelTests
.venv/bin/python -m pytest -q tests/contract/test_studio_app_project.py tests/contract/test_beta2_candidate_documentation.py
```

Expected: all focused tests pass before reconciliation.

**Step 3: Merge current `main` without flattening history**

Run:

```bash
git merge --no-ff main
```

Resolve conflicts by preserving the Local Intelligence implementation and tests while accepting the published Beta 2 icon assets, build-3 release records, and public documentation. Do not discard either history.

**Step 4: Regenerate and verify the Xcode project**

Run:

```bash
xcodegen generate
git diff --check
swift test --filter AgentConnectionGuideModelTests
swift test --filter StudioLocalModelManagerViewModelTests
.venv/bin/python -m pytest -q tests/contract/test_studio_app_project.py tests/contract/test_beta2_candidate_documentation.py
```

Expected: generation is reproducible and focused tests pass.

**Step 5: Commit only if conflict resolution was not captured by the merge commit**

```bash
git add Package.swift project.yml LocalOCRStudio.xcodeproj App Sources tests docs scripts README.md
git commit -m "merge: reconcile Local Intelligence with beta 2"
```

### Task 2: Build a native offline Help Center

**Files:**
- Create `Sources/LocalOCRStudioKit/HelpCenterModel.swift`
- Create `Sources/LocalOCRStudioKit/HelpCenterView.swift`
- Create `tests/LocalOCRStudioKitTests/HelpCenterModelTests.swift`
- Modify `App/LocalOCRStudioApp.swift`
- Modify `App/LocalOCRStudioUITestSupport.swift`
- Modify `tests/LocalOCRStudioKitTests/StudioViewContractTests.swift`

**Step 1: Write the failing Help model tests**

Define stable topics for getting started, single-document OCR, desktop batch, outputs, Local Intelligence, Apple Foundation Models, local runtimes, agent connection, privacy, troubleshooting, FAQ, and version/build. Assert ordering, search terms, privacy wording, and version/build rendering.

Run:

```bash
swift test --filter HelpCenterModelTests
```

Expected: compilation fails because the Help model does not exist.

**Step 2: Implement the smallest offline Help model**

Use value types with stable identifiers and bundled strings. Do not fetch or render network content. Include searchable title, summary, body, and keywords for every topic.

**Step 3: Implement the Help window and menu ownership**

Add a reusable Help window with search and topic navigation. Replace the dead system Help behavior with three explicit menu items:

1. `LocalOCR Studio Help`
2. `Connect to Your Agent`
3. `Report Beta Feedback`

The first two open reusable native windows. The feedback item opens the documented public feedback destination and does not transmit document content.

**Step 4: Add deterministic UI fixtures and contracts**

Expose launch arguments that open Help at a named topic and render a stable accessibility identifier. Add source contracts proving the menu labels and native Help window exist.

**Step 5: Run the focused tests**

```bash
swift test --filter HelpCenterModelTests
swift test --filter StudioViewContractTests
xcodebuild -project LocalOCRStudio.xcodeproj -scheme LocalOCRStudio -configuration Debug build
```

Expected: Help tests, source contracts, and the Debug app build pass.

**Step 6: Commit**

```bash
git add App Sources/LocalOCRStudioKit tests/LocalOCRStudioKitTests
git commit -m "feat: add offline LocalOCR help center"
```

### Task 3: Add a shell-free agent connection engine

**Files:**
- Create `Sources/LocalOCRStudioKit/AgentClientConnection.swift`
- Create `Sources/LocalOCRStudioKit/AgentClientDiscovery.swift`
- Create `Sources/LocalOCRStudioKit/AgentClientCommandRunner.swift`
- Create `tests/LocalOCRStudioKitTests/AgentClientConnectionTests.swift`
- Create `tests/LocalOCRStudioKitTests/AgentClientDiscoveryTests.swift`
- Create `tests/LocalOCRStudioKitTests/AgentClientCommandRunnerTests.swift`

**Step 1: Write failing command-spec tests**

Define `AgentClientKind`, `ClaudeMCPConnectionScope`, `AgentClientInstallation`, and `AgentClientCommandSpec`. Assert exact argument arrays for Codex inspect/connect/disconnect and Claude inspect/connect/disconnect. Assert that arguments, not an interpolated shell string, carry the helper path.

**Step 2: Write failing discovery tests**

Use a temporary fake filesystem. Test bounded discovery in known application-bundle paths and literal executable directories. Reject non-executable files, symlinks escaping approved locations, and unsupported client versions.

**Step 3: Write failing process-runner tests**

Use fixture executables to prove:

- stdout and stderr are captured separately;
- output is capped at 1 MiB;
- timeout terminates and reaps the child;
- cancellation terminates and reaps the child;
- environment and arguments are explicit;
- no shell executable is accepted as a client binary.

**Step 4: Implement command specifications and discovery**

Keep all client-specific command construction in pure functions. Discovery may inspect metadata and executable presence but may not launch the client.

**Step 5: Implement the bounded runner**

Use Foundation `Process` with `executableURL` and `arguments`. Sanitize surfaced errors so credentials, environment values, and unrelated client configuration are not displayed or logged.

**Step 6: Run the focused tests**

```bash
swift test --filter AgentClientConnectionTests
swift test --filter AgentClientDiscoveryTests
swift test --filter AgentClientCommandRunnerTests
```

Expected: all tests pass, including timeout and output-cap cases.

**Step 7: Commit**

```bash
git add Sources/LocalOCRStudioKit tests/LocalOCRStudioKitTests
git commit -m "feat: add safe agent connection engine"
```

### Task 4: Turn the guide into Connect, Inspect, and Disconnect workflows

**Files:**
- Modify `Sources/LocalOCRStudioKit/AgentConnectionGuideModel.swift`
- Modify `Sources/LocalOCRStudioKit/AgentConnectionGuideView.swift`
- Modify `tests/LocalOCRStudioKitTests/AgentConnectionGuideModelTests.swift`
- Modify `App/LocalOCRStudioUITestSupport.swift`
- Modify `tests/contract/test_studio_app_project.py`

**Step 1: Extend failing guide-model tests**

Add states for unavailable, inspecting, disconnected, connected with exact helper path, conflict, and failed. Test that:

- inspect distinguishes this app's helper from another `localocr` registration;
- connect requires the current external-agent acknowledgment and a final confirmation;
- disconnect removes only the registration selected by the user;
- Claude requires an explicit local or user scope;
- generic clients remain copy-only;
- no path can request an agent force-quit.

**Step 2: Implement state transitions with injected dependencies**

Inject discovery, command runner, consent store, and clock. Keep the UI model deterministic and independently testable. Refresh status after each successful mutation.

**Step 3: Implement the guided UI**

Show detected clients, actual registration status, helper path, and clear Connect/Disconnect buttons. Put confirmation text immediately before mutation. Keep manual commands available as copyable fallback. Explain that the agent may need a normal restart, but never offer to kill it.

**Step 4: Add UI fixtures that never touch real client configuration**

Use fake discovery and command results for connected, disconnected, conflict, and failure screens. Add accessibility identifiers for client selection, scope, confirmation, Connect, Disconnect, and status.

**Step 5: Run focused model, UI-contract, and app-build tests**

```bash
swift test --filter AgentConnectionGuideModelTests
.venv/bin/python -m pytest -q tests/contract/test_studio_app_project.py
xcodebuild -project LocalOCRStudio.xcodeproj -scheme LocalOCRStudio -configuration Debug build
```

Expected: tests pass without altering the developer machine's Codex or Claude configuration.

**Step 6: Commit**

```bash
git add App Sources/LocalOCRStudioKit tests/LocalOCRStudioKitTests tests/contract/test_studio_app_project.py
git commit -m "feat: guide MCP connection from Studio"
```

### Task 5: Package and police the third native helper

**Files:**
- Create `scripts/validate-model-bridge-policy.py`
- Modify `scripts/build-native-tools.sh`
- Modify `scripts/build-unsigned-studio-app.sh`
- Modify `scripts/stage-direct-release.sh`
- Modify `scripts/sign-direct-release.sh`
- Modify `scripts/verify-direct-release.sh`
- Modify `scripts/notarize-direct-release.sh`
- Modify `scripts/test-downloaded-release.sh`
- Modify `scripts/smoke-native-tools.sh`
- Modify `scripts/release-toolchain.sh`
- Modify `tests/contract/test_direct_release_scripts.py`
- Modify `tests/contract/test_release_artifacts.py`
- Modify `tests/contract/test_native_python_compatibility.py`

**Step 1: Add failing exact-inventory release tests**

Assert that the app contains exactly:

```text
Contents/Helpers/localocr
Contents/Helpers/localocr-mcp
Contents/Helpers/localocr-model-bridge
```

Assert helper-first/app-last signing, per-helper signature verification, per-helper dependency/RPATH inspection, and bridge inclusion in artifact hashes.

**Step 2: Add the failing bridge policy validator tests**

The validator must reject non-loopback hosts, wildcard binds, remote redirects, proxy-environment inheritance, and unbounded response bodies. It must accept only the bridge's explicit Ollama and LM Studio loopback routes.

**Step 3: Implement the policy validator**

Parse source and staged binary evidence deterministically. Produce machine-readable pass/fail output suitable for the release evidence folder.

**Step 4: Extend build, stage, sign, and verify scripts**

Build universal or approved architecture slices with stable Xcode. Copy the bridge into `Contents/Helpers`, sign all three helpers before the app, verify every nested signature, and reject absolute Xcode RPATHs or non-Apple/system dynamic dependencies.

**Step 5: Extend native smoke tests**

Use a fake local loopback provider. Prove the bridge can list models and respond through its framed protocol while remote and ambiguous endpoints fail closed. Do not require Ollama or LM Studio installation for automated release tests.

**Step 6: Run the focused release tests**

```bash
.venv/bin/python -m pytest -q tests/contract/test_direct_release_scripts.py tests/contract/test_release_artifacts.py tests/contract/test_native_python_compatibility.py
scripts/build-native-tools.sh
scripts/smoke-native-tools.sh
.venv/bin/python scripts/validate-model-bridge-policy.py
```

Expected: exact helper inventory and local-only policy pass.

**Step 7: Commit**

```bash
git add scripts tests/contract
git commit -m "build: package LocalOCR model bridge"
```

### Task 6: Set version 0.3.1 build 4 and align public guidance

**Files:**
- Modify `project.yml`
- Modify `LocalOCRStudio.xcodeproj/project.pbxproj`
- Modify `Sources/LocalOCRService/LocalOCRRuntime.swift`
- Modify `README.md`
- Modify `BETA_TESTING.md`
- Modify `docs/studio.md`
- Modify `docs/cli.md`
- Modify `docs/mcp.md`
- Create `docs/release/v0.3.1-beta.1-notes.md`
- Modify documentation contract tests under `tests/contract/`

**Step 1: Write failing version and documentation contracts**

Require version `0.3.1`, build `4`, title `LocalOCR Studio Beta 2.1`, tag `v0.3.1-beta.1`, the three-helper inventory, exactly nine MCP tools, Apple/Ollama/LM Studio claims, offline Help, consent language, and supported client setup. Require a clear distinction between automatic Codex/Claude setup and copy-only generic-client instructions.

**Step 2: Update version sources and regenerate the Xcode project**

```bash
xcodegen generate
```

Confirm the generated project matches `project.yml` and runtime-reported versions.

**Step 3: Update tester and developer documentation**

Lead with the desktop app. Put advanced MCP setup after desktop use. Include exact Codex CLI and Claude CLI guidance, generic JSON concepts without pretending all clients use the same schema, provider-selection behavior, acknowledgments, troubleshooting, and Beta 2.1 limitations.

**Step 4: Add release notes**

Describe offline Help, guided connection, Local Intelligence providers, desktop batch, exact privacy boundaries, macOS requirements, known limitations, and the no-silent-switching rule.

**Step 5: Run documentation and version tests**

```bash
.venv/bin/python -m pytest -q tests/contract/test_beta_documentation_alignment.py tests/contract/test_beta_tester_guide.py tests/contract/test_mcp_consent_and_intelligence_documentation.py tests/contract/test_studio_app_project.py
swift test --filter MCPToolCatalogTests
```

Expected: all claims align with implemented behavior and the catalog contains exactly nine tools.

**Step 6: Commit**

```bash
git add project.yml LocalOCRStudio.xcodeproj Sources/LocalOCRService README.md BETA_TESTING.md docs tests/contract
git commit -m "docs: prepare LocalOCR beta 2.1"
```

### Task 7: Produce exact-commit candidate acceptance evidence

**Files:**
- Modify `docs/release/local-intelligence-candidate-acceptance.md`
- Create `docs/release/v0.3.1-beta.1-candidate-acceptance.md`
- Update dated records under `/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/reports/mcp-macvision/`

**Step 1: Seal the candidate identity**

Record UTC time, commit, branch, clean status, stable Xcode build/version, Swift version, Python version, macOS version, architecture, and machine identity.

**Step 2: Run full automated verification from a clean build state**

```bash
swift package clean
swift test
xcodebuild -project LocalOCRStudio.xcodeproj -scheme LocalOCRStudio -configuration Debug clean build
xcodebuild -project LocalOCRStudio.xcodeproj -scheme LocalOCRStudio -configuration Release clean build
.venv/bin/python scripts/validate-mcp-stdio-policy.py
.venv/bin/python scripts/validate-model-bridge-policy.py
scripts/build-native-tools.sh
scripts/smoke-native-tools.sh
.venv/bin/python -m pytest -q Tests
git diff --check
git status --short
```

Expected: every command passes and the worktree is clean except for newly created evidence files.

**Step 3: Run live Apple Foundation Models acceptance**

On a supported Mac, use a synthetic two-page document with known facts. Record provider availability, cold and warm latency separately, three Local Intelligence actions, grounding validation, refusal/error behavior, and proof that OCR text did not change.

**Step 4: Run MCP and agent-connection acceptance**

Exercise all nine MCP tools with synthetic documents. Confirm consent-gated intelligence tools refuse before acknowledgment and succeed after it. Inspect/connect/disconnect a disposable test registration for Codex and Claude, confirm exact-helper conflict handling, and confirm no agent process is killed.

**Step 5: Run local-runtime acceptance when already available**

If Ollama or LM Studio is already installed and running, qualify it and execute a synthetic-document request. Do not install, start, stop, or reconfigure either runtime merely to complete this gate. Record unavailable as unavailable, not as a pass.

**Step 6: Record privacy and network evidence**

Observe the app and MCP during Vision OCR and Apple Foundation Models flows. Verify no network handles. For an explicitly selected local runtime, verify connections stay on approved loopback addresses and fail closed when the provider becomes ambiguous.

**Step 7: Update business records from dated evidence**

Update the project overview and time-and-cost log using only dated evidence and known direct or reasonably allocated costs. Do not invent hours or amounts. Preserve final commit, test, and candidate-release evidence.

**Step 8: Commit acceptance records**

```bash
git add docs/release
git commit -m "test: seal LocalOCR beta 2.1 candidate"
```

The reports folder is outside the release repository. Commit its changes separately if it belongs to a repository; otherwise preserve dated file hashes alongside the release evidence. Record the release-repository commit and the reports-repository commit or dated hashes.

### Task 8: Review and merge the candidate

**Files:**
- Review all files changed from the merge base
- Preserve untracked main-checkout files, including `AGENTS.md` and `downloads/`

**Step 1: Review the complete candidate diff**

```bash
git diff --stat main...HEAD
git diff --check main...HEAD
git log --oneline main..HEAD
```

Review privacy boundaries, subprocess safety, connection mutations, timeout/reaping, local-runtime qualification, packaged helper inventory, version consistency, Help content, and release scripts.

**Step 2: Fix every critical or important review finding with a failing test**

Rerun the smallest relevant test after each fix, then rerun Task 7's full automated verification.

**Step 3: Present merge evidence and stop at the merge gate**

Report exact candidate commit, clean status, test counts, manual acceptance results, and remaining limitations. Merge only after explicit merge authorization based on this evidence.

**Step 4: Merge without rewriting candidate history**

After authorization:

```bash
git switch main
git merge --ff-only feature/local-intelligence-mcp-faq
git status --short --branch
```

Do not tag, push, sign, install, or publish as part of the merge unless those gates are also explicitly authorized.

### Task 9: Sign, notarize, install, and publish Beta 2.1

**Files:**
- Create immutable release evidence under `artifacts/release/`
- Update `docs/release/second-mac-acceptance.md`
- Update public download metadata and website only after publication authorization
- Update `/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/reports/mcp-macvision/`

**Step 1: Present the merged exact-commit release candidate and stop at the signing gate**

Require explicit authorization for signing/notarization. Use stable Xcode, Developer Team `DZ8B5454ZN`, the installed Developer ID Application certificate, and Keychain profile `localocr-notary`.

**Step 2: Build from an immutable detached worktree**

Create a temporary detached worktree at the authorized release commit. Run the release toolchain preflight, build all helpers, and stage `LocalOCR Studio.app` with exact version 0.3.1 build 4.

**Step 3: Sign nested code first and the app last**

Run the repository release scripts with identity `Developer ID Application: John Scott Ray (DZ8B5454ZN)`. Verify every helper and the containing app, Hardened Runtime, entitlements, RPATHs, dependencies, and sealed resources before notarization.

**Step 4: Notarize and staple through the repository pipeline**

Set `LOCALOCR_NOTARY_PROFILE=localocr-notary` for `scripts/notarize-direct-release.sh`. Preserve submission JSON, notarization log, stapler output, `codesign` verification, and `spctl` assessment in the immutable evidence directory.

**Step 5: Create and verify the downloadable archive**

Create `LocalOCR-Studio-0.3.1-4.zip` and its SHA-256 file from the stapled app. Run `scripts/test-downloaded-release.sh` against a fresh download copy and confirm exact version, build, signatures, ticket, Gatekeeper acceptance, and three-helper inventory.

**Step 6: Present distribution evidence and stop at installation/publication gates**

Install only after explicit device-install authorization. Publish only after explicit publication authorization.

**Step 7: Install and accept on the authorized Macs**

Back up each existing app, install via SSH where available, launch in an unlocked user session, and run desktop OCR, batch, Help, Local Intelligence, and MCP acceptance on the MacBook Air, MacBook Pro, and Mac mini. Distinguish exact-build acceptance from historical installation claims.

**Step 8: Publish the GitHub prerelease and website update**

After publication authorization, push the merged commit and annotated tag `v0.3.1-beta.1`, create the GitHub prerelease, upload the archive and SHA-256 file, verify the public release page, update the website CTA and Beta 2.1 feature copy, deploy through the established Cloudflare workflow, and verify the downloaded public artifact again.

**Step 9: Close the release records**

Record public URLs, exact tag/commit, artifact SHA-256, notarization ID, Gatekeeper results, per-Mac acceptance, website verification, and known limitations. Establish the Beta 2.1 download baseline and begin dated beta metrics and feedback logs. Reconcile provisional time/cost rows from evidence without inventing final hours.

**Step 10: Final audit**

Verify that source, tag, release assets, website copy, Help content, MCP instructions, version/build strings, business records, and beta metrics all describe the same Beta 2.1 artifact.
