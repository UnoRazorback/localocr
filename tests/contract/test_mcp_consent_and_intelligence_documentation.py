from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MCP = ROOT / "docs/mcp.md"
STUDIO = ROOT / "docs/studio.md"

TOOLS = (
    "get_pdf_page_count",
    "inspect_pdf",
    "ocr_pdf",
    "ocr_pdf_batch",
    "ocr_image",
    "make_searchable_pdf",
    "summarize_document",
    "organize_document",
    "extract_document_fields",
)

DISCLOSURE = """LocalOCR and Apple Foundation Models process documents locally on this Mac,
and LocalOCR does not upload them. When you connect LocalOCR to an agent
through MCP, that MCP client or its AI provider may send filenames, paths,
document text, summaries, extracted fields, and tool results to an outside
service. Transmission, retention, model training, and other handling are
controlled by the agent and provider, not LocalOCR. Review their privacy and
data policies, and only continue if you are authorized to share the data."""


def test_canonical_faq_documents_exact_tool_and_consent_contracts():
    text = MCP.read_text()
    for tool in TOOLS:
        assert f"`{tool}`" in text
    assert DISCLOSURE in text
    assert (
        "I understand that my MCP client or agent may transmit LocalOCR inputs and "
        "results to an outside provider."
    ) in text
    assert (
        "I confirm that I am authorized to share this data and choose to enable "
        "LocalOCR MCP document tools."
    ) in text
    for command in (
        "localocr mcp-consent status",
        "localocr mcp-consent accept",
        "localocr mcp-consent revoke",
    ):
        assert command in text


def test_canonical_faq_documents_client_setup_without_automatic_edits():
    text = MCP.read_text()
    prose = " ".join(text.split())
    assert "local child process" in text
    assert "standard input and standard output" in text
    assert "codex mcp add localocr --" in text
    assert "claude mcp add --transport stdio --scope local localocr --" in text
    assert '"command": "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp"' in text
    assert ".build/release/localocr-mcp" in text
    assert "does not automatically edit" in prose
    assert "filesystem permissions" in text


def test_canonical_faq_preserves_local_intelligence_and_provider_boundaries():
    text = MCP.read_text()
    prose = " ".join(text.split())
    for requirement in (
        "macOS 26 or later",
        "eligible Mac",
        "Apple Intelligence enabled",
        "on-device model ready",
        "supported Apple Intelligence language",
    ):
        assert requirement in text
    for unavailable in (
        "Apple Intelligence is not enabled",
        "model is not ready",
        "language is not supported",
    ):
        assert unavailable in text
    assert "does not use Private Cloud Compute" in text
    assert "no cloud fallback" in text
    assert "do not assume that data remains on your Mac" in prose
    assert "privacy, retention, training, and provider behavior may change" in prose


def test_studio_docs_distinguish_temporary_single_document_intelligence_from_batch():
    text = STUDIO.read_text()
    assert "single-document" in text
    assert "temporary" in text
    assert "non-destructive" in text
    assert "Batch remains OCR-only" in text
    assert "does not require MCP consent" in text


def test_canonical_faq_has_complete_troubleshooting_and_retention_guidance():
    text = MCP.read_text()
    for issue in (
        "Helper path",
        "Client connection",
        "Filesystem permissions",
        "Consent required",
        "Local Intelligence unavailable",
    ):
        assert issue in text
    assert "Keep the original document" in text
