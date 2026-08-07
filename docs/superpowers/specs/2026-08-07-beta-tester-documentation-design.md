# LocalOCR Studio Beta Tester Documentation Design

**Date:** 2026-08-07
**Status:** Owner-approved design

## Objective

Prepare the published private-repository prerelease `v0.2.0-beta.1` for
approved beta testers with accurate, desktop-first instructions and a separate
advanced MCP path. Correct stale release identity and publication language
without rebuilding or changing the signed application artifacts.

## Audience and information hierarchy

The primary audience is a privacy-conscious Mac user testing LocalOCR Studio.
The main guide must assume no MCP knowledge and lead with the desktop app.
Developer and AI-agent users receive a clearly separated advanced section for
the bundled local CLI and stdio MCP server.

The hierarchy is:

1. Access, download, verification, and installation.
2. Desktop features and a short acceptance checklist.
3. Privacy, compatibility, build provenance, and limitations.
4. Feedback instructions.
5. Optional advanced MCP configuration.

## Published release identity

Every tester-facing surface must use the reviewed replacement candidate:

- Release ID/tag: `366160392` / `v0.2.0-beta.1`.
- Release URL:
  `https://github.com/UnoRazorback/localocr/releases/tag/v0.2.0-beta.1`.
- Source commit: `2cb03cc9684ed9bb4b449a0f7d79f0588fb7ae38`.
- Version/build: `0.2.0` / `1`.
- ZIP SHA-256:
  `3a6a1c754ee369ab9a8ffe01bcc96e7f4927ac44eb1f82b410f538aee901c0d5`.
- State: published prerelease in a private repository; access is limited to
  authorized repository users.

The live release notes must no longer reference commit `67c09271...`, ZIP
SHA-256 `0b1ea1ab...`, an unpublished draft, or missing owner authorization.

## Beta tester guide

Create `BETA_TESTING.md` as the single tester-facing entry point.

### Access, verification, and installation

- State that the repository and published prerelease remain private and that a
  tester needs repository access.
- Tell testers to download both the ZIP and matching `.sha256` file from the
  tagged release into the same directory.
- Provide the exact `shasum -a 256 -c` command and require an `OK` result.
- Direct testers to expand the verified ZIP, move `LocalOCR Studio.app` to
  `/Applications`, and open it normally.
- Instruct testers not to bypass Gatekeeper, remove quarantine attributes, or
  use an unverified build/staging copy.

### Desktop features

Describe only implemented Beta 1 behavior:

- One PDF or image at a time through Open or drag and drop.
- Local Apple Vision and PDFKit processing.
- Common ImageIO-backed formats including PNG, JPEG, TIFF, and HEIC/HEIF,
  subject to the installed macOS ImageIO support.
- Existing usable PDF text is preserved; pages needing OCR are recognized.
- Copy recognized text.
- Save recognized text as a plain-text file.
- Create a new searchable PDF while preserving the source.
- Use **Process Another Document** to return immediately to the drop/open
  screen without relaunching.

### Five-minute tester checklist

Ask the tester to:

1. Open one PDF and confirm useful recognized text.
2. Create a searchable PDF at a new destination and confirm the original was
   not replaced.
3. Select **Process Another Document** and confirm the drop/open screen returns
   without relaunching.
4. Open one supported image and confirm recognized text.
5. Copy or save the text.
6. Quit and reopen the app normally.

The guide must tell testers to use non-sensitive sample documents when
reporting issues and never attach confidential source documents or recognized
text to a public or broadly shared channel.

## Privacy and limitations

State that OCR runs locally and LocalOCR does not provide cloud OCR, cloud
storage, an HTTP MCP listener, or a network MCP service. Documents,
recognized text, paths, cache entries, and outputs are not uploaded by
LocalOCR. Explain the local cache path and that the application retains no
document/result history.

List current Beta 1 limitations:

- Apple silicon only.
- macOS 14 or later.
- No Intel, Windows, or Linux support.
- Desktop processing is one document at a time.
- No history, batch queue, language/settings wizard, or guided MCP setup.
- MCP setup is manual and uses local stdio.
- Beta output behavior may change; testers must retain original documents.

