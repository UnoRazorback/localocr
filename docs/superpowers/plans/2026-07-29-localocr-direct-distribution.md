# LocalOCR Direct Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a privately staged, Developer ID signed, Hardened Runtime enabled, notarized, stapled, and independently verifiable LocalOCR Studio app containing the native `localocr` and `localocr-mcp` executables, ready for a separately authorized direct-distribution beta.

**Architecture:** The app build and the release pipeline remain separate. The pipeline consumes an unsigned Release app built by the LocalOCR Studio app target, rebuilds the two native tools with stable Xcode, stages the tools under `Contents/Helpers`, rejects unsafe dependencies and RPATHs, signs every nested executable before signing the containing app, submits a ZIP to Apple with `notarytool`, staples the accepted ticket, and emits a final ZIP, checksum, manifest, and evidence directory. Publication and second-Mac acceptance are explicit gates rather than side effects of building.

**Tech Stack:** Swift 6, Swift Package Manager, stable Xcode, Developer ID Application signing, Hardened Runtime, `codesign`, `notarytool`, `stapler`, `spctl`, `otool`, `ditto`, SHA-256, pytest contract tests, GitHub Releases

## Global Constraints

- Direct distribution is outside the Mac App Store; the repository and release remain private until the owner separately authorizes publication.
- Use the selected stable Xcode at `/Applications/Xcode.app/Contents/Developer`; reject Xcode paths whose app name contains `beta`, `rc`, or `preview`, case-insensitively.
- Use Apple Developer Team ID `DZ8B5454ZN`.
- Use signing identity `Developer ID Application: John Scott Ray (DZ8B5454ZN)`.
- Never store an Apple ID password, app-specific password, API private key, or notary credential in the repository or release logs.
- Consume notarization credentials only through a verified keychain profile named by `LOCALOCR_NOTARY_PROFILE`.
- Build and package arm64 binaries for macOS 14 or later.
- Embed `localocr` and `localocr-mcp` at `LocalOCR Studio.app/Contents/Helpers/`.
- Sign nested helpers and other nested code first. Sign the containing app last.
- Use a secure timestamp and Hardened Runtime for every Developer ID signature.
- Do not use `codesign --deep` to create signatures. Verify each nested executable explicitly and then verify the containing app with `--deep --strict`.
- Distribution binaries may depend only on Apple/system frameworks and libraries under `/System/Library` or `/usr/lib`, plus the existing weak `@rpath/libswiftCompatibilitySpan.dylib` resolved by `/usr/lib/swift`.
- The only permitted `LC_RPATH` is `/usr/lib/swift`. Reject absolute Xcode, Homebrew, `/usr/local`, repository, and user-directory RPATHs.
- Distribution binaries must not contain `com.apple.security.get-task-allow`.
- Do not claim notarization until `notarytool` returns `Accepted`, `stapler` validates the ticket, and `spctl` accepts the stapled app.
- Build the final ZIP only after stapling; compute its checksum after the final ZIP is complete.
- Do not publish a beta until a fresh downloaded copy passes on the build Mac and a second Mac.
- At publication, preserve the release commit, test output, signature details, notarization submission ID and status, Gatekeeper result, SHA-256, download URL, and two-Mac results.
- At publication, establish the download baseline and begin the MCP MacVision beta metrics and feedback logs. Never backfill invented download or feedback counts.

---

## Planned File Structure

```text
scripts/
  release-toolchain.sh                 Stable-Xcode and release-input validation
  stage-direct-release.sh              Clean staging and helper installation
  verify-direct-release.sh             Dependency, RPATH, signature, ticket, and policy checks
  sign-direct-release.sh               Nested-first Developer ID signing
  notarize-direct-release.sh           Submission, stapling, final packaging, and checksum
  test-downloaded-release.sh           Fresh-download verification on each Mac
tests/contract/
  test_direct_release_scripts.py       Release-script policy and ordering contracts
docs/release/
  second-mac-acceptance.md             Exact second-Mac test record
docs/superpowers/plans/
  2026-07-29-localocr-direct-distribution.md
dist/direct-release/                   Generated and ignored release outputs
```

