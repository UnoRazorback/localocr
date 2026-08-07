# LocalOCR Studio Beta Tester Documentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the already-published private LocalOCR Studio Beta 1 release ready for invited testers by adding accurate desktop-first guidance, advanced MCP setup, structured feedback intake, synchronized release notes, and dated campaign-readiness evidence.

**Architecture:** Treat `BETA_TESTING.md` as the single tester-facing entry point, retain `docs/mcp.md` as the complete tool reference, and keep a tracked canonical copy of the live GitHub release notes. Add focused contract tests for documentation identity and feedback-form structure. Merge repository documentation before updating the existing live release body, then capture the unchanged asset identity and pre-campaign download snapshot in the connected business records.

**Tech Stack:** Markdown, GitHub issue forms/YAML, Python `pytest` contract checks, Ruby Psych YAML validation, Git/GitHub CLI, existing LocalOCR release evidence.

## Global Constraints

- Release ID/tag: `366160392` / `v0.2.0-beta.1`.
- Release target commit: `2cb03cc9684ed9bb4b449a0f7d79f0588fb7ae38`.
- Version/build: `0.2.0` / `1`.
- ZIP asset: `LocalOCR-Studio-0.2.0-1.zip`, asset ID `504329402`, SHA-256 `3a6a1c754ee369ab9a8ffe01bcc96e7f4927ac44eb1f82b410f538aee901c0d5`.
- Checksum asset: `LocalOCR-Studio-0.2.0-1.sha256`, asset ID `504329415`, SHA-256 `7ac51f2ac30224c02e7253d541d49b5205ed2056e3cab648dae4ec66552d26ec`.
- Keep the repository private and the release marked as a prerelease.
- Do not rebuild, re-sign, re-notarize, replace assets, change the tag, or change the release target commit.
- Desktop Studio processes one document at a time; batch PDF OCR is MCP-only in Beta 1.
- Describe compatibility as tested on macOS 27 beta build `26A5388g`, never as safe on every macOS 27 beta.
- Build provenance is stable Xcode 26.6 (`17F113`), Swift 6, arm64, deployment target macOS 14.0.
- Document contents, recognized text, filenames, paths, thumbnails, hashes, cache entries, and outputs must never be sent by LocalOCR over the network.
- Record hours and costs only from dated evidence; leave unsupported values blank.
- Preserve the existing untracked `downloads/` directory and all prior release evidence.

---

## Execution Preparation

Before Task 1, invoke `superpowers:using-git-worktrees`. Create a feature
worktree from the commit containing this plan on branch
`feature/beta-tester-documentation`. Confirm the unrelated `downloads/`
directory remains only in the original checkout and is never staged.

---

### Task 1: Create the Desktop-First Beta Guide and Canonical Release Notes

**Files:**
- Create: `BETA_TESTING.md`
- Create: `docs/release/v0.2.0-beta.1-notes.md`
- Create: `tests/contract/test_beta_tester_guide.py`

**Interfaces:**
- Consumes: the exact release identity and compatibility wording in the design specification.
- Produces: the tester entry point used by repository docs and a canonical release body used by Task 5.

- [ ] **Step 1: Create a failing guide contract test**

Create `tests/contract/test_beta_tester_guide.py` with these assertions:

