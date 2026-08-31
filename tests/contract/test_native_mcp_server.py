"""End-to-end contract for the native stdio MCP executable."""

from __future__ import annotations

import anyio
from contextlib import contextmanager
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import tempfile

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
import pytest


EXPECTED_TOOL_NAMES = {
    "extract_document_fields",
    "get_pdf_page_count",
    "inspect_pdf",
    "make_searchable_pdf",
    "ocr_image",
    "ocr_pdf",
    "ocr_pdf_batch",
    "organize_document",
    "summarize_document",
}
ACKNOWLEDGMENT_ERROR = {
    "error": {
        "code": "external_data_acknowledgment_required",
        "message": "Accept the LocalOCR MCP external-data acknowledgment in LocalOCR Studio Help or with `localocr mcp-consent accept`, then retry.",
    }
}
RECEIPT_KEYS = {
    "accepted_at",
    "document_tool_access_accepted",
    "external_provider_risk_accepted",
    "policy_version",
    "schema_version",
}


@contextmanager
def _isolated_test_home(parent: Path):
    parent = parent.resolve(strict=True)
    _assert_symlink_free_path(parent)
    root = Path(tempfile.mkdtemp(prefix="localocr-mcp-home-", dir=parent))
    os.chmod(root, 0o700)
    identity = root.stat().st_dev, root.stat().st_ino
    _assert_private_directory(root)
    try:
        yield root
    finally:
        current = root.lstat()
        assert stat.S_ISDIR(current.st_mode) and not root.is_symlink()
        assert (current.st_dev, current.st_ino) == identity
        assert root.parent.resolve(strict=True) == parent
        shutil.rmtree(root)


def _assert_symlink_free_path(path: Path) -> None:
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current = current / component
        assert not current.is_symlink()


def _assert_private_directory(path: Path) -> None:
    metadata = path.lstat()
    assert stat.S_ISDIR(metadata.st_mode) and not path.is_symlink()
    assert stat.S_IMODE(metadata.st_mode) == 0o700
    assert metadata.st_uid == os.geteuid()


def _make_environment(home: Path) -> dict[str, str]:
    environment = os.environ.copy()
    environment["CFFIXED_USER_HOME"] = str(home)
    environment["HOME"] = str(home)
    environment["LOCALOCR_CACHE_DIR"] = str(home / "cache")
    return environment


def _install_test_receipt(home: Path) -> Path:
    directory = home / "Library" / "Application Support" / "com.rayconsulting.localocr"
    current = home
    for component in ("Library", "Application Support", "com.rayconsulting.localocr"):
        current = current / component
        current.mkdir(mode=0o700, exist_ok=True)
        os.chmod(current, 0o700)
        _assert_private_directory(current)

    receipt = directory / "mcp-consent.json"
    payload = {
        "schema_version": 1,
        "policy_version": 1,
        "accepted_at": "2026-08-27T00:00:00Z",
        "external_provider_risk_accepted": True,
        "document_tool_access_accepted": True,
    }
    assert set(payload) == RECEIPT_KEYS
    descriptor = os.open(
        receipt,
        os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW,
        0o600,
    )
    try:
        os.write(descriptor, json.dumps(payload, separators=(",", ":")).encode())
        os.fchmod(descriptor, 0o600)
    finally:
        os.close(descriptor)
    receipt_metadata = receipt.lstat()
    assert stat.S_ISREG(receipt_metadata.st_mode) and not receipt.is_symlink()
    assert stat.S_IMODE(receipt_metadata.st_mode) == 0o600
    assert receipt_metadata.st_uid == os.geteuid()
    assert set(json.loads(receipt.read_text())) == RECEIPT_KEYS
    return receipt


def _result_json(result):
    assert len(result.content) == 1
    return json.loads(result.content[0].text)