The scripts consume these required inputs:

```bash
export LOCALOCR_UNSIGNED_APP="/absolute/path/to/LocalOCR Studio.app"
export LOCALOCR_RELEASE_VERSION="0.2.0"
export LOCALOCR_RELEASE_BUILD="1"
export LOCALOCR_EXPECTED_BUNDLE_ID="com.rayconsulting.localocr"
export LOCALOCR_NOTARY_PROFILE="LocalOCR-Notary"
```

`LOCALOCR_NOTARY_PROFILE` is an external keychain item name, not a secret. The scripts must validate that it is nonempty but must not print it into evidence logs. The other values must match the staged app’s `Info.plist`; a mismatch is a hard failure.

### Task 1: Freeze the Direct-Release Policy

**Files:**
- Create: `tests/contract/test_direct_release_scripts.py`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: release script text and generated fixture output
- Produces: executable policy tests that later tasks must satisfy

- [ ] **Step 1: Write contract tests for required scripts and immutable policy**

Create `tests/contract/test_direct_release_scripts.py` with tests that read the five planned scripts and assert:

```python
EXPECTED_IDENTITY = "Developer ID Application: John Scott Ray (DZ8B5454ZN)"
EXPECTED_TEAM = "DZ8B5454ZN"
EXPECTED_HELPERS = ("localocr", "localocr-mcp")

assert EXPECTED_IDENTITY in sign_script
assert EXPECTED_TEAM in toolchain_script
assert "--options" in sign_script and "runtime" in sign_script
assert "--timestamp" in sign_script
assert sign_script.index('Contents/Helpers/localocr"') < sign_script.index('STAGED_APP}"')
assert sign_script.index('Contents/Helpers/localocr-mcp"') < sign_script.index('STAGED_APP}"')
assert "notarytool submit" in notarize_script
assert "--keychain-profile" in notarize_script
assert "--wait" in notarize_script
assert "stapler staple" in notarize_script
assert "stapler validate" in verify_script
assert "spctl --assess --type execute" in verify_script
assert "otool -L" in verify_script
assert "otool -l" in verify_script
```

Also assert that no release script contains `Xcode-beta`, `--deep --force`, an Apple password flag, an API private-key value, or a hard-coded notary profile.

- [ ] **Step 2: Test rejection helpers directly**

Import or invoke script test modes and verify that:

- `/Applications/Xcode.app/Contents/Developer` is accepted.
- `/Applications/Xcode-beta.app/Contents/Developer` is rejected.
- `/Applications/Xcode-RC.app/Contents/Developer` is rejected.
- `/Applications/Xcode Preview.app/Contents/Developer` is rejected.
- `/Applications/Xcode.app/Contents/Developer/usr/lib/swift/macosx` is rejected as an RPATH.
- `/usr/lib/swift` is accepted as an RPATH.
- `/opt/homebrew/lib/libexample.dylib`, `/usr/local/lib/libexample.dylib`, and `@rpath/third-party.dylib` are rejected install names.
- `/System/Library/Frameworks/Vision.framework/Versions/A/Vision`, `/usr/lib/libSystem.B.dylib`, and `@rpath/libswiftCompatibilitySpan.dylib` are accepted install names.

- [ ] **Step 3: Run the tests and verify failure**

Run:

```bash
"/Users/scott/Desktop/ocr-mcp/.venv/bin/python" -m pytest \
  tests/contract/test_direct_release_scripts.py -q
```

Expected: FAIL because the release scripts do not exist.

- [ ] **Step 4: Ignore generated direct-release outputs**

Add exactly this line to `.gitignore`:

```gitignore
dist/direct-release/
```

- [ ] **Step 5: Commit the policy tests**

```bash
git add .gitignore tests/contract/test_direct_release_scripts.py
git commit -m "test: define direct distribution release policy"
```

### Task 2: Pin Stable Xcode and Stage the App

