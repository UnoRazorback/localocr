"""Executable-level contract tests for the native Swift stdio MCP server."""

import asyncio
import json
import subprocess
import tempfile
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


REPOSITORY_ROOT = Path(__file__).parents[2]
BINARY = REPOSITORY_ROOT / ".build" / "debug" / "localocr-mcp"
FIXTURE = REPOSITORY_ROOT / "tests" / "LocalOCRCoreTests" / "Fixtures" / "mixed.pdf"
EXPECTED_TOOL_NAMES = {
    "get_pdf_page_count",
    "inspect_pdf",
    "ocr_pdf",
    "ocr_pdf_batch",
    "ocr_image",
    "make_searchable_pdf",
}


class RecordingReceiveStream:
    """Record every stdout frame after the MCP client has parsed it."""

    def __init__(self, stream):
        self._stream = stream
        self.messages = []

    async def __aenter__(self):
        await self._stream.__aenter__()
        return self

    async def __aexit__(self, *args):
        return await self._stream.__aexit__(*args)

    def __aiter__(self):
        return self

    async def __anext__(self):
        message = await self._stream.__anext__()
        self.messages.append(message)
        return message


async def _exercise_server(missing: Path):
    parameters = StdioServerParameters(command=str(BINARY), args=[], cwd=REPOSITORY_ROOT)

    with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as errlog:
        async with stdio_client(parameters, errlog=errlog) as (read, write):
            recorded_read = RecordingReceiveStream(read)
            async with ClientSession(recorded_read, write) as session:
                initialization = await session.initialize()
                names = {tool.name for tool in (await session.list_tools()).tools}
                page_count = await session.call_tool(
                    "get_pdf_page_count", {"file_path": str(FIXTURE)}
                )
                bad = await session.call_tool("ocr_pdf", {"file_path": str(missing)})
                good = await session.call_tool("inspect_pdf", {"file_path": str(FIXTURE)})
                await asyncio.sleep(0.05)
        errlog.seek(0)
        stderr = errlog.read()

    return {
        "initialization": initialization,
        "names": names,
        "page_count": page_count,
        "bad": bad,
        "good": good,
        "messages": recorded_read.messages,
        "stderr": stderr,
    }


def test_native_server_session_survives_a_recoverable_tool_error(tmp_path):
    result = asyncio.run(_exercise_server(tmp_path / "missing.pdf"))

    assert result["initialization"].serverInfo.name == "localocr"
    assert result["initialization"].serverInfo.version == "0.2.0"
    assert result["names"] == EXPECTED_TOOL_NAMES
    assert result["page_count"].isError is False
    assert result["page_count"].content[0].text == "2"
    assert result["page_count"].structuredContent is None
    assert result["bad"].isError is True
    assert result["good"].isError is False
    inspection = json.loads(result["good"].content[0].text)
    assert set(inspection) == {
        "source_path",
        "source_sha256",
        "pages",
        "searchable_pages",
        "ocr_needed_pages",
        "characters",
        "fully_searchable",
        "page_details",
    }
    assert inspection["searchable_pages"] == 1
    assert inspection["ocr_needed_pages"] == 1
    assert len(result["messages"]) == 5
    assert not any(isinstance(message, Exception) for message in result["messages"])
    assert result["stderr"] == ""


def test_native_server_exits_cleanly_on_eof():
    completed = subprocess.run(
        [BINARY],
        input=b"",
        capture_output=True,
        cwd=REPOSITORY_ROOT,
        timeout=5,
        check=False,
    )

    assert completed.returncode == 0
    assert completed.stdout == b""
    assert completed.stderr == b""


def test_native_server_reports_startup_failure_only_on_stderr():
    completed = subprocess.run(
        ["/bin/sh", "-c", 'exec 1>&-; exec "$1"', "localocr-mcp", BINARY],
        input=b"",
        capture_output=True,
        cwd=REPOSITORY_ROOT,
        timeout=5,
        check=False,
    )

    assert completed.returncode != 0
    assert completed.stdout == b""
    lines = completed.stderr.decode().splitlines()
    assert len(lines) == 1
    assert lines[0].startswith("localocr-mcp: startup failed:")
