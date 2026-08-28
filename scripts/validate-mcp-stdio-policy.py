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
REVIEWED_LICENSE_SHA256 = "0382b0057770ca05e9c350a50aa3b1c1fea84da0bc81d723bf00b9aa841be58a"
REVIEWED_ORIGIN_INVENTORY_SHA256 = "dafbceaccc07c3b5a2dfe69f6386bc00ed68ffbb40a42391e90f45790c71f2fc"
REVIEWED_LOCAL_ONLY_PATHS = {"MCPStdio.swift", "Server/RequestRegistry.swift"}
XCODE_DEVELOPER_DIR = Path("/Applications/Xcode.app/Contents/Developer")
XCODE_SWIFTC = (
    XCODE_DEVELOPER_DIR
    / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
)
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
FORBIDDEN_VENDOR_PATH = re.compile(
    r"(?:^|/)(?:[^/]*Client[^/]*|Authorization|"
    r"[^/]*(?:HTTP|OAuth|EventSource|Network|Socket|WebSocket)[^/]*)(?:/|\.swift$)"
)
FORBIDDEN_NETWORK_SOURCE = (
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
    FORBIDDEN_NETWORK_SOURCE[6],
    FORBIDDEN_NETWORK_SOURCE[7],
)
FORBIDDEN_SWIFT_IMPORTS = {"CFNetwork", "Network", "FoundationNetworking"}
EXPECTED_PACKAGE_DEPENDENCIES = [
    {
        "sourceControl": [
            {
                "identity": "swift-argument-parser",
                "location": {
                    "remote": [
                        {"urlString": "https://github.com/apple/swift-argument-parser"}
                    ]
                },
                "productFilter": None,
                "requirement": {"exact": ["1.8.2"]},
                "traits": [{"name": "default"}],
            }
        ]
    },
    {
        "sourceControl": [
            {
                "identity": "swift-system",
                "location": {
                    "remote": [
                        {"urlString": "https://github.com/apple/swift-system.git"}
                    ]
                },
                "productFilter": None,
                "requirement": {
                    "range": [{"lowerBound": "1.0.0", "upperBound": "2.0.0"}]
                },
                "traits": [{"name": "default"}],
            }
        ]
    },
    {
        "sourceControl": [
            {
                "identity": "swift-log",
                "location": {
                    "remote": [
                        {"urlString": "https://github.com/apple/swift-log.git"}
                    ]
                },
                "productFilter": None,
                "requirement": {
                    "range": [{"lowerBound": "1.5.0", "upperBound": "2.0.0"}]
                },
                "traits": [{"name": "default"}],
            }
        ]
    },
]
APPROVED_MCP_STDIO_PRODUCTS = {
    ("SystemPackage", "swift-system"),
    ("Logging", "swift-log"),
}
EXPECTED_TARGET_DEPENDENCIES = {
    "LocalOCRCore": (),
    "LocalOCRService": (("target", "LocalOCRCore"),),
    "LocalOCRIntelligence": (("target", "LocalOCRService"),),
    "LocalOCRStudioKit": (
        ("target", "LocalOCRIntelligence"),
        ("target", "LocalOCRService"),
        ("target", "LocalOCRCore"),
    ),
    "LocalOCRCommandKit": (
        ("target", "LocalOCRIntelligence"),
        ("target", "LocalOCRService"),
        ("product", "ArgumentParser", "swift-argument-parser"),
    ),
    "MCPStdio": (
        ("product", "SystemPackage", "swift-system"),
        ("product", "Logging", "swift-log"),
    ),
    "LocalOCRMCP": (
        ("target", "LocalOCRIntelligence"),
        ("target", "LocalOCRService"),
        ("target", "MCPStdio"),
    ),
    "LocalOCRCLIExecutable": (("target", "LocalOCRCommandKit"),),
    "LocalOCRMCPExecutable": (("target", "LocalOCRMCP"),),
    "LocalOCRCoreTests": (("target", "LocalOCRCore"),),
    "LocalOCRServiceTests": (("target", "LocalOCRService"),),
    "LocalOCRStudioKitTests": (
        ("target", "LocalOCRStudioKit"),
        ("target", "LocalOCRService"),
        ("target", "LocalOCRCore"),
    ),
    "LocalOCRCommandKitTests": (("target", "LocalOCRCommandKit"),),
    "LocalOCRMCPTests": (
        ("target", "LocalOCRMCP"),
        ("target", "LocalOCRService"),
        ("target", "LocalOCRCore"),
        ("target", "MCPStdio"),
    ),
    "MCPStdioTests": (("target", "MCPStdio"),),
    "LocalOCRIntelligenceTests": (
        ("target", "LocalOCRIntelligence"),
        ("target", "LocalOCRService"),
        ("target", "LocalOCRCore"),
    ),
}
EXPECTED_TARGET_TYPES = {
    name: (
        "executable"
        if name in {"LocalOCRCLIExecutable", "LocalOCRMCPExecutable"}
        else "test"
        if name.endswith("Tests")
        else "regular"
    )
    for name in EXPECTED_TARGET_DEPENDENCIES
}
EXPECTED_TARGET_SETTINGS = [
    {
        "kind": {"enableUpcomingFeature": {"_0": "StrictConcurrency"}},
        "tool": "swift",
    }
]
EXPECTED_RESOLVED_ORIGIN_HASH = "e70a6db1047b5f47cbfc6632ad66bb3063a23696616bd25aca75b3d59d4e6505"
EXPECTED_RESOLVED_PINS = {
    "swift-argument-parser": {
        "identity": "swift-argument-parser",
        "kind": "remoteSourceControl",
        "location": "https://github.com/apple/swift-argument-parser",
        "state": {
            "revision": "6a52f3251125d74daf04fcbd5e6f08a75d074382",
            "version": "1.8.2",
        },
    },
    "swift-log": {
        "identity": "swift-log",
        "kind": "remoteSourceControl",
        "location": "https://github.com/apple/swift-log.git",
        "state": {
            "revision": "a878e7f8f46cfc0e1125e565b5c08e7d5272dc9a",
            "version": "1.14.0",
        },
    },
    "swift-system": {
        "identity": "swift-system",
        "kind": "remoteSourceControl",
        "location": "https://github.com/apple/swift-system.git",
        "state": {
            "revision": "50688cacbd41d547e9eb9f7a213542340b7c442b",
            "version": "1.7.5",
        },
    },
}
SWIFT_IMPORT_PATTERN = re.compile(
    r"\bimport\b\s*(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?"
    r"([A-Za-z_][A-Za-z0-9_]*)"
)
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


