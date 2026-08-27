from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GUIDE = ROOT / "BETA_TESTING.md"
RELEASE_NOTES = ROOT / "docs/release/v0.2.0-beta.1-notes.md"

RELEASE_COMMIT = "2cb03cc9684ed9bb4b449a0f7d79f0588fb7ae38"
ZIP_SHA256 = "3a6a1c754ee369ab9a8ffe01bcc96e7f4927ac44eb1f82b410f538aee901c0d5"
DEPLOYMENT_TARGET = "deployment target macOS 14.0"
TESTED_ON_BUILD = "tested on macOS 27 beta build `26A5388g`"
LATER_BETA_WARNING = (
    "Later Apple beta builds may introduce regressions; report the exact macOS version "
    "and build number."
)
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
    prose = " ".join(text.split())
    helper = "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp"
    assert helper in text
    assert "codex mcp add localocr --" in text
    assert "claude mcp add --transport stdio --scope local localocr --" in text
    assert "Claude Code defaults to local scope for the current project" in prose
    assert "local/project scope" not in text
    assert "--scope user" in text
    for tool in (
        "get_pdf_page_count",
        "inspect_pdf",
        "ocr_pdf",
        "ocr_pdf_batch",
        "ocr_image",
        "make_searchable_pdf",
        "summarize_document",
        "organize_document",
        "extract_document_fields",
    ):
        assert tool in text


def test_beta_guide_keeps_desktop_first_and_links_to_the_canonical_mcp_faq():
    text = GUIDE.read_text()
    assert text.index("## What the desktop app does") < text.index("## Advanced: MCP setup")
    assert "[canonical MCP FAQ](docs/mcp.md#advanced-setup)" in text
    assert "next-version candidate" in text
    assert "not yet published" in text


def test_guide_and_release_notes_use_exact_candidate_identity():
    for path in (GUIDE, RELEASE_NOTES):
        text = path.read_text()
        assert RELEASE_COMMIT in text
        assert ZIP_SHA256 in text
        assert "Xcode 26.6" in text
        assert "17F113" in text
        assert DEPLOYMENT_TARGET in text
        assert TESTED_ON_BUILD in text
        assert text.count(LATER_BETA_WARNING) == 1
        for stale in STALE_VALUES:
            assert stale not in text
