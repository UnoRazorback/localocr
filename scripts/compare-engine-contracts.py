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


def _expect_same_structure(
    label: str,
    python_value: Any,
    swift_value: Any,
) -> None:
    if isinstance(python_value, dict):
        if not isinstance(swift_value, dict):
            raise ContractMismatch(
                f"{label} structure mismatch: Python object, "
                f"Swift {type(swift_value).__name__}"
            )
        _expect_same_keys(label, python_value, swift_value)
        for key in python_value:
            _expect_same_structure(
                f"{label}.{key}",
                python_value[key],
                swift_value[key],
            )
        return
    if isinstance(python_value, list):
        if not isinstance(swift_value, list):
            raise ContractMismatch(
                f"{label} structure mismatch: Python array, "
                f"Swift {type(swift_value).__name__}"
            )
        _expect_equal(f"{label} array length", len(python_value), len(swift_value))
        for index, (python_item, swift_item) in enumerate(
            zip(python_value, swift_value)
        ):
            _expect_same_structure(
                f"{label}[{index}]",
                python_item,
                swift_item,
            )
        return

    python_is_number = (
        isinstance(python_value, (int, float))
        and not isinstance(python_value, bool)
    )
    swift_is_number = (
        isinstance(swift_value, (int, float))
        and not isinstance(swift_value, bool)
    )
    if python_is_number and swift_is_number:
        return
    if type(python_value) is not type(swift_value):
        raise ContractMismatch(
            f"{label} structure mismatch: Python {type(python_value).__name__}, "
            f"Swift {type(swift_value).__name__}"
        )


def _mean_confidence(page: dict[str, Any]) -> float | None:
    confidences = [
        line["confidence"]
        for line in page["lines"]
        if isinstance(line.get("confidence"), (int, float))
    ]
    return sum(confidences) / len(confidences) if confidences else None


def _check_line_structure(
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
        _expect_same_keys(
            f"page {page_number} line {line_index}",
            python_line,
            swift_line,
        )
        _expect_same_keys(
            f"page {page_number} line {line_index} bounding_box",
            python_line["bounding_box"],
            swift_line["bounding_box"],
        )


def compare_engine_contracts(
    python_directory: Path,
    swift_directory: Path,
) -> dict[str, Any]:
    """Compare contract directories or raise ContractMismatch."""
    python_inspection = _load_contract(python_directory, "inspect_mixed")
    swift_inspection = _load_contract(swift_directory, "inspect_mixed")
    _expect_equal("inspect_mixed", python_inspection, swift_inspection)

    python_ocr = _load_contract(python_directory, "ocr_existing_text")
    swift_ocr = _load_contract(swift_directory, "ocr_existing_text")
    _expect_same_keys("ocr_existing_text", python_ocr, swift_ocr)
    for field in (
        "source_path",
        "source_sha256",
        "failed_pages",
        "empty_ocr_pages",
    ):
        _expect_equal(field, python_ocr[field], swift_ocr[field])

    python_pages = python_ocr["pages"]
    swift_pages = swift_ocr["pages"]
    _expect_same_structure("ocr_existing_text.pages", python_pages, swift_pages)
    for label, rotated_pages in (
        ("Python rotated_ocr_pages", python_ocr["rotated_ocr_pages"]),
        ("Swift rotated_ocr_pages", swift_ocr["rotated_ocr_pages"]),
    ):
        if not isinstance(rotated_pages, dict) or not all(
            isinstance(page, str)
            and isinstance(orientation, int)
            and not isinstance(orientation, bool)
            for page, orientation in rotated_pages.items()
        ):
            raise ContractMismatch(
                f"{label} structure mismatch: expected string-to-integer object"
            )

    recognition = []
    for python_page, swift_page in zip(python_pages, swift_pages):
        page_number = python_page["page"]
        _expect_same_keys(f"page {page_number}", python_page, swift_page)
        _expect_equal(f"page {page_number} number", page_number, swift_page["page"])
        _expect_equal(
            f"page {page_number} method",
            python_page["method"],
            swift_page["method"],
        )
        _check_line_structure(
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
                f"page {page_number} printed-text similarity {similarity:.4f} "
                f"is below {PRINTED_TEXT_SIMILARITY_THRESHOLD:.2f}"
            )
        recognition.append(
            {
                "page": page_number,
                "method": python_page["method"],
                "text_similarity": similarity,
                "python_confidence": _mean_confidence(python_page),
                "swift_confidence": _mean_confidence(swift_page),
                "python_orientation": python_page["orientation"],
                "swift_orientation": swift_page["orientation"],
            }
        )

    orientation_differences = {
        "python_rotated_ocr_pages": python_ocr["rotated_ocr_pages"],
        "swift_rotated_ocr_pages": swift_ocr["rotated_ocr_pages"],
    }
    return {
        "structural_contract_match": True,
        "printed_text_similarity_threshold": PRINTED_TEXT_SIMILARITY_THRESHOLD,
        "recognition": recognition,
        "orientation_differences": orientation_differences,
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
            f"Page {result['page']}: text similarity "
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