**Files:**
- Create: `scripts/release-toolchain.sh`
- Create: `scripts/stage-direct-release.sh`
- Test: `tests/contract/test_direct_release_scripts.py`

**Interfaces:**
- Consumes: `LOCALOCR_UNSIGNED_APP`, version, build, bundle ID, selected Xcode
- Produces: `dist/direct-release/staged/LocalOCR Studio.app` with native helpers installed but not Developer ID signed

- [ ] **Step 1: Implement stable toolchain selection**

In `scripts/release-toolchain.sh`, define:

```bash
configure_release_developer_dir()
validate_release_inputs()
validate_signing_identity()
release_evidence_dir()
```

`configure_release_developer_dir` must set and export:

```bash
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
```

It must verify `xcodebuild` exists, reject `beta`, `rc`, or `preview` in the resolved path, run `xcodebuild -version`, and save the exact two-line result to the release evidence directory. `validate_signing_identity` must require one valid identity whose full label exactly matches:

```text
Developer ID Application: John Scott Ray (DZ8B5454ZN)
```

- [ ] **Step 2: Implement deterministic staging**

In `scripts/stage-direct-release.sh`:

1. Source `release-toolchain.sh`.
2. Validate that `LOCALOCR_UNSIGNED_APP` is an absolute path ending in `.app`.
3. Restrict cleanup to the exact repository path `dist/direct-release`.
4. Build `localocr` and `localocr-mcp` by calling `scripts/build-native-tools.sh`.
5. Copy the unsigned app with `/usr/bin/ditto`.
6. Create `Contents/Helpers`.
7. Copy both native tools into that directory and make them executable.
8. Clear extended attributes only from the staged app with `/usr/bin/xattr -cr`.
9. Read `CFBundleIdentifier`, `CFBundleShortVersionString`, and `CFBundleVersion` with `PlistBuddy`.
10. Fail unless they exactly equal the three corresponding release inputs.
11. Fail unless both helpers report arm64 Mach-O executables.

- [ ] **Step 3: Record the unsigned input without mutating it**

Before copying, calculate SHA-256 values for the unsigned app’s main executable and the two freshly built helpers. Save them to:

```text
dist/direct-release/evidence/pre-signing-sha256.txt
```

The script must never run `codesign`, `xattr`, or `install_name_tool` against `LOCALOCR_UNSIGNED_APP`.

- [ ] **Step 4: Run the focused tests**

Run:

```bash
"/Users/scott/Desktop/ocr-mcp/.venv/bin/python" -m pytest \
  tests/contract/test_direct_release_scripts.py -q
```

Expected: stable-toolchain and staging policy tests PASS.

- [ ] **Step 5: Commit stable staging**

```bash
git add scripts/release-toolchain.sh scripts/stage-direct-release.sh \
  tests/contract/test_direct_release_scripts.py
git commit -m "build: stage stable direct release app"
```

### Task 3: Enforce Dependency, RPATH, and Signing Contracts

**Files:**
- Create: `scripts/verify-direct-release.sh`
- Create: `scripts/sign-direct-release.sh`
- Modify: `tests/contract/test_direct_release_scripts.py`

**Interfaces:**
- Consumes: staged app and exact Developer ID identity
- Produces: nested-first Developer ID signed app whose every code object has Hardened Runtime and a secure timestamp

- [ ] **Step 1: Implement the binary policy verifier**

In `scripts/verify-direct-release.sh`, define:

```bash
verify_binary_dependencies "/path/to/binary"
verify_binary_rpaths "/path/to/binary"
verify_no_private_paths "/path/to/binary"
verify_signature "/path/to/code"
verify_hardened_runtime "/path/to/code"
verify_no_debug_entitlement "/path/to/code"
```

For each helper and the app executable:

