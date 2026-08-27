"""Black-box JSON-RPC compatibility checks for the shipping stdio helper.

These tests intentionally use raw bytes and a freshly built executable.  They
do not import MCPStdio: the observable pipe contract is the boundary being
protected.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile
from typing import Any

import pytest


ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / "dist" / "native-tools" / "localocr-mcp"
MAXIMUM_MESSAGE_BYTES = 1_048_576


class RawMCPProcess:
    def __init__(self, home: Path) -> None:
        assert BINARY.is_file(), "run ./scripts/build-native-tools.sh before this contract"
        assert home.is_dir() and not home.is_symlink()
        assert home.resolve() == home
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

    def send(self, message: dict[str, Any]) -> None:
        self.send_raw(json.dumps(message, separators=(",", ":")).encode() + b"\n")

    def send_raw(self, frame: bytes) -> None:
        assert self.process.stdin is not None
        self.process.stdin.write(frame)
        self.process.stdin.flush()

    def receive(self, timeout: float = 3.0) -> dict[str, Any]:
        assert self.process.stdout is not None
        selector = selectors.DefaultSelector()
        selector.register(self.process.stdout, selectors.EVENT_READ)
        try:
            assert selector.select(timeout), "timed out waiting for JSON-RPC output"
            line = self.process.stdout.readline()
        finally:
            selector.close()
        assert line, "helper closed stdout before a response"
        response = json.loads(line)
        assert response["jsonrpc"] == "2.0"
        return response

    def assert_no_output(self, timeout: float = 0.25) -> None:
        assert self.process.stdout is not None
        selector = selectors.DefaultSelector()
        selector.register(self.process.stdout, selectors.EVENT_READ)
        try:
            assert not selector.select(timeout), "notification unexpectedly produced stdout"
        finally:
            selector.close()

    def wait_for_stdout_close(self, timeout: float = 8.0) -> None:
        assert self.process.stdout is not None
        selector = selectors.DefaultSelector()
        selector.register(self.process.stdout, selectors.EVENT_READ)
        try:
            assert selector.select(timeout), "timed out waiting for fail-closed stdout EOF"
            assert self.process.stdout.readline() == b"", "fail-closed input unexpectedly produced stdout"
        finally:
            selector.close()

    def close(self) -> tuple[bytes, bytes]:
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        assert self.process.stderr is not None
        if not self.process.stdin.closed:
            self.process.stdin.close()
        self.process.wait(timeout=5)
        return self.process.stdout.read(), self.process.stderr.read()

    def terminate(self) -> None:
        if self.process.poll() is None:
            if self.process.stdin is not None and not self.process.stdin.closed:
                self.process.stdin.close()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=2)


@pytest.fixture
def mcp_process(request: pytest.FixtureRequest) -> RawMCPProcess:
    build_root = ROOT / ".build"
    assert build_root.is_dir() and not build_root.is_symlink()
    home = Path(tempfile.mkdtemp(prefix="localocr-mcp-protocol-home-", dir=build_root))
    os.chmod(home, 0o700)
    process = RawMCPProcess(home)
    def cleanup() -> None:
        process.terminate()
        shutil.rmtree(home)

    request.addfinalizer(cleanup)
    return process


def request(request_id: int, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    message: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if params is not None:
        message["params"] = params
    return message


def initialize(process: RawMCPProcess, request_id: int = 1, protocol_version: str = "2025-06-18", capabilities: dict[str, Any] | None = None, client_name: str = "raw-protocol-contract") -> dict[str, Any]:
    process.send(
        request(
            request_id,
            "initialize",
            {
                "protocolVersion": protocol_version,
                "capabilities": capabilities or {},
                "clientInfo": {"name": client_name, "version": "test"},
            },
        )
    )
    response = process.receive()
    assert response["id"] == request_id
    assert "result" in response
    process.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    return response


def oversized_unknown_method_frame(byte_count: int) -> bytes:
    prefix = b'{"jsonrpc":"2.0","id":91,"method":"files/delete","params":{"padding":"'
    suffix = b'"}}'
    assert byte_count >= len(prefix) + len(suffix)
    frame = prefix + (b"x" * (byte_count - len(prefix) - len(suffix))) + suffix
    assert len(frame) == byte_count
    return frame + b"\n"


def test_malformed_utf8_and_json_return_parse_errors_without_stdout_noise(mcp_process: RawMCPProcess) -> None:
    # Removing UTF-8 validation or treating a JSON decoder failure as a crash
    # would break this test.
    mcp_process.send_raw(b"\xff\n")
    malformed_utf8 = mcp_process.receive()
    assert malformed_utf8["id"] is None
    assert malformed_utf8["error"]["code"] == -32700

    mcp_process.send_raw(b'{"jsonrpc":"2.0"\n')
    malformed_json = mcp_process.receive()
    assert malformed_json["id"] is None
    assert malformed_json["error"]["code"] == -32700

    trailing_stdout, stderr = mcp_process.close()
    assert trailing_stdout == b""
    assert stderr == b""


def test_unknown_method_never_reaches_dispatcher(mcp_process: RawMCPProcess) -> None:
    # Replacing the allow-list with LocalOCR dispatch would make an unsupported
    # method reach application code instead of returning JSON-RPC -32601.
    initialize(mcp_process)
    mcp_process.send(request(81, "files/delete", {}))
    response = mcp_process.receive()
    assert response["id"] == 81
    assert response["error"]["code"] == -32601


def test_notifications_never_receive_responses(mcp_process: RawMCPProcess) -> None:
    # Turning notifications into requests would make either notification emit
    # a correlated frame and desynchronize ordinary clients.
    initialize(mcp_process)
    mcp_process.send({"jsonrpc": "2.0", "method": "notifications/unknown", "params": {}})
    mcp_process.assert_no_output()
    mcp_process.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 999}})
    mcp_process.assert_no_output()


def test_rapid_same_id_tool_frames_keep_their_response_ids_well_formed(mcp_process: RawMCPProcess) -> None:
    # Active-ID rejection itself has a deterministic CallGate protocol test in
    # ServerTests. A real subprocess has no production test hook to prove that
    # the first tool handler reached its active state before this second write.
    initialize(mcp_process)
    call = request(71, "tools/call", {"name": "get_pdf_page_count", "arguments": {"file_path": "/missing.pdf"}})
    mcp_process.send(call)
    mcp_process.send(call)
    first, second = mcp_process.receive(), mcp_process.receive()
    responses = [first, second]
    assert [response["id"] for response in responses] == [71, 71]
    assert all("error" in response or "result" in response for response in responses)


def test_late_repeated_cancellation_is_silent_through_eof(mcp_process: RawMCPProcess) -> None:
    # During-work idempotence is proved by ServerTests' CallGate. This real
    # helper check first receives the terminal tool frame, so it deterministically
    # covers only late cancellation and drains any unexpected output through EOF.
    initialize(mcp_process)
    mcp_process.send(request(72, "tools/call", {"name": "get_pdf_page_count", "arguments": {"file_path": "/missing.pdf"}}))
    completed = mcp_process.receive()
    assert completed["id"] == 72
    assert completed["result"]["isError"] is True
    cancellation = {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 72}}
    mcp_process.send(cancellation)
    mcp_process.send(cancellation)
    trailing_stdout, stderr = mcp_process.close()
    assert mcp_process.process.returncode == 0
    assert trailing_stdout == b""
    assert stderr == b""


def test_exact_maximum_frame_is_dispatched_and_one_byte_larger_fails_closed(mcp_process: RawMCPProcess) -> None:
    # An off-by-one limit, parse-error response, or dispatching the following
    # line would violate the fail-closed transport framing contract.
    initialize(mcp_process)
    mcp_process.send_raw(oversized_unknown_method_frame(MAXIMUM_MESSAGE_BYTES))
    exact_limit = mcp_process.receive(timeout=8)
    assert exact_limit["id"] == 91
    assert exact_limit["error"]["code"] == -32601

    mcp_process.send_raw(oversized_unknown_method_frame(MAXIMUM_MESSAGE_BYTES + 1) + json.dumps(request(92, "ping", {}), separators=(",", ":")).encode() + b"\n")
    mcp_process.wait_for_stdout_close()
    assert mcp_process.process.wait(timeout=5) == 0
    assert mcp_process.process.stdout is not None
    assert mcp_process.process.stderr is not None
    trailing_stdout, stderr = mcp_process.process.stdout.read(), mcp_process.process.stderr.read()
    assert mcp_process.process.returncode == 0
    assert trailing_stdout == b""
    assert stderr == b""


@pytest.mark.parametrize(
    ("client_name", "protocol_version", "capabilities", "expected_protocol_version"),
    [
        ("generic-stdio-client", "2025-06-18", {}, "2025-06-18"),
        ("codex-cli", "2025-11-25", {"roots": {"listChanged": True}, "sampling": {}}, "2025-06-18"),
        ("claude-code", "2025-03-26", {}, "2025-03-26"),
    ],
)
def test_common_client_initialize_handshakes_need_no_client_configuration_changes(
    mcp_process: RawMCPProcess,
    client_name: str,
    protocol_version: str,
    capabilities: dict[str, Any],
    expected_protocol_version: str,
) -> None:
    # Rejecting a current generic, Codex, or Claude shaped initialize request
    # would prevent those clients from attaching to the unconfigured helper.
    initialization = initialize(mcp_process, protocol_version=protocol_version, capabilities=capabilities, client_name=client_name)
    assert initialization["result"]["protocolVersion"] == expected_protocol_version
    assert initialization["result"]["serverInfo"] == {"name": "localocr", "version": "0.3.0"}
    mcp_process.send(request(93, "ping", {}))
    assert mcp_process.receive() == {"id": 93, "jsonrpc": "2.0", "result": {}}


def test_eof_is_clean_and_every_stdout_record_is_json_rpc(mcp_process: RawMCPProcess) -> None:
    # Printing a diagnostic to stdout or treating EOF as an error would make
    # client line framing unreliable at connection shutdown.
    initialize(mcp_process)
    mcp_process.send(request(94, "ping", {}))
    assert mcp_process.receive() == {"id": 94, "jsonrpc": "2.0", "result": {}}
    trailing_stdout, stderr = mcp_process.close()
    assert mcp_process.process.returncode == 0
    assert trailing_stdout == b""
    assert stderr == b""
