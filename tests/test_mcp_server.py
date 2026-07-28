"""End-to-end test: drives the actual server subprocess over real stdio JSON-RPC
with the official mcp client, rather than calling the Python functions directly.
"""

import asyncio
import json
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

EXPECTED_TOOLS = {
    "get_pdf_page_count",
    "inspect_pdf",
    "ocr_pdf",
    "ocr_pdf_batch",
    "ocr_image",
    "make_searchable_pdf",
}


async def _call_tools(native_path: str, image_path: str) -> dict:
    params = StdioServerParameters(command=sys.executable, args=["-m", "ocr_service.server"])
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            tool_names = {t.name for t in tools.tools}

            page_count = await session.call_tool("get_pdf_page_count", {"file_path": native_path})
            inspect_result = await session.call_tool("inspect_pdf", {"file_path": native_path})
            ocr_result = await session.call_tool(
                "ocr_pdf", {"file_path": image_path, "page_range": "1"}
            )

            return {
                "tool_names": tool_names,
                "page_count": page_count.content[0].text,
                "inspect": json.loads(inspect_result.content[0].text),
                "ocr": json.loads(ocr_result.content[0].text),
            }


def test_server_exposes_expected_tools_and_answers_real_calls(native_text_pdf, image_only_pdf):
    native_path, _ = native_text_pdf
    image_path, expected_text_fragment = image_only_pdf

    result = asyncio.run(_call_tools(native_path, image_path))

    assert EXPECTED_TOOLS.issubset(result["tool_names"])
    assert result["page_count"] == "1"
    assert result["inspect"]["fully_searchable"] is True
    assert result["ocr"]["pages"][0]["method"] == "vision_ocr"
    assert "144,904.17" in result["ocr"]["pages"][0]["text"]