## Compatibility and build provenance

Tester-facing documents and release notes must distinguish the build toolchain,
deployment target, and tested operating-system builds:

- Built with stable Xcode 26.6, build `17F113`.
- Swift 6, arm64, deployment target macOS 14.0.
- Developer ID signed with Hardened Runtime, Apple notarized, stapled, and
  Gatekeeper accepted.
- Complete downloaded-package and GUI acceptance passed on Apple M5 and Apple
  M4 Macs running macOS 27 beta build `26A5388g`.

Use the wording **tested on macOS 27 beta build `26A5388g`**, not “safe on all
macOS 27 betas.” State that later Apple beta builds may introduce regressions
and should be reported with the exact macOS version and build number.

## Advanced MCP setup

The advanced section must explain that Studio remains one-document-at-a-time,
while the bundled MCP server exposes six tools and includes batch PDF OCR. The
installed helper path is:

```text
/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp
```

### Codex CLI

Use the current official stdio command shape:

```bash
codex mcp add localocr -- \
  "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp"
codex mcp list
```

Tell testers to use `/mcp` in Codex to inspect the connected server. Note that
the Codex CLI, IDE extension, and desktop app share MCP configuration on the
same Codex host. Link to the current official Codex MCP documentation rather
than duplicating mutable configuration-file locations.

### Claude Code

Use the current official stdio command shape:

```bash
claude mcp add --transport stdio localocr -- \
  "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp"
claude mcp list
```

Tell testers to use `/mcp` inside Claude Code to inspect status. Explain that
the default local scope applies to the current project and that testers may
choose `--scope user` only when they intentionally want LocalOCR available
across projects. Link to Anthropic's current MCP documentation.

### Other MCP clients

Provide a client-neutral stdio shape:

```json
{
  "command": "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp",
  "args": []
}
```

Do not name or imply support for untested clients. Tell testers to use their
client's current official documentation to locate its MCP configuration and
verification interface.

### MCP verification and prompts

List the six tools: `get_pdf_page_count`, `inspect_pdf`, `ocr_pdf`,
`ocr_pdf_batch`, `ocr_image`, and `make_searchable_pdf`. Provide a small set of
safe example requests using absolute local paths and non-sensitive fixtures.
Make clear that LocalOCR does not edit client configuration and that filesystem
permissions are still enforced by macOS and the MCP client.

## Feedback workflow

Add `.github/ISSUE_TEMPLATE/beta-feedback.yml` with structured fields for:

- LocalOCR version/build and desktop/MCP surface.
- Mac model and Apple chip.
- macOS version and build number.
- Input type and approximate page count, without requesting the document.
- Expected and actual behavior.
- Reproduction steps and frequency.
- Category and severity.
- Confirmation that sensitive documents/text are not attached.

Link the template or private repository issue tracker from `BETA_TESTING.md`
and the release notes. Retain the existing evidence-based metrics and feedback
logs; the documentation change does not alter their publication baseline.

## Repository and live-release updates

Update:

- `README.md` to replace all unpublished-beta language and link the beta guide.
- `docs/studio.md` to include **Process Another Document**, current published
  private-beta status, and the compatibility statement.
- `docs/mcp.md` to link the client-specific advanced setup while retaining the
  complete tool reference.
- The live release body for release ID `366160392` with the exact candidate
  identity, desktop-first instructions, feature summary, compatibility/build
  provenance, advanced-guide link, known limitations, and feedback link.

The release remains a prerelease in a private repository. Do not replace its
ZIP/checksum assets, change the tag or target commit, rebuild, re-sign,
re-notarize, or make the repository public.

## Verification

- Markdown links and referenced paths resolve.
- No tester-facing file contains obsolete commit/hash/draft language.
- The exact release identity appears consistently.
- Codex and Claude commands match their current official stdio syntax.
- The feedback issue form parses as valid YAML and contains the privacy
  confirmation.
- Repository documentation checks and `git diff --check` pass.
- After merge, the live release body is updated and fetched back through the
  GitHub API; release ID, tag, target commit, prerelease state, assets, and
  digests remain unchanged.