```python
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GUIDE = ROOT / "BETA_TESTING.md"
RELEASE_NOTES = ROOT / "docs/release/v0.2.0-beta.1-notes.md"

RELEASE_COMMIT = "2cb03cc9684ed9bb4b449a0f7d79f0588fb7ae38"
ZIP_SHA256 = "3a6a1c754ee369ab9a8ffe01bcc96e7f4927ac44eb1f82b410f538aee901c0d5"
STALE_VALUES = (
    "67c09271c1aa6dbf23e671cc8c8ebbe7b3b3657d",
    "0b1ea1abcf7528e0ed20665571224d02b4532e693453be0c47b847db276b3ad6",
    "This release remains a draft",
)


def test_beta_guide_contains_install_desktop_and_privacy_contracts():
    text = GUIDE.read_text()
    required = (
        "LocalOCR-Studio-0.2.0-1.zip",
        "LocalOCR-Studio-0.2.0-1.sha256",
        'shasum -a 256 -c "LocalOCR-Studio-0.2.0-1.sha256"',
        "Process Another Document",
        "Create Searchable PDF",
        "one document at a time",
        "Apple silicon",
        "macOS 14",
        "does not upload",
    )
    for value in required:
        assert value in text


def test_beta_guide_contains_advanced_client_commands():
    text = GUIDE.read_text()
    helper = "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp"
    assert helper in text
    assert "codex mcp add localocr --" in text
    assert "claude mcp add --transport stdio localocr --" in text
    assert "--scope user" in text
    for tool in (
        "get_pdf_page_count",
        "inspect_pdf",
        "ocr_pdf",
        "ocr_pdf_batch",
        "ocr_image",
        "make_searchable_pdf",
    ):
        assert tool in text


def test_guide_and_release_notes_use_exact_candidate_identity():
    for path in (GUIDE, RELEASE_NOTES):
        text = path.read_text()
        assert RELEASE_COMMIT in text
        assert ZIP_SHA256 in text
        assert "Xcode 26.6" in text
        assert "17F113" in text
        assert "26A5388g" in text
        assert "later Apple beta builds may introduce regressions" in text
        for stale in STALE_VALUES:
            assert stale not in text
```

- [ ] **Step 2: Run the focused test and confirm the missing-file failure**

Run:

```bash
.venv/bin/python -m pytest tests/contract/test_beta_tester_guide.py -q
```

Expected: FAIL because `BETA_TESTING.md` and the canonical release-notes file do not exist.

- [ ] **Step 3: Write the complete beta tester guide**

Create `BETA_TESTING.md` with these sections and exact content requirements:

1. `# LocalOCR Studio Beta 1 Tester Guide`.
2. A short statement that this is a private-repository prerelease for invited testers and that repository access is required.
3. `## Download and install` with the exact ZIP/checksum names, release URL, quoted `shasum` command, required `OK` result, `/Applications` destination, and a warning not to bypass Gatekeeper or remove quarantine.
4. `## What the desktop app does` covering Open/drag-and-drop, one document at a time, PDF/image OCR, preservation of usable PDF text, Copy, Save Text, Create Searchable PDF, source immutability, and Process Another Document.
5. `## Five-minute desktop test` with the six approved steps from the design specification.
6. `## Privacy` stating that recognition uses Apple Vision/PDFKit locally; LocalOCR does not upload documents, recognized text, filenames, paths, thumbnails, hashes, cache entries, or outputs; the cache path is `~/Library/Caches/com.rayconsulting.localocr/ocr-v1`; there is no history.
7. `## Compatibility and build provenance` with stable Xcode 26.6 (`17F113`), Swift 6, arm64, macOS 14 deployment target, Developer ID/Hardened Runtime/notarization/stapling/Gatekeeper, and exact M5/M4 acceptance on macOS 27 beta build `26A5388g`. Include the exact sentence: `Later Apple beta builds may introduce regressions; report the exact macOS version and build number.`
8. `## Known Beta 1 limitations` with the complete approved limitation list.
9. `## Report feedback` linking `.github/ISSUE_TEMPLATE/beta-feedback.yml` through the repository's new-issue chooser and explicitly prohibiting attachment of confidential documents or recognized text.
10. `## Advanced: MCP setup` separated visually and conceptually from the desktop flow.
11. Codex commands:

```bash
codex mcp add localocr -- \
  "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp"
codex mcp list
```

12. Claude Code commands:

```bash
claude mcp add --transport stdio localocr -- \
  "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp"
claude mcp list
```

