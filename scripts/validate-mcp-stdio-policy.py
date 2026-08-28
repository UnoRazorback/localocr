#!/usr/bin/env python3
"""Fail-closed source and Swift-package policy for LocalOCR's MCPStdio boundary."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


UPSTREAM_COMMIT = "a0ae212ebf6eab5f754c3129608bc5557637e605"
UPSTREAM_REPOSITORY = "https://github.com/modelcontextprotocol/swift-sdk"
UPSTREAM_RELEASE = "0.12.1"
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
FORBIDDEN_VENDOR_PATH = re.compile(
    r"(?:^|/)(?:[^/]*Client[^/]*|Authorization|"
    r"[^/]*(?:HTTP|OAuth|EventSource|Network|Socket|WebSocket)[^/]*)(?:/|\.swift$)"
)
FORBIDDEN_NETWORK_SOURCE = (
    re.compile(r"(?m)^\s*import\s+(?:CFNetwork|Network|FoundationNetworking)\b"),
    re.compile(
        r"\b(?:URLSession(?:Configuration|Task|DataTask|DownloadTask|UploadTask|"
        r"StreamTask|WebSocketTask)?|URLRequest|URLResponse|HTTPURLResponse|"
        r"URLProtocol|URLAuthenticationChallenge|EventSource)\b"
    ),
    re.compile(r"\b(?:Data|NSData|String|NSString)(?:\s*\.\s*init)?\s*\(\s*contentsOf\s*:"),
    re.compile(r"\bURL\s*\.\s*openConnection\s*\("),
    re.compile(r"\bNS(?:MutableURLRequest|URLRequest|URLConnection|URLSession)\b"),
    re.compile(r"\bOAuth[A-Za-z0-9_]*\b"),
    re.compile(r"\bHTTP[A-Za-z0-9_]*\b"),
    re.compile(r"\b(?:NWConnection|NWListener|NWTCPConnection|CFNetwork)\b"),
    re.compile(r"\b(?:socket|Socket)[A-Za-z0-9_]*\b"),
)
FORBIDDEN_VENDOR_CLIENT_DECLARATION = (
    re.compile(
        r"\b(?:actor|class|struct|enum|protocol)\s+"
        r"(?!Client(?:Info|Capabilities)\b)[A-Za-z_][A-Za-z0-9_]*Client[A-Za-z0-9_]*\b"
    ),
    re.compile(r"\b(?:actor|class|struct|enum|protocol)\s+Client\b"),
)
FORBIDDEN_SHIPPING_NETWORK_SOURCE = (
    FORBIDDEN_NETWORK_SOURCE[0],
    FORBIDDEN_NETWORK_SOURCE[1],
    FORBIDDEN_NETWORK_SOURCE[7],
    FORBIDDEN_NETWORK_SOURCE[8],
)
APPROVED_REMOTE_PACKAGES = {
    "swift-argument-parser": "https://github.com/apple/swift-argument-parser",
    "swift-system": "https://github.com/apple/swift-system.git",
    "swift-log": "https://github.com/apple/swift-log.git",
}
APPROVED_MCP_STDIO_PRODUCTS = {
    ("SystemPackage", "swift-system"),
    ("Logging", "swift-log"),
}
REQUIRED_UPSTREAM_RECORDS = {
    "LICENSE",
    "PROVENANCE.md",
    "manifest.json",
    "origin-inventory.json",
}


class PolicyError(Exception):
    """Raised when the closed MCP source/package policy does not hold."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise PolicyError(message)


def load_json(path: Path) -> Any:
    require(path.is_file() and not path.is_symlink(), f"missing or symlinked record: {path}")
    try:
        return json.loads(path.read_text())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PolicyError(f"invalid JSON record: {path}: {error}") from error


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def is_sha256(value: object) -> bool:
    return isinstance(value, str) and SHA256_PATTERN.fullmatch(value) is not None


def normalized_relative_swift_path(value: object) -> bool:
    if not isinstance(value, str) or not value.endswith(".swift"):
        return False
    path = Path(value)
    return (
        value == path.as_posix()
        and not path.is_absolute()
        and all(component not in {"", ".", ".."} for component in path.parts)
    )


