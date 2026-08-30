"""Documentation boundary for the published LocalOCR Studio v0.3 beta."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
NOTES = ROOT / "docs/release/v0.3.0-beta.1-notes.md"
STUDIO = ROOT / "docs/studio.md"
BETA_GUIDE = ROOT / "BETA_TESTING.md"

RELEASE_URL = "https://github.com/UnoRazorback/localocr/releases/tag/v0.3.0-beta.1"
RELEASE_COMMIT = "c2ff3259e190ef5adf037c091a04b34830014131"
ZIP_SHA256 = "620cb698b9e98d3547edca4ab3891dc8a52adaa3261d528de9f91b516838b107"


def test_published_beta2_identity_is_consistent() -> None:
    for path in (NOTES, STUDIO, BETA_GUIDE):
        text = path.read_text()
        assert RELEASE_URL in text
        assert "v0.3.0-beta.1" in text
        assert "0.3.0" in text
        assert "build `2`" in text
        assert "not yet published" not in text.lower()
        assert "currently published prerelease remains" not in text.lower()

    for path in (NOTES, BETA_GUIDE):
        text = path.read_text()
        assert RELEASE_COMMIT in text
        assert ZIP_SHA256 in text
        assert "LocalOCR-Studio-0.3.0-2.zip" in text
        assert "LocalOCR-Studio-0.3.0-2.sha256" in text


def test_published_beta2_documents_describe_the_actual_batch_flow() -> None:
    for path in (NOTES, STUDIO, BETA_GUIDE):
        text = path.read_text()
        for phrase in (
            "New Batch",
            "output folder",
            "Start Batch",
            "sequential",
            "Start New Batch",
        ):
            assert phrase in text


def test_published_beta2_keeps_exact_acceptance_boundary() -> None:
    combined = "\n".join(path.read_text() for path in (NOTES, STUDIO, BETA_GUIDE))
    assert "macOS 27.0 beta build `26A5421a`" in combined
    assert "second-Mac" in combined
    assert "pending" in combined
    assert "Apple notarized" in combined
    assert "stapled" in combined
    assert "Gatekeeper accepted" in combined
    assert "Future Apple beta compatibility is not guaranteed." in combined


def test_public_beta2_docs_do_not_market_unreleased_local_intelligence() -> None:
    combined = "\n".join(path.read_text() for path in (NOTES, STUDIO, BETA_GUIDE))
    for unreleased_claim in (
        "Ollama model selection is available",
        "LM Studio model selection is available",
        "Foundation Models summaries are included",
    ):
        assert unreleased_claim not in combined