def mask_swift_comments_strings_and_escaped_identifiers(source: str) -> str:
    masked = list(source)
    index = 0
    length = len(source)
    while index < length:
        if source.startswith("//", index):
            end = source.find("\n", index + 2)
            end = length if end == -1 else end
        elif source.startswith("/*", index):
            depth = 1
            cursor = index + 2
            while cursor < length and depth:
                if source.startswith("/*", cursor):
                    depth += 1
                    cursor += 2
                elif source.startswith("*/", cursor):
                    depth -= 1
                    cursor += 2
                else:
                    cursor += 1
            end = cursor
        elif source[index] == "`":
            closing = source.find("`", index + 1)
            end = length if closing == -1 else closing + 1
        else:
            hash_count = 0
            while index + hash_count < length and source[index + hash_count] == "#":
                hash_count += 1
            quote_start = index + hash_count
            if quote_start >= length or source[quote_start] != '"':
                index += 1
                continue
            quote_count = 3 if source.startswith('"""', quote_start) else 1
            closing = ('"' * quote_count) + ('#' * hash_count)
            cursor = quote_start + quote_count
            while cursor < length:
                found = source.find(closing, cursor)
                if found == -1:
                    cursor = length
                    break
                if hash_count or found == 0 or source[found - 1] != "\\":
                    cursor = found + len(closing)
                    break
                cursor = found + 1
            end = cursor
        for position in range(index, end):
            if masked[position] != "\n":
                masked[position] = " "
        index = max(end, index + 1)
    return "".join(masked)


def validate_swift_parse_and_imports(source_paths: list[Path]) -> None:
    require(source_paths, "shipping Swift source set is empty")
    require(
        XCODE_SWIFTC.exists()
        and XCODE_SWIFTC.resolve(strict=True).is_file()
        and XCODE_SWIFTC.resolve(strict=True).is_relative_to(XCODE_DEVELOPER_DIR),
        f"stable Xcode Swift parser is unavailable: {XCODE_SWIFTC}",
    )
    swift_environment = os.environ.copy()
    swift_environment["DEVELOPER_DIR"] = str(XCODE_DEVELOPER_DIR)
    swift_environment.pop("SDKROOT", None)
    for source_path in source_paths:
        require(
            source_path.is_file() and not source_path.is_symlink(),
            f"shipping source must be a physical file: {source_path}",
        )
        result = subprocess.run(
            [
                str(XCODE_SWIFTC),
                "-frontend",
                "-parse",
                "-enable-bare-slash-regex",
                str(source_path),
            ],
            check=False,
            capture_output=True,
            text=True,
            env=swift_environment,
        )
        require(
            result.returncode == 0,
            f"Swift parser rejected shipping source {source_path}: "
            f"{result.stderr.strip()}",
        )
        masked_source = mask_swift_comments_strings_and_escaped_identifiers(
            source_path.read_text()
        )
        import_nodes = re.findall(r"\bimport\b", masked_source)
        imported_modules = SWIFT_IMPORT_PATTERN.findall(masked_source)
        require(
            len(imported_modules) == len(import_nodes),
            f"Swift import parser returned an unrecognized declaration: {source_path}",
        )
        forbidden_imports = sorted(
            module
            for module in imported_modules
            if module.split(".", 1)[0] in FORBIDDEN_SWIFT_IMPORTS
        )
        require(
            not forbidden_imports,
            f"forbidden Swift import in {source_path}: {forbidden_imports}",
        )


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
    require(
        sha256(inventory_path) == REVIEWED_ORIGIN_INVENTORY_SHA256,
        "reviewed origin inventory digest changed",
    )
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
    local_only_paths: set[str] = set()
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
            local_only_paths.add(path)
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
        local_only_paths == REVIEWED_LOCAL_ONLY_PATHS,
        f"local-only source path set changed: {sorted(local_only_paths)}",
    )

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
    require(
        sha256(license_path) == REVIEWED_LICENSE_SHA256,
        "reviewed license digest changed",
    )
    provenance = provenance_path.read_text()
    for required_text in (UPSTREAM_REPOSITORY, UPSTREAM_RELEASE, UPSTREAM_COMMIT, "MCPStdio"):
        require(required_text in provenance, f"provenance is missing {required_text!r}")

    vendored_sources = [vendor / path for path in sorted(entries)]
    validate_swift_parse_and_imports(vendored_sources)
    for relative_path in entries:
        require(FORBIDDEN_VENDOR_PATH.search(relative_path) is None, f"forbidden vendored path: {relative_path}")
        source = (vendor / relative_path).read_text()
        for pattern in (*FORBIDDEN_NETWORK_SOURCE, *FORBIDDEN_VENDOR_CLIENT_DECLARATION):
            require(pattern.search(source) is None, f"forbidden source API in {relative_path}: {pattern.pattern}")


