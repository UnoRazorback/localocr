#!/usr/bin/env python3
"""Compare normalized Python and Swift LocalOCR engine contract fixtures."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).parents[1]
DEFAULT_PYTHON_DIR = ROOT / "tests" / "contract" / "expected"
DEFAULT_SWIFT_DIR = ROOT / ".build" / "engine-contracts" / "swift"
DEFAULT_REPORT = ROOT / ".build" / "engine-contract-comparison.json"
PRINTED_TEXT_SIMILARITY_THRESHOLD = 0.95
OCR_FIXTURES = ("ocr_existing_text", "ocr_image_only")


class ContractMismatch(AssertionError):
    """The Swift result does not satisfy the Python behavioral contract."""


def normalized_levenshtein_similarity(first: str, second: str) -> float:
    """Return 1 - edit_distance / max_length, with two empty strings equal."""
    if first == second:
        return 1.0
    denominator = max(len(first), len(second))
    if denominator == 0:
        return 1.0

    previous = list(range(len(second) + 1))
    for first_index, first_character in enumerate(first, start=1):
        current = [first_index]
        for second_index, second_character in enumerate(second, start=1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[second_index] + 1,
                    previous[second_index - 1]
                    + (first_character != second_character),
                )
            )
        previous = current
    return 1.0 - previous[-1] / denominator


def _load_contract(directory: Path, name: str) -> dict[str, Any]:
    path = directory / f"{name}.json"
    try:
        value = json.loads(path.read_text())
    except FileNotFoundError as error:
        raise ContractMismatch(f"missing contract fixture: {path}") from error
    if not isinstance(value, dict):
        raise ContractMismatch(f"{path} must contain a JSON object")
    return value


def _expect_equal(label: str, python_value: Any, swift_value: Any) -> None:
    if python_value != swift_value:
        raise ContractMismatch(
            f"{label} mismatch: Python={python_value!r}, Swift={swift_value!r}"
        )


def _expect_same_keys(label: str, python_value: dict, swift_value: dict) -> None:
    _expect_equal(
        f"{label} fields",
        sorted(python_value),
        sorted(swift_value),
    )


def _expect_integer(label: str, value: Any) -> None:
    if type(value) is not int:
        raise ContractMismatch(
            f"{label} structure mismatch: expected integer, "
            f"got {type(value).__name__}"
        )


def _expect_integer_list(label: str, value: Any) -> None:
    if not isinstance(value, list):
        raise ContractMismatch(f"{label} structure mismatch: expected array")
    for index, item in enumerate(value):
        _expect_integer(f"{label}[{index}]", item)


def _expect_number(label: str, value: Any) -> None:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise ContractMismatch(
            f"{label} structure mismatch: expected number, "
            f"got {type(value).__name__}"
        )


def _validate_inspection_contract(label: str, value: dict[str, Any]) -> None:
    for field in ("source_path", "source_sha256"):
        if not isinstance(value.get(field), str):
            raise ContractMismatch(
                f"{label}.{field} structure mismatch: expected string"
            )
    for field in ("pages", "characters"):
        _expect_integer(f"{label}.{field}", value.get(field))
    for field in ("searchable_pages", "ocr_needed_pages"):
        _expect_integer_list(f"{label}.{field}", value.get(field))
    if type(value.get("fully_searchable")) is not bool:
        raise ContractMismatch(
            f"{label}.fully_searchable structure mismatch: expected boolean"
        )
    page_details = value.get("page_details")
    if not isinstance(page_details, list):
        raise ContractMismatch(
            f"{label}.page_details structure mismatch: expected array"
        )
    for index, detail in enumerate(page_details):
        if not isinstance(detail, dict):
            raise ContractMismatch(
                f"{label}.page_details[{index}] structure mismatch: "
                "expected object"
            )
        _expect_same_keys(
            f"{label}.page_details[{index}]",
            {"page": None, "characters": None, "searchable": None},
            detail,
        )
        _expect_integer(f"{label}.page_details[{index}].page", detail["page"])
        _expect_integer(
            f"{label}.page_details[{index}].characters",
            detail["characters"],
        )
        if type(detail["searchable"]) is not bool:
            raise ContractMismatch(
                f"{label}.page_details[{index}].searchable structure "
                "mismatch: expected boolean"
            )


def _mean_confidence(page: dict[str, Any]) -> float | None:
    confidences = [
        line["confidence"]
        for line in page["lines"]
        if isinstance(line.get("confidence"), (int, float))
    ]
    return sum(confidences) / len(confidences) if confidences else None


def _check_line_structure(
    fixture: str,
    page_number: int,
    python_lines: list[dict[str, Any]],
    swift_lines: list[dict[str, Any]],
) -> None:
    _expect_equal(
        f"page {page_number} line count",
        len(python_lines),
        len(swift_lines),
    )
    for line_index, (python_line, swift_line) in enumerate(
        zip(python_lines, swift_lines), start=1
    ):
        for implementation, line in (
            ("Python", python_line),
            ("Swift", swift_line),
        ):
            label = (
                f"{fixture} {implementation} page {page_number} "
                f"line {line_index}"
            )
            if not isinstance(line, dict):
                raise ContractMismatch(
                    f"{label} structure mismatch: expected object"
                )
            _expect_same_keys(
                label,
                {
                    "text": None,
                    "confidence": None,
                    "bounding_box": None,
                },
                line,
            )
            if not isinstance(line["text"], str):
                raise ContractMismatch(
                    f"{label}.text structure mismatch: expected string"
                )
            _expect_number(f"{label}.confidence", line["confidence"])
            bounding_box = line["bounding_box"]
            if not isinstance(bounding_box, dict):
                raise ContractMismatch(
                    f"{label}.bounding_box structure mismatch: expected object"
                )
            _expect_same_keys(
                f"{label}.bounding_box",
                {"x": None, "y": None, "width": None, "height": None},
                bounding_box,
            )
            for coordinate in ("x", "y", "width", "height"):
                _expect_number(
                    f"{label}.bounding_box.{coordinate}",
                    bounding_box[coordinate],
                )


def _validate_ocr_contract(label: str, value: dict[str, Any]) -> None:
    for field in ("source_path", "source_sha256"):
        if not isinstance(value.get(field), str):
            raise ContractMismatch(
                f"{label}.{field} structure mismatch: expected string"
            )
    for field in ("failed_pages", "empty_ocr_pages"):
        _expect_integer_list(f"{label}.{field}", value.get(field))
    pages = value.get("pages")
    if not isinstance(pages, list):
        raise ContractMismatch(f"{label}.pages structure mismatch: expected array")
    for index, page in enumerate(pages):
        if not isinstance(page, dict):
            raise ContractMismatch(
                f"{label}.pages[{index}] structure mismatch: expected object"
            )
        _expect_same_keys(
            f"{label}.pages[{index}]",
            {
                "page": None,
                "text": None,
                "method": None,
                "lines": None,
                "orientation": None,
            },
            page,
        )
        _expect_integer(f"{label}.pages[{index}].page", page["page"])
        _expect_integer(
            f"{label}.pages[{index}].orientation",
            page["orientation"],
        )
        for field in ("text", "method"):
            if not isinstance(page[field], str):
                raise ContractMismatch(
                    f"{label}.pages[{index}].{field} structure mismatch: "
                    "expected string"
                )
        if not isinstance(page["lines"], list):
            raise ContractMismatch(
                f"{label}.pages[{index}].lines structure mismatch: "
                "expected array"
            )
    rotated_pages = value.get("rotated_ocr_pages")
    if not isinstance(rotated_pages, dict):
        raise ContractMismatch(
            f"{label}.rotated_ocr_pages structure mismatch: expected object"
        )
    for page, orientation in rotated_pages.items():
        if not isinstance(page, str) or not page.isdigit():
            raise ContractMismatch(
                f"{label}.rotated_ocr_pages key structure mismatch: "
                "expected integer string"
            )
        _expect_integer(
            f"{label}.rotated_ocr_pages[{page}]",
            orientation,
        )


def _compare_ocr_fixture(
    fixture: str,
    python_ocr: dict[str, Any],
    swift_ocr: dict[str, Any],
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    _expect_same_keys(fixture, python_ocr, swift_ocr)
    _validate_ocr_contract(f"{fixture} Python", python_ocr)
    _validate_ocr_contract(f"{fixture} Swift", swift_ocr)
    for field in (
        "source_path",
        "source_sha256",
        "failed_pages",
        "empty_ocr_pages",
    ):
        _expect_equal(
            f"{fixture}.{field}",
            python_ocr[field],
            swift_ocr[field],
        )

    python_pages = python_ocr["pages"]
    swift_pages = swift_ocr["pages"]
    _expect_equal(
        f"{fixture} page count",
        len(python_pages),
        len(swift_pages),
    )

    recognition = []
    for python_page, swift_page in zip(python_pages, swift_pages):
        page_number = python_page["page"]
        _expect_same_keys(
            f"{fixture} page {page_number}",
            python_page,
            swift_page,
        )
        _expect_equal(
            f"{fixture} page {page_number} number",
            page_number,
            swift_page["page"],
        )
        _expect_equal(
            f"{fixture} page {page_number} method",
            python_page["method"],
            swift_page["method"],
        )
        _check_line_structure(
            fixture,
            page_number,
            python_page["lines"],
            swift_page["lines"],
        )

        similarity = normalized_levenshtein_similarity(
            python_page["text"],
            swift_page["text"],
        )
        if similarity < PRINTED_TEXT_SIMILARITY_THRESHOLD:
            raise ContractMismatch(
                f"{fixture} page {page_number} printed-text similarity "
                f"{similarity:.4f} is below "
                f"{PRINTED_TEXT_SIMILARITY_THRESHOLD:.2f}"
            )
        recognition.append(
            {
                "fixture": fixture,
                "page": page_number,
                "method": python_page["method"],
                "text_similarity": similarity,
                "python_confidence": _mean_confidence(python_page),
                "swift_confidence": _mean_confidence(swift_page),
                "python_orientation": python_page["orientation"],
                "swift_orientation": swift_page["orientation"],
            }
        )

    return recognition, {
        "python_rotated_ocr_pages": python_ocr["rotated_ocr_pages"],
        "swift_rotated_ocr_pages": swift_ocr["rotated_ocr_pages"],
    }


def compare_engine_contracts(
    python_directory: Path,
    swift_directory: Path,
) -> dict[str, Any]:
    """Compare contract directories or raise ContractMismatch."""
    python_inspection = _load_contract(python_directory, "inspect_mixed")
    swift_inspection = _load_contract(swift_directory, "inspect_mixed")
    _validate_inspection_contract("inspect_mixed Python", python_inspection)
    _validate_inspection_contract("inspect_mixed Swift", swift_inspection)
    _expect_equal("inspect_mixed", python_inspection, swift_inspection)

    recognition = []
    orientations_by_fixture = {}
    for fixture in OCR_FIXTURES:
        fixture_recognition, fixture_orientations = _compare_ocr_fixture(
            fixture,
            _load_contract(python_directory, fixture),
            _load_contract(swift_directory, fixture),
        )
        recognition.extend(fixture_recognition)
        orientations_by_fixture[fixture] = fixture_orientations
    return {
        "structural_contract_match": True,
        "printed_text_similarity_threshold": PRINTED_TEXT_SIMILARITY_THRESHOLD,
        "recognition": recognition,
        "orientation_differences": orientations_by_fixture[
            "ocr_existing_text"
        ],
        "orientation_differences_by_fixture": orientations_by_fixture,
    }


def _format_optional_confidence(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.4f}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python-dir", type=Path, default=DEFAULT_PYTHON_DIR)
    parser.add_argument("--swift-dir", type=Path, default=DEFAULT_SWIFT_DIR)
    parser.add_argument("--output", type=Path, default=DEFAULT_REPORT)
    arguments = parser.parse_args()

    try:
        report = compare_engine_contracts(
            arguments.python_dir,
            arguments.swift_dir,
        )
    except ContractMismatch as error:
        print(f"Engine contract comparison: FAIL — {error}", file=sys.stderr)
        return 1

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n"
    )
    print("Structural contract: PASS")
    for result in report["recognition"]:
        print(
            f"{result['fixture']} page {result['page']}: text similarity "
            f"{result['text_similarity']:.4f} "
            f"(required >= {PRINTED_TEXT_SIMILARITY_THRESHOLD:.2f}); "
            f"confidence Python={_format_optional_confidence(result['python_confidence'])}, "
            f"Swift={_format_optional_confidence(result['swift_confidence'])}; "
            f"orientation Python={result['python_orientation']}, "
            f"Swift={result['swift_orientation']}"
        )
    print(f"Comparison report: {arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
