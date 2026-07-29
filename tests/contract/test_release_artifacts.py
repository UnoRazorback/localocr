"""Release artifact contract for the standalone native tools."""

from __future__ import annotations

import asyncio
import os
import subprocess
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


ROOT = Path(__file__).parents[2]
ARTIFACTS = ROOT / "dist" / "native-tools"
VERSION = "0.2.0"


def _run(*arguments: str) -> str:
    return subprocess.run(
        arguments,
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def _dependencies(binary: Path) -> str:
    lines = _run("otool", "-L", str(binary)).splitlines()
    assert lines, f"otool returned no output for {binary}"
    return "\n".join(lines[1:])


async def _negotiated_server_version(binary: Path) -> str:
    async with stdio_client(
        StdioServerParameters(command=str(binary), args=[])
    ) as (read, write):
        async with ClientSession(read, write) as session:
            initialized = await session.initialize()
            return initialized.serverInfo.version


def test_release_artifacts_are_native_standalone_executables() -> None:
    cli = ARTIFACTS / "localocr"
    mcp = ARTIFACTS / "localocr-mcp"

    for binary in (cli, mcp):
        assert binary.is_file(), f"missing release artifact: {binary}"
        assert os.access(binary, os.X_OK), f"release artifact is not executable: {binary}"
        assert "Mach-O" in _run("file", "-b", str(binary)), f"not a Mach-O executable: {binary}"

        dependencies = _dependencies(binary).lower()
        for forbidden in ("python", "ruby", "/opt/homebrew", str(ROOT).lower()):
            assert forbidden not in dependencies, (
                f"release artifact links forbidden runtime path {forbidden!r}: {binary}\n"
                f"{dependencies}"
            )

    assert _run(str(cli), "--version").strip() == VERSION
    assert asyncio.run(_negotiated_server_version(mcp)) == VERSION
