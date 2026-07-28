"""OCR via Apple's Vision framework (VNRecognizeTextRequest)."""

from dataclasses import dataclass

import Vision
from Foundation import NSData


@dataclass
class TextLine:
    text: str
    confidence: float
    # Normalized Vision bounding box: origin bottom-left, values in [0, 1],
    # relative to image width/height.
    x: float
    y: float
    width: float
    height: float


@dataclass
class OcrResult:
    lines: list[TextLine]
    orientation: str  # "up", "right", "left", or "down" — the orientation Vision was told to assume


# (name, CGImagePropertyOrientation) — checked in this order when the upright pass scores low
_ROTATION_ORIENTATIONS = [
    ("up", Vision.kCGImagePropertyOrientationUp),
    ("right", Vision.kCGImagePropertyOrientationRight),
    ("left", Vision.kCGImagePropertyOrientationLeft),
    ("down", Vision.kCGImagePropertyOrientationDown),
]

# Below this (chars * confidence, summed) a page reads as "mostly garbage" — worth
# retrying at other orientations in case the source was scanned sideways.
_LOW_SCORE_THRESHOLD = 120.0


def _run_request(image_bytes: bytes, orientation: int) -> list:
    ns_data = NSData.dataWithBytes_length_(image_bytes, len(image_bytes))
    handler = Vision.VNImageRequestHandler.alloc().initWithData_orientation_options_(
        ns_data, orientation, None
    )

    request = Vision.VNRecognizeTextRequest.alloc().init()
    request.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelAccurate)
    request.setUsesLanguageCorrection_(True)

    success, error = handler.performRequests_error_([request], None)
    if not success:
        raise RuntimeError(f"Vision text recognition failed: {error}")

    return request.results() or []


def _to_lines(observations: list) -> list[TextLine]:
    lines = []
    for observation in observations:
        candidates = observation.topCandidates_(1)
        if not candidates:
            continue
        top = candidates[0]
        box = observation.boundingBox()
        lines.append(
            TextLine(
                text=str(top.string()),
                confidence=float(top.confidence()),
                x=float(box.origin.x),
                y=float(box.origin.y),
                width=float(box.size.width),
                height=float(box.size.height),
            )
        )
    return lines


def _score(lines: list[TextLine]) -> float:
    return sum(len(line.text) * line.confidence for line in lines)


def ocr_image_lines(image_bytes: bytes) -> list[TextLine]:
    """OCR raw image bytes assuming upright orientation, returning one TextLine per recognized line.

    No rotation retry — used where recovered text must stay in the original
    image's coordinate space (e.g. positioning an invisible PDF text layer).
    """
    return _to_lines(_run_request(image_bytes, Vision.kCGImagePropertyOrientationUp))


def ocr_image_lines_best_orientation(image_bytes: bytes, try_rotations: bool = True) -> OcrResult:
    """OCR raw image bytes, retrying at rotated orientations if the upright pass scores low.

    Useful for scanned pages that went through the scanner sideways. Not used
    for make_searchable_pdf, since a non-"up" result's bounding boxes are in a
    rotated coordinate space relative to the original page.
    """
    lines = ocr_image_lines(image_bytes)
    orientation = "up"
    if try_rotations and _score(lines) < _LOW_SCORE_THRESHOLD:
        best_score = _score(lines)
        for name, cg_orientation in _ROTATION_ORIENTATIONS[1:]:
            candidate = _to_lines(_run_request(image_bytes, cg_orientation))
            candidate_score = _score(candidate)
            if candidate_score > best_score:
                lines, orientation, best_score = candidate, name, candidate_score
    return OcrResult(lines=lines, orientation=orientation)


def ocr_image_text(image_bytes: bytes, try_rotations: bool = True) -> str:
    """OCR raw image bytes and return plain joined text (one line per recognized line)."""
    result = ocr_image_lines_best_orientation(image_bytes, try_rotations=try_rotations)
    return "\n".join(line.text for line in result.lines)