- Parse `otool -L`; permit only `/System/Library/*`, `/usr/lib/*`, and the exact weak install name `@rpath/libswiftCompatibilitySpan.dylib`.
- Parse every `LC_RPATH` from `otool -l`; permit only `/usr/lib/swift`.
- Reject strings containing `/Applications/Xcode`, `/Users/`, the repository path, `/opt/homebrew`, `/usr/local`, `.venv`, `python`, `pyobjc`, `pymupdf`, or `ruby`.
- Run `codesign --verify --strict --verbose=2` on that exact code object.
- Parse `codesign -dv --verbose=4`; require `TeamIdentifier=DZ8B5454ZN`, a trusted timestamp, and runtime flag `0x10000`.
- Parse entitlements with `codesign -d --entitlements :-`; fail if `com.apple.security.get-task-allow` is true.

After explicit nested checks, run:

```bash
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
```

- [ ] **Step 2: Implement nested-first signing**

In `scripts/sign-direct-release.sh`, use the exact identity constant and execute in this order:

```bash
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
  --options runtime --timestamp \
  "$STAGED_APP/Contents/Helpers/localocr"

/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
  --options runtime --timestamp \
  "$STAGED_APP/Contents/Helpers/localocr-mcp"

/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
  --options runtime --timestamp \
  "$STAGED_APP"
```

Immediately call `verify_signature`, `verify_hardened_runtime`, and `verify_no_debug_entitlement` after each signing command. Do not use `--deep` while signing.

- [ ] **Step 3: Make unexpected nested code a hard failure**

Before signing, enumerate nested Mach-O files, frameworks, XPC services, app extensions, and nested apps. The current allowed set is:

```text
Contents/MacOS/${CFBundleExecutable}
Contents/Helpers/localocr
Contents/Helpers/localocr-mcp
```

Fail if another code object appears. When the product intentionally adds a framework, XPC service, or extension, update the allowlist and add its leaf-first signing order in the same reviewed commit.

- [ ] **Step 4: Run tests and a private signing dry run**

Run the contract suite. Then run staging and signing against a local unsigned Release app. Expected:

- Both helpers verify independently.
- The app verifies independently and with `--deep --strict`.
- All three signatures show team `DZ8B5454ZN`, a timestamp, and Hardened Runtime.
- No object carries `get-task-allow`.

- [ ] **Step 5: Commit signing and verification**

```bash
git add scripts/sign-direct-release.sh scripts/verify-direct-release.sh \
  tests/contract/test_direct_release_scripts.py
git commit -m "build: sign and verify direct release app"
```

### Task 4: Notarize, Staple, and Package the Final Candidate

**Files:**
- Create: `scripts/notarize-direct-release.sh`
- Modify: `scripts/verify-direct-release.sh`
- Modify: `tests/contract/test_direct_release_scripts.py`

**Interfaces:**
- Consumes: signed staged app and `LOCALOCR_NOTARY_PROFILE`
- Produces: accepted/stapled app, final ZIP, SHA-256 file, and preserved Apple submission evidence

- [ ] **Step 1: Validate notarization access without exposing credentials**

Require a nonempty `LOCALOCR_NOTARY_PROFILE`. Verify it with:

```bash
xcrun notarytool history --keychain-profile "$LOCALOCR_NOTARY_PROFILE" \
  --output-format json
```

Discard or redact account identifiers before saving evidence. Never enable shell tracing around notarization commands.

- [ ] **Step 2: Create the submission ZIP**

After a full pre-notarization verification, create:

```text
dist/direct-release/submission/LocalOCR-Studio-${LOCALOCR_RELEASE_VERSION}-${LOCALOCR_RELEASE_BUILD}.zip
```

with:

```bash
ditto -c -k --keepParent "$STAGED_APP" "$SUBMISSION_ZIP"
```

- [ ] **Step 3: Submit and preserve the result**

Run:

```bash
xcrun notarytool submit "$SUBMISSION_ZIP" \
  --keychain-profile "$LOCALOCR_NOTARY_PROFILE" \
  --wait \
  --output-format json
```

Save the JSON as `dist/direct-release/evidence/notary-submit.json`. Parse it and require status `Accepted`. Preserve the submission ID. On rejection, fetch and save:

```bash
xcrun notarytool log "$submission_id" \
  --keychain-profile "$LOCALOCR_NOTARY_PROFILE" \
  dist/direct-release/evidence/notary-log.json
```

