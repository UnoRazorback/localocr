"""Documentation boundary for the unpublished LocalOCR Studio Beta 2 candidate."""

import re
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
NOTES = ROOT / "docs/release/v0.3.0-beta.1-notes.md"
STUDIO = ROOT / "docs/studio.md"
BETA_GUIDE = ROOT / "BETA_TESTING.md"


def _normalized(text: str) -> str:
    return " ".join(text.split())


def _section(text: str, heading: str, next_heading: str | None = None) -> str:
    start = text.index(heading)
    if next_heading is None:
        next_match = re.search(r"^## ", text[start + len(heading) :], re.MULTILINE)
        end = start + len(heading) + (next_match.start() if next_match else len(text))
    else:
        end = text.index(next_heading, start + len(heading))
    return text[start:end]


def _assert_no_contradictory_candidate_claims(candidate_sections: str) -> None:
    normalized = _normalized(candidate_sections).lower()
    forbidden_claims = (
        ("publication", ("it is published.", "candidate is published", "v0.3.0-beta.1 is published")),
        ("signing", ("it is signed.", "candidate is signed", "v0.3.0-beta.1 is signed")),
        ("notarization", ("it is notarized.", "candidate is notarized", "v0.3.0-beta.1 is notarized")),
        ("stapling", ("it is stapled.", "candidate is stapled", "v0.3.0-beta.1 is stapled")),
        (
            "Gatekeeper acceptance",
            (
                "it is gatekeeper accepted.",
                "candidate is gatekeeper accepted",
                "v0.3.0-beta.1 is gatekeeper accepted",
            ),
        ),
        (
            "acceptance",
            (
                "it passed acceptance.",
                "candidate passed acceptance",
                "v0.3.0-beta.1 passed acceptance",
            ),
        ),
    )
    for claim, forbidden_phrases in forbidden_claims:
        assert not any(phrase in normalized for phrase in forbidden_phrases), (
            f"candidate must not claim {claim}"
        )


def _validate_candidate_documentation(
    *,
    notes: str,
    studio: str,
    beta_guide: str,
) -> None:
    candidate_identity = notes[: notes.index("## Desktop batch")]
    candidate_workflow = _section(notes, "## Desktop batch", "## Privacy")
    candidate_compatibility = _section(
        notes,
        "## Compatibility and verification boundary",
        "## Current limitations",
    )
    studio_workflow = _section(studio, "## Desktop batch", "## Result actions")
    studio_published_beta1 = _section(studio, "## Beta status", "## Compatibility")
    beta_guide_candidate_identity = beta_guide[: beta_guide.index("## Download and install")]
    beta_guide_workflow = _section(
        beta_guide,
        "## Beta 2 candidate: desktop batch workflow",
        "## Five-minute desktop test",
    )
    beta_guide_published_beta1 = _section(
        beta_guide,
        "## Compatibility and build provenance",
        "## Known limitations",
    )

    normalized_identity = _normalized(candidate_identity)
    normalized_compatibility = _normalized(candidate_compatibility)
    normalized_workflow = _normalized(candidate_workflow)

    _assert_no_contradictory_candidate_claims(
        "\n".join(
            (
                candidate_identity,
                candidate_workflow,
                candidate_compatibility,
                studio_published_beta1,
                beta_guide_candidate_identity,
                beta_guide_workflow,
            )
        )
    )

    assert (
        "`v0.3.0-beta.1` is a release candidate for LocalOCR Studio version "
        "`0.3.0`, build `2`."
    ) in normalized_identity
    assert "It is not yet published." in normalized_identity
    assert (
        "It has no release archive, checksum, signature, notarization, stapling, Gatekeeper result, or acceptance record."
        in normalized_identity
    )
    assert (
        "The currently published prerelease remains [`v0.2.0-beta.1`](https://github.com/UnoRazorback/localocr/releases/tag/v0.2.0-beta.1)."
        in normalized_identity
    )

    assert "LocalOCR Studio still opens with one document at a time." in normalized_workflow
    assert (
        "In **New Batch**, add files or folders and choose the output folder before starting."
        in normalized_workflow
    )
    assert (
        "After review, **Start Batch** processes the queue sequentially, one document at a time."
        in normalized_workflow
    )
    assert (
        "At completion, use **Retry Failed** for failed items only, **Reveal Output Folder** to open the selected destination, or **Start New Batch** to clear the queue."
        in normalized_workflow
    ), "completion actions must name Start New Batch"

    assert (
        "macOS 14.0+ on Apple silicon is supported by this candidate's project target."
        in normalized_compatibility
    )
    assert (
        "This statement does not establish a built, signed, notarized, or accepted candidate."
        in normalized_compatibility
    )
    assert "Beta 1 release only; it is not evidence for this candidate." in normalized_compatibility
    assert "Future Apple beta compatibility is not guaranteed." in normalized_compatibility

    assert (
        "The published prerelease is [v0.2.0-beta.1](https://github.com/UnoRazorback/localocr/releases/tag/v0.2.0-beta.1)."
        in _normalized(studio_published_beta1)
    )
    normalized_beta1_provenance = _normalized(beta_guide_published_beta1)
    assert "The published Beta 1 build (version `0.2.0`)" in normalized_beta1_provenance
    assert "Release provenance: version `0.2.0` build `1`" in normalized_beta1_provenance
    assert "Apple notarized, stapled, and Gatekeeper accepted." in normalized_beta1_provenance

    assert (
        "After a completed run, use **Retry Failed** to try only failed items, "
        "**Reveal Output Folder** to open the chosen destination, or **Start New Batch** "
        "to clear the review and begin again."
        in _normalized(studio_workflow)
    )
    assert (
        "You can cancel a running batch, retry only failed items after it completes, "
        "reveal the chosen output folder, or select **Start New Batch** to clear the queue."
        in _normalized(beta_guide_workflow)
    )


