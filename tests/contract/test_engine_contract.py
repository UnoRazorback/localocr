"""Regression tests that freeze the Python engine's Swift-facing contract."""

import importlib.util
import json
from pathlib import Path

import pytest


@pytest.fixture
def contract_fixture_dir() -> Path:
    return Path(__file__).parent / "expected"


def _load_generator():
    script_path = Path(__file__).parents[2] / "scripts" / "generate-contract-fixtures.py"
    spec = importlib.util.spec_from_file_location("contract_fixture_generator", script_path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.generate_contract_fixtures


def test_contract_fixture_generator_matches_committed_contract(tmp_path, contract_fixture_dir):
    generate_contract_fixtures = _load_generator()

    first = generate_contract_fixtures(tmp_path)
    second = generate_contract_fixtures(tmp_path)
    committed = {
        name: json.loads((contract_fixture_dir / f"{name}.json").read_text())
        for name in ("inspect_mixed", "ocr_existing_text", "ocr_image_only")
    }

    assert first == second
    assert first == committed
    assert first["inspect_mixed"]["ocr_needed_pages"] == [2]
    assert first["ocr_existing_text"]["pages"][0]["method"] == "existing_text"
    assert first["ocr_image_only"]["pages"][0]["method"] == "vision_ocr"
    assert first["ocr_image_only"]["pages"][0]["lines"][0]["confidence"] > 0
