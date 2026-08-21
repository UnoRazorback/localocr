"""Documentation boundary for the unpublished LocalOCR Studio Beta 2 candidate."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def test_beta2_candidate_identity_and_boundaries_are_explicit() -> None:
    notes = (ROOT / "docs/release/v0.3.0-beta.1-notes.md").read_text()

    assert "v0.3.0-beta.1" in notes
    assert "not yet published" in notes
    assert "Desktop batch" in notes
    assert "one document at a time" in notes
    assert "100% local" in notes
    assert "macOS 14.0+" in notes
