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


def test_contract_fixture_generator_is_deterministic(contract_fixture_dir):
    generate_contract_fixtures = _load_generator()

    first = generate_contract_fixtures(contract_fixture_dir)
    second = generate_contract_fixtures(contract_fixture_dir)

    assert first == second
    assert first["inspect_mixed"]["ocr_needed_pages"] == [2]
    assert first["ocr_existing_text"]["pages"][0]["method"] == "existing_text"
    assert json.loads((contract_fixture_dir / "inspect_mixed.json").read_text()) == first["inspect_mixed"]
    assert json.loads((contract_fixture_dir / "ocr_existing_text.json").read_text()) == first["ocr_existing_text"]