13. Explain that Claude Code defaults to local/project scope and that `--scope user` is optional for intentional cross-project availability.
14. Link to `https://learn.chatgpt.com/docs/extend/mcp` and `https://code.claude.com/docs/en/mcp`.
15. Provide the generic stdio JSON object from the design and name all six tools.
16. Provide three safe example prompts using fictional absolute paths under `/Users/your-name/Documents/LocalOCR-Test/` for one PDF, one image, and a PDF batch.
17. Link to `docs/mcp.md` for the complete tool schema.

- [ ] **Step 4: Create the canonical live release notes**

Create `docs/release/v0.2.0-beta.1-notes.md` as a concise release page with:

- A desktop-first summary and a direct link to `BETA_TESTING.md` on `main`.
- Privacy and feature bullets, including **Process Another Document**.
- The exact install command and asset names.
- A compatibility section using the approved wording.
- A known-limitations section.
- An advanced MCP paragraph linking to the beta guide and `docs/mcp.md`.
- A feedback link to `https://github.com/UnoRazorback/localocr/issues/new/choose`.
- Exact source commit, version/build, ZIP SHA-256, signing/notarization statement, and published-private-prerelease status.

Do not include the words `draft`, `future authorized beta`, or `not yet published` except in a sentence explicitly saying that those former states no longer apply; the cleaner result is to omit them entirely.

- [ ] **Step 5: Run the guide test and review rendered Markdown structure**

Run:

```bash
.venv/bin/python -m pytest tests/contract/test_beta_tester_guide.py -q
git diff --check
```

Expected: all guide tests PASS and `git diff --check` produces no output.

- [ ] **Step 6: Commit the tester guide and release-note source**

```bash
git add BETA_TESTING.md docs/release/v0.2.0-beta.1-notes.md tests/contract/test_beta_tester_guide.py
git commit -m "docs: add LocalOCR beta tester guide"
```

---

### Task 2: Align README, Studio, and MCP Documentation

**Files:**
- Modify: `README.md:8-13,26-35,71-138,185-191`
- Modify: `docs/studio.md:1-72`
- Modify: `docs/mcp.md:8-42`
- Create: `tests/contract/test_beta_documentation_alignment.py`

**Interfaces:**
- Consumes: `BETA_TESTING.md` and the exact release identity from Task 1.
- Produces: consistent repository navigation with no stale publication claims.

- [ ] **Step 1: Create a failing alignment contract test**

Create `tests/contract/test_beta_documentation_alignment.py`:

```python
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FILES = {
    "readme": ROOT / "README.md",
    "studio": ROOT / "docs/studio.md",
    "mcp": ROOT / "docs/mcp.md",
}


def test_repository_docs_link_to_beta_guide():
    assert "BETA_TESTING.md" in FILES["readme"].read_text()
    assert "../BETA_TESTING.md" in FILES["studio"].read_text()
    assert "../BETA_TESTING.md" in FILES["mcp"].read_text()


def test_readme_and_studio_describe_published_beta_and_reset():
    for key in ("readme", "studio"):
        text = FILES[key].read_text()
        assert "v0.2.0-beta.1" in text
        assert "Process Another Document" in text
        assert "Xcode 26.6" in text
        assert "26A5388g" in text
        assert "no supported localocr studio beta download" not in text.lower()
        assert "not yet published" not in text.lower()


def test_mcp_guide_has_installed_helper_and_verified_client_commands():
    text = FILES["mcp"].read_text()
    assert "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp" in text
    assert "codex mcp add localocr --" in text
    assert "claude mcp add --transport stdio localocr --" in text
    assert "https://learn.chatgpt.com/docs/extend/mcp" in text
    assert "https://code.claude.com/docs/en/mcp" in text
```

- [ ] **Step 2: Run the focused test and confirm stale-document failures**

```bash
.venv/bin/python -m pytest tests/contract/test_beta_documentation_alignment.py -q
```

Expected: FAIL because the existing documents still describe the beta as unpublished and do not contain the complete installed-client setup.

- [ ] **Step 3: Update the repository README**

Make these bounded changes:

- Replace the unpublished-beta paragraph at lines 8-13 with the published private-prerelease status and a link to `BETA_TESTING.md`.
- Add **Process Another Document** to the Studio feature summary.
- Replace the entire `Private beta distribution` section with a short current-release block containing the tag, private-access boundary, exact ZIP verification command, tester-guide link, and correct release identity.
- Retain operator verification details only where they help maintainers; do not make testers read the release pipeline.
- Replace the obsolete `next milestone` paragraph with a beta-operations statement: collect desktop and advanced-MCP feedback, preserve local-only behavior, and use evidence to choose Beta 2 scope.

- [ ] **Step 4: Update the Studio guide**

Make these exact semantic changes:

- Add **Process Another Document** under Result actions and explain that it immediately returns to the drop/open screen without relaunching or deleting saved outputs.
- Replace the unsupported-beta status with the published tag, private repository access requirement, tester-guide link, and installation boundary.
- Add a compatibility/build-provenance section with Xcode 26.6 (`17F113`), Swift 6, arm64, macOS 14 target, M5/M4 acceptance, macOS 27 beta build `26A5388g`, and the later-beta regression caveat.

- [ ] **Step 5: Update the MCP guide's setup section**

Retain all six tool schemas and local-behavior details. Replace the generic-only setup introduction with:

- The installed Studio helper path.
- The exact Codex command and verification commands from Task 1.
- The exact Claude Code command, `claude mcp list`, `/mcp`, and local-vs-user scope explanation from Task 1.
- The client-neutral JSON shape.
- Current official documentation links.
- A clear link back to the advanced section of `BETA_TESTING.md`.
- A separate source-build note preserving `scripts/build-native-tools.sh` and `scripts/smoke-native-tools.sh` for developers.

- [ ] **Step 6: Run focused and existing documentation-related contracts**

```bash
.venv/bin/python -m pytest \
  tests/contract/test_beta_tester_guide.py \
  tests/contract/test_beta_documentation_alignment.py \
  tests/contract/test_extension_manifest.py \
  tests/contract/test_native_python_compatibility.py \
  -q
git diff --check
```

Expected: all tests PASS and no whitespace errors.

- [ ] **Step 7: Commit the aligned repository documentation**

```bash
git add README.md docs/studio.md docs/mcp.md tests/contract/test_beta_documentation_alignment.py
git commit -m "docs: align published beta guidance"
```

---

### Task 3: Add Structured Beta Feedback Intake

**Files:**
- Create: `.github/ISSUE_TEMPLATE/config.yml`
- Create: `.github/ISSUE_TEMPLATE/beta-feedback.yml`
- Create: `tests/contract/test_beta_feedback_template.py`

**Interfaces:**
- Consumes: the feedback link already published in the guide and release notes.
- Produces: a private-repository issue form that supplies consistent evidence for the feedback log.

- [ ] **Step 1: Create a failing feedback-template contract test**

Create `tests/contract/test_beta_feedback_template.py`:

```python
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FORM = ROOT / ".github/ISSUE_TEMPLATE/beta-feedback.yml"


def test_feedback_form_collects_required_beta_context():
    text = FORM.read_text()
    for field_id in (
        "surface",
        "version",
        "mac_model",
        "macos_build",
        "input_profile",
        "expected",
        "actual",
        "reproduction",
        "frequency",
        "category",
        "severity",
        "privacy_confirmation",
    ):
        assert f"id: {field_id}" in text
    assert "v0.2.0-beta.1" in text
    assert "Do not attach the source document or recognized text" in text
    assert "required: true" in text


def test_feedback_form_does_not_request_document_content():
    text = FORM.read_text().lower()
    assert "upload your document" not in text
    assert "paste recognized text" not in text
```

- [ ] **Step 2: Run the focused test and confirm the missing-form failure**

```bash
.venv/bin/python -m pytest tests/contract/test_beta_feedback_template.py -q
```

Expected: FAIL because the form does not exist.

- [ ] **Step 3: Create the issue-template chooser configuration**

Create `.github/ISSUE_TEMPLATE/config.yml`:

```yaml
blank_issues_enabled: false
contact_links: []
```

