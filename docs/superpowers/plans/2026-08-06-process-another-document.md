# LocalOCR Studio Process Another Document Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a visible result-screen action that immediately returns LocalOCR Studio to its empty drop/open screen so the user can process another document.

**Architecture:** Extend the existing `StudioViewContract` with one result-only capability, wire a secondary footer button through `StudioResultView` to a focused reset method in `LocalOCRStudioView`, and reuse `StudioViewModel.clear()` for the model transition. Keep view-owned searchable-PDF and drop lifecycle cleanup explicit and test the contract, lifecycle invalidation, source wiring, and real UI transition.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, XCTest UI tests, Python 3/pytest contract tests, Xcode 26.6, macOS 14 deployment target, Developer ID, Hardened Runtime, `notarytool`, `stapler`, `spctl`

## Global Constraints

- The visible label is exactly `Process Another Document`.
- The accessibility identifier is exactly `studio.process-another`.
- The action appears for PDF and image results and nowhere else.
- Activation immediately clears the result without confirmation.
- The action is disabled while searchable-PDF creation is active.
- Source documents and previously saved outputs are never modified or deleted.
- The desktop app remains a one-document workflow; MCP batch behavior is unchanged.
- Version/build remain `0.2.0` / `1`, bundle identifier remains `com.rayconsulting.localocr`, architecture remains arm64, and minimum macOS remains 14.0.
- Direct distribution remains private and unpublished until the owner explicitly approves publication.
- Release production uses stable Xcode 26.6, Developer Team `DZ8B5454ZN`, helper-first signing, Hardened Runtime, notarization, stapling, Gatekeeper assessment, and two-Mac acceptance.

---

### Task 1: Expose the result-only capability in the view contract

**Files:**
- Modify: `tests/LocalOCRStudioKitTests/StudioViewContractTests.swift`
- Modify: `Sources/LocalOCRStudioKit/StudioStatusViews.swift`

**Interfaces:**
- Consumes: `StudioViewContract.init(state: StudioState)`
- Produces: `StudioViewContract.canProcessAnotherDocument: Bool`

- [ ] **Step 1: Write the failing contract assertions**

Add `canProcessAnotherDocument` assertions to every state test:

```swift
@Test func emptyInvitesOneLocalDocumentWithoutOfferingActions() {
    let contract = StudioViewContract(state: .empty)

    #expect(contract.canProcessAnotherDocument == false)
}

@Test func processingNamesTheDocumentAndKeepsTheLocalProcessingPromiseVisible() {
    let contract = StudioViewContract(
        state: .processing(
            sourceURL: URL(fileURLWithPath: "/tmp/Client Notes.pdf"),
            progress: .recognizing(page: 2, total: 4)
        )
    )

    #expect(contract.canProcessAnotherDocument == false)
}

@Test func pdfResultOffersEveryDocumentAction() {
    let contract = StudioViewContract(
        state: .result(result(kind: .pdf, pageCount: 4))
    )

    #expect(contract.canProcessAnotherDocument == true)
}

@Test func imageResultDoesNotOfferSearchablePDF() {
    let contract = StudioViewContract(
        state: .result(
            result(
                kind: .image,
                pageCount: 1,
                searchablePages: 0,
                ocrNeededPages: 1
            )
        )
    )

    #expect(contract.canProcessAnotherDocument == true)
}

@Test func failureOffersRecoveryWithoutDocumentActions() {
    let error = StudioPresentedError(
        title: "Couldn’t Read Document",
        message: "This document appears to be damaged or unreadable.",
        details: nil
    )
    let contract = StudioViewContract(
        state: .failure(
            sourceURL: URL(fileURLWithPath: "/tmp/damaged.pdf"),
            error
        )
    )

    #expect(contract.canProcessAnotherDocument == false)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter StudioViewContractTests
```

Expected: compilation fails because `StudioViewContract` has no member
`canProcessAnotherDocument`.

- [ ] **Step 3: Add the minimal contract property**

Add the stored property:

```swift
public let canProcessAnotherDocument: Bool
```

Set it in every `StudioState` branch:

```swift
case .empty:
    canProcessAnotherDocument = false

case .processing:
    canProcessAnotherDocument = false

case .result:
    canProcessAnotherDocument = true

case .failure:
    canProcessAnotherDocument = false
```

Keep all existing capability assignments unchanged.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run:

```bash
swift test --filter StudioViewContractTests
```

Expected: all `StudioViewContractTests` pass.

- [ ] **Step 5: Commit the contract increment**

```bash
git add \
  Sources/LocalOCRStudioKit/StudioStatusViews.swift \
  tests/LocalOCRStudioKitTests/StudioViewContractTests.swift
git commit -m "feat: expose process-another result action"
```

---

### Task 2: Add reset lifecycle semantics and result-screen wiring

**Files:**
- Modify: `tests/LocalOCRStudioKitTests/StudioViewLifecycleTests.swift`
- Modify: `tests/contract/test_studio_app_project.py`
- Modify: `AppUITests/LocalOCRStudioUITests.swift`
- Modify: `Sources/LocalOCRStudioKit/StudioViewLifecycle.swift`
- Modify: `Sources/LocalOCRStudioKit/StudioResultView.swift`
- Modify: `Sources/LocalOCRStudioKit/LocalOCRStudioView.swift`

**Interfaces:**
- Consumes: `StudioViewModel.clear()`, `StudioViewContract.canProcessAnotherDocument`
- Produces: `StudioViewLifecycle.invalidateForReset()`, `StudioResultView.onProcessAnother: () -> Void`, `LocalOCRStudioView.resetToEmpty()`

- [ ] **Step 1: Write the failing lifecycle test**

Add:

```swift
@Test @MainActor func resetInvalidatesInputAndSearchableCallbacks() {
    let lifecycle = StudioViewLifecycle()
    let pendingInput = lifecycle.beginPendingInput()
    let searchableAction = lifecycle.beginSearchableAction()
    let sourceURL = URL(fileURLWithPath: "/tmp/stale.pdf")
    var openedURLs: [URL] = []
    var progresses: [StudioProgress] = []
    var errors: [StudioPresentedError] = []
    var didFinish = false

    lifecycle.invalidateForReset()
    lifecycle.resolveInput(sourceURL, for: pendingInput) {
        openedURLs.append($0)
    }
    lifecycle.publishSearchableProgress(.assembling, for: searchableAction) {
        progresses.append($0)
    }
    lifecycle.publishSearchableError(FixtureError.failed, for: searchableAction) {
        errors.append($0)
    }
    lifecycle.finishSearchableAction(searchableAction) {
        didFinish = true
    }

    #expect(openedURLs.isEmpty)
    #expect(progresses.isEmpty)
    #expect(errors.isEmpty)
    #expect(didFinish == false)
}
```

- [ ] **Step 2: Write the failing source-wiring contract**

Immediately after the existing `ROOT = Path(__file__).parents[2]` assignment in
`tests/contract/test_studio_app_project.py`, add:

```python
ROOT_VIEW = ROOT / "Sources" / "LocalOCRStudioKit" / "LocalOCRStudioView.swift"
RESULT_VIEW = ROOT / "Sources" / "LocalOCRStudioKit" / "StudioResultView.swift"
```

Add:

```python
def test_result_screen_has_a_visible_process_another_reset_action() -> None:
    root_view = _read(ROOT_VIEW)
    result_view = _read(RESULT_VIEW)

    assert "let onProcessAnother: () -> Void" in result_view
    assert 'Button("Process Another Document", action: onProcessAnother)' in result_view
    assert '.accessibilityIdentifier("studio.process-another")' in result_view
    assert "if contract.canProcessAnotherDocument" in result_view
    assert "onProcessAnother: resetToEmpty" in root_view
    assert "private func resetToEmpty()" in root_view
    assert "lifecycle.invalidateForReset()" in root_view
    assert "model.clear()" in root_view
```

