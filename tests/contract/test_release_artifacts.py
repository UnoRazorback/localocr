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
SMOKE_SCRIPT = ROOT / "scripts" / "smoke-native-tools.sh"
VERSION = "0.3.0"
SYSTEM_LIBRARY_PREFIXES = ("/System/Library/", "/usr/lib/")
COMPATIBILITY_SPAN_INSTALL_NAME = "@rpath/libswiftCompatibilitySpan.dylib"
SYSTEM_SWIFT_RPATH = "/usr/lib/swift"
FORBIDDEN_RUNTIME_STRING_FRAGMENTS = (
    ".venv",
    "python",
    "pyobjc",
    "pymupdf",
    "ruby",
    "/opt/homebrew",
    "/usr/local",
    str(ROOT),
    "/Users/",
)


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


def _install_names(otool_output: str) -> list[str]:
    return [line.strip().split(" ", 1)[0] for line in otool_output.splitlines() if line.strip()]


def _rpaths(otool_output: str) -> list[str]:
    rpaths = []
    expects_path = False
    for line in otool_output.splitlines():
        fields = line.split()
        if fields == ["cmd", "LC_RPATH"]:
            expects_path = True
        elif expects_path and fields[:1] == ["path"]:
            rpaths.append(fields[1])
            expects_path = False
    return rpaths


def _assert_allowed_install_names(install_names: list[str]) -> None:
    unexpected = [
        install_name
        for install_name in install_names
        if not install_name.startswith(SYSTEM_LIBRARY_PREFIXES)
        and install_name != COMPATIBILITY_SPAN_INSTALL_NAME
    ]
    assert not unexpected, f"unapproved dylib install names: {unexpected}"


def _assert_allowed_rpaths(rpaths: list[str]) -> None:
    unexpected = [rpath for rpath in rpaths if rpath != SYSTEM_SWIFT_RPATH]
    assert not unexpected, f"unapproved dylib RPATHs: {unexpected}"


def _assert_no_forbidden_runtime_strings(strings_output: str, binary: Path) -> None:
    normalized_output = strings_output.lower()
    forbidden = [
        fragment
        for fragment in FORBIDDEN_RUNTIME_STRING_FRAGMENTS
        if fragment.lower() in normalized_output
    ]
    assert not forbidden, (
        f"release artifact contains forbidden embedded runtime or machine strings: "
        f"{binary}: {forbidden}"
    )


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

        _assert_no_forbidden_runtime_strings(_run("strings", str(binary)), binary)

    assert _run(str(cli), "--version").strip() == VERSION
    assert asyncio.run(_negotiated_server_version(mcp)) == VERSION


def test_native_smoke_script_handles_repository_paths_with_spaces() -> None:
    assert " " in str(ROOT), "this regression requires a space-bearing repo path"

    result = subprocess.run(
        [str(SMOKE_SCRIPT)],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stdout + result.stderr


def test_release_artifacts_expose_only_system_dylibs_and_safe_rpaths() -> None:
    for binary in (ARTIFACTS / "localocr", ARTIFACTS / "localocr-mcp"):
        install_names = _install_names(_dependencies(binary))
        assert install_names
        _assert_allowed_install_names(install_names)

        rpaths = _rpaths(_run("otool", "-l", str(binary)))
        _assert_allowed_rpaths(rpaths)
        if COMPATIBILITY_SPAN_INSTALL_NAME in install_names:
            assert SYSTEM_SWIFT_RPATH in rpaths
            # The real CLI/MCP executions in the preceding contract test verify
            # dynamic-loader resolution; macOS can serve this system library
            # from the shared cache without a conventional on-disk file.


def test_release_artifacts_do_not_ship_absolute_user_paths_or_dsyms() -> None:
    for binary in (ARTIFACTS / "localocr", ARTIFACTS / "localocr-mcp"):
        assert b"/Users/" not in binary.read_bytes(), (
            f"release artifact embeds an absolute user path: {binary}"
        )
        assert "/Users/" not in _run("nm", "-ap", str(binary)), (
            f"release artifact retains an N_SO/N_OSO user path: {binary}"
        )

    assert not list(ARTIFACTS.rglob("*.dSYM")), (
        "release artifact directory must not contain dSYM bundles"
    )


def test_release_artifact_policy_rejects_malicious_load_paths_and_rpaths() -> None:
    malicious_dependencies = """\
/tmp/evil.dylib (compatibility version 1.0.0, current version 1.0.0)
@rpath/third-party.dylib (compatibility version 1.0.0, current version 1.0.0)
"""
    malicious_rpaths = """\
Load command 20
          cmd LC_RPATH
      cmdsize 48
         path /Applications/Xcode.app/Contents/Developer (offset 12)
Load command 21
          cmd LC_RPATH
      cmdsize 32
         path /tmp/evil (offset 12)
"""

    try:
        _assert_allowed_install_names(_install_names(malicious_dependencies))
    except AssertionError as error:
        assert "/tmp/evil.dylib" in str(error)
        assert "@rpath/third-party.dylib" in str(error)
    else:
        raise AssertionError("malicious dylib paths were accepted")

    try:
        _assert_allowed_rpaths(_rpaths(malicious_rpaths))
    except AssertionError as error:
        assert "/Applications/Xcode.app/Contents/Developer" in str(error)
        assert "/tmp/evil" in str(error)
    else:
        raise AssertionError("malicious RPATHs were accepted")


def test_release_artifact_policy_rejects_malicious_embedded_runtime_strings() -> None:
    malicious_strings = "\n".join(
        (
            "safe text",
            ".venv/bin/python",
            "PyObjC.framework",
            "PyMuPDF.binding",
            "/opt/homebrew/bin/ruby",
            "/usr/local/bin/tool",
            "/Users/example/private",
            str(ROOT / "embedded"),
        )
    )

    try:
        _assert_no_forbidden_runtime_strings(malicious_strings, ARTIFACTS / "malicious")
    except AssertionError as error:
        message = str(error)
        for forbidden in (
            ".venv",
            "python",
            "pyobjc",
            "pymupdf",
            "ruby",
            "/opt/homebrew",
            "/usr/local",
            "/Users/",
            str(ROOT),
        ):
            assert forbidden in message
    else:
        raise AssertionError("malicious embedded runtime strings were accepted")