- [ ] **Step 4: Create the Beta 1 feedback issue form**

Create `.github/ISSUE_TEMPLATE/beta-feedback.yml` with:

```yaml
name: LocalOCR Studio Beta feedback
description: Report a Beta 1 bug, usability issue, question, or feature request.
title: "[Beta 1] "
labels: []
assignees: []
body:
  - type: markdown
    attributes:
      value: |
        Thanks for testing LocalOCR Studio. Do not attach the source document or recognized text. Use a non-sensitive sample if an example is necessary.
  - type: dropdown
    id: surface
    attributes:
      label: Product surface
      options:
        - Desktop app
        - MCP server
        - Command-line tool
    validations:
      required: true
  - type: input
    id: version
    attributes:
      label: LocalOCR version and build
      value: v0.2.0-beta.1 (0.2.0 build 1)
    validations:
      required: true
  - type: input
    id: mac_model
    attributes:
      label: Mac model and Apple chip
      placeholder: MacBook Pro, Apple M4 Pro
    validations:
      required: true
  - type: input
    id: macos_build
    attributes:
      label: macOS version and build number
      placeholder: macOS 27.0 beta, build 26A5388g
    validations:
      required: true
  - type: input
    id: input_profile
    attributes:
      label: Input type and approximate size
      description: Describe only the format and approximate page count, not its content or filename.
      placeholder: Image-only PDF, about 12 pages
    validations:
      required: true
  - type: textarea
    id: expected
    attributes:
      label: Expected behavior
    validations:
      required: true
  - type: textarea
    id: actual
    attributes:
      label: Actual behavior
    validations:
      required: true
  - type: textarea
    id: reproduction
    attributes:
      label: Steps to reproduce
      description: Use non-sensitive descriptions and omit document text, filenames, and paths.
    validations:
      required: true
  - type: dropdown
    id: frequency
    attributes:
      label: Frequency
      options:
        - Every time
        - Often
        - Sometimes
        - Once
    validations:
      required: true
  - type: dropdown
    id: category
    attributes:
      label: Category
      options:
        - Bug
        - Usability issue
        - Privacy concern
        - Feature request
        - Setup question
        - Other
    validations:
      required: true
  - type: dropdown
    id: severity
    attributes:
      label: Severity
      options:
        - Blocking
        - Major
        - Minor
        - Suggestion
    validations:
      required: true
  - type: checkboxes
    id: privacy_confirmation
    attributes:
      label: Privacy confirmation
      options:
        - label: I have not attached or pasted a sensitive source document, recognized text, filename, path, thumbnail, or document hash.
          required: true
    validations:
      required: true
```

- [ ] **Step 5: Parse the YAML and run the feedback tests**

```bash
ruby -e 'require "yaml"; YAML.safe_load_file(".github/ISSUE_TEMPLATE/config.yml", aliases: false); YAML.safe_load_file(".github/ISSUE_TEMPLATE/beta-feedback.yml", aliases: false); puts "issue forms: valid YAML"'
.venv/bin/python -m pytest tests/contract/test_beta_feedback_template.py -q
git diff --check
```

Expected: `issue forms: valid YAML`, all tests PASS, and no diff-check output.

- [ ] **Step 6: Commit the feedback workflow**

```bash
git add .github/ISSUE_TEMPLATE tests/contract/test_beta_feedback_template.py
git commit -m "docs: add structured beta feedback form"
```

---

### Task 4: Verify and Merge the Repository Documentation

**Files:**
- Modify only if verification exposes a defect: files created or edited in Tasks 1-3.

**Interfaces:**
- Consumes: the complete repository documentation change.
- Produces: a reviewed merge commit whose URLs can safely be placed in the live release body.

- [ ] **Step 1: Run the complete documentation contract set**

```bash
.venv/bin/python -m pytest \
  tests/contract/test_beta_tester_guide.py \
  tests/contract/test_beta_documentation_alignment.py \
  tests/contract/test_beta_feedback_template.py \
  tests/contract/test_extension_manifest.py \
  tests/contract/test_native_python_compatibility.py \
  tests/contract/test_release_artifacts.py \
  -q
```

