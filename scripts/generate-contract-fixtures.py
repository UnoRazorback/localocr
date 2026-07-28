#!/usr/bin/env python3
"""Generate stable Swift-facing contract fixtures from the Python reference engine."""

import importlib.util
import json
import tempfile
from pathlib import Path

from ocr_service import core, pdf_utils


ROOT = Path(__file__).parents[1]
SHARED_IMAGE_ONLY_FIXTURE = (
    ROOT / "tests" / "LocalOCRCoreTests" / "Fixtures" / "image-only.pdf"
)
ORIENTATION_RAW_VALUES = {"up": 1, "up_mirrored": 2, "down": 3, "down_mirrored": 4, "left_mirrored": 5, "right": 6, "right_mirrored": 7, "left": 8}


def normalize(result: dict) -> dict:
    """Replace machine-specific source metadata with stable fixture values."""
    result = dict(result)
    result["source_path"] = "<fixture>"
    result["source_sha256"] = "<sha256>"
    return result


def _fixture_builders():
    spec = importlib.util.spec_from_file_location("contract_fixture_builders", ROOT / "tests" / "conftest.py")
    if spec is None or spec.loader is None:
        raise RuntimeError("Could not load synthetic PDF fixture builders")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.mixed_pdf.__wrapped__, module.native_text_pdf.__wrapped__


def _inspection_contract(result: dict) -> dict:
    """Express Python's inspection counts as the page lists used by LocalOCRCore."""
    result = normalize(result)
    details = result["page_details"]
    result["searchable_pages"] = [detail["page"] for detail in details if detail["searchable"]]
    result["ocr_needed_pages"] = [detail["page"] for detail in details if not detail["searchable"]]
    return result


def _ocr_result_contract(result: dict) -> dict:
    """Convert Python OCR output into the public Swift OCRResult wire shape."""
    result = normalize(result)
    rotated_pages = {
        str(entry["page"]): ORIENTATION_RAW_VALUES[entry["orientation"]] for entry in result["rotated_ocr_pages"]
    }
    pages = []
    for page in result["pages"]:
        lines = [
            {
                "text": line["text"],
                "confidence": line["confidence"],
                "bounding_box": {
                    "x": line["x"],
                    "y": line["y"],
                    "width": line["width"],
                    "height": line["height"],
                },
            }
            for line in page["lines"]
        ]
        pages.append(
            {
                "page": page["page"],
                "text": page["text"],
                "method": page["method"],
                "lines": lines,
                "orientation": ORIENTATION_RAW_VALUES[page.get("orientation", "up")],
            }
        )

    return {
        "source_path": result["source_path"],
        "source_sha256": result["source_sha256"],
        "pages": pages,
        "failed_pages": result["failed_pages"],
        "empty_ocr_pages": result["empty_ocr_pages"],
        "rotated_ocr_pages": rotated_pages,
    }


def _write_json(path: Path, result: dict) -> None:
    path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")


def generate_contract_fixtures(output_dir: Path) -> dict:
    """Generate deterministic inspection, native-text, and Vision OCR fixtures."""
    output_dir.mkdir(parents=True, exist_ok=True)
    mixed_pdf, native_text_pdf = _fixture_builders()

    with tempfile.TemporaryDirectory() as temporary_directory:
        temporary_path = Path(temporary_directory)
        mixed_path, _ = mixed_pdf(temporary_path)
        native_path, _ = native_text_pdf(temporary_path)
        fixtures = {
            "inspect_mixed": _inspection_contract(pdf_utils.inspect_pdf(mixed_path)),
            "ocr_existing_text": _ocr_result_contract(core.ocr_pdf_pages(native_path, None, dpi=250, include_lines=True)),
            "ocr_image_only": _ocr_result_contract(
                core.ocr_pdf_pages(
                    SHARED_IMAGE_ONLY_FIXTURE,
                    "1",
                    dpi=250,
                    include_lines=True,
                )
            ),
        }

    for name, result in fixtures.items():
        _write_json(output_dir / f"{name}.json", result)
    return fixtures


if __name__ == "__main__":
    generate_contract_fixtures(ROOT / "tests" / "contract" / "expected")
