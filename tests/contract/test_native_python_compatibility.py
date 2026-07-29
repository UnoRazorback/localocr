"""Cross-process compatibility tests for the Python and native MCP servers."""

import asyncio
import json
import os
import re
import shutil
import tempfile
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


REPOSITORY_ROOT = Path(__file__).parents[2]
PYTHON = REPOSITORY_ROOT.parent.parent / ".venv" / "bin" / "python"
NATIVE_BINARY = REPOSITORY_ROOT / ".build" / "debug" / "localocr-mcp"
FIXTURES = REPOSITORY_ROOT / "tests" / "LocalOCRCoreTests" / "Fixtures"
EXPECTED = Path(__file__).parent / "expected"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
FLOAT_FIELDS = {"confidence", "x", "y", "width", "height"}


def _tool_schema(tool) -> dict:
    """Keep the complete argument schema, independent of tool ordering."""
    dumped = tool.model_dump(by_alias=True, exclude_none=True)
    return dumped["inputSchema"]


async def _list_tool_schemas(parameters: StdioServerParameters) -> dict[str, dict]:
    with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as errlog:
        async with stdio_client(parameters, errlog=errlog) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                tools = (await session.list_tools()).tools
    return {tool.name: _tool_schema(tool) for tool in tools}


def _server_parameters(
    cwd: Path = REPOSITORY_ROOT,
) -> tuple[StdioServerParameters, StdioServerParameters]:
    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(REPOSITORY_ROOT / "src")
    python = StdioServerParameters(
        command=str(PYTHON),
        args=["-c", "from ocr_service.server import main; main()"],
        cwd=cwd,
        env=environment,
    )
    native = StdioServerParameters(
        command=str(NATIVE_BINARY),
        args=[],
        cwd=cwd,
    )
    return python, native


async def _list_both_tool_schemas(
    python: StdioServerParameters,
    native: StdioServerParameters,
) -> tuple[dict[str, dict], dict[str, dict]]:
    return await asyncio.gather(
        _list_tool_schemas(python),
        _list_tool_schemas(native),
    )


def _decode_result(result):
    assert result.isError is False
    assert len(result.content) == 1
    text = result.content[0].text
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


async def _exercise_server(parameters: StdioServerParameters, fixture_dir: Path) -> dict:
    mixed = fixture_dir / "mixed.pdf"
    image_only = fixture_dir / "image-only.pdf"
    upright_image = fixture_dir / "upright-text.png"
    missing = fixture_dir / "missing.pdf"

    with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as errlog:
        async with stdio_client(parameters, errlog=errlog) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                results = {
                    "get_pdf_page_count": _decode_result(
                        await session.call_tool(
                            "get_pdf_page_count",
                            {"file_path": str(mixed)},
                        )
                    ),
                    "inspect_pdf": _decode_result(
                        await session.call_tool("inspect_pdf", {"file_path": str(mixed)})
                    ),
                    "ocr_pdf": _decode_result(
                        await session.call_tool(
                            "ocr_pdf",
                            {"file_path": str(mixed), "page_range": "1", "dpi": 72},
                        )
                    ),
                    "ocr_pdf_lines": _decode_result(
                        await session.call_tool(
                            "ocr_pdf",
                            {
                                "file_path": str(image_only),
                                "page_range": "1",
                                "dpi": 250,
                                "include_lines": True,
                            },
                        )
                    ),
                    "ocr_pdf_batch": _decode_result(
                        await session.call_tool(
                            "ocr_pdf_batch",
                            {
                                "file_paths": [str(mixed), str(missing)],
                                "page_range": "1",
                                "dpi": 72,
                            },
                        )
                    ),
                    "ocr_image": _decode_result(
                        await session.call_tool(
                            "ocr_image",
                            {"file_path": str(upright_image)},
                        )
                    ),
                    "make_searchable_pdf": _decode_result(
                        await session.call_tool(
                            "make_searchable_pdf",
                            {"file_path": str(mixed), "dpi": 250},
                        )
                    ),
                }
    return results


def _normalize(value, fixture_dir: Path, key: str | None = None):
    if isinstance(value, dict):
        return {
            item_key: _normalize(item_value, fixture_dir, item_key)
            for item_key, item_value in value.items()
        }
    if isinstance(value, list):
        return [_normalize(item, fixture_dir, key) for item in value]
    if isinstance(value, float) and key in FLOAT_FIELDS:
        return round(value, 6)
    if isinstance(value, str):
        if SHA256.fullmatch(value):
            return "<sha256>"
        fixture_paths = {
            str(fixture_dir),
            str(fixture_dir).removeprefix("/private"),
        }
        normalized = value
        for fixture_path in sorted(fixture_paths, key=len, reverse=True):
            normalized = normalized.replace(fixture_path, "<fixture>")
        if key == "output_path":
            normalized = re.sub(
                r"(?<=<fixture>/)mixed_searchable(?:_\d+)?\.pdf$",
                "<output>",
                normalized,
            )
        return normalized
    return value


def _copy_fixtures(destination: Path) -> None:
    destination.mkdir(parents=True)
    for name in ("mixed.pdf", "image-only.pdf", "upright-text.png"):
        shutil.copy2(FIXTURES / name, destination / name)


async def _native_page_counts(paths: list[Path]) -> list[int]:
    _, parameters = _server_parameters()
    async with stdio_client(parameters) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            return [
                _decode_result(
                    await session.call_tool(
                        "get_pdf_page_count",
                        {"file_path": str(path)},
                    )
                )
                for path in paths
            ]


def test_native_and_python_servers_advertise_identical_tool_schemas():
    python, native = _server_parameters()

    python_schemas, native_schemas = asyncio.run(_list_both_tool_schemas(python, native))

    assert native_schemas == python_schemas


def test_native_and_python_servers_return_compatible_results(tmp_path):
    shared_root = tmp_path / "shared"
    fixture_dir = shared_root / "fixtures"
    _copy_fixtures(fixture_dir)
    python, native = _server_parameters(shared_root)

    python_results = asyncio.run(_exercise_server(python, fixture_dir))
    python_output = Path(python_results["make_searchable_pdf"]["output_path"])
    saved_python_output = tmp_path / "python-searchable.pdf"
    python_output.replace(saved_python_output)
    native_results = asyncio.run(_exercise_server(native, fixture_dir))
    normalized_python = _normalize(python_results, fixture_dir)
    normalized_native = _normalize(native_results, fixture_dir)

    assert normalized_native == normalized_python
    assert normalized_python["get_pdf_page_count"] == 2
    assert isinstance(normalized_python["ocr_image"], str)
    assert all(
        "orientation" not in page
        for result_name in ("ocr_pdf", "ocr_pdf_lines")
        for page in normalized_python[result_name]["pages"]
    )
    assert all(
        "lines" not in page for page in normalized_python["ocr_pdf"]["pages"]
    )
    assert all(
        set(line) == {"text", "confidence", "x", "y", "width", "height"}
        for page in normalized_python["ocr_pdf_lines"]["pages"]
        for line in page["lines"]
    )

    snapshot_names = {
        "inspect_pdf",
        "ocr_pdf",
        "ocr_pdf_lines",
        "ocr_pdf_batch",
        "make_searchable_pdf",
    }
    for name in snapshot_names:
        expected = json.loads((EXPECTED / f"{name}.json").read_text())
        assert normalized_python[name] == expected

    output_paths = [
        saved_python_output,
        Path(native_results["make_searchable_pdf"]["output_path"]),
    ]
    assert asyncio.run(_native_page_counts(output_paths)) == [2, 2]
