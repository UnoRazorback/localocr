from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DEPLOYMENT_TARGET = "deployment target macOS 14.0"
TESTED_ON_BUILD = "macOS 27.0 beta build `26A5421a`"
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
        assert "v0.3.0-beta.1" in text
        assert "Process Another Document" in text
        assert "Xcode 26.6" in text
        assert DEPLOYMENT_TARGET in text
        assert TESTED_ON_BUILD in text
        assert "no supported localocr studio beta download" not in text.lower()
        assert "not yet published" not in text.lower()
        assert "beta 1 remains the current published release" not in text.lower()


def test_mcp_guide_has_installed_helper_and_verified_client_commands():
    text = FILES["mcp"].read_text()
    assert "/Applications/LocalOCR Studio.app/Contents/Helpers/localocr-mcp" in text
    assert "codex mcp add localocr --" in text
    assert "claude mcp add --transport stdio localocr --" in text
    assert "https://learn.chatgpt.com/docs/extend/mcp" in text
    assert "https://code.claude.com/docs/en/mcp" in text
