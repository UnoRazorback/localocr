#!/usr/bin/env python3
"""Emit deterministic evidence for the shipped model bridge's local-only policy."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse


ALLOWED_URLS = {
    "http://127.0.0.1:11434/api/version",
    "http://127.0.0.1:11434/api/tags",
    "http://127.0.0.1:11434/api/chat",
    "http://127.0.0.1:1234/api/v1/models",
    "http://127.0.0.1:1234/api/v1/chat",
    "http://[::1]:11434/api/version",
    "http://[::1]:11434/api/tags",
    "http://[::1]:11434/api/chat",
    "http://[::1]:1234/api/v1/models",
    "http://[::1]:1234/api/v1/chat",
}
SOURCE_REQUIREMENTS = {
    "ephemeral session": "URLSessionConfiguration.ephemeral",
    "proxy environment disabled": "configuration.connectionProxyDictionary = [:]",
    "credential storage disabled": "configuration.urlCredentialStorage = nil",
    "cookies disabled": "configuration.httpCookieStorage = nil",
    "cache disabled": "configuration.urlCache = nil",
    "connectivity waiting disabled": "configuration.waitsForConnectivity = false",
    "bounded response constant": (
        "public static let maximumResponseBytes = ModelBridgeLimits.maximumMessageBytes"
    ),
    "bounded streaming read": "guard data.count < maximumResponseBytes else",
    "redirect rejected": "completionHandler(nil)",
    "authentication rejected": "completionHandler(.cancelAuthenticationChallenge, nil)",
    "response origin checked": (
        "response.url == endpoint.ipv4URL || response.url == endpoint.ipv6URL"
    ),
}
URL_PATTERN = re.compile(r"https?://(?:\[[^\]]+\]|[^/\s\"']+)[^\s\"']*")


def _command(*arguments: str) -> str:
    return subprocess.run(
        arguments,
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def _canonical_system_install_name(value: str) -> bool:
    prefixes = ("/System/Library/", "/usr/lib/")
    relative = next((value.removeprefix(prefix) for prefix in prefixes if value.startswith(prefix)), "")
    return bool(relative) and "//" not in value and all(
        component not in {"", ".", ".."} for component in relative.split("/")
    )


def _binary_evidence(binary: Path, failures: list[str]) -> dict[str, object]:
    evidence: dict[str, object] = {"path": str(binary)}
    if not binary.is_file() or binary.is_symlink():
        failures.append("binary must be a physical regular file")
        return evidence
    try:
        description = _command("/usr/bin/file", "-b", str(binary)).strip()
        evidence["file"] = description
        if "Mach-O 64-bit executable arm64" not in description:
            failures.append("binary is not an arm64 Mach-O executable")

        dependency_lines = _command("/usr/bin/otool", "-L", str(binary)).splitlines()[1:]
        install_names = [line.strip().split(" ", 1)[0] for line in dependency_lines if line.strip()]
        evidence["install_names"] = install_names
        unexpected = [
            value
            for value in install_names
            if value != "@rpath/libswiftCompatibilitySpan.dylib"
            and not _canonical_system_install_name(value)
        ]
        if unexpected:
            failures.append(f"binary has non-system dependencies: {unexpected}")

        load_commands = _command("/usr/bin/otool", "-l", str(binary))
        rpaths = re.findall(
            r"\bcmd LC_RPATH\s+cmdsize \d+\s+path ([^\s]+) \(offset \d+\)",
            load_commands,
        )
        evidence["rpaths"] = rpaths
        if any(path != "/usr/lib/swift" for path in rpaths):
            failures.append(f"binary has an unapproved RPATH: {rpaths}")

        string_output = _command("/usr/bin/strings", str(binary))
        binary_urls = sorted(set(URL_PATTERN.findall(string_output)))
        evidence["embedded_urls"] = binary_urls
        unexpected_urls = sorted(set(binary_urls) - ALLOWED_URLS)
        if unexpected_urls:
            failures.append(f"binary embeds unapproved URLs: {unexpected_urls}")
        for private_fragment in ("/Applications/Xcode", "/Users/"):
            if private_fragment in string_output:
                failures.append(f"binary embeds private build path fragment: {private_fragment}")
    except (OSError, subprocess.CalledProcessError) as error:
        failures.append(f"binary inspection failed: {error}")
    return evidence


def validate(source_root: Path, binary: Path | None) -> tuple[int, dict[str, object]]:
    failures: list[str] = []
    source_file = (
        source_root
        / "Sources"
        / "LocalOCRModelBridgeKit"
        / "LoopbackHTTPClient.swift"
    )
    if not source_file.is_file() or source_file.is_symlink():
        failures.append("LoopbackHTTPClient.swift is missing or symlinked")
        source = ""
    else:
        source = source_file.read_text()

    source_urls = sorted(set(URL_PATTERN.findall(source)))
    if set(source_urls) != ALLOWED_URLS:
        failures.append(
            "source URL inventory differs from the approved Ollama and LM Studio loopback routes"
        )
    parsed_hosts = sorted({urlparse(value).hostname for value in source_urls if urlparse(value).hostname})
    if parsed_hosts != ["127.0.0.1", "::1"]:
        failures.append(f"source contains a non-loopback or wildcard host: {parsed_hosts}")

    for label, fragment in SOURCE_REQUIREMENTS.items():
        if fragment not in source:
            failures.append(f"missing policy control: {label}")

    binary_evidence = _binary_evidence(binary, failures) if binary is not None else None
    evidence: dict[str, object] = {
        "status": "fail" if failures else "pass",
        "source": str(source_file),
        "allowed_hosts": ["127.0.0.1", "::1"],
        "allowed_urls": sorted(ALLOWED_URLS),
        "redirects": "rejected",
        "proxy_environment": "disabled",
        "maximum_response_bytes": 1_048_576,
        "binary": binary_evidence,
        "failures": failures,
    }
    return (1 if failures else 0), evidence


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--binary", type=Path)
    arguments = parser.parse_args()
    status, evidence = validate(arguments.source_root.resolve(), arguments.binary)
    print(json.dumps(evidence, indent=2, sort_keys=True))
    return status


if __name__ == "__main__":
    sys.exit(main())