def validate_origin_inventory(vendor: Path) -> dict[str, str]:
    inventory_path = vendor / "Upstream" / "origin-inventory.json"
    inventory = load_json(inventory_path)
    require(
        isinstance(inventory, dict)
        and set(inventory) == {"schema_version", "upstream", "files"},
        "origin inventory schema changed",
    )
    require(inventory["schema_version"] == 1, "origin inventory schema version changed")
    require(
        inventory["upstream"]
        == {
            "repository": UPSTREAM_REPOSITORY,
            "release": UPSTREAM_RELEASE,
            "commit": UPSTREAM_COMMIT,
        },
        "origin inventory upstream identity changed",
    )
    require(isinstance(inventory["files"], list), "origin inventory files must be a list")

    hashes: dict[str, str] = {}
    for entry in inventory["files"]:
        require(
            isinstance(entry, dict) and set(entry) == {"path", "sha256"},
            "origin inventory file schema changed",
        )
        path = entry["path"]
        digest = entry["sha256"]
        require(
            normalized_relative_swift_path(path) and path.startswith("Sources/MCP/"),
            f"invalid origin inventory path: {path!r}",
        )
        require(is_sha256(digest), f"invalid origin inventory hash: {path}")
        require(path not in hashes, f"duplicate origin inventory path: {path}")
        hashes[path] = digest
    require(hashes, "origin inventory is empty")
    return hashes


