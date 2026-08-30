from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GUIDE = ROOT / "BETA_TESTING.md"
RELEASE_NOTES = ROOT / "docs/release/v0.3.0-beta.1-notes.md"

RELEASE_COMMIT = "c2ff3259e190ef5adf037c091a04b34830014131"
ZIP_SHA256 = "620cb698b9e98d3547edca4ab3891dc8a52adaa3261d528de9f91b516838b107"
DEPLOYMENT_TARGET = "deployment target macOS 14.0"
TESTED_ON_BUILD = "macOS 27.0 beta build `26A5421a`"
LATER_BETA_WARNING = "Future Apple beta compatibility is not guaranteed."


def test_beta_guide_contains_install_desktop_batch_and_privacy_contracts():
    text = GUIDE.read_text()
    required = (
        "LocalOCR-Studio-0.3.0-2.zip",
        "LocalOCR-Studio-0.3.0-2.sha256",
        'shasum -a 256 -c "LocalOCR-Studio-0.3.0-2.sha256"',
        "Process Another Document",
        "Create Searchable PDF",
        "New Batch",
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


def test_guide_and_release_notes_use_exact_published_identity():
    for path in (GUIDE, RELEASE_NOTES):
        text = path.read_text()
        assert RELEASE_COMMIT in text
        assert ZIP_SHA256 in text
        assert "Xcode 26.6" in text
        assert "17F113" in text
        assert DEPLOYMENT_TARGET in text
        assert TESTED_ON_BUILD in text
        assert LATER_BETA_WARNING in text