- [ ] **Step 3: Write the failing UI transition test**

Add:

```swift
func testProcessAnotherDocumentReturnsToTheEmptyDropScreen() {
    let app = launch(state: "result")
    let processAnother = app.buttons["studio.process-another"]
    let result = element("studio.result-text", in: app)

    XCTAssertTrue(result.waitForExistence(timeout: 5))
    XCTAssertTrue(processAnother.waitForExistence(timeout: 5))
    processAnother.click()

    XCTAssertTrue(element("studio.drop-zone", in: app).waitForExistence(timeout: 5))
    XCTAssertFalse(result.exists)
}
```

Also extend `testResultStateExposesReadableTextAndDocumentActions()` with:

```swift
XCTAssertTrue(app.buttons["studio.process-another"].isEnabled)
```

- [ ] **Step 4: Run the focused non-UI tests and verify RED**

Run:

```bash
swift test --filter StudioViewLifecycleTests
.venv/bin/python -m pytest -q \
  tests/contract/test_studio_app_project.py::test_result_screen_has_a_visible_process_another_reset_action
```

Expected:

- Swift compilation fails because `invalidateForReset()` does not exist.
- Pytest fails because the result and root views do not contain the new wiring.

- [ ] **Step 5: Attempt the targeted UI test and preserve the result**

Run:

```bash
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
  xcodebuild test \
  -project "LocalOCR Studio.xcodeproj" \
  -scheme "LocalOCR Studio" \
  -destination "platform=macOS,arch=arm64" \
  -only-testing:"LocalOCR StudioUITests/LocalOCRStudioUITests/testProcessAnotherDocumentReturnsToTheEmptyDropScreen"
```

Expected feature-level RED: `studio.process-another` is missing. If macOS 27
beta build `26A5388g` repeats the documented XCUI host hang before the assertion,
record that exact runner result; do not misreport it as a feature failure or
pass. The Swift and Python RED results remain the mandatory executable
feature-level failures.

- [ ] **Step 6: Implement reset invalidation**

Add to `StudioViewLifecycle`:

```swift
func invalidateForReset() {
    inputGeneration = UUID()
    searchableGeneration = UUID()
}
```

- [ ] **Step 7: Add the result button**

Add the closure to `StudioResultView`:

```swift
let onProcessAnother: () -> Void
```

Place this before the footer `Spacer()`:

```swift
if contract.canProcessAnotherDocument {
    Button("Process Another Document", action: onProcessAnother)
        .accessibilityIdentifier("studio.process-another")
}

Spacer()
```

Keep the existing footer-level:

```swift
.disabled(isCreatingSearchablePDF)
```

This disables the reset action during searchable-PDF creation without adding
new state.

- [ ] **Step 8: Wire the reset through the root view**

Pass the closure:

```swift
StudioResultView(
    result: result,
    isCreatingSearchablePDF: isCreatingSearchablePDF,
    searchableProgress: searchableProgress,
    onProcessAnother: resetToEmpty,
    onCopy: { actions.copy(result) },
    onSaveText: { showTextSavePanel(for: result) },
    onCreateSearchablePDF: { showSearchablePDFSavePanel(for: result) }
)
```

Add:

```swift
private func resetToEmpty() {
    lifecycle.invalidateForReset()
    pendingDropLoad?.cancel()
    pendingDropLoad = nil
    actionError = nil
    isCreatingSearchablePDF = false
    searchableProgress = nil
    let task = searchablePDFTask
    searchablePDFTask = nil
    task?.cancel()
    model.clear()
}
```

- [ ] **Step 9: Run focused tests and verify GREEN**

Run:

```bash
swift test --filter StudioViewLifecycleTests
swift test --filter StudioViewContractTests
.venv/bin/python -m pytest -q \
  tests/contract/test_studio_app_project.py::test_result_screen_has_a_visible_process_another_reset_action
```

Expected: all focused tests pass.

- [ ] **Step 10: Run the targeted UI test when the host permits**