Stop without stapling or packaging a final candidate.

- [ ] **Step 4: Staple and validate**

Only after `Accepted`, run:

```bash
xcrun stapler staple "$STAGED_APP"
xcrun stapler validate "$STAGED_APP"
spctl --assess --type execute --verbose=2 "$STAGED_APP"
```

Save the complete validation and Gatekeeper output. A nonzero result is a release blocker.

- [ ] **Step 5: Build the final package and checksum**

Create the final ZIP from the stapled app:

```text
dist/direct-release/final/LocalOCR-Studio-${LOCALOCR_RELEASE_VERSION}-${LOCALOCR_RELEASE_BUILD}.zip
dist/direct-release/final/LocalOCR-Studio-${LOCALOCR_RELEASE_VERSION}-${LOCALOCR_RELEASE_BUILD}.sha256
```

Use `ditto -c -k --keepParent` and `shasum -a 256`. Extract the ZIP into a new `mktemp -d` directory and rerun explicit signature checks, `stapler validate`, `spctl`, helper `--version`, MCP initialization/version, dependency checks, and RPATH checks against the extracted copy.

- [ ] **Step 6: Commit notarization tooling**

```bash
git add scripts/notarize-direct-release.sh scripts/verify-direct-release.sh \
  tests/contract/test_direct_release_scripts.py
git commit -m "build: notarize and package direct release"
```

### Task 5: Preserve Evidence and Require Two-Mac Acceptance

**Files:**
- Create: `scripts/test-downloaded-release.sh`
- Create: `docs/release/second-mac-acceptance.md`
- Modify: `tests/contract/test_direct_release_scripts.py`

**Interfaces:**
- Consumes: a freshly downloaded final ZIP and published SHA-256 file
- Produces: machine-specific pass/fail evidence that gates publication or promotion

- [ ] **Step 1: Implement downloaded-package verification**

`scripts/test-downloaded-release.sh` accepts exactly two absolute arguments: the downloaded ZIP and checksum file. It must:

1. Verify SHA-256 before extraction.
2. Extract into a new temporary directory.
3. Verify both helpers and the app signatures.
4. Validate the stapled ticket.
5. Require Gatekeeper acceptance.
6. Recheck architecture, dependencies, RPATHs, and forbidden strings.
7. Run `localocr --version`.
8. Initialize `localocr-mcp` over stdio and require the expected version.
9. Run OCR on an explicitly supplied local PDF/image fixture only when `LOCALOCR_SMOKE_INPUT` is set.
10. Write toolchain, macOS version, Mac model, CPU architecture, checksum, results, and UTC timestamp to an evidence file without recording document content or paths.

- [ ] **Step 2: Create the second-Mac acceptance record**

Create `docs/release/second-mac-acceptance.md` with these required fields:

```markdown
# LocalOCR Studio second-Mac acceptance

- Release version:
- Build:
- Release commit:
- Download URL:
- ZIP SHA-256:
- Test date and time:
- Mac model:
- Processor:
- macOS version:
- Gatekeeper result:
- Stapled ticket result:
- App launch result:
- CLI version result:
- MCP initialization result:
- OCR smoke input type:
- OCR smoke result:
- Tester:
- Overall result: PASS or FAIL
```

The completed record belongs in release evidence, not committed with personal machine identifiers unless the owner approves.

- [ ] **Step 3: Test on the build Mac from the downloaded asset**

Do not reuse the staging ZIP. Download the candidate through the same URL a tester will use, run `test-downloaded-release.sh`, launch the extracted app, exercise one PDF and one macOS Vision-decodable image, create a searchable PDF, verify the source files remain unchanged, and quit cleanly.

- [ ] **Step 4: Test on a second Mac**

Repeat Step 3 on a second Mac. Publication or promotion remains blocked until the completed second-Mac record says `PASS`.

- [ ] **Step 5: Commit the acceptance tooling**

