"""Unit-level test for the orientation-retry decision logic itself.

Real Vision text detection turns out to already be fairly rotation-robust
(see test_core.test_sideways_pdf_recovers_text for the real-world case), so
that integration test alone doesn't prove ocr_image_lines_best_orientation's
selection logic is correct — it could pass even if the retry loop were
broken, as long as the "up" pass happens to work. This test fakes _run_request
so each orientation has a controlled, known score, and checks the function
actually picks the best one.
"""

from ocr_service import vision_ocr


def _line(text: str, confidence: float) -> vision_ocr.TextLine:
    return vision_ocr.TextLine(text=text, confidence=confidence, x=0.1, y=0.1, width=0.5, height=0.1)


def test_best_orientation_picks_highest_scoring_rotation(monkeypatch):
    # "up" scores low (simulating garbage from a sideways scan); "left" scores
    # highest and should win.
    fake_results = {
        vision_ocr.Vision.kCGImagePropertyOrientationUp: [_line("x", 0.1)],
        vision_ocr.Vision.kCGImagePropertyOrientationRight: [_line("y", 0.2)],
        vision_ocr.Vision.kCGImagePropertyOrientationLeft: [_line("correct text here", 0.99)],
        vision_ocr.Vision.kCGImagePropertyOrientationDown: [_line("z", 0.1)],
    }

    def fake_run_request(image_bytes, orientation):
        return fake_results[orientation]

    # _run_request normally returns raw Vision observations that _to_lines then
    # converts to TextLine objects; here the fakes already *are* TextLine
    # objects, so _to_lines is patched to a passthrough.
    monkeypatch.setattr(vision_ocr, "_run_request", fake_run_request)
    monkeypatch.setattr(vision_ocr, "_to_lines", lambda observations: observations)

    result = vision_ocr.ocr_image_lines_best_orientation(b"fake-bytes")

    assert result.orientation == "left"
    assert result.lines[0].text == "correct text here"


def test_best_orientation_keeps_up_when_it_already_scores_highest(monkeypatch):
    fake_results = {
        vision_ocr.Vision.kCGImagePropertyOrientationUp: [_line("already correct and long enough", 0.95)],
        vision_ocr.Vision.kCGImagePropertyOrientationRight: [_line("x", 0.1)],
        vision_ocr.Vision.kCGImagePropertyOrientationLeft: [_line("y", 0.1)],
        vision_ocr.Vision.kCGImagePropertyOrientationDown: [_line("z", 0.1)],
    }

    def fake_run_request(image_bytes, orientation):
        return fake_results[orientation]

    # _run_request normally returns raw Vision observations that _to_lines then
    # converts to TextLine objects; here the fakes already *are* TextLine
    # objects, so _to_lines is patched to a passthrough.
    monkeypatch.setattr(vision_ocr, "_run_request", fake_run_request)
    monkeypatch.setattr(vision_ocr, "_to_lines", lambda observations: observations)

    result = vision_ocr.ocr_image_lines_best_orientation(b"fake-bytes")

    assert result.orientation == "up"
    assert result.lines[0].text == "already correct and long enough"


def test_try_rotations_false_never_retries(monkeypatch):
    calls = []

    def fake_run_request(image_bytes, orientation):
        calls.append(orientation)
        return [_line("x", 0.1)]  # deliberately low score

    monkeypatch.setattr(vision_ocr, "_run_request", fake_run_request)
    monkeypatch.setattr(vision_ocr, "_to_lines", lambda observations: observations)

    vision_ocr.ocr_image_lines_best_orientation(b"fake-bytes", try_rotations=False)

    assert calls == [vision_ocr.Vision.kCGImagePropertyOrientationUp]