Run the exact `xcodebuild test` command from Step 5.

Expected: the result fixture exposes `studio.process-another`; clicking it
removes `studio.result-text` and exposes `studio.drop-zone`. If the documented
XCUI host defect recurs, retain the runner evidence and require the signed-app
manual test in Task 5.

- [ ] **Step 11: Commit the UI increment**

```bash
git add \
  Sources/LocalOCRStudioKit/StudioViewLifecycle.swift \
  Sources/LocalOCRStudioKit/StudioResultView.swift \
  Sources/LocalOCRStudioKit/LocalOCRStudioView.swift \
  tests/LocalOCRStudioKitTests/StudioViewLifecycleTests.swift \
  tests/contract/test_studio_app_project.py \
  AppUITests/LocalOCRStudioUITests.swift
git commit -m "feat: return Studio results to document drop"
```

---

### Task 3: Verify and review the feature branch

**Files:**
- No additional production files
- Generated test/build output only

**Interfaces:**
- Consumes: completed Tasks 1 and 2
- Produces: reviewed, merge-ready feature branch

- [ ] **Step 1: Run syntax, lint, and diff checks**

```bash
for script in scripts/*.sh; do
  /bin/bash -n "$script"
  /opt/homebrew/bin/shellcheck -x "$script"
done
git diff --check main...HEAD
```

Expected: all commands exit zero.

- [ ] **Step 2: Run the complete Swift suite**

```bash
swift test
```

Expected: all Swift tests pass, including the new contract and lifecycle tests.

- [ ] **Step 3: Run the complete Python/contract suite**

```bash
env LOCALOCR_TEST_REUSE_UNSIGNED_STUDIO_APP=1 \
  .venv/bin/python -m pytest -q
```

Expected: all Python/contract tests pass; the five known SWIG deprecation
warnings may remain.

- [ ] **Step 4: Build the Release app with stable Xcode**

Because the standard wrapper’s UI-test phase is known to hang on macOS 27 beta
build `26A5388g`, run the approved Release-only contingency while reusing the
wrapper’s confined build-root, validation, and atomic publication functions:

```bash
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
  /bin/bash -c '
set -euo pipefail
source scripts/build-unsigned-studio-app.sh
select_release_developer_dir
temporary_build_root="$(/usr/bin/mktemp -d /tmp/localocr-studio-build.XXXXXX)"
set_validated_build_root "$temporary_build_root"
validate_build_root
trap cleanup_studio_build_artifacts EXIT
derived_data="$build_root/DerivedData"
/bin/mkdir "$derived_data"
"$release_xcodebuild_path" build -quiet \
  -project "$project_path" \
  -scheme "$scheme_name" \
  -configuration Release \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  ARCHS=arm64
built_app="$derived_data/Build/Products/Release/LocalOCR Studio.app"
staging_root="$build_root/Staged"
staged_app="$staging_root/LocalOCR Studio.app"
/bin/mkdir "$staging_root"
/usr/bin/ditto "$built_app" "$staged_app"
validate_and_publish_staged_app "$staged_app"
'
```

Expected: the unsigned Release app is atomically published to
`dist/unsigned-app/LocalOCR Studio.app`.

- [ ] **Step 5: Request independent review**

Review `main...HEAD` for:

- immediate result reset behavior;
- stale searchable callback prevention;
- button placement and busy-state disabling;
- accessibility label/identifier;
- no CLI/MCP/release-policy changes; and
- test quality and TDD evidence.

Expected: no unresolved Critical or Important findings.

- [ ] **Step 6: Push, open a PR, and merge after review**

```bash
git push -u origin feature/process-another-document
gh pr create \
  --base main \
  --head feature/process-another-document \
  --title "Add Process Another Document action" \
  --body-file docs/superpowers/specs/2026-08-06-process-another-document-design.md
```

After the review gate is clean:

```bash
gh pr merge --merge --delete-branch
git switch main
git pull --ff-only origin main
git rev-parse HEAD
```

Record the exact merge commit.

