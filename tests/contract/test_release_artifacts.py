"""Release artifact contract for the standalone native tools."""

from __future__ import annotations

import asyncio
import json
import os
import re
import subprocess
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


ROOT = Path(__file__).parents[2]
ARTIFACTS = ROOT / "dist" / "native-tools"
SMOKE_SCRIPT = ROOT / "scripts" / "smoke-native-tools.sh"
MCP_SMOKE_EXCHANGE = ROOT / "scripts" / "mcp-smoke-exchange.py"
VERSION = "0.3.0"
BRIDGE = ARTIFACTS / "localocr-model-bridge"
SYSTEM_LIBRARY_PREFIXES = ("/System/Library/", "/usr/lib/")
COMPATIBILITY_SPAN_INSTALL_NAME = "@rpath/libswiftCompatibilitySpan.dylib"
SYSTEM_SWIFT_RPATH = "/usr/lib/swift"
KNOWN_FORBIDDEN_NETWORK_INSTALL_NAMES = {
    "/System/Library/Frameworks/CFNetwork.framework/Versions/A/CFNetwork",
    "/System/Library/Frameworks/CFNetwork.framework/Versions/B/CFNetwork",
    "/System/Library/Frameworks/CFNetwork.framework/CFNetwork",
    "/System/Library/Frameworks/Network.framework/Versions/A/Network",
    "/System/Library/Frameworks/Network.framework/Versions/Current/Network",
    "/System/Library/Frameworks/Network.framework/Network",
}
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
FORBIDDEN_NETWORK_SYMBOL_PATTERN = re.compile(
    r"(?:CFNetwork|NSURLSession|URLSession(?:Configuration|Task|DataTask|DownloadTask|UploadTask|StreamTask|WebSocketTask)?)"
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


def _minimum_macos(otool_output: str) -> str:
    lines = iter(otool_output.splitlines())
    for line in lines:
        if line.split() == ["cmd", "LC_BUILD_VERSION"]:
            for build_line in lines:
                fields = build_line.split()
                if fields[:1] == ["minos"]:
                    return fields[1]
                if fields[:1] == ["cmd"]:
                    break
    raise AssertionError("LC_BUILD_VERSION minos was not found")


def _is_canonical_system_install_name(install_name: str) -> bool:
    relative_path = ""
    for prefix in SYSTEM_LIBRARY_PREFIXES:
        if install_name.startswith(prefix):
            relative_path = install_name.removeprefix(prefix)
            break
    if not relative_path or "//" in install_name or install_name.endswith("/"):
        return False
    return all(component not in {"", ".", ".."} for component in relative_path.split("/"))


def _is_forbidden_network_install_name(install_name: str) -> bool:
    if not _is_canonical_system_install_name(install_name):
        return False
    framework_root = "/System/Library/Frameworks/"
    if not install_name.startswith(framework_root):
        return False
    components = install_name.removeprefix(framework_root).split("/")
    return (
        len(components) >= 2
        and (components[0], components[-1])
        in {
            ("CFNetwork.framework", "CFNetwork"),
            ("Network.framework", "Network"),
        }
    )


def _assert_allowed_install_names(
    install_names: list[str], *, allow_system_network: bool = False
) -> None:
    unexpected = [
        install_name
        for install_name in install_names
        if not _is_canonical_system_install_name(install_name)
        and install_name != COMPATIBILITY_SPAN_INSTALL_NAME
    ]
    assert not unexpected, f"unapproved dylib install names: {unexpected}"
    network_libraries = [
        install_name
        for install_name in install_names
        if _is_forbidden_network_install_name(install_name)
    ]
    assert allow_system_network or not network_libraries, (
        f"network libraries are forbidden in local-only release artifacts: {network_libraries}"
    )


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


def _assert_no_forbidden_network_symbols(symbols_output: str, binary: Path) -> None:
    matches = sorted(set(FORBIDDEN_NETWORK_SYMBOL_PATTERN.findall(symbols_output)))
    assert not matches, (
        f"release artifact contains forbidden network symbols: {binary}: {matches}"
    )


async def _negotiated_server_version(binary: Path) -> str:
    async with stdio_client(
        StdioServerParameters(command=str(binary), args=[])
    ) as (read, write):
        async with ClientSession(read, write) as session:
            initialized = await session.initialize()
            return initialized.serverInfo.version


async def _listed_tool_names(binary: Path) -> list[str]:
    async with stdio_client(
        StdioServerParameters(command=str(binary), args=[])
    ) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            listed = await session.list_tools()
            return [tool.name for tool in listed.tools]


def test_release_artifacts_are_native_standalone_executables() -> None:
    cli = ARTIFACTS / "localocr"
    mcp = ARTIFACTS / "localocr-mcp"

    for binary in (cli, mcp, BRIDGE):
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
    assert asyncio.run(_listed_tool_names(mcp)) == [
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

    bridge_request = json.dumps({
        "version": 1,
        "id": 77,
        "action": "status",
        "provider": "ollama",
        "model": None,
        "expectedIdentity": None,
        "operation": None,
        "prompt": None,
        "fields": [],
        "timeoutMilliseconds": 1000,
    }) + "\n"
    bridge_response = subprocess.run(
        [str(BRIDGE)],
        input=bridge_request,
        check=True,
        capture_output=True,
        text=True,
    )
    assert bridge_response.stderr == ""
    assert json.loads(bridge_response.stdout)["id"] == 77


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


def test_mcp_smoke_exchange_keeps_stdin_open_for_delayed_response(tmp_path: Path) -> None:
    delayed_server = tmp_path / "delayed-mcp"
    delayed_server.write_text(
        """#!/bin/bash
set -euo pipefail
IFS= read -r _
/bin/sleep 1.2
printf '{"jsonrpc":"2.0","id":1,"result":{}}\\n'
IFS= read -r _ || true
"""
    )
    delayed_server.chmod(0o755)

    result = subprocess.run(
        [
            str(MCP_SMOKE_EXCHANGE),
            "--timeout",
            "3",
            "--expect-id",
            "1",
            "--",
            str(delayed_server),
        ],
        input='{"jsonrpc":"2.0","id":1,"method":"initialize"}\n',
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout == '{"jsonrpc":"2.0","id":1,"result":{}}\n'
    assert result.stderr == ""


def test_release_artifacts_expose_only_system_dylibs_and_safe_rpaths() -> None:
    for binary in (ARTIFACTS / "localocr", ARTIFACTS / "localocr-mcp", BRIDGE):
        assert _minimum_macos(_run("otool", "-l", str(binary))) == "14.0"
        install_names = _install_names(_dependencies(binary))
        assert install_names
        _assert_allowed_install_names(
            install_names,
            allow_system_network=binary == BRIDGE,
        )
        if binary != BRIDGE:
            _assert_no_forbidden_network_symbols(_run("nm", "-u", str(binary)), binary)

        rpaths = _rpaths(_run("otool", "-l", str(binary)))
        _assert_allowed_rpaths(rpaths)
        if COMPATIBILITY_SPAN_INSTALL_NAME in install_names:
            assert SYSTEM_SWIFT_RPATH in rpaths
            # The real CLI/MCP executions in the preceding contract test verify
            # dynamic-loader resolution; macOS can serve this system library
            # from the shared cache without a conventional on-disk file.


def test_release_artifacts_do_not_ship_absolute_user_paths_or_dsyms() -> None:
    for binary in (ARTIFACTS / "localocr", ARTIFACTS / "localocr-mcp", BRIDGE):
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
/usr/lib/../tmp/evil.dylib (compatibility version 1.0.0, current version 1.0.0)
/System/Library/Frameworks/../PrivateFrameworks/Evil.framework/Evil (compatibility version 1.0.0, current version 1.0.0)
/usr/lib//evil.dylib (compatibility version 1.0.0, current version 1.0.0)
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
        assert "/usr/lib/../tmp/evil.dylib" in str(error)
        assert "/System/Library/Frameworks/../PrivateFrameworks" in str(error)
        assert "/usr/lib//evil.dylib" in str(error)
    else:
        raise AssertionError("malicious dylib paths were accepted")

    arbitrary_network_versions = {
        "/System/Library/Frameworks/CFNetwork.framework/Versions/Preview/CFNetwork",
        "/System/Library/Frameworks/Network.framework/Versions/42/Network",
    }
    for network_library in KNOWN_FORBIDDEN_NETWORK_INSTALL_NAMES | arbitrary_network_versions:
        try:
            _assert_allowed_install_names([network_library])
        except AssertionError as error:
            assert "network libraries are forbidden" in str(error)
        else:
            raise AssertionError(f"network library was accepted: {network_library}")

    try:
        _assert_allowed_rpaths(_rpaths(malicious_rpaths))
    except AssertionError as error:
        assert "/Applications/Xcode.app/Contents/Developer" in str(error)
        assert "/tmp/evil" in str(error)
    else:
        raise AssertionError("malicious RPATHs were accepted")


def test_release_artifact_policy_rejects_url_session_symbols() -> None:
    malicious_symbols = "\n".join(
        (
            "_OBJC_CLASS_$_NSURLSession",
            "_$s10Foundation10URLSessionC13ConfigurationV",
            "_NSURLSessionDataTask",
        )
    )

    try:
        _assert_no_forbidden_network_symbols(
            malicious_symbols,
            ARTIFACTS / "malicious-symbols",
        )
    except AssertionError as error:
        message = str(error)
        assert "NSURLSession" in message
        assert "URLSession" in message
    else:
        raise AssertionError("URL-session symbols were accepted")


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
