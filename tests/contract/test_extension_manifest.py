"""Extension manifest contract for the portable native MCP server."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).parents[2]
MANIFEST = ROOT / "extension" / "manifest.json"


def test_extension_manifest_starts_native_server_without_machine_runtime_paths() -> None:
    manifest = json.loads(MANIFEST.read_text())
    server = manifest["server"]
    mcp_config = server["mcp_config"]
    serialized = json.dumps(manifest).lower()

    assert manifest["version"] == "0.2.0"
    assert server["entry_point"] == "localocr-mcp"
    assert mcp_config["command"] == "localocr-mcp"
    assert mcp_config["args"] == []
    assert "on path" in manifest["description"].lower()
    assert {tool["name"] for tool in manifest["tools"]} == {
        "get_pdf_page_count",
        "inspect_pdf",
        "ocr_pdf",
        "ocr_pdf_batch",
        "ocr_image",
        "make_searchable_pdf",
    }
    for forbidden in ("/users", ".venv", "python", "homebrew"):
        assert forbidden not in serialized
