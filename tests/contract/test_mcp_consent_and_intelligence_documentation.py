import re
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
    documented_tools = tuple(re.findall(r"^### `([a-z0-9_]+)`$", text, re.MULTILINE))
    assert documented_tools == TOOLS
    assert DISCLOSURE in text
    assert (
        "I understand that my MCP client or agent may transmit LocalOCR inputs and "
        "results to an outside provider."
    ) in text
    assert (
        "I confirm that I am authorized to share this data and choose to enable "
        "LocalOCR MCP document tools."
    ) in text
    installed_cli = "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr"
    for operation in ("status", "accept", "revoke"):
        assert f'"{installed_cli}" mcp-consent {operation}' in text


def test_canonical_faq_documents_guided_known_clients_and_copy_only_generic_setup():
    text = MCP.read_text()
    prose = " ".join(text.split())
    codex = text.split("### Codex", 1)[1].split("### Claude Code", 1)[0]
    claude = text.split("### Claude Code", 1)[1].split("### Other MCP clients", 1)[0]
    assert "local child process" in text
    assert "standard input and standard output" in text
    assert "codex mcp add localocr --" in codex
    assert "codex mcp list" in codex
    assert "codex mcp remove localocr" in codex
    assert "Use `/mcp`" in codex
    assert "Codex has no project or user scope option" in " ".join(codex.split())
    assert "claude mcp add --transport stdio --scope local localocr --" in claude
    assert "claude mcp list" in claude
    assert "claude mcp remove --scope local localocr" in claude
    assert "Use `/mcp`" in claude
    assert "Claude Code defaults to local scope for the current project" in " ".join(claude.split())
    assert "--scope user" in claude
    assert '"command": "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp"' in text
    assert ".build/release/localocr-mcp" in text
    assert "requires a separate confirmation" in prose
    assert "Generic clients remain copy-only" in prose
    assert "filesystem permissions" in text


def test_installed_and_source_consent_commands_use_their_matching_cli_helpers():
    text = MCP.read_text()
    installed = text.split("### Source builds for developers", 1)[0]
    source = text.split("### Source builds for developers", 1)[1].split("## Tools", 1)[0]

    installed_cli = "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr"
    installed_mcp = f"{installed_cli}-mcp"
    assert installed_cli in installed
    assert installed_mcp in installed
    for operation in ("status", "accept", "revoke"):
        assert f'"{installed_cli}" mcp-consent {operation}' in installed
    assert "\nlocalocr mcp-consent" not in installed

    for operation in ("status", "accept", "revoke"):
        assert f'"/path/to/localocr/.build/release/localocr" mcp-consent {operation}' in source
    assert '"/path/to/localocr/.build/release/localocr-mcp"' in source
    assert "`dist/native-tools/localocr`" in source
    assert "`dist/native-tools/localocr-mcp`" in source


def test_cli_exit_code_two_covers_all_consent_outcomes():
    text = (ROOT / "docs/cli.md").read_text()
    prose = " ".join(text.split())
    assert "MCP consent is required" in prose
    assert "either acknowledgment is refused" in prose
    assert "input reaches EOF" in prose
    assert "non-interactive terminal" in prose


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
    assert "Ollama" in text
    assert "LM Studio" in text
    assert "Generic OpenAI-compatible endpoints are not accepted" in prose
    assert "never silently switches providers" in prose
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