```bash
git add scripts/test-downloaded-release.sh docs/release/second-mac-acceptance.md \
  tests/contract/test_direct_release_scripts.py
git commit -m "test: require downloaded two-Mac release acceptance"
```

### Task 6: Gate Private Beta Publication and Start Business Metrics

**Files:**
- Modify: `README.md`
- External: private GitHub prerelease and release assets
- External: `/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/reports/mcp-macvision/MCP-MacVision-Beta-Metrics.csv`
- External: `/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/reports/mcp-macvision/MCP-MacVision-Feedback-Log.csv`
- External: milestone evidence and project overview in the same recordkeeping folder

**Interfaces:**
- Consumes: verified release commit, final ZIP/checksum, notarization evidence, two-Mac PASS records, explicit owner authorization
- Produces: private prerelease URL, initial download baseline, feedback channel, and preserved release evidence

- [ ] **Step 1: Confirm all release gates**

Require all of the following before creating a release:

- Clean release commit pushed to the private repository.
- Full Swift and Python suites pass.
- Artifact dependency, RPATH, and embedded-string policies pass.
- Every nested helper and the app have valid Developer ID, timestamped Hardened Runtime signatures.
- Notarization status is `Accepted`.
- Ticket is stapled and validates.
- Gatekeeper accepts the extracted final ZIP.
- Downloaded-copy test passes on the build Mac.
- Downloaded-copy test passes on a second Mac.
- SHA-256 matches the final asset.
- Owner explicitly authorizes publishing the private beta.

- [ ] **Step 2: Create a draft private prerelease**

Use a tag derived from the approved release version, target the exact release commit, mark it prerelease and draft, and upload only the final ZIP and checksum. Include macOS 14+, Apple silicon, local-only processing, beta status, installation steps, known limitations, and the feedback URL in release notes.

- [ ] **Step 3: Re-download and test the draft assets**

Download both assets from GitHub, rerun `test-downloaded-release.sh`, and compare SHA-256 with the locally preserved final checksum. If GitHub does not permit draft asset testing through the intended tester path, publish only after owner authorization and perform this check immediately; withdraw the release if it fails.

- [ ] **Step 4: Establish the beta baseline**

At the first published-beta capture time:

- Record the primary ZIP download count separately from checksum/supporting-asset counts.
- Record the release tag, review date, feedback count, responses sent, open bugs, issue/discussion comments, and notes in `MCP-MacVision-Beta-Metrics.csv`.
- Add each substantive tester item to `MCP-MacVision-Feedback-Log.csv`.
- Treat known internal/test downloads as part of the raw GitHub count and disclose them in notes; do not present the count as unique external testers.

- [ ] **Step 5: Close the release milestone record**

Update the MCP MacVision overview and milestone evidence with:

- Final merge and release commits
- Release tag and URL
- Asset SHA-256
- Test counts and commands
- Signing identity and team
- Notarization submission ID/status
- Stapler and Gatekeeper results
- Build-Mac and second-Mac results
- Direct receipts and supported allocations only
- Evidence-reconciled owner time, still labeled as an estimate unless payroll records exist

- [ ] **Step 6: Commit documentation updates**

```bash
git add README.md
git commit -m "docs: document direct beta installation and verification"
git push origin HEAD
```

Do not commit generated release assets, credentials, notarization account details, private document paths, or personal machine identifiers.

---

## Final Release Review

Before calling the pipeline complete:

1. Run the complete Swift and Python test suites.
2. Run the direct-release contract suite.
3. Run all five release scripts from a clean checkout with stable Xcode.
4. Inspect `otool -L` and every `LC_RPATH` for the app executable and both helpers.
5. Verify each signature separately, then verify the app with `--deep --strict`.
6. Confirm Hardened Runtime, timestamp, team ID, and absence of `get-task-allow`.
7. Confirm notarization `Accepted`, stapler validation, and Gatekeeper acceptance.
8. Verify the final ZIP checksum after downloading.
9. Require downloaded-copy PASS on two Macs.
10. Preserve evidence and update business records.
11. Publish only after explicit owner authorization.
