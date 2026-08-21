"""Documentation boundary for the unpublished LocalOCR Studio Beta 2 candidate."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CANDIDATE_DOCS = (
    ROOT / "docs/release/v0.3.0-beta.1-notes.md",
    ROOT / "docs/studio.md",
    ROOT / "BETA_TESTING.md",
)


def test_beta2_candidate_identity_and_boundaries_are_explicit() -> None:
    notes = (ROOT / "docs/release/v0.3.0-beta.1-notes.md").read_text()

    assert "v0.3.0-beta.1" in notes
    assert "not yet published" in notes
    assert "Desktop batch" in notes
    assert "one document at a time" in notes
    assert "100% local" in notes
    assert "macOS 14.0+" in notes
    assert "build `2`" in notes
    assert "Apple silicon" in notes
    assert "v0.2.0-beta.1" in notes
    assert "published prerelease remains" in notes
    assert "no release archive, checksum" in notes
    assert "Future Apple beta compatibility is not guaranteed." in notes
    for path in CANDIDATE_DOCS:
        assert "**Start New Batch**" in path.read_text()
