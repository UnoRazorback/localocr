"""Documentation boundary for the unpublished LocalOCR Studio Beta 2 candidate."""

import re
from dataclasses import dataclass
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
NOTES = ROOT / "docs/release/v0.3.0-beta.1-notes.md"
STUDIO = ROOT / "docs/studio.md"
BETA_GUIDE = ROOT / "BETA_TESTING.md"


@dataclass(frozen=True)
class MarkdownHeading:
    level: int
    title: str
    start: int
    end: int


def _normalized(text: str) -> str:
    return " ".join(text.split())


def _markdown_headings(text: str) -> tuple[MarkdownHeading, ...]:
    return tuple(
        MarkdownHeading(
            level=len(match.group("marker")),
            title=match.group("title").strip(),
            start=match.start(),
            end=match.end(),
        )
        for match in re.finditer(
            r"^(?P<marker>#{1,6})\s+(?P<title>.+?)\s*$",
            text,
            re.MULTILINE,
        )
    )


def _required_sections(
    text: str,
    required_headings: tuple[tuple[int, str], ...],
) -> dict[str, str]:
    headings = _markdown_headings(text)
    selected: list[MarkdownHeading] = []
    for level, title in required_headings:
        matches = [heading for heading in headings if heading.title == title]
        assert len(matches) == 1, (
            f"required heading '{title}' must appear exactly once"
        )
        heading = matches[0]
        assert heading.level == level, (
            f"required heading '{title}' must use level {level}"
        )
        selected.append(heading)

    assert [heading.start for heading in selected] == sorted(
        heading.start for heading in selected
    ), "required headings are out of order"

    sections: dict[str, str] = {}
    for heading in selected:
        next_heading = next(
            (
                candidate
                for candidate in headings
                if candidate.start > heading.start
                and candidate.level <= heading.level
            ),
            None,
        )
        section_end = next_heading.start if next_heading else len(text)
        sections[heading.title] = text[heading.end:section_end]
    return sections


def _section_lead(section: str, *, section_level: int) -> str:
    boundary = next(
        (
            heading
            for heading in _markdown_headings(section)
            if heading.level <= section_level + 1
        ),
        None,
    )
    return section[: boundary.start if boundary else len(section)]


_CANDIDATE_SUBJECT = (
    r"(?:the\s+candidate|this\s+candidate|candidate|this\s+build|"
    r"`?v0\.3\.0-beta\.1`?|it)"
)
_STATUS_ADVERB = r"(?:now|not|never|no|yet|longer)"
_COPULAR_STATUS = re.compile(
    rf"(?P<statement>(?:no\s+)?{_CANDIDATE_SUBJECT}\s+"
    rf"(?P<verb_phrase>"
    rf"(?:is|was)(?:\s+{_STATUS_ADVERB})*|"
    rf"(?:has|had)(?:\s+{_STATUS_ADVERB})*\s+been"
    rf"(?:\s+{_STATUS_ADVERB})*"
    rf")\s+"
    rf"(?P<status>gatekeeper\s+accepted|published|signed|notarized|stapled)\b)",
    re.IGNORECASE,
)
_ACCEPTANCE_STATUS = re.compile(
    rf"(?P<statement>(?:no\s+)?{_CANDIDATE_SUBJECT}\s+"
    rf"(?P<verb_phrase>(?:has|had)(?:\s+{_STATUS_ADVERB})*\s+passed|passed)"
    rf"\s+acceptance\b)",
    re.IGNORECASE,
)
_NEGATION = re.compile(r"\b(?:not|never|no)\b", re.IGNORECASE)
_STATUS_CLAIMS = {
    "published": "publication",
    "signed": "signing",
    "notarized": "notarization",
    "stapled": "stapling",
    "gatekeeper accepted": "Gatekeeper acceptance",
}


def _positive_candidate_status(candidate_sections: str) -> str | None:
    normalized = _normalized(candidate_sections).replace("**", "")
    for statement in _COPULAR_STATUS.finditer(normalized):
        if _NEGATION.search(statement.group("statement")) is None:
            status = statement.group("status").lower()
            return _STATUS_CLAIMS[status]

    for statement in _ACCEPTANCE_STATUS.finditer(normalized):
        if _NEGATION.search(statement.group("statement")) is None:
            return "acceptance"

    return None