Expected: all selected tests PASS.

- [ ] **Step 2: Run exact stale-language and identity scans**

```bash
! rg -n '67c09271c1aa6dbf23e671cc8c8ebbe7b3b3657d|0b1ea1abcf7528e0ed20665571224d02b4532e693453be0c47b847db276b3ad6|not yet published|no supported LocalOCR Studio beta download|This release remains a draft' \
  README.md BETA_TESTING.md docs/studio.md docs/mcp.md docs/release/v0.2.0-beta.1-notes.md
rg -n '2cb03cc9684ed9bb4b449a0f7d79f0588fb7ae38|3a6a1c754ee369ab9a8ffe01bcc96e7f4927ac44eb1f82b410f538aee901c0d5|26A5388g|Process Another Document' \
  README.md BETA_TESTING.md docs/studio.md docs/release/v0.2.0-beta.1-notes.md
git diff --check origin/main...HEAD
```

Expected: the negative search exits successfully with no matches; the positive search finds each required value; diff check has no output.

- [ ] **Step 3: Verify local Markdown targets**

Run this exact checker:

```bash
.venv/bin/python - <<'PY'
import re
from pathlib import Path

root = Path.cwd()
files = [root / "README.md", root / "BETA_TESTING.md", root / "docs/studio.md", root / "docs/mcp.md"]
missing = []
for source in files:
    for target in re.findall(r"\[[^]]+\]\(([^)]+)\)", source.read_text()):
        if target.startswith(("http://", "https://", "#")):
            continue
        path_text = target.split("#", 1)[0]
        destination = (source.parent / path_text).resolve()
        if path_text and not destination.exists():
            missing.append(f"{source.relative_to(root)} -> {target}")
if missing:
    raise SystemExit("Missing local links:\n" + "\n".join(missing))
print("local Markdown links: valid")
PY
```

Expected: `local Markdown links: valid`.

- [ ] **Step 4: Request review and resolve every Critical or Important finding**

Invoke `superpowers:requesting-code-review` on the complete branch diff. Do not continue while a Critical or Important finding remains. Apply any corrections with focused tests and separate fix commits.

- [ ] **Step 5: Push, open a pull request, and merge only after review passes**

```bash
git push -u origin feature/beta-tester-documentation
gh pr create \
  --base main \
  --head feature/beta-tester-documentation \
  --title "docs: prepare LocalOCR Studio beta testers" \
  --body "Adds the desktop-first Beta 1 guide, verified Codex and Claude Code MCP setup, structured privacy-safe feedback intake, synchronized repository guidance, and canonical release notes. Does not modify release assets, signing, notarization, tag, or release target."
```

After the pull request reports passing checks and approved review, merge it without rewriting earlier release history. Fetch `origin/main` and record the resulting merge commit for Task 6.

```bash
localocr_pr_url="$(gh pr view feature/beta-tester-documentation --json url --jq .url)"
gh pr merge "$localocr_pr_url" --merge --delete-branch
git fetch origin main
git rev-parse origin/main
```

---

### Task 5: Synchronize and Verify the Existing Live Release Body

**Files:**
- Read: `docs/release/v0.2.0-beta.1-notes.md`
- Do not modify: the ZIP/checksum assets or tag.

**Interfaces:**
- Consumes: the merged canonical release notes from Task 4.
- Produces: accurate live tester-facing release notes while preserving release identity and assets.

- [ ] **Step 1: Capture the live release precondition**

```bash
gh api repos/UnoRazorback/localocr/releases/366160392 \
  --jq '{id,tag_name,target_commitish,draft,prerelease,published_at,assets:[.assets[]|{id,name,size,digest,download_count}]}' \
  > /tmp/localocr-release-before.json
```

