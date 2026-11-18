from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GUIDE = ROOT / "BETA_TESTING.md"
RELEASE_NOTES = ROOT / "docs/release/v0.3.2-beta.2-notes.md"
DEPLOYMENT_TARGET = "deployment target macOS 14.0"
RELEASE_URL = "https://github.com/UnoRazorback/localocr/releases/tag/v0.3.2-beta.2"
ZIP_SHA256 = "d49128b2e5ea566d379735dfff0270c91e615de5bb42f12a54e16c392c4b10a1"
LATER_BETA_WARNING = "Future Apple beta compatibility is not guaranteed."


def test_beta_guide_contains_install_desktop_batch_and_privacy_contracts():
    text = GUIDE.read_text()
    required = (
        "LocalOCR-Studio-0.3.2-11.zip",
        "LocalOCR-Studio-0.3.2-11.sha256",
        'shasum -a 256 -c "LocalOCR-Studio-0.3.2-11.sha256"',
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
    assert "release candidate" not in text.lower()
    assert "Do not distribute" not in text


def test_guide_and_release_notes_use_exact_published_identity_and_open_acceptance():
    for path in (GUIDE, RELEASE_NOTES):
        text = path.read_text()
        assert "0.3.2" in text
        assert "build `11`" in text
        assert "v0.3.2-beta.2" in text
        assert "Xcode 27.2" in text
        assert "27B52" in text
        assert DEPLOYMENT_TARGET in text
        assert LATER_BETA_WARNING in text
        prose = " ".join(text.split())
        assert RELEASE_URL in text or "published on November 18, 2026" in prose
        assert "prerelease" in text
        assert "remain open" in prose or "remains open" in prose
    assert ZIP_SHA256 in GUIDE.read_text()
    assert ZIP_SHA256 in RELEASE_NOTES.read_text()
    assert RELEASE_URL in RELEASE_NOTES.read_text()
    notes_prose = " ".join(RELEASE_NOTES.read_text().split())
    assert "not a published download" not in notes_prose
    assert "Not rerun for this build" in notes_prose


def test_beta_guide_documents_help_guided_clients_and_local_model_choices():
    text = GUIDE.read_text()
    prose = " ".join(text.split())
    for required in (
        "offline Help",
        "Ollama",
        "LM Studio",
        "verified IPv4 or IPv6 loopback",
        "never silently switches",
        "Generic MCP clients receive copy-only",
    ):
        assert required in prose
