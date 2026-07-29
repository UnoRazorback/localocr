"""Cross-server MCP compatibility contract for the Python and native servers."""

from __future__ import annotations

import anyio
import json
import os
import re
import shutil
import sys
from pathlib import Path
from typing import Any

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
import pytest


ROOT = Path(__file__).parents[2]
NATIVE = ROOT / ".build" / "debug" / "localocr-mcp"
EXPECTED = Path(__file__).with_name("expected")
FIXTURE_NAMES = ("mixed.pdf", "image-only.pdf")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SCALAR_RESULTS = {"get_pdf_page_count", "ocr_image"}
LINE_GEOMETRY_FIELDS = {"x", "y", "width", "height"}
GEOMETRY_TOLERANCE = 0.005
SNAPSHOT_NAMES = ("inspect_pdf", "ocr_pdf", "ocr_pdf_lines", "ocr_pdf_batch", "make_searchable_pdf")


def _copy_fixtures(destination: Path) -> dict[str, Path]:
    source = ROOT / "tests" / "LocalOCRCoreTests" / "Fixtures"
    destination.mkdir()
    copied = {}
    for name in FIXTURE_NAMES:
        target = destination / name
        shutil.copy2(source / name, target)
        copied[name] = target
    return copied


def _result_value(result) -> Any:
    assert result.isError is not True
    assert len(result.content) == 1
    text = result.content[0].text
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


def _structured_content(result) -> Any:
    value = result.structuredContent
    if hasattr(value, "model_dump"):
        return value.model_dump(mode="json", by_alias=True)
    return value


async def _call_server(params: StdioServerParameters, fixtures: dict[str, Path]) -> dict[str, Any]:
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()

            mixed = str(fixtures["mixed.pdf"])
            image_only = str(fixtures["image-only.pdf"])
            missing = str(fixtures["mixed.pdf"].with_name("missing.pdf"))
            calls = {
                "get_pdf_page_count": ("get_pdf_page_count", {"file_path": mixed}),
                "inspect_pdf": ("inspect_pdf", {"file_path": mixed}),
                "ocr_pdf": ("ocr_pdf", {"file_path": mixed}),
                "ocr_pdf_lines": ("ocr_pdf", {"file_path": image_only, "include_lines": True}),
                "ocr_pdf_batch": (
                    "ocr_pdf_batch",
                    {"file_paths": [mixed, missing, image_only]},
                ),
                "ocr_image": ("ocr_image", {"file_path": str(ROOT / "tests" / "LocalOCRServiceTests" / "Fixtures" / "sample.png")}),
                "make_searchable_pdf": ("make_searchable_pdf", {"file_path": image_only}),
            }
            values = {}
            for name, (tool, arguments) in calls.items():
                result = await session.call_tool(tool, arguments)
                values[name] = {
                    "text": _result_value(result),
                    "structured_content": _structured_content(result),
                }
            return {
                "tools": {tool.name: tool.model_dump(mode="json", by_alias=True) for tool in tools.tools},
                "results": values,
            }


def _normalize(value: Any, fixture_root: Path, path: tuple[str | int, ...] = ()) -> Any:
    if isinstance(value, dict):
        return {key: _normalize(item, fixture_root, path + (key,)) for key, item in value.items()}
    if isinstance(value, list):
        return [_normalize(item, fixture_root, path + (index,)) for index, item in enumerate(value)]
    if isinstance(value, float):
        return round(value, 6) if path[-1:] == ("confidence",) and "lines" in path else value
    if isinstance(value, str):
        fixture_directories = (str(fixture_root), str(fixture_root).removeprefix("/private"))
        for directory in fixture_directories:
            if value.startswith(directory):
                return "<output>" if value.endswith("_searchable.pdf") or "_searchable_" in value else value.replace(directory, "<fixture>", 1)
            if directory in value:
                return value.replace(directory, "<fixture>")
        if SHA256.fullmatch(value):
            return "<sha256>"
    return value


def _assert_matching_payloads(python: Any, native: Any, path: tuple[str | int, ...] = ()) -> None:
    if isinstance(python, dict):
        assert isinstance(native, dict), f"{_display_path(path)} type differs: dict != {type(native).__name__}"
        assert set(native) == set(python), f"{_display_path(path)} keys differ: {set(python) ^ set(native)}"
        for key, python_value in python.items():
            native_value = native[key]
            field_path = path + (key,)
            if key in LINE_GEOMETRY_FIELDS and "lines" in path:
                assert isinstance(python_value, (int, float)) and not isinstance(python_value, bool)
                assert isinstance(native_value, (int, float)) and not isinstance(native_value, bool)
                difference = abs(native_value - python_value)
                assert difference <= GEOMETRY_TOLERANCE, (
                    f"{_display_path(field_path)} geometry differs: Python={python_value:.6f}, "
                    f"Swift={native_value:.6f}, difference={difference:.6f}, "
                    f"allowed={GEOMETRY_TOLERANCE:.6f}"
                )
            else:
                _assert_matching_payloads(python_value, native_value, field_path)
        return
    if isinstance(python, list):
        assert isinstance(native, list), f"{_display_path(path)} type differs: list != {type(native).__name__}"
        assert len(native) == len(python), f"{_display_path(path)} length differs: {len(python)} != {len(native)}"
        for index, (python_value, native_value) in enumerate(zip(python, native, strict=True)):
            _assert_matching_payloads(python_value, native_value, path + (index,))
        return
    assert native == python, f"{_display_path(path)} differs: Python={python!r}, Swift={native!r}"