---

### Task 4: Rebuild, sign, notarize, and replace the private draft candidate

**Files:**
- Generated: isolated release worktree `dist/unsigned-app/`
- Generated: isolated release worktree `dist/direct-release/`
- External: private GitHub draft release ID `366160392`

**Interfaces:**
- Consumes: exact merged `main`, `localocr-notary`, installed Developer ID identity
- Produces: fresh notarized ZIP/checksum and updated private draft assets

- [ ] **Step 1: Create an isolated release worktree at the exact merge commit**

```bash
release_parent="$(/usr/bin/mktemp -d /tmp/localocr-process-another-release.XXXXXX)"
release_worktree="$release_parent/repo"
release_commit="$(git rev-parse origin/main)"
git worktree add --detach "$release_worktree" "$release_commit"
git -C "$release_worktree" status --short
git -C "$release_worktree" rev-parse HEAD
```

Expected: clean detached worktree and exact `origin/main` commit.

- [ ] **Step 2: Validate release credentials and toolchain**

```bash
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
security find-identity -v -p codesigning |
  grep -F "Developer ID Application: John Scott Ray (DZ8B5454ZN)"
xcrun notarytool history \
  --keychain-profile "localocr-notary" \
  --output-format json >/dev/null
xcodebuild -version
```

Expected: Developer ID identity found, notary profile valid, Xcode 26.6 build
`17F113`.

- [ ] **Step 3: Build the exact-commit unsigned app**

From `$release_worktree`, run the Release-only contingency from Task 3 Step 4.

Expected: fresh unsigned app built from the merge commit; record its executable
SHA-256.

- [ ] **Step 4: Stage and sign helpers first, app last**

```bash
export LOCALOCR_UNSIGNED_APP="$release_worktree/dist/unsigned-app/LocalOCR Studio.app"
export LOCALOCR_RELEASE_VERSION="0.2.0"
export LOCALOCR_RELEASE_BUILD="1"
export LOCALOCR_EXPECTED_BUNDLE_ID="com.rayconsulting.localocr"
cd "$release_worktree"
scripts/stage-direct-release.sh
scripts/sign-direct-release.sh
```

Expected: exact pre-signing hashes recorded and all three signatures pass.

- [ ] **Step 5: Notarize, staple, assess, package, and re-extract**

```bash
export LOCALOCR_NOTARY_PROFILE="localocr-notary"
scripts/notarize-direct-release.sh
```

Expected:

- Apple status `Accepted`;
- nonempty submission ID;
- stapler validation passes;
- Gatekeeper source is `Notarized Developer ID`;
- extracted final candidate passes dependency, RPATH, signature, CLI, MCP, and
  checksum checks; and
- new ZIP/checksum exist under `dist/direct-release/final/`.

- [ ] **Step 6: Update the exact private draft and replace both assets**

Resolve the current asset IDs first:

```bash
release_json="$(gh api repos/UnoRazorback/localocr/releases/366160392)"
old_zip_asset_id="$(
  /usr/bin/jq -r \
    '.assets[] | select(.name == "LocalOCR-Studio-0.2.0-1.zip") | .id' \
    <<< "$release_json"
)"
old_checksum_asset_id="$(
  /usr/bin/jq -r \
    '.assets[] | select(.name == "LocalOCR-Studio-0.2.0-1.sha256") | .id' \
    <<< "$release_json"
)"
test -n "$old_zip_asset_id"
test -n "$old_checksum_asset_id"
/usr/bin/jq \
  '{target_commitish,draft,prerelease,assets:[.assets[]|{id,name,digest}]}' \
  <<< "$release_json"
```

Patch the target while retaining draft/prerelease:

```bash
gh api --method PATCH \
  repos/UnoRazorback/localocr/releases/366160392 \
  -f tag_name="v0.2.0-beta.1" \
  -f target_commitish="$release_commit" \
  -F draft=true \
  -F prerelease=true >/dev/null
```

Delete only the two resolved superseded asset IDs, then upload:

