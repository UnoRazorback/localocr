"""Documentation boundary for the published LocalOCR Studio v0.3 beta."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
NOTES = ROOT / "docs/release/v0.3.0-beta.2-notes.md"
STUDIO = ROOT / "docs/studio.md"
BETA_GUIDE = ROOT / "BETA_TESTING.md"

RELEASE_URL = "https://github.com/UnoRazorback/localocr/releases/tag/v0.3.0-beta.2"
RELEASE_COMMIT = "54828938f4b8bf23a4ae0e7a63fa9552548e7f78"
ZIP_SHA256 = "a60fb34f5f9b9c19413bb2222d2846f472398c73ad4a0a7a1ac19eee09b55691"


def test_published_beta2_identity_is_consistent() -> None:
    for path in (NOTES, STUDIO, BETA_GUIDE):
        text = path.read_text()
        assert RELEASE_URL in text
        assert "v0.3.0-beta.2" in text
        assert "0.3.0" in text
        assert "build `3`" in text
        release_url_index = text.index(RELEASE_URL)
        published_release_context = text[
            max(0, release_url_index - 200) : release_url_index + 400
        ].lower()
        assert "not yet published" not in published_release_context
        assert "currently published prerelease remains" not in published_release_context

    for path in (NOTES, BETA_GUIDE):
        text = path.read_text()
        assert RELEASE_COMMIT in text
        assert ZIP_SHA256 in text
        assert "LocalOCR-Studio-0.3.0-3.zip" in text
        assert "LocalOCR-Studio-0.3.0-3.sha256" in text


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
    assert "Scott’s Mac mini" in combined
    assert "passed" in combined
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
