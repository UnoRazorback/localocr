"""Behavior tests for the Python-versus-Swift contract comparator."""

import importlib.util
import json
from pathlib import Path

import pytest


def _load_comparator():
    script_path = Path(__file__).parents[2] / "scripts" / "compare-engine-contracts.py"
    spec = importlib.util.spec_from_file_location("engine_contract_comparator", script_path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _write_contracts(root: Path, ocr_contract: dict) -> tuple[Path, Path]:
    python_dir = root / "python"
    swift_dir = root / "swift"
    python_dir.mkdir()
    swift_dir.mkdir()
    inspection = {
        "source_path": "<fixture>",
        "source_sha256": "<sha256>",
        "pages": 1,
        "searchable_pages": [1],
        "ocr_needed_pages": [],
        "characters": 21,
        "fully_searchable": True,
        "page_details": [{"page": 1, "characters": 21, "searchable": True}],
    }
    for directory in (python_dir, swift_dir):
        (directory / "inspect_mixed.json").write_text(json.dumps(inspection))
        (directory / "ocr_existing_text.json").write_text(json.dumps(ocr_contract))
    return python_dir, swift_dir


def _ocr_contract() -> dict:
    return {
        "source_path": "<fixture>",
        "source_sha256": "<sha256>",
        "pages": [
            {
                "page": 1,
                "text": "Synthetic printed contract total is 57508601 dollars.",
                "method": "existing_text",
                "lines": [],
                "orientation": 1,
            }
        ],
        "failed_pages": [],
        "empty_ocr_pages": [],
        "rotated_ocr_pages": {},
    }


def test_compare_accepts_matching_structures_and_reports_text_similarity(tmp_path):
    comparator = _load_comparator()
    contract = _ocr_contract()
    python_dir, swift_dir = _write_contracts(tmp_path, contract)
    swift_contract = dict(contract)
    swift_contract["pages"] = [dict(contract["pages"][0], text="Synthetic printed contract total is 57508601 dollar.")]
    (swift_dir / "ocr_existing_text.json").write_text(json.dumps(swift_contract))

    report = comparator.compare_engine_contracts(python_dir, swift_dir)

    assert report["structural_contract_match"] is True
    assert report["recognition"][0]["page"] == 1
    assert report["recognition"][0]["text_similarity"] >= 0.95
    assert report["recognition"][0]["python_orientation"] == 1
    assert report["recognition"][0]["swift_orientation"] == 1


def test_compare_reports_orientation_differences_without_rejecting_contract(tmp_path):
    comparator = _load_comparator()
    contract = _ocr_contract()
    python_dir, swift_dir = _write_contracts(tmp_path, contract)
    swift_contract = dict(contract)
    swift_contract["pages"] = [dict(contract["pages"][0], orientation=3)]
    swift_contract["rotated_ocr_pages"] = {"1": 3}
    (swift_dir / "ocr_existing_text.json").write_text(json.dumps(swift_contract))

    report = comparator.compare_engine_contracts(python_dir, swift_dir)

    assert report["recognition"][0]["python_orientation"] == 1
    assert report["recognition"][0]["swift_orientation"] == 3
    assert report["orientation_differences"] == {
        "python_rotated_ocr_pages": {},
        "swift_rotated_ocr_pages": {"1": 3},
    }


def test_compare_rejects_page_method_mismatch(tmp_path):
    comparator = _load_comparator()
    contract = _ocr_contract()
    python_dir, swift_dir = _write_contracts(tmp_path, contract)
    swift_contract = dict(contract)
    swift_contract["pages"] = [dict(contract["pages"][0], method="vision_ocr")]
    (swift_dir / "ocr_existing_text.json").write_text(json.dumps(swift_contract))

    with pytest.raises(comparator.ContractMismatch, match="method"):
        comparator.compare_engine_contracts(python_dir, swift_dir)


def test_compare_rejects_wrong_field_type_even_when_keys_match(tmp_path):
    comparator = _load_comparator()
    contract = _ocr_contract()
    python_dir, swift_dir = _write_contracts(tmp_path, contract)
    swift_contract = dict(contract)
    swift_contract["pages"] = [dict(contract["pages"][0], orientation="up")]
    (swift_dir / "ocr_existing_text.json").write_text(json.dumps(swift_contract))

    with pytest.raises(comparator.ContractMismatch, match="structure"):
        comparator.compare_engine_contracts(python_dir, swift_dir)


def test_compare_rejects_printed_text_below_similarity_threshold(tmp_path):
    comparator = _load_comparator()
    contract = _ocr_contract()
    python_dir, swift_dir = _write_contracts(tmp_path, contract)
    swift_contract = dict(contract)
    swift_contract["pages"] = [dict(contract["pages"][0], text="unrelated")]
    (swift_dir / "ocr_existing_text.json").write_text(json.dumps(swift_contract))

    with pytest.raises(comparator.ContractMismatch, match="similarity"):
        comparator.compare_engine_contracts(python_dir, swift_dir)
