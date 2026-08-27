"""Raw subprocess compatibility contract for the shipping native MCP helper."""

from __future__ import annotations

import json
import os
from pathlib import Path
import selectors
import shutil
import stat
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / "dist" / "native-tools" / "localocr-mcp"
EXPECTED_TOOL_NAMES = [
    "get_pdf_page_count",
    "inspect_pdf",
    "ocr_pdf",
    "ocr_pdf_batch",
    "ocr_image",
    "make_searchable_pdf",
    "summarize_document",
    "organize_document",
    "extract_document_fields",
]
ACKNOWLEDGMENT_ERROR = {
    "error": {
        "code": "external_data_acknowledgment_required",
        "message": "Accept the LocalOCR MCP external-data acknowledgment in LocalOCR Studio Help or with `localocr mcp-consent accept`, then retry.",
    }
}


class MCPProcess:
    def __init__(self, home: Path) -> None:
        environment = os.environ.copy()
        environment.update(
            HOME=str(home),
            CFFIXED_USER_HOME=str(home),
            LOCALOCR_CACHE_DIR=str(home / "cache"),
        )
        self.process = subprocess.Popen(
            [str(BINARY)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
        )

    def send(self, message: dict[str, object]) -> None:
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(message, separators=(",", ":")).encode() + b"\n")
        self.process.stdin.flush()

    def receive(self, request_id: int, timeout: float = 10.0) -> dict[str, object]:
        assert self.process.stdout is not None
        selector = selectors.DefaultSelector()
        selector.register(self.process.stdout, selectors.EVENT_READ)
        try:
            assert selector.select(timeout), f"timed out waiting for response {request_id}"
            line = self.process.stdout.readline()
        finally:
            selector.close()
        assert line, f"helper closed stdout before response {request_id}"
        response = json.loads(line)
        assert response["jsonrpc"] == "2.0"
        assert response["id"] == request_id
        return response

    def close_input_and_wait(self) -> tuple[bytes, bytes]:
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        assert self.process.stderr is not None
        self.process.stdin.close()
        self.process.wait(timeout=10)
        return self.process.stdout.read(), self.process.stderr.read()

    def terminate(self) -> None:
        if self.process.poll() is not None:
            return
        if self.process.stdin is not None and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=2)


def _request(request_id: int, method: str, params: dict[str, object] | None = None) -> dict[str, object]:
    message: dict[str, object] = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if params is not None:
        message["params"] = params
    return message


def _tool_call(request_id: int, name: str, arguments: dict[str, object]) -> dict[str, object]:
    return _request(request_id, "tools/call", {"name": name, "arguments": arguments})


def _install_consent_receipt(home: Path) -> None:
    directory = home / "Library" / "Application Support" / "com.rayconsulting.localocr"
    directory.mkdir(parents=True, mode=0o700)
    for path in (home / "Library", home / "Library" / "Application Support", directory):
        os.chmod(path, 0o700)
        metadata = path.lstat()
        assert stat.S_ISDIR(metadata.st_mode) and not path.is_symlink()
        assert stat.S_IMODE(metadata.st_mode) == 0o700

    receipt = directory / "mcp-consent.json"
    payload = {
        "schema_version": 1,
        "policy_version": 1,
        "accepted_at": "2026-08-27T00:00:00Z",
        "external_provider_risk_accepted": True,
        "document_tool_access_accepted": True,
    }
    descriptor = os.open(receipt, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        os.write(descriptor, json.dumps(payload, separators=(",", ":")).encode())
        os.fchmod(descriptor, 0o600)
    finally:
        os.close(descriptor)
    assert stat.S_IMODE(receipt.stat().st_mode) == 0o600


def _tool_text(response: dict[str, object]) -> str:
    result = response["result"]
    assert isinstance(result, dict)
    content = result["content"]
    assert isinstance(content, list) and len(content) == 1
    item = content[0]
    assert isinstance(item, dict) and item["type"] == "text"
    text = item["text"]
    assert isinstance(text, str)
    return text


def test_native_helper_preserves_localocr_stdio_contract_and_clean_eof(tmp_path: Path, request) -> None:
    assert BINARY.is_file(), "run ./scripts/build-native-tools.sh before this contract"
    home = Path(tempfile.mkdtemp(prefix="localocr-mcp-contract-home-", dir=ROOT / ".build"))
    os.chmod(home, 0o700)
    request.addfinalizer(lambda: shutil.rmtree(home))
    fixture = ROOT / "tests" / "LocalOCRCoreTests" / "Fixtures" / "mixed.pdf"
    cancellation_fixture = ROOT / "tests" / "LocalOCRCoreTests" / "Fixtures" / "image-only.pdf"
    missing = tmp_path / "missing.pdf"
    server = MCPProcess(home)
    request.addfinalizer(server.terminate)

    server.send(
        _request(
            1,
            "initialize",
            {
                # Current Codex accepts the newer handshake shape. The vendored
                # helper intentionally negotiates its supported 2025-06-18 wire
                # version without requiring any client configuration edit.
                "protocolVersion": "2025-11-25",
                "capabilities": {"roots": {"listChanged": True}, "sampling": {}},
                "clientInfo": {"name": "codex-cli", "version": "0.136.0"},
            },
        )
    )
    initialization = server.receive(1)["result"]
    assert isinstance(initialization, dict)
    assert initialization["protocolVersion"] == "2025-06-18"
    assert initialization["serverInfo"] == {"name": "localocr", "version": "0.3.0"}
    server.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    server.send(_request(2, "tools/list", {}))
    listed = server.receive(2)["result"]
    assert isinstance(listed, dict)
    assert [tool["name"] for tool in listed["tools"]] == EXPECTED_TOOL_NAMES

    server.send(_tool_call(3, "get_pdf_page_count", {"file_path": str(missing)}))
    blocked = server.receive(3)
    assert blocked["result"]["isError"] is True
    assert json.loads(_tool_text(blocked)) == ACKNOWLEDGMENT_ERROR

    _install_consent_receipt(home)
    server.send(_tool_call(4, "get_pdf_page_count", {"file_path": str(fixture)}))
    page_count = server.receive(4)
    assert _tool_text(page_count) == "2"
    assert "structuredContent" not in page_count["result"]

    server.send(_tool_call(5, "inspect_pdf", {"file_path": str(fixture)}))
    inspection = server.receive(5)
    inspection_text = json.loads(_tool_text(inspection))
    assert inspection["result"]["structuredContent"] == inspection_text
    assert inspection_text["pages"] == 2

    server.send(
        _tool_call(
            6,
            "ocr_pdf_batch",
            {"file_paths": [str(cancellation_fixture)] * 64},
        )
    )
    server.send(
        {
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": {"requestId": 6, "reason": "active compatibility probe"},
        }
    )
    cancellation = server.receive(6)
    assert cancellation["error"]["code"] == -32603
    assert "image-only.pdf" not in json.dumps(cancellation)

    server.send(_request(7, "ping", {}))
    assert server.receive(7)["result"] == {}

    trailing_stdout, stderr = server.close_input_and_wait()
    assert server.process.returncode == 0
    assert trailing_stdout == b""
    assert stderr == b""