def validate_vendor(repo_root: Path) -> None:
    vendor = repo_root / "Sources" / "MCPStdio"
    require(vendor.is_dir() and not vendor.is_symlink(), "MCPStdio vendor directory is missing or symlinked")
    manifest_path = vendor / "Upstream" / "manifest.json"
    manifest = load_json(manifest_path)
    require(
        isinstance(manifest, dict)
        and set(manifest) == {"schema_version", "upstream", "files", "adaptations"},
        "vendor manifest schema changed",
    )
    require(manifest["schema_version"] == 1, "vendor manifest schema version changed")

    upstream = manifest["upstream"]
    require(
        isinstance(upstream, dict)
        and set(upstream)
        == {
            "repository",
            "release",
            "commit",
            "retrieved_on",
            "selection_rule",
            "exclusions",
            "hash_command",
            "provisional_dependencies",
        },
        "vendor upstream metadata schema changed",
    )
    require(upstream["repository"] == UPSTREAM_REPOSITORY, "upstream repository changed")
    require(upstream["release"] == UPSTREAM_RELEASE, "upstream release changed")
    require(upstream["commit"] == UPSTREAM_COMMIT, "upstream commit changed")
    require(upstream["retrieved_on"] == "2026-08-27", "upstream retrieval date changed")
    require(upstream["hash_command"] == "shasum -a 256 <file>", "hash procedure changed")
    require(
        isinstance(upstream["selection_rule"], str) and upstream["selection_rule"].strip(),
        "selection rule is missing",
    )
    require(
        upstream["exclusions"]
        == ["client", "HTTP", "OAuth", "EventSource", "URLSession", "socket", "Network", "CFNetwork"],
        "network/client exclusion list changed",
    )
    require(
        upstream["provisional_dependencies"] == ["swift-system", "swift-log"],
        "audited MCPStdio dependency declaration changed",
    )

    origin_hashes = validate_origin_inventory(vendor)
    files = manifest["files"]
    adaptations = manifest["adaptations"]
    require(isinstance(files, list) and files, "vendor file manifest is empty")
    require(isinstance(adaptations, list), "adaptations must be a list")

    adaptations_by_path: dict[str, dict[str, object]] = {}
    for adaptation in adaptations:
        require(
            isinstance(adaptation, dict) and set(adaptation) == {"path", "reason"},
            "adaptation schema changed",
        )
        path = adaptation["path"]
        reason = adaptation["reason"]
        require(normalized_relative_swift_path(path), f"invalid adaptation path: {path!r}")
        require(isinstance(reason, str) and reason.strip(), f"blank adaptation reason: {path}")
        require(path not in adaptations_by_path, f"duplicate adaptation path: {path}")
        adaptations_by_path[path] = adaptation

    entries: dict[str, dict[str, object]] = {}
    required_adaptations: set[str] = set()
    for entry in files:
        require(isinstance(entry, dict), "vendor file entry must be an object")
        path = entry.get("path")
        require(normalized_relative_swift_path(path), f"invalid vendored path: {path!r}")
        assert isinstance(path, str)
        require(path not in entries, f"duplicate vendored path: {path}")
        local_path = vendor / path
        require(local_path.is_file() and not local_path.is_symlink(), f"missing or symlinked vendored source: {path}")
        require(is_sha256(entry.get("local_sha256")), f"invalid local source hash: {path}")
        require(entry["local_sha256"] == sha256(local_path), f"local source hash mismatch: {path}")

        if "local_only" in entry:
            require(
                set(entry) == {"path", "local_only", "local_sha256"}
                and entry["local_only"] is True,
                f"invalid local-only source entry: {path}",
            )
        else:
            require(
                set(entry) == {"path", "origin", "upstream_sha256", "local_sha256"},
                f"derived source entry schema changed: {path}",
            )
            origin = entry["origin"]
            require(
                isinstance(origin, str) and origin in origin_hashes,
                f"unknown derived source origin: {path}",
            )
            require(
                entry["upstream_sha256"] == origin_hashes[origin],
                f"upstream source hash mismatch: {path}",
            )
            if entry["local_sha256"] != entry["upstream_sha256"]:
                required_adaptations.add(path)
        entries[path] = entry

    require(
        required_adaptations <= set(adaptations_by_path),
        f"missing adaptation records: {sorted(required_adaptations - set(adaptations_by_path))}",
    )
    require(
        set(adaptations_by_path) <= set(entries),
        f"adaptations reference unlisted source: {sorted(set(adaptations_by_path) - set(entries))}",
    )

    expected_files = set(entries) | {f"Upstream/{name}" for name in REQUIRED_UPSTREAM_RECORDS}
    actual_files: set[str] = set()
    for candidate in vendor.rglob("*"):
        require(not candidate.is_symlink(), f"symlink is forbidden in vendored tree: {candidate}")
        if candidate.is_file():
            actual_files.add(candidate.relative_to(vendor).as_posix())
    require(
        actual_files == expected_files,
        f"closed vendored file set changed; extra={sorted(actual_files - expected_files)} "
        f"missing={sorted(expected_files - actual_files)}",
    )

    license_path = vendor / "Upstream" / "LICENSE"
    provenance_path = vendor / "Upstream" / "PROVENANCE.md"
    require(license_path.stat().st_size > 0, "upstream license is empty")
    provenance = provenance_path.read_text()
    for required_text in (UPSTREAM_REPOSITORY, UPSTREAM_RELEASE, UPSTREAM_COMMIT, "MCPStdio"):
        require(required_text in provenance, f"provenance is missing {required_text!r}")

    for relative_path in entries:
        require(FORBIDDEN_VENDOR_PATH.search(relative_path) is None, f"forbidden vendored path: {relative_path}")
        source = (vendor / relative_path).read_text()
        for pattern in (*FORBIDDEN_NETWORK_SOURCE, *FORBIDDEN_VENDOR_CLIENT_DECLARATION):
            require(pattern.search(source) is None, f"forbidden source API in {relative_path}: {pattern.pattern}")


def package_dependency_identity(entry: object) -> tuple[str, str]:
    require(isinstance(entry, dict) and set(entry) == {"sourceControl"}, "non-source-control package dependency is forbidden")
    source_control = entry["sourceControl"]
    require(isinstance(source_control, list) and len(source_control) == 1, "invalid source-control dependency")
    record = source_control[0]
    require(isinstance(record, dict), "invalid source-control dependency record")
    identity = record.get("identity")
    location = record.get("location")
    require(isinstance(identity, str) and isinstance(location, dict), "package identity/location is missing")
    remote = location.get("remote")
    require(isinstance(remote, list) and len(remote) == 1, "package dependency must use one remote URL")
    url = remote[0].get("urlString") if isinstance(remote[0], dict) else None
    require(isinstance(url, str), "package dependency remote URL is missing")
    return identity, url