```bash
gh api --method DELETE \
  "repos/UnoRazorback/localocr/releases/assets/$old_zip_asset_id"
gh api --method DELETE \
  "repos/UnoRazorback/localocr/releases/assets/$old_checksum_asset_id"

gh api --method POST \
  -H "Content-Type: application/zip" \
  --input "$release_worktree/dist/direct-release/final/LocalOCR-Studio-0.2.0-1.zip" \
  "https://uploads.github.com/repos/UnoRazorback/localocr/releases/366160392/assets?name=LocalOCR-Studio-0.2.0-1.zip"

gh api --method POST \
  -H "Content-Type: text/plain" \
  --input "$release_worktree/dist/direct-release/final/LocalOCR-Studio-0.2.0-1.sha256" \
  "https://uploads.github.com/repos/UnoRazorback/localocr/releases/366160392/assets?name=LocalOCR-Studio-0.2.0-1.sha256"
```

Expected: draft remains private/unpublished, targets the exact merge commit, and
contains exactly the new ZIP and checksum.

---

### Task 5: Redownload, verify the real workflow on two Macs, and reconcile records

**Files:**
- Generated: `downloads/process-another-candidate/`
- Modify: `/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/reports/mcp-macvision/README.md`
- Modify: `/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/reports/mcp-macvision/MCP-MacVision-Beta-Candidate-1-Evidence-2026-08-06.md`
- Modify: `/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/reports/mcp-macvision/MCP-MacVision-Time-and-Cost-Log.csv`
- Create: dated build-Mac and second-Mac raw acceptance evidence files

**Interfaces:**
- Consumes: new draft asset IDs, exact ZIP/checksum, Mac mini SSH alias `mini`
- Produces: two-Mac acceptance and updated dated business records

- [ ] **Step 1: Download both draft assets through the GitHub API**

```bash
mkdir -p downloads/process-another-candidate
release_json="$(
  gh api repos/UnoRazorback/localocr/releases/366160392
)"
zip_asset_id="$(
  /usr/bin/jq -r \
    '.assets[] | select(.name == "LocalOCR-Studio-0.2.0-1.zip") | .id' \
    <<< "$release_json"
)"
checksum_asset_id="$(
  /usr/bin/jq -r \
    '.assets[] | select(.name == "LocalOCR-Studio-0.2.0-1.sha256") | .id' \
    <<< "$release_json"
)"
test -n "$zip_asset_id"
test -n "$checksum_asset_id"
gh api -H "Accept: application/octet-stream" \
  "repos/UnoRazorback/localocr/releases/assets/$zip_asset_id" \
  > downloads/process-another-candidate/LocalOCR-Studio-0.2.0-1.zip
gh api -H "Accept: application/octet-stream" \
  "repos/UnoRazorback/localocr/releases/assets/$checksum_asset_id" \
  > downloads/process-another-candidate/LocalOCR-Studio-0.2.0-1.sha256
cd downloads/process-another-candidate
shasum -a 256 -c LocalOCR-Studio-0.2.0-1.sha256
```

Expected: both IDs resolve from exact asset names, exactly two assets are
present, and checksum verification passes.

- [ ] **Step 2: Run the complete downloaded verifier on the build Mac**

```bash
export LOCALOCR_RELEASE_VERSION="0.2.0"
export LOCALOCR_RELEASE_BUILD="1"
export LOCALOCR_EXPECTED_BUNDLE_ID="com.rayconsulting.localocr"
export LOCALOCR_SMOKE_INPUT="$PWD/tests/LocalOCRCoreTests/Fixtures/image-only.pdf"
scripts/test-downloaded-release.sh \
  "$PWD/downloads/process-another-candidate/LocalOCR-Studio-0.2.0-1.zip" \
  "$PWD/downloads/process-another-candidate/LocalOCR-Studio-0.2.0-1.sha256"
```

Expected: `Overall result: PASS`.

- [ ] **Step 3: Test the signed GUI reset on the build Mac**

