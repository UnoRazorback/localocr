#!/usr/bin/env python3
"""Generate stable Swift-facing contract fixtures from the Python reference engine."""

import importlib.util
import json
import tempfile
from pathlib import Path

from ocr_service import core, pdf_utils


ROOT = Path(__file__).parents[1]


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


def _write_json(path: Path, result: dict) -> None:
    path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")


def generate_contract_fixtures(output_dir: Path) -> dict:
    """Generate deterministic inspection and native-text OCR fixtures."""
    output_dir.mkdir(parents=True, exist_ok=True)
    mixed_pdf, native_text_pdf = _fixture_builders()

    with tempfile.TemporaryDirectory() as temporary_directory:
        temporary_path = Path(temporary_directory)
        mixed_path, _ = mixed_pdf(temporary_path)
        native_path, _ = native_text_pdf(temporary_path)
        fixtures = {
            "inspect_mixed": _inspection_contract(pdf_utils.inspect_pdf(mixed_path)),
            "ocr_existing_text": normalize(core.ocr_pdf_pages(native_path, None, dpi=250, include_lines=True)),
        }

    for name, result in fixtures.items():
        _write_json(output_dir / f"{name}.json", result)
    return fixtures


if __name__ == "__main__":
    generate_contract_fixtures(ROOT / "tests" / "contract" / "expected")