def validate_package_policy(repo_root: Path) -> None:
    package_path = repo_root / "Package.swift"
    resolved_path = repo_root / "Package.resolved"
    require(package_path.is_file() and not package_path.is_symlink(), "Package.swift is missing or symlinked")
    require(resolved_path.is_file() and not resolved_path.is_symlink(), "Package.resolved is missing or symlinked")

    swift_environment = os.environ.copy()
    swift_environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    swift_environment.pop("SDKROOT", None)
    result = subprocess.run(
        ["/usr/bin/xcrun", "swift", "package", "dump-package"],
        cwd=repo_root,
        check=False,
        capture_output=True,
        text=True,
        env=swift_environment,
    )
    require(result.returncode == 0, f"Swift package manifest could not be evaluated: {result.stderr.strip()}")
    try:
        package = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise PolicyError(f"Swift package dump was not JSON: {error}") from error

    dependency_pairs = {package_dependency_identity(entry) for entry in package.get("dependencies", [])}
    require(
        dependency_pairs == set(APPROVED_REMOTE_PACKAGES.items()),
        f"remote package dependency set changed: {sorted(dependency_pairs)}",
    )

    targets = package.get("targets")
    require(isinstance(targets, list), "Swift package targets are missing")
    target_by_name = {
        target.get("name"): target for target in targets if isinstance(target, dict)
    }
    require("MCPStdio" in target_by_name, "MCPStdio target is missing")
    require(target_by_name["MCPStdio"].get("exclude") == ["Upstream"], "MCPStdio must exclude Upstream records")

    mcp_product_edges: list[tuple[str, str]] = []
    for target in targets:
        require(isinstance(target, dict), "invalid Swift target record")
        for dependency in target.get("dependencies", []):
            if isinstance(dependency, dict) and "product" in dependency:
                product = dependency["product"]
                if isinstance(product, list) and len(product) >= 2 and product[0] == "MCP":
                    mcp_product_edges.append((str(target.get("name")), str(product[1])))
    require(not mcp_product_edges, f"remote/forked MCP package product edges are forbidden: {mcp_product_edges}")

    mcp_products = {
        (dependency["product"][0], dependency["product"][1])
        for dependency in target_by_name["MCPStdio"].get("dependencies", [])
        if isinstance(dependency, dict)
        and isinstance(dependency.get("product"), list)
        and len(dependency["product"]) >= 2
    }
    require(
        mcp_products == APPROVED_MCP_STDIO_PRODUCTS,
        f"MCPStdio package product dependencies changed: {sorted(mcp_products)}",
    )

    resolved = load_json(resolved_path)
    require(isinstance(resolved, dict) and resolved.get("version") == 3, "Package.resolved schema changed")
    pins = resolved.get("pins")
    require(isinstance(pins, list), "Package.resolved pins are missing")
    resolved_pairs = {
        (pin.get("identity"), pin.get("location"))
        for pin in pins
        if isinstance(pin, dict)
    }
    require(
        resolved_pairs == set(APPROVED_REMOTE_PACKAGES.items()),
        f"resolved package dependency set changed: {sorted(resolved_pairs)}",
    )

    shipping_sources = sorted((repo_root / "App").glob("**/*.swift")) + sorted(
        (repo_root / "Sources").glob("**/*.swift")
    )
    require(shipping_sources, "shipping Swift source set is empty")
    for source_path in shipping_sources:
        require(not source_path.is_symlink(), f"shipping source must not be symlinked: {source_path}")
        source = source_path.read_text()
        for pattern in FORBIDDEN_SHIPPING_NETWORK_SOURCE:
            require(
                pattern.search(source) is None,
                f"forbidden network API in shipping source {source_path.relative_to(repo_root)}: {pattern.pattern}",
            )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--vendor-only", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        repo_root = arguments.repo_root.resolve(strict=True)
        validate_vendor(repo_root)
        if not arguments.vendor_only:
            validate_package_policy(repo_root)
    except (OSError, UnicodeDecodeError, PolicyError) as error:
        print(f"MCP stdio source policy rejected: {error}", file=sys.stderr)
        return 1
    print("MCP stdio source policy: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