def _display_path(path: tuple[str | int, ...]) -> str:
    return "result" + "".join(f"[{item}]" if isinstance(item, int) else f".{item}" for item in path)


def _tool_input_semantics(tool: dict[str, Any]) -> dict[str, dict[str, Any]]:
    schema = tool["inputSchema"]
    required = set(schema.get("required", []))
    result = {}
    for name, property_schema in schema.get("properties", {}).items():
        alternatives = property_schema.get("anyOf", [property_schema])
        types = sorted({item.get("type") for item in alternatives if item.get("type") != "null"})
        default = property_schema.get("default")
        result[name] = {
            "types": types,
            "required": name in required,
            # FastMCP's optional None default is presentation-only; native omission means the same call default.
            "default": None if not (name in required or default not in (None,)) else default,
        }
    return result


def _assert_matching_tool_schemas(python: dict[str, Any], native: dict[str, Any]) -> None:
    assert set(native) == set(python), f"tool names differ: {set(python) ^ set(native)}"
    for name in python:
        python_parameters = _tool_input_semantics(python[name])
        native_parameters = _tool_input_semantics(native[name])
        assert native_parameters == python_parameters, (
            f"{name} input schema semantics differ:\n"
            f"Python: {json.dumps(python_parameters, sort_keys=True)}\n"
            f"Swift: {json.dumps(native_parameters, sort_keys=True)}"
        )


async def _assert_outputs_reopen_with_native_pdfkit(output_paths: list[str]) -> None:
    async with stdio_client(StdioServerParameters(command=str(NATIVE), args=[])) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            for output_path in output_paths:
                result = await session.call_tool("get_pdf_page_count", {"file_path": output_path})
                assert result.isError is not True, f"native PDFKit could not reopen {output_path}"
                assert int(result.content[0].text) > 0, f"native PDFKit found no pages in {output_path}"


def _load_snapshot(name: str) -> Any:
    return json.loads((EXPECTED / f"{name}.json").read_text())


async def _exercise_compatibility(tmp_path: Path) -> None:
    python_fixtures = _copy_fixtures(tmp_path / "python-fixtures")
    native_fixtures = _copy_fixtures(tmp_path / "native-fixtures")
    python_environment = os.environ.copy()
    source_path = str(ROOT / "src")
    python_environment["PYTHONPATH"] = source_path + os.pathsep + python_environment.get("PYTHONPATH", "")
    assert python_environment["PYTHONPATH"].split(os.pathsep)[0] == source_path
    python = await _call_server(
        StdioServerParameters(command=sys.executable, args=["-m", "ocr_service.server"], env=python_environment),
        python_fixtures,
    )
    native = await _call_server(StdioServerParameters(command=str(NATIVE), args=[]), native_fixtures)

    normalized_python = _normalize(python, python_fixtures["mixed.pdf"].parent)
    normalized_native = _normalize(native, native_fixtures["mixed.pdf"].parent)

    _assert_matching_tool_schemas(normalized_python["tools"], normalized_native["tools"])
    await _assert_outputs_reopen_with_native_pdfkit([
        python["results"]["make_searchable_pdf"]["text"]["output_path"],
        native["results"]["make_searchable_pdf"]["text"]["output_path"],
    ])
    for name, python_result in normalized_python["results"].items():
        native_result = normalized_native["results"][name]
        _assert_matching_payloads(python_result["text"], native_result["text"], (name, "text"))
        if name in SCALAR_RESULTS:
            assert python_result["structured_content"] == {"result": python_result["text"]}
            assert native_result["structured_content"] is None
        else:
            assert python_result["structured_content"] is None
            assert native_result["structured_content"] == native_result["text"]
    for name in SNAPSHOT_NAMES:
        assert normalized_python["results"][name]["text"] == _load_snapshot(name)


def test_native_mcp_matches_python_reference_for_all_six_tools(tmp_path):
    assert NATIVE.is_file(), "build localocr-mcp before running this contract test"

    anyio.run(_exercise_compatibility, tmp_path)


def test_normalization_keeps_raw_geometry_at_the_tolerance_boundary(tmp_path):
    root = tmp_path / "fixture"
    payload = {"lines": [{"confidence": 0.12345678, "x": 0.0050004}]}

    normalized = _normalize(payload, root)

    assert normalized["lines"][0]["confidence"] == 0.123457
    assert normalized["lines"][0]["x"] == 0.0050004
    with pytest.raises(AssertionError, match=r"difference=0.005000.*allowed=0.005000"):
        _assert_matching_payloads({"lines": [{"x": 0.0}]}, {"lines": [{"x": normalized["lines"][0]["x"]}]})