Freshly extract and launch the downloaded app. Process
`tests/LocalOCRCoreTests/Fixtures/image-only.pdf`, click
**Process Another Document**, and verify:

- `studio.result-text` disappears;
- `studio.drop-zone` appears immediately;
- no confirmation appears;
- the source SHA-256 is unchanged; and
- another image can be opened and processed without relaunching.

Expected: build-Mac GUI reset `PASS`.

- [ ] **Step 4: Transfer and verify the exact package on the Mac mini**

Create a fresh remote temporary directory, transfer the ZIP, checksum, the three
verifier scripts, and `image-only.pdf`, then run:

```bash
export LOCALOCR_RELEASE_VERSION="0.2.0"
export LOCALOCR_RELEASE_BUILD="1"
export LOCALOCR_EXPECTED_BUNDLE_ID="com.rayconsulting.localocr"
export LOCALOCR_SMOKE_INPUT="$PWD/image-only.pdf"
./test-downloaded-release.sh \
  "$PWD/LocalOCR-Studio-0.2.0-1.zip" \
  "$PWD/LocalOCR-Studio-0.2.0-1.sha256"
```

Expected: Mac mini `Overall result: PASS`.

- [ ] **Step 5: Replace the per-user Mac mini installation atomically**

Resolve and verify the existing installed app at:

```text
/Users/oneeyedai/Applications/LocalOCR Studio.app
```

Preserve the prior installed app as a recoverable sibling backup, install the
new verified candidate, then require:

```bash
set -euo pipefail
applications_dir="/Users/oneeyedai/Applications"
final_app="$applications_dir/LocalOCR Studio.app"
backup_app="$applications_dir/LocalOCR Studio.app.backup.$(/bin/date -u +%Y%m%dT%H%M%SZ)"
archive="$PWD/LocalOCR-Studio-0.2.0-1.zip"
install_root="$(/usr/bin/mktemp -d "$applications_dir/.localocr-install.XXXXXX")"
candidate_app="$install_root/LocalOCR Studio.app"

test -d "$final_app"
test ! -e "$backup_app"
/usr/bin/ditto -x -k "$archive" "$install_root"
/usr/bin/codesign --verify --deep --strict "$candidate_app"
/usr/bin/xcrun stapler validate "$candidate_app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$candidate_app"

/bin/mv "$final_app" "$backup_app"
if ! /bin/mv "$candidate_app" "$final_app"; then
  /bin/mv "$backup_app" "$final_app"
  exit 1
fi
/bin/rmdir "$install_root"

/usr/bin/codesign --verify --deep --strict "$final_app"
/usr/bin/xcrun stapler validate "$final_app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$final_app"
"$final_app/Contents/Helpers/localocr" --version
```

Expected: strict signature, valid staple, `Notarized Developer ID`, and version
`0.2.0`.

- [ ] **Step 6: Complete hands-on reset and accessibility acceptance**

On the Mac mini:

1. Process one PDF.
2. Create a searchable PDF.
3. Activate **Process Another Document**.
4. Confirm the empty drop/open screen appears without relaunch.
5. Process one image.
6. Confirm VoiceOver announces the button as **Process Another Document**.
7. Quit cleanly.

Expected: all seven checks pass.

- [ ] **Step 7: Reconcile dated business evidence without inventing hours or costs**

Update the project overview and candidate record with:

- exact merge commit and PR;
- full test counts;
- notary submission ID/status;
- final ZIP SHA-256;
- draft target and asset digests;
- build-Mac and Mac mini acceptance evidence;
- Mac mini installation result; and
- the superseded candidate retained as historical evidence.

Leave Hours, Direct Cost, and Shared Cost Allocation blank unless dated evidence
supports an amount. Do not establish a download baseline until the draft is
published.

- [ ] **Step 8: Stop for owner publication approval**

Present the exact commit, notary ID, ZIP SHA-256, two-Mac results, open beta-watch
items, and current draft state. Do not publish the draft without the owner’s
explicit approval.