def _assert_no_contradictory_candidate_claims(candidate_sections: str) -> None:
    claim = _positive_candidate_status(candidate_sections)
    assert claim is None, f"candidate must not claim {claim}"


def _assert_completion_action(workflow: str) -> None:
    normalized = _normalized(workflow)
    assert "**Start New Batch**" in normalized
    assert re.search(
        r"(?:at completion|after a completed run|after it completes)[^.]*\*\*Start New Batch\*\*",
        normalized,
        re.IGNORECASE,
    ), "completion actions must name Start New Batch"


def _validate_candidate_documentation(
    *,
    notes: str,
    studio: str,
    beta_guide: str,
) -> None:
    notes_sections = _required_sections(
        notes,
        (
            (1, "LocalOCR Studio v0.3.0-beta.1 candidate"),
            (2, "Desktop batch, after the default single-document flow"),
            (2, "Privacy"),
            (2, "Compatibility and verification boundary"),
            (2, "Current limitations"),
        ),
    )
    studio_sections = _required_sections(
        studio,
        (
            (2, "Desktop batch"),
            (2, "Result actions"),
            (2, "Beta status"),
            (2, "Compatibility and build provenance"),
        ),
    )
    beta_guide_sections = _required_sections(
        beta_guide,
        (
            (1, "LocalOCR Studio Beta Tester Guide"),
            (2, "Download and install"),
            (2, "Beta 2 candidate: desktop batch workflow"),
            (2, "Five-minute desktop test"),
            (2, "Compatibility and build provenance"),
            (2, "Known limitations"),
        ),
    )

    candidate_identity = _section_lead(
        notes_sections["LocalOCR Studio v0.3.0-beta.1 candidate"],
        section_level=1,
    )
    candidate_workflow = notes_sections[
        "Desktop batch, after the default single-document flow"
    ]
    candidate_compatibility = notes_sections["Compatibility and verification boundary"]
    beta_guide_candidate_identity = _section_lead(
        beta_guide_sections["LocalOCR Studio Beta Tester Guide"],
        section_level=1,
    )
    beta_guide_workflow = beta_guide_sections[
        "Beta 2 candidate: desktop batch workflow"
    ]

    _assert_no_contradictory_candidate_claims(
        "\n".join(
            (
                candidate_identity,
                candidate_workflow,
                candidate_compatibility,
                beta_guide_candidate_identity,
                beta_guide_workflow,
            )
        )
    )

    normalized_identity = _normalized(candidate_identity)
    assert "`v0.3.0-beta.1`" in normalized_identity
    assert "version `0.3.0`" in normalized_identity
    assert "build `2`" in normalized_identity
    assert "not yet published" in normalized_identity
    assert (
        "It has no release archive, checksum, signature, notarization, stapling, "
        "Gatekeeper result, or acceptance record."
        in normalized_identity
    )
    assert (
        "The currently published prerelease remains "
        "[`v0.2.0-beta.1`](https://github.com/UnoRazorback/localocr/releases/tag/v0.2.0-beta.1)."
        in normalized_identity
    )

    normalized_workflow = _normalized(candidate_workflow)
    for phrase in (
        "one document at a time",
        "**New Batch**",
        "output folder",
        "**Start Batch**",
        "sequentially",
    ):
        assert phrase in normalized_workflow
    _assert_completion_action(candidate_workflow)

    normalized_compatibility = _normalized(candidate_compatibility)
    assert "macOS 14.0+" in normalized_compatibility
    assert "Apple silicon" in normalized_compatibility
    assert "not evidence for this candidate" in normalized_compatibility
    assert "Future Apple beta compatibility is not guaranteed." in normalized_compatibility

    studio_published_beta1 = studio_sections["Beta status"]
    assert (
        "The published prerelease is "
        "[v0.2.0-beta.1](https://github.com/UnoRazorback/localocr/releases/tag/v0.2.0-beta.1)."
        in _normalized(studio_published_beta1)
    )
    beta1_provenance = _normalized(
        beta_guide_sections["Compatibility and build provenance"]
    )
    for phrase in (
        "published Beta 1 build",
        "version `0.2.0`",
        "build `1`",
        "Apple notarized",
        "stapled",
        "Gatekeeper accepted",
    ):
        assert phrase in beta1_provenance

    _assert_completion_action(studio_sections["Desktop batch"])
    _assert_completion_action(beta_guide_workflow)


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