Inspect the JSON and require release ID `366160392`, tag `v0.2.0-beta.1`, target `2cb03cc9684ed9bb4b449a0f7d79f0588fb7ae38`, `draft=false`, `prerelease=true`, and exactly the two approved assets before mutating the body.

- [ ] **Step 2: Update only the release body**

```bash
gh release edit v0.2.0-beta.1 \
  --repo UnoRazorback/localocr \
  --notes-file docs/release/v0.2.0-beta.1-notes.md
```

Do not pass `--title`, `--target`, `--draft`, `--prerelease`, or asset-upload flags.

- [ ] **Step 3: Fetch and compare the postcondition**

```bash
gh api repos/UnoRazorback/localocr/releases/366160392 \
  --jq '{id,tag_name,target_commitish,draft,prerelease,published_at,body,assets:[.assets[]|{id,name,size,digest,download_count}]}' \
  > /tmp/localocr-release-after.json

.venv/bin/python - <<'PY'
import json
from pathlib import Path

before = json.loads(Path("/tmp/localocr-release-before.json").read_text())
after = json.loads(Path("/tmp/localocr-release-after.json").read_text())
for field in ("id", "tag_name", "target_commitish", "draft", "prerelease", "published_at", "assets"):
    assert after[field] == before[field], field
expected = Path("docs/release/v0.2.0-beta.1-notes.md").read_text().strip()
assert after["body"].strip() == expected
print("release body updated; identity and assets unchanged")
PY
```

Expected: `release body updated; identity and assets unchanged`.

- [ ] **Step 4: Verify the tester links against merged main**

Open the release URL and confirm that the Beta guide, feedback chooser, and advanced MCP documentation resolve for an authorized repository user. Confirm the body no longer contains either superseded commit/hash or draft language.

---

### Task 6: Record Campaign Readiness from Dated Evidence

**Files:**
- Create: `/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/reports/mcp-macvision/MCP-MacVision-Beta-Campaign-Readiness-Evidence-2026-08-07.md`
- Modify: `/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/reports/mcp-macvision/MCP-MacVision-Beta-Metrics.csv`
- Modify: `/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/reports/mcp-macvision/MCP-MacVision-Time-and-Cost-Log.csv`
- Modify: `/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/reports/mcp-macvision/README.md`

**Interfaces:**
- Consumes: repository merge commit, live release API snapshot, current issue/discussion counts, and live asset download counts.
- Produces: the evidence-backed point from which invited-tester campaign uptake is measured.

- [ ] **Step 1: Capture current campaign-readiness evidence**

Collect, without changing external state:

```bash
gh api repos/UnoRazorback/localocr/releases/366160392 \
  --jq '{id,tag_name,target_commitish,draft,prerelease,published_at,updated_at,html_url,assets:[.assets[]|{id,name,digest,download_count}]}'
gh api repos/UnoRazorback/localocr/issues --paginate --jq '[.[] | select(.pull_request == null)] | length'
gh api graphql -f query='query { repository(owner:"UnoRazorback", name:"localocr") { discussions(first:100) { totalCount } } }'
git rev-parse origin/main
```

Record the exact returned values and timestamp. Do not infer tester downloads from checksum downloads and do not count pull requests as issues.

- [ ] **Step 2: Write the readiness evidence file**

The evidence file must contain:

- The merged documentation commit and pull request.
- The unchanged release ID, target, tag, state, asset IDs, names, sizes, and digests.
- The release-body synchronization timestamp and verification result.
- ZIP download count and checksum download count as separate fields.
- Net invited-tester ZIP uptake calculated from the publication baseline of `3`, never below zero.
- Current issue and discussion counts.
- Links to `BETA_TESTING.md`, the feedback form, and the live release.
- A statement that the signed/notarized package was not rebuilt or replaced.
- The exact remaining launch action: owner approval of tester list and outreach copy.

- [ ] **Step 3: Append the current metrics snapshot**

Append one CSV row dated from the live evidence. Keep the primary ZIP count and checksum count separate. In Notes, identify this as the pre-campaign readiness snapshot and preserve the publication baseline of three for calculating net tester uptake.

