import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DEPLOYMENT_TARGET = "deployment target macOS 14.0"
VERSION = "0.3.1"
BUILD = "4"
TAG = "v0.3.1-beta.1"
FILES = {
    "readme": ROOT / "README.md",
    "studio": ROOT / "docs/studio.md",
    "mcp": ROOT / "docs/mcp.md",
    "cli": ROOT / "docs/cli.md",
}


def test_repository_docs_link_to_beta_guide():
    assert "BETA_TESTING.md" in FILES["readme"].read_text()
    assert "../BETA_TESTING.md" in FILES["studio"].read_text()
    assert "../BETA_TESTING.md" in FILES["mcp"].read_text()


def test_readme_and_studio_describe_beta_2_1_candidate_and_reset():
    for key in ("readme", "studio"):
        text = FILES[key].read_text()
        prose = " ".join(text.split())
        assert VERSION in text
        assert BUILD in text
        assert TAG in text
        assert "release candidate" in text.lower()
        assert "no published Beta 2.1 download is claimed" in prose or "no Beta 2.1 download is being claimed" in prose
        assert "Process Another Document" in text
        assert "Xcode 26.6" in text
        assert DEPLOYMENT_TARGET in prose
        assert "Future Apple beta compatibility is not guaranteed" in prose


def test_mcp_guide_has_installed_helper_and_verified_client_commands():
    text = FILES["mcp"].read_text()
    assert "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp" in text
    assert "codex mcp add localocr --" in text
    assert "claude mcp add --transport stdio --scope local localocr --" in text
    assert "https://learn.chatgpt.com/docs/extend/mcp" in text
    assert "https://code.claude.com/docs/en/mcp" in text
    assert "requires a separate confirmation" in text
    assert "Generic clients remain" in text and "copy-only" in text


def test_current_docs_align_on_beta_2_1_providers_help_and_helpers():
    for path in (*FILES.values(), ROOT / "BETA_TESTING.md"):
        text = path.read_text()
        prose = " ".join(text.split())
        if path.name in {"README.md", "studio.md", "mcp.md", "BETA_TESTING.md"}:
            assert "Ollama" in text
            assert "LM Studio" in text
            assert "never silently switches" in prose
    readme = FILES["readme"].read_text()
    assert "localocr-model-bridge" in readme
    assert "offline Help" in readme


def test_desktop_first_docs_point_to_one_canonical_advanced_setup():
    for key in ("readme", "studio"):
        text = FILES[key].read_text()
        assert "docs/mcp.md#advanced-setup" in text or "mcp.md#advanced-setup" in text

    beta = (ROOT / "BETA_TESTING.md").read_text()
    assert "docs/mcp.md#advanced-setup" in beta


def test_cli_and_mcp_docs_align_on_consent_management():
    cli_text = FILES["cli"].read_text()
    mcp_text = FILES["mcp"].read_text()
    installed_cli = "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr"
    for operation in ("status", "accept", "revoke"):
        assert f"localocr mcp-consent {operation}" in cli_text
        assert f'"{installed_cli}" mcp-consent {operation}' in mcp_text