def normalized_target_dependency(entry: object) -> tuple[str, ...]:
    require(isinstance(entry, dict) and len(entry) == 1, "invalid target dependency")
    if "byName" in entry:
        value = entry["byName"]
        require(
            isinstance(value, list)
            and len(value) == 2
            and isinstance(value[0], str)
            and value[1] is None,
            "conditional or malformed target dependency is forbidden",
        )
        return ("target", value[0])
    if "product" in entry:
        value = entry["product"]
        require(
            isinstance(value, list)
            and len(value) == 4
            and isinstance(value[0], str)
            and isinstance(value[1], str)
            and value[2:] == [None, None],
            "conditional or malformed package product dependency is forbidden",
        )
        return ("product", value[0], value[1])
    raise PolicyError(f"unsupported target dependency kind: {sorted(entry)}")


def validate_package_policy(repo_root: Path) -> None:
    package_path = repo_root / "Package.swift"
    resolved_path = repo_root / "Package.resolved"
    require(package_path.is_file() and not package_path.is_symlink(), "Package.swift is missing or symlinked")
    require(resolved_path.is_file() and not resolved_path.is_symlink(), "Package.resolved is missing or symlinked")

    swift_environment = os.environ.copy()
    swift_environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    swift_environment.pop("SDKROOT", None)
    result = subprocess.run(
        [
            "/usr/bin/xcrun",
            "--toolchain",
            "XcodeDefault.xctoolchain",
            "swift",
            "package",
            "dump-package",
        ],
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

    dependencies = package.get("dependencies")
    require(
        dependencies == EXPECTED_PACKAGE_DEPENDENCIES,
        "package dependency records changed",
    )

    targets = package.get("targets")
    require(isinstance(targets, list), "Swift package targets are missing")
    target_by_name = {
        target.get("name"): target for target in targets if isinstance(target, dict)
    }
    require(
        set(target_by_name) == set(EXPECTED_TARGET_DEPENDENCIES),
        f"target policy changed: {sorted(target_by_name)}",
    )
    for target_name, expected_dependencies in EXPECTED_TARGET_DEPENDENCIES.items():
        target = target_by_name[target_name]
        actual_dependencies = tuple(
            normalized_target_dependency(dependency)
            for dependency in target.get("dependencies", [])
        )
        require(
            actual_dependencies == expected_dependencies,
            f"target policy changed: dependencies for {target_name}: {actual_dependencies}",
        )
        require(
            target.get("type") == EXPECTED_TARGET_TYPES[target_name],
            f"target policy changed: type for {target_name}",
        )
        require(
            target.get("settings") == EXPECTED_TARGET_SETTINGS,
            f"target policy changed: build settings for {target_name}",
        )
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
    require(
        isinstance(resolved, dict)
        and set(resolved) == {"originHash", "pins", "version"}
        and resolved.get("version") == 3
        and resolved.get("originHash") == EXPECTED_RESOLVED_ORIGIN_HASH,
        "Package.resolved schema or origin hash changed",
    )
    pins = resolved.get("pins")
    require(isinstance(pins, list), "Package.resolved pins are missing")
    require(all(isinstance(pin, dict) for pin in pins), "Package.resolved pin is invalid")
    resolved_by_identity = {pin.get("identity"): pin for pin in pins}
    require(
        len(resolved_by_identity) == len(pins)
        and resolved_by_identity == EXPECTED_RESOLVED_PINS,
        f"resolved package pin state changed: {sorted(resolved_by_identity)}",
    )

    shipping_sources = sorted((repo_root / "App").glob("**/*.swift")) + sorted(
        (repo_root / "Sources").glob("**/*.swift")
    )
    validate_swift_parse_and_imports(shipping_sources)
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