def test_beta2_candidate_identity_and_boundaries_are_explicit() -> None:
    _validate_candidate_documentation(
        notes=NOTES.read_text(),
        studio=STUDIO.read_text(),
        beta_guide=BETA_GUIDE.read_text(),
    )


@pytest.mark.parametrize(
    ("replacement", "expected_message"),
    (
        ("It is published.", "candidate must not claim publication"),
        ("It is signed.", "candidate must not claim signing"),
        ("It is notarized.", "candidate must not claim notarization"),
        ("It is stapled.", "candidate must not claim stapling"),
        ("It is Gatekeeper accepted.", "candidate must not claim Gatekeeper acceptance"),
        ("It passed acceptance.", "candidate must not claim acceptance"),
    ),
)
def test_candidate_validator_rejects_contradictory_candidate_claims(
    replacement: str,
    expected_message: str,
) -> None:
    notes = NOTES.read_text().replace("It is not yet published.", replacement)

    with pytest.raises(AssertionError, match=expected_message):
        _validate_candidate_documentation(
            notes=notes,
            studio=STUDIO.read_text(),
            beta_guide=BETA_GUIDE.read_text(),
        )


def test_candidate_validator_rejects_misplaced_completion_control() -> None:
    notes = NOTES.read_text().replace(
        "or **Start New Batch** to clear the queue.",
        "or start another review.",
    ).replace(
        "## Privacy",
        "**Start New Batch** is mentioned outside completion actions.\n\n## Privacy",
    )

    with pytest.raises(AssertionError, match="completion actions must name Start New Batch"):
        _validate_candidate_documentation(
            notes=notes,
            studio=STUDIO.read_text(),
            beta_guide=BETA_GUIDE.read_text(),
        )


def test_candidate_validator_rejects_a_contradictory_claim_in_the_beta_guide() -> None:
    beta_guide = BETA_GUIDE.read_text().replace(
        "## Download and install",
        "The candidate is signed.\n\n## Download and install",
    )

    with pytest.raises(AssertionError, match="candidate must not claim signing"):
        _validate_candidate_documentation(
            notes=NOTES.read_text(),
            studio=STUDIO.read_text(),
            beta_guide=beta_guide,
        )