async def _exercise_server(
    binary: Path,
    fixture: Path,
    missing: Path,
    home: Path,
    errlog,
) -> None:
    async with stdio_client(
        StdioServerParameters(command=str(binary), args=[], env=_make_environment(home)),
        errlog=errlog,
    ) as (read, write):
        async with ClientSession(read, write) as session:
            initialization = await session.initialize()
            assert initialization.serverInfo.name == "localocr"
            assert initialization.serverInfo.version == "0.3.1"

            tools = await session.list_tools()
            assert {tool.name for tool in tools.tools} == EXPECTED_TOOL_NAMES

            blocked = await session.call_tool(
                "get_pdf_page_count", {"file_path": str(missing)}
            )
            assert blocked.isError is True
            assert _result_json(blocked) == ACKNOWLEDGMENT_ERROR

            _install_test_receipt(home)

            page_count = await session.call_tool(
                "get_pdf_page_count", {"file_path": str(fixture)}
            )
            assert page_count.isError is not True
            assert page_count.content[0].text == "2"

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

    with _isolated_test_home(root / ".build") as home:
        with stderr_path.open("w+") as errlog:
            anyio.run(_exercise_server, binary, fixture, missing, home, errlog)

    # The MCP client consumed every newline-delimited stdout record as JSON-RPC;
    # any diagnostic stdout would have made one of the session calls fail parsing.
    assert stderr_path.read_text() == ""


def test_native_mcp_reads_the_shared_model_selection_without_mutating_it(tmp_path):
    root = Path(__file__).parents[2]
    mcp_binary = root / ".build" / "debug" / "localocr-mcp"
    cli_binary = root / ".build" / "debug" / "localocr"
    fixture = root / "tests" / "LocalOCRCoreTests" / "Fixtures" / "mixed.pdf"
    stderr_path = tmp_path / "selection.stderr"

    assert mcp_binary.is_file(), "build localocr-mcp before running this contract test"
    assert cli_binary.is_file(), "build localocr before running this contract test"

    async def exercise(home: Path, errlog) -> None:
        environment = _make_environment(home)
        current = home
        for component in ("Library", "Application Support"):
            current = current / component
            current.mkdir(mode=0o700)
            os.chmod(current, 0o700)
            _assert_private_directory(current)
        reset = subprocess.run(
            [str(cli_binary), "intelligence", "reset", "--json"],
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )
        assert reset.returncode == 0, reset.stderr
        assert json.loads(reset.stdout)["state"] == "reset"
        selection_receipt = (
            home
            / "Library"
            / "Application Support"
            / "com.rayconsulting.localocr"
            / "local-intelligence-selection.json"
        )
        before = selection_receipt.read_bytes()
        _install_test_receipt(home)

        async with stdio_client(
            StdioServerParameters(command=str(mcp_binary), args=[], env=environment),
            errlog=errlog,
        ) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                result = await session.call_tool(
                    "summarize_document", {"file_path": str(fixture)}
                )
                assert result.isError is True
                payload = _result_json(result)
                assert payload["error"]["code"] == "local_intelligence_selection_required"

        assert selection_receipt.read_bytes() == before

    with _isolated_test_home(root / ".build") as home:
        with stderr_path.open("w+") as errlog:
            anyio.run(exercise, home, errlog)

    assert stderr_path.read_text() == ""


@pytest.mark.skipif(
    os.environ.get("LOCALOCR_RUN_FOUNDATION_MODELS_TESTS") != "1",
    reason="live Foundation Models subprocess coverage requires explicit opt-in",
)
def test_opt_in_native_foundation_models_subprocess_uses_local_fixture(tmp_path):
    major_version = int(platform.mac_ver()[0].split(".", 1)[0])
    assert major_version >= 26, "opted-in live Foundation Models coverage requires macOS 26+"

    root = Path(__file__).parents[2]
    binary = root / ".build" / "debug" / "localocr-mcp"
    fixture = root / "tests" / "LocalOCRCoreTests" / "Fixtures" / "mixed.pdf"
    stderr_path = tmp_path / "foundation-models.stderr"

    async def exercise(home: Path, errlog) -> None:
        async with stdio_client(
            StdioServerParameters(
                command=str(binary),
                args=[],
                env=_make_environment(home),
            ),
            errlog=errlog,
        ) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                result = await session.call_tool(
                    "summarize_document", {"file_path": str(fixture)}
                )
                assert result.isError is not True, _result_json(result)
                payload = _result_json(result)
                assert set(payload) == {"citations", "local_model", "text"}
                assert payload["text"]
                assert payload["local_model"] == {
                    "model": "SystemLanguageModel.default",
                    "processing": "on_device",
                    "provider": "Apple Foundation Models",
                }

    with _isolated_test_home(root / ".build") as home:
        _install_test_receipt(home)
        with stderr_path.open("w+") as errlog:
            anyio.run(exercise, home, errlog)

    assert stderr_path.read_text() == ""
