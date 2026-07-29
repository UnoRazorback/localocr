"""End-to-end contract for the native stdio MCP executable."""

from __future__ import annotations

import anyio
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


EXPECTED_TOOL_NAMES = {
    "get_pdf_page_count",
    "inspect_pdf",
    "make_searchable_pdf",
    "ocr_image",
    "ocr_pdf",
    "ocr_pdf_batch",
}


async def _exercise_server(binary: Path, fixture: Path, missing: Path, errlog) -> None:
    async with stdio_client(
        StdioServerParameters(command=str(binary), args=[]), errlog=errlog
    ) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            tools = await session.list_tools()
            assert {tool.name for tool in tools.tools} == EXPECTED_TOOL_NAMES

            page_count = await session.call_tool(
                "get_pdf_page_count", {"file_path": str(fixture)}
            )
            assert page_count.isError is not True

            bad = await session.call_tool("ocr_pdf", {"file_path": str(missing)})
            assert bad.isError is True

            good = await session.call_tool("inspect_pdf", {"file_path": str(fixture)})
            assert good.isError is not True


def test_native_stdio_server_keeps_protocol_stdout_clean_and_survives_tool_errors(tmp_path):
    root = Path(__file__).parents[2]
    binary = root / ".build" / "debug" / "localocr-mcp"
    fixture = root / "tests" / "LocalOCRCoreTests" / "Fixtures" / "mixed.pdf"
    missing = tmp_path / "missing.pdf"
    stderr_path = tmp_path / "server.stderr"

    assert binary.is_file(), "build localocr-mcp before running this contract test"

    with stderr_path.open("w+") as errlog:
        anyio.run(_exercise_server, binary, fixture, missing, errlog)

    # The MCP client consumed every newline-delimited stdout record as JSON-RPC;
    # any diagnostic stdout would have made one of the session calls fail parsing.
    assert stderr_path.read_text() == ""
