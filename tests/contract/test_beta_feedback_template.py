from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FORM = ROOT / ".github/ISSUE_TEMPLATE/beta-feedback.yml"


def test_feedback_form_collects_required_beta_context():
    text = FORM.read_text()
    for field_id in (
        "surface",
        "version",
        "mac_model",
        "macos_build",
        "input_profile",
        "expected",
        "actual",
        "reproduction",
        "frequency",
        "category",
        "severity",
        "privacy_confirmation",
    ):
        assert f"id: {field_id}" in text
    assert "v0.3.0-beta.1" in text
    assert "Do not attach the source document or recognized text" in text
    assert "required: true" in text


def test_feedback_form_does_not_request_document_content():
    text = FORM.read_text().lower()
    assert "upload your document" not in text
    assert "paste recognized text" not in text