def test_candidate_validator_rejects_candidate_has_been_published() -> None:
    notes = NOTES.read_text().replace(
        "It is not yet published.",
        "The candidate has been published.",
    )

    with pytest.raises(AssertionError, match="candidate must not claim publication"):
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


def test_candidate_validator_rejects_duplicate_required_heading() -> None:
    notes = NOTES.read_text().replace(
        "## Privacy",
        "## Desktop batch, after the default single-document flow\n\n"
        "The candidate is signed.\n\n## Privacy",
    )

    with pytest.raises(AssertionError, match="required heading.*exactly once"):
        _validate_candidate_documentation(
            notes=notes,
            studio=STUDIO.read_text(),
            beta_guide=BETA_GUIDE.read_text(),
        )


def test_candidate_validator_rejects_reordered_required_headings() -> None:
    notes = (
        NOTES.read_text()
        .replace("## Privacy", "## Temporary Privacy")
        .replace("## Current limitations", "## Privacy")
        .replace("## Temporary Privacy", "## Current limitations")
    )

    with pytest.raises(AssertionError, match="required headings are out of order"):
        _validate_candidate_documentation(
            notes=notes,
            studio=STUDIO.read_text(),
            beta_guide=BETA_GUIDE.read_text(),
        )


def test_candidate_validator_allows_explicitly_scoped_beta1_signing_history() -> None:
    beta_guide = BETA_GUIDE.read_text().replace(
        "Release provenance:",
        "The published Beta 1 build was separately verified. It is signed. "
        "Release provenance:",
    )

    _validate_candidate_documentation(
        notes=NOTES.read_text(),
        studio=STUDIO.read_text(),
        beta_guide=beta_guide,
    )


def test_candidate_validator_allows_harmless_workflow_editorial_rewrite() -> None:
    notes = NOTES.read_text().replace(
        "LocalOCR Studio still opens with one document at a time.",
        "The default LocalOCR Studio flow remains one document at a time.",
    )

    _validate_candidate_documentation(
        notes=notes,
        studio=STUDIO.read_text(),
        beta_guide=BETA_GUIDE.read_text(),
    )


def test_candidate_validator_checks_claim_below_nested_heading() -> None:
    notes = NOTES.read_text().replace(
        "## Privacy",
        "### Candidate verification\n\n"
        "This candidate was signed.\n\n"
        "## Privacy",
    )

    with pytest.raises(AssertionError, match="candidate must not claim signing"):
        _validate_candidate_documentation(
            notes=notes,
            studio=STUDIO.read_text(),
            beta_guide=BETA_GUIDE.read_text(),
        )


@pytest.mark.parametrize(
    ("replacement", "expected_message"),
    (
        ("The candidate was published.", "candidate must not claim publication"),
        (
            "`v0.3.0-beta.1` is now published.",
            "candidate must not claim publication",
        ),
        ("This build was signed.", "candidate must not claim signing"),
        ("This candidate had been notarized.", "candidate must not claim notarization"),
    ),
)
def test_candidate_validator_rejects_additional_positive_status_forms(
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


@pytest.mark.parametrize(
    "negative_status",
    (
        "The candidate has not passed acceptance.",
        "This candidate is not Gatekeeper accepted.",
        "This build was not signed.",
    ),
)
def test_candidate_validator_allows_negative_provenance_wording(
    negative_status: str,
) -> None:
    notes = NOTES.read_text().replace(
        "## Privacy",
        f"{negative_status}\n\n## Privacy",
    )

    _validate_candidate_documentation(
        notes=notes,
        studio=STUDIO.read_text(),
        beta_guide=BETA_GUIDE.read_text(),
    )