- [ ] **Step 4: Add a dated time-and-cost milestone row**

Append a row with Workstream `Beta Documentation and Campaign Preparation`, the documentation merge/release-body/evidence links, and blank Hours, Direct Cost, and Shared Cost Allocation unless the user supplies dated evidence. State that automated and agent runtime were excluded.

- [ ] **Step 5: Update the project overview**

Update the report README status and connected evidence list to say that tester instructions, structured feedback, and live release notes are synchronized and that the project is ready for owner-approved invitations. Do not claim outreach has occurred.

- [ ] **Step 6: Validate the records**

```bash
.venv/bin/python - <<'PY'
import csv
from pathlib import Path

base = Path("/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/reports/mcp-macvision")
for name in ("MCP-MacVision-Beta-Metrics.csv", "MCP-MacVision-Time-and-Cost-Log.csv"):
    with (base / name).open(newline="") as handle:
        rows = list(csv.reader(handle))
    width = len(rows[0])
    assert all(len(row) == width for row in rows), name
print("business-record CSV structure: valid")
PY
```

Expected: `business-record CSV structure: valid`.

- [ ] **Step 7: Preserve the records with their own dated commit if the reports folder is version-controlled**

Check the reports repository boundary with:

```bash
git -C "/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/reports/mcp-macvision" rev-parse --show-toplevel
```

If version-controlled, commit only the four Task 6 files with message
`docs: record LocalOCR beta campaign readiness`. If not version-controlled,
retain them in place and record their SHA-256 values in the readiness evidence
file without initializing a new repository.

---

### Task 7: Prepare the Owner-Approval Campaign Packet

**Files:**
- Create: `/Users/scott/Documents/Claude/Projects/Ray Consulting (AI)/reports/mcp-macvision/MCP-MacVision-Beta-Outreach-Drafts-2026-08-07.md`

**Interfaces:**
- Consumes: the verified guide, private release URL, feedback form, and campaign-readiness baseline.
- Produces: exact invitation copy for approval; it does not send invitations or grant repository access.

- [ ] **Step 1: Draft the desktop-first invitation**

Write a concise direct-message/email draft that:

- Calls it `LocalOCR Studio Beta 1`.
- Says it performs private, on-device PDF and image OCR on Apple-silicon Macs.
- States macOS 14 or later and private GitHub access are required.
- Requests a five-minute desktop test first.
- Links to the private release and `BETA_TESTING.md`.
- Asks for Mac model/chip, exact macOS version/build, input type/page count, expected/actual result, and whether Process Another Document worked.
- Warns the tester not to send confidential documents or recognized text.

- [ ] **Step 2: Draft the advanced MCP invitation variant**

Write a second paragraph for developers using Codex or Claude Code. Mention local stdio, the six tools, MCP batch PDF OCR, and the advanced section of the guide. Do not imply tested support for other named clients.

- [ ] **Step 3: Draft the short social/community post**

Prepare a non-sent post that leads with the user problem, local privacy, desktop simplicity, and a request for a small number of Apple-silicon Mac testers. Disclose that the creator is seeking feedback. Do not include the private release URL in a public post; direct interested testers to request access.

- [ ] **Step 4: Define the initial campaign cohort and cadence**

Recommend a controlled first cohort of 5-10 testers:

- 3-5 desktop-only users with scanned PDFs/images.
- 2-3 Codex or Claude Code MCP users.
- At least one tester on macOS 14-26 if available, because current acceptance evidence is on macOS 27 beta.
- Keep the repository private and grant access only after owner approval of each person/account.

Set the first review at 48 hours after invitations and the normal review cadence weekly. At each review, report ZIP downloads separately from checksum downloads, classify substantive feedback, draft replies, and obtain approval before posting or changing external records.

- [ ] **Step 5: Stop for owner approval**

Present the exact drafts, proposed tester list, intended channels, and current evidence snapshot. Do not invite testers, add GitHub collaborators, publish social posts, or send replies until the owner explicitly approves those external actions.
