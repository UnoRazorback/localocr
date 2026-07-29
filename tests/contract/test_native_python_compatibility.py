"""Cross-server MCP compatibility contract for the Python and native servers."""

from __future__ import annotations

import anyio
import json
import re
import shutil
import sys
from pathlib import Path
from typing import Any

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


ROOT = Path(__file__).parents[2]
NATIVE = ROOT / ".build" / "debug" / "localocr-mcp"
FIXTURE_NAMES = ("mixed.pdf", "image-only.pdf")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SCALAR_RESULTS = {"get_pdf_page_count", "ocr_image"}


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


def _normalize(value: Any, fixture_root: Path) -> Any:
    if isinstance(value, dict):
        return {key: _normalize(item, fixture_root) for key, item in value.items()}
    if isinstance(value, list):
        return [_normalize(item, fixture_root) for item in value]
    if isinstance(value, float):
        return round(value, 6)
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


async def _exercise_compatibility(tmp_path: Path) -> None:
    python_fixtures = _copy_fixtures(tmp_path / "python-fixtures")
    native_fixtures = _copy_fixtures(tmp_path / "native-fixtures")
    python = await _call_server(
        StdioServerParameters(command=sys.executable, args=["-m", "ocr_service.server"]),
        python_fixtures,
    )
    native = await _call_server(StdioServerParameters(command=str(NATIVE), args=[]), native_fixtures)

    normalized_python = _normalize(python, python_fixtures["mixed.pdf"].parent)
    normalized_native = _normalize(native, native_fixtures["mixed.pdf"].parent)

    assert set(normalized_native["tools"]) == set(normalized_python["tools"])
    for name, python_result in normalized_python["results"].items():
        native_result = normalized_native["results"][name]
        assert native_result["text"] == python_result["text"]
        if name in SCALAR_RESULTS:
            assert python_result["structured_content"] == {"result": python_result["text"]}
            assert native_result["structured_content"] is None
        else:
            assert python_result["structured_content"] is None
            assert native_result["structured_content"] == native_result["text"]


def test_native_mcp_matches_python_reference_for_all_six_tools(tmp_path):
    assert NATIVE.is_file(), "build localocr-mcp before running this contract test"

    anyio.run(_exercise_compatibility, tmp_path)
