"""Closed provenance contract for the staged MCPStdio vendor target."""

from __future__ import annotations

import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
VENDOR = ROOT / "Sources" / "MCPStdio"
MANIFEST = VENDOR / "Upstream" / "manifest.json"
LICENSE = VENDOR / "Upstream" / "LICENSE"
PROVENANCE = VENDOR / "Upstream" / "PROVENANCE.md"
POLICY_VALIDATOR = ROOT / "scripts" / "validate-mcp-stdio-policy.py"
UPSTREAM_COMMIT = "a0ae212ebf6eab5f754c3129608bc5557637e605"
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
FORBIDDEN_SOURCE_PATH = re.compile(
    r"(?:^|/)(?:[^/]*Client[^/]*|Authorization|[^/]*(?:HTTP|OAuth|EventSource|Network|Socket)[^/]*)(?:/|\.swift$)"
)
FORBIDDEN_SOURCE_CONTENT = (
    re.compile(r"(?m)^\s*import\s+(?:CFNetwork|Network)\b"),
    re.compile(r"\b(?:URLSession|URLRequest|URLResponse|HTTPURLResponse|EventSource)\b"),
    re.compile(r"\b(?:Data|NSData|String|NSString)(?:\s*\.\s*init)?\s*\(\s*contentsOf\s*:"),
    re.compile(r"\bURL\s*\.\s*openConnection\s*\("),
    re.compile(r"\bNS(?:MutableURLRequest|URLRequest|URLConnection|URLSession)\b"),
    re.compile(r"\bOAuth[A-Za-z0-9_]*\b"),
    re.compile(r"\bHTTP[A-Za-z0-9_]*\b"),
    re.compile(r"\b(?:NWConnection|NWListener|NWTCPConnection|CFNetwork)\b"),
    re.compile(r"\b(?:socket|Socket)[A-Za-z0-9_]*\b"),
    re.compile(
        r"\b(?:actor|class|struct|enum|protocol)\s+(?!Client(?:Info|Capabilities)\b)[A-Za-z_][A-Za-z0-9_]*Client[A-Za-z0-9_]*\b"
    ),
    re.compile(r"\b(?:actor|class|struct|enum|protocol)\s+Client\b"),
)
LOCALOCR_MCP_SWIFT_ROOTS = (
    Path("Sources/LocalOCRMCP"),
    Path("tests/LocalOCRMCPTests"),
)
SWIFT_IMPORT_DECL = re.compile(
    r'(?m)^\s*\(import_decl\b[^\n]*\bmodule="([^"]+)"'
)
MCP_STDIO_TYPE_USAGE = re.compile(
    r'\b(?:id|name|inherits)="(?:Value|CallTool|ListTools|Tool|Server|Transport|'
    r'StdioTransport|Initialize|InitializedNotification|CancelledNotification|MCPError|'
    r'Ping|Metadata|ID|Message|Request|Response)"'
)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _is_sha256(value: object) -> bool:
    return isinstance(value, str) and SHA256_PATTERN.fullmatch(value) is not None


def _origin_hashes(vendor: Path) -> dict[str, str]:
    inventory = vendor / "Upstream" / "origin-inventory.json"
    assert inventory.is_file()
    data = json.loads(inventory.read_text())
    assert data["schema_version"] == 1
    assert data["upstream"] == {
        "repository": "https://github.com/modelcontextprotocol/swift-sdk",
        "release": "0.12.1",
        "commit": UPSTREAM_COMMIT,
    }
    entries = {entry["path"]: entry["sha256"] for entry in data["files"]}
    assert len(entries) == len(data["files"])
    for path, sha256 in entries.items():
        assert path.startswith("Sources/MCP/")
        assert path.endswith(".swift")
        assert Path(path).as_posix() == path
        assert ".." not in Path(path).parts
        assert _is_sha256(sha256)
    return entries


def _validate_vendor(root: Path) -> None:
    vendor = root / "Sources" / "MCPStdio"
    manifest = vendor / "Upstream" / "manifest.json"
    data = json.loads(manifest.read_text())

    assert data["schema_version"] == 1
    assert data["upstream"]["repository"] == "https://github.com/modelcontextprotocol/swift-sdk"
    assert data["upstream"]["release"] == "0.12.1"
    assert data["upstream"]["commit"] == UPSTREAM_COMMIT
    assert data["upstream"]["retrieved_on"] == "2026-08-27"
    assert data["upstream"]["hash_command"] == "shasum -a 256 <file>"
    assert isinstance(data["upstream"]["selection_rule"], str)
    assert isinstance(data["upstream"]["exclusions"], list)
    origin_hashes = _origin_hashes(vendor)

    actual = {path.relative_to(vendor).as_posix() for path in vendor.rglob("*.swift")}
    entries = {entry["path"]: entry for entry in data["files"]}
    assert len(entries) == len(data["files"])
    assert set(entries) == actual

    adaptations = {entry["path"]: entry for entry in data["adaptations"]}
    for path, entry in entries.items():
        local_path = vendor / path
        assert local_path.is_file()
        assert entry["local_sha256"] == _sha256(local_path)
        assert _is_sha256(entry["local_sha256"])

        if "local_only" in entry:
            assert entry["local_only"] is True
            assert set(entry) == {"path", "local_only", "local_sha256"}
            continue

        origin = entry["origin"]
        assert origin in origin_hashes
        assert ".." not in Path(origin).parts
        assert origin.endswith(".swift")
        assert Path(origin).as_posix() == origin
        upstream_hash = entry["upstream_sha256"]
        assert _is_sha256(upstream_hash)
        assert upstream_hash == origin_hashes[origin]
        if entry["local_sha256"] != upstream_hash:
            assert path in adaptations
            assert adaptations[path]["reason"].strip()

    assert not (set(adaptations) - set(entries))
    assert (vendor / "Upstream" / "LICENSE").is_file()
    assert (vendor / "Upstream" / "PROVENANCE.md").is_file()

    for path in actual:
        assert FORBIDDEN_SOURCE_PATH.search(path) is None
        source = (vendor / path).read_text()
        assert not any(pattern.search(source) for pattern in FORBIDDEN_SOURCE_CONTENT)


def _copied_tree(tmp_path: Path) -> Path:
    copy = tmp_path / "localocr"
    shutil.copytree(ROOT, copy, ignore=shutil.ignore_patterns(".build", ".git", ".venv"))
    return copy


def _run_policy(root: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(POLICY_VALIDATOR), "--repo-root", str(root), *arguments],
        check=False,
        capture_output=True,
        text=True,
    )


def _swift_parse_tree(source: str) -> str:
    try:
        result = subprocess.run(
            ["swiftc", "-frontend", "-dump-parse", "-enable-bare-slash-regex", "-"],
            input=source,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as error:
        raise AssertionError("Swift parser is unavailable") from error

    if result.returncode != 0:
        raise AssertionError("Swift parser failed")
    if not result.stdout.lstrip().startswith('(source_file "<stdin>"'):
        raise AssertionError("Swift parser returned an unrecognized parse tree")
    return result.stdout


def _swift_imported_modules_from_parse_tree(parse_tree: str) -> tuple[str, ...]:
    import_nodes = re.findall(r"(?m)^\s*\(import_decl\b", parse_tree)
    modules = tuple(SWIFT_IMPORT_DECL.findall(parse_tree))
    if len(modules) != len(import_nodes):
        raise AssertionError("Swift parser returned an unrecognized import declaration")
    return modules


def _swift_imported_modules(source: str) -> tuple[str, ...]:
    return _swift_imported_modules_from_parse_tree(_swift_parse_tree(source))


def _validate_localocr_mcp_imports(root: Path) -> None:
    swift_files = sorted(
        path
        for swift_root in LOCALOCR_MCP_SWIFT_ROOTS
        for path in (root / swift_root).rglob("*.swift")
    )
    assert swift_files

    for path in swift_files:
        relative_path = path.relative_to(root).as_posix()
        source = path.read_text()
        parse_tree = _swift_parse_tree(source)
        imported_modules = _swift_imported_modules_from_parse_tree(parse_tree)
        module_roots = {module.partition(".")[0] for module in imported_modules}
        assert "MCP" not in module_roots, relative_path
        if MCP_STDIO_TYPE_USAGE.search(parse_tree):
            assert "MCPStdio" in module_roots, relative_path


def test_package_uses_local_mcp_stdio() -> None:
    """Catches a remote swift-sdk dependency returning before migration completes."""
    package = (ROOT / "Package.swift").read_text()
    assert 'name: "MCPStdio"' in package
    assert 'exclude: ["Upstream"]' in package
    assert "modelcontextprotocol/swift-sdk" not in package
    assert '.product(name: "MCP", package: "swift-sdk")' not in package


def test_localocr_mcp_targets_and_sources_use_only_mcp_stdio() -> None:
    """Catches LocalOCR source, tests, or target edges reverting to the remote MCP module."""
    package = json.loads(
        subprocess.run(
            ["swift", "package", "dump-package"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    )
    targets = {target["name"]: target for target in package["targets"]}
    assert not any(
        dependency.get("product", [None, None])[0] == "MCP"
        and dependency.get("product", [None, None])[1] == "swift-sdk"
        for target in package["targets"]
        for dependency in target["dependencies"]
    )
    for target_name in ("LocalOCRMCP", "LocalOCRMCPTests"):
        dependencies = targets[target_name]["dependencies"]
        by_name = {dependency["byName"][0] for dependency in dependencies if "byName" in dependency}
        assert "MCPStdio" in by_name

    resolved = json.loads((ROOT / "Package.resolved").read_text())
    assert not any(
        pin.get("identity") == "swift-sdk"
        or "modelcontextprotocol/swift-sdk" in pin.get("location", "")
        for pin in resolved["pins"]
    )

    _validate_localocr_mcp_imports(ROOT)


def test_localocr_mcp_import_policy_discovers_new_nested_swift_files(tmp_path: Path) -> None:
    """Catches newly added LocalOCR MCP source or test files escaping migration policy."""
    copy = _copied_tree(tmp_path)
    legacy = copy / "Sources" / "LocalOCRMCP" / "Nested" / "Legacy.swift"
    legacy.parent.mkdir()
    legacy.write_text("import MCP\npublic let legacy: Value = .null\n")
    with pytest.raises(AssertionError):
        _validate_localocr_mcp_imports(copy)

    legacy.unlink()
    missing_import = copy / "tests" / "LocalOCRMCPTests" / "Nested" / "ValueProbe.swift"
    missing_import.parent.mkdir()
    missing_import.write_text("import Testing\nlet probe: Value = .null\n")
    with pytest.raises(AssertionError):
        _validate_localocr_mcp_imports(copy)

    missing_import.write_text("import MCPStdio\nimport Testing\nlet probe: Value = .null\n")
    _validate_localocr_mcp_imports(copy)


def test_localocr_mcp_import_policy_rejects_every_swift_import_form(tmp_path: Path) -> None:
    """Catches scoped imports and imports decorated with attributes or access levels."""
    copy = _copied_tree(tmp_path)
    probe = copy / "Sources" / "LocalOCRMCP" / "LegacyImportForms.swift"
    forbidden_imports = (
        "import struct MCP.Value",
        "import class MCP.Client",
        "import enum MCP.CallTool",
        "import protocol MCP.Transport",
        "import typealias MCP.ID",
        "import let MCP.someValue",
        "import var MCP.someVariable",
        "import func MCP.someFunction",
        "private import MCP",
        "fileprivate import MCP",
        "internal import MCP",
        "public import MCP",
        "package import MCP",
        "@testable import MCP",
        "@_exported import MCP",
        "@preconcurrency import MCP",
        "@_spi(Testing) import MCP",
        "@_implementationOnly internal import MCP",
        "@_spi(Testing) public import enum MCP.Value",
        "@_spi(Testing)\npublic import struct\nMCP.Value",
    )

    for declaration in forbidden_imports:
        probe.write_text(f"{declaration}\n")
        with pytest.raises(AssertionError, match="LegacyImportForms.swift"):
            _validate_localocr_mcp_imports(copy)

    probe.write_text(
        '''import MCPStdio
// import MCP
/* public import struct MCP.Value
   /* @_spi(Testing) import MCP */
*/
let ordinary = "@_spi(Testing) import MCP"
let multiline = """
package import enum MCP.CallTool
"""
let raw = #"import protocol MCP.Transport"#
'''
    )
    _validate_localocr_mcp_imports(copy)


def test_localocr_mcp_import_policy_defers_regex_literals_to_swift_parser(tmp_path: Path) -> None:
    """Allows import-like regex text but rejects a real import after regex comment tokens."""
    copy = _copied_tree(tmp_path)
    probe = copy / "Sources" / "LocalOCRMCP" / "RegexImportLookalikes.swift"
    probe.write_text(
        "let bare = /import MCP/\n"
        "let raw = #/import MCP/#\n"
        "let commentTokens = #/a/*b/#\n"
    )
    _validate_localocr_mcp_imports(copy)

    probe.write_text(
        "let commentTokens = #/a/*b/#\n"
        "import MCP\n"
    )
    with pytest.raises(AssertionError, match="RegexImportLookalikes.swift"):
        _validate_localocr_mcp_imports(copy)


def test_swift_import_parser_is_available_and_fails_closed(monkeypatch: pytest.MonkeyPatch) -> None:
    """Makes parser absence or a nonzero parse result a hard contract failure."""
    assert shutil.which("swiftc") is not None

    def unavailable(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
        raise FileNotFoundError("swiftc")

    monkeypatch.setattr(subprocess, "run", unavailable)
    with pytest.raises(AssertionError, match="Swift parser is unavailable"):
        _swift_imported_modules("import MCP\n")

    def parse_failure(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr="parse failed")

    monkeypatch.setattr(subprocess, "run", parse_failure)
    with pytest.raises(AssertionError, match="Swift parser failed"):
        _swift_imported_modules("import MCP\n")

    def invalid_tree(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(args=[], returncode=0, stdout="unexpected", stderr="")

    monkeypatch.setattr(subprocess, "run", invalid_tree)
    with pytest.raises(AssertionError, match="unrecognized parse tree"):
        _swift_imported_modules("import MCP\n")


def test_manifest_is_closed_and_pinned() -> None:
    """Catches a source added outside the reviewed, pinned manifest."""
    _validate_vendor(ROOT)


def test_canonical_policy_accepts_the_reviewed_source_and_package_boundary() -> None:
    result = _run_policy(ROOT)
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize(
    "mutation",
    (
        "extra_file",
        "missing_file",
        "missing_license",
        "missing_provenance",
        "duplicate_adaptation",
        "blank_adaptation_reason",
    ),
)
def test_canonical_policy_rejects_closed_vendor_boundary_mutations(
    tmp_path: Path,
    mutation: str,
) -> None:
    copy = _copied_tree(tmp_path)
    vendor = copy / "Sources" / "MCPStdio"
    manifest_path = vendor / "Upstream" / "manifest.json"
    manifest = json.loads(manifest_path.read_text())

    if mutation == "extra_file":
        (vendor / "RemoteTransport.c").write_text("int remote_transport;\n")
    elif mutation == "missing_file":
        (vendor / manifest["files"][0]["path"]).unlink()
    elif mutation == "missing_license":
        (vendor / "Upstream" / "LICENSE").unlink()
    elif mutation == "missing_provenance":
        (vendor / "Upstream" / "PROVENANCE.md").unlink()
    elif mutation == "duplicate_adaptation":
        manifest["adaptations"].append(dict(manifest["adaptations"][0]))
        manifest_path.write_text(json.dumps(manifest))
    elif mutation == "blank_adaptation_reason":
        manifest["adaptations"][0]["reason"] = "   "
        manifest_path.write_text(json.dumps(manifest))
    else:  # pragma: no cover - parametrization is closed above.
        raise AssertionError(mutation)

    result = _run_policy(copy, "--vendor-only")
    assert result.returncode != 0, mutation
    assert "MCP stdio source policy rejected" in result.stderr


@pytest.mark.parametrize(
    "source",
    (
        "import FoundationNetworking\n",
        "let configuration = URLSessionConfiguration.ephemeral\n",
        "let protocolClass: URLProtocol.Type? = nil\n",
        "let task: URLSessionDataTask? = nil\n",
        "let challenge: URLAuthenticationChallenge? = nil\n",
    ),
)
def test_canonical_policy_rejects_network_api_tokens(
    tmp_path: Path,
    source: str,
) -> None:
    copy = _copied_tree(tmp_path)
    vendor = copy / "Sources" / "MCPStdio"
    source_path = vendor / "NetworkProbe.swift"
    source_path.write_text(source)
    manifest_path = vendor / "Upstream" / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["files"].append(
        {
            "path": source_path.name,
            "local_only": True,
            "local_sha256": _sha256(source_path),
        }
    )
    manifest_path.write_text(json.dumps(manifest))

    result = _run_policy(copy, "--vendor-only")
    assert result.returncode != 0, source
    assert "MCP stdio source policy rejected" in result.stderr


def test_canonical_policy_rejects_remote_mcp_sdk_forks_and_product_edges(
    tmp_path: Path,
) -> None:
    copy = _copied_tree(tmp_path)
    package_path = copy / "Package.swift"
    package = package_path.read_text()
    package = package.replace(
        "    dependencies: [\n",
        "    dependencies: [\n"
        "        .package(url: \"https://example.invalid/vendor/mcp-fork\", exact: \"0.12.1\"),\n",
        1,
    )
    package = package.replace(
        '            name: "MCPStdio",\n            dependencies: [\n',
        '            name: "MCPStdio",\n            dependencies: [\n'
        '                .product(name: "MCP", package: "mcp-fork"),\n',
        1,
    )
    package_path.write_text(package)

    result = _run_policy(copy)
    assert result.returncode != 0
    assert "MCP stdio source policy rejected" in result.stderr


def test_origin_inventory_is_pinned_and_hashed() -> None:
    """Catches a missing deterministic origin inventory for derived Swift source."""
    inventory_path = VENDOR / "Upstream" / "origin-inventory.json"
    assert inventory_path.is_file()
    inventory = json.loads(inventory_path.read_text())
    assert inventory["upstream"]["commit"] == UPSTREAM_COMMIT
    assert any(entry["path"] == "Sources/MCP/Base/ID.swift" for entry in inventory["files"])


def test_origin_inventory_rejects_non_hex_hash(tmp_path: Path) -> None:
    """Catches a 64-character inventory value outside lowercase hexadecimal."""
    copy = _copied_tree(tmp_path)
    inventory_path = copy / "Sources" / "MCPStdio" / "Upstream" / "origin-inventory.json"
    inventory = json.loads(inventory_path.read_text())
    inventory["files"][0]["sha256"] = "g" * 64
    inventory_path.write_text(json.dumps(inventory))
    with pytest.raises(AssertionError):
        _validate_vendor(copy)


def test_manifest_rejects_duplicate_source_entries(tmp_path: Path) -> None:
    """Catches duplicate records that conceal a changed source declaration."""
    copy = _copied_tree(tmp_path)
    manifest = copy / "Sources" / "MCPStdio" / "Upstream" / "manifest.json"
    data = json.loads(manifest.read_text())
    data["files"].append(data["files"][0])
    manifest.write_text(json.dumps(data))
    with pytest.raises(AssertionError):
        _validate_vendor(copy)


def test_manifest_rejects_unlisted_and_missing_sources(tmp_path: Path) -> None:
    """Catches source-set drift in either direction."""
    copy = _copied_tree(tmp_path)
    extra = copy / "Sources" / "MCPStdio" / "Unlisted.swift"
    extra.write_text("public enum Unlisted {}\n")
    with pytest.raises(AssertionError):
        _validate_vendor(copy)

    extra.unlink()
    identity = copy / "Sources" / "MCPStdio" / "MCPStdio.swift"
    identity.unlink()
    with pytest.raises(AssertionError):
        _validate_vendor(copy)


def test_manifest_rejects_malformed_hashes_and_invalid_origins(tmp_path: Path) -> None:
    """Catches unverifiable hashes and origins that escape the upstream MCP tree."""
    copy = _copied_tree(tmp_path)
    manifest = copy / "Sources" / "MCPStdio" / "Upstream" / "manifest.json"
    data = json.loads(manifest.read_text())
    data["files"][0]["local_sha256"] = "g" * 64
    manifest.write_text(json.dumps(data))
    with pytest.raises(AssertionError):
        _validate_vendor(copy)

    data = json.loads(MANIFEST.read_text())
    derived = copy / "Sources" / "MCPStdio" / "Derived.swift"
    derived.write_text("public enum Derived {}\n")
    data["files"].append(
        {
            "path": "Derived.swift",
            "origin": "Sources/MCP/Base",
            "upstream_sha256": "a" * 64,
            "local_sha256": _sha256(derived),
        }
    )
    manifest.write_text(json.dumps(data))
    with pytest.raises(AssertionError):
        _validate_vendor(copy)


def test_manifest_rejects_unknown_pinned_origin(tmp_path: Path) -> None:
    """Catches a plausible-looking origin absent from the pinned source inventory."""
    copy = _copied_tree(tmp_path)
    manifest = copy / "Sources" / "MCPStdio" / "Upstream" / "manifest.json"
    data = json.loads(manifest.read_text())
    derived = copy / "Sources" / "MCPStdio" / "Derived.swift"
    derived.write_text("public enum Derived {}\n")
    data["files"].append(
        {
            "path": "Derived.swift",
            "origin": "Sources/MCP/Base/NotInPinnedSnapshot.swift",
            "upstream_sha256": "a" * 64,
            "local_sha256": _sha256(derived),
        }
    )
    manifest.write_text(json.dumps(data))
    with pytest.raises(AssertionError):
        _validate_vendor(copy)

    data = json.loads(MANIFEST.read_text())
    identity = copy / "Sources" / "MCPStdio" / "Derived.swift"
    identity.write_text("public enum Derived {}\n")
    data["files"].append(
        {
            "path": "Derived.swift",
            "origin": "Sources/Outside.swift",
            "upstream_sha256": "a" * 64,
            "local_sha256": _sha256(identity),
        }
    )
    manifest.write_text(json.dumps(data))
    with pytest.raises(AssertionError):
        _validate_vendor(copy)


def test_manifest_rejects_non_normalized_origin(tmp_path: Path) -> None:
    """Catches a traversing origin even when it resolves to an upstream source."""
    copy = _copied_tree(tmp_path)
    manifest = copy / "Sources" / "MCPStdio" / "Upstream" / "manifest.json"
    data = json.loads(manifest.read_text())
    derived = copy / "Sources" / "MCPStdio" / "Derived.swift"
    derived.write_text("public enum Derived {}\n")
    data["files"].append(
        {
            "path": "Derived.swift",
            "origin": "Sources/MCP/Base/../Base/ID.swift",
            "upstream_sha256": "519d7804eabbf14299b8f067374bf714aa03303b711d2c4423e0078e8e4ee4da",
            "local_sha256": _sha256(derived),
        }
    )
    manifest.write_text(json.dumps(data))
    with pytest.raises(AssertionError):
        _validate_vendor(copy)


def test_manifest_rejects_upstream_hash_that_disagrees_with_inventory(tmp_path: Path) -> None:
    """Catches a derived record whose declared upstream hash is not the pinned hash."""
    copy = _copied_tree(tmp_path)
    manifest = copy / "Sources" / "MCPStdio" / "Upstream" / "manifest.json"
    data = json.loads(manifest.read_text())
    derived = copy / "Sources" / "MCPStdio" / "Derived.swift"
    derived.write_text("public enum Derived {}\n")
    data["files"].append(
        {
            "path": "Derived.swift",
            "origin": "Sources/MCP/Base/ID.swift",
            "upstream_sha256": "a" * 64,
            "local_sha256": _sha256(derived),
        }
    )
    data["adaptations"].append({"path": "Derived.swift", "reason": "test mutation"})
    manifest.write_text(json.dumps(data))
    with pytest.raises(AssertionError):
        _validate_vendor(copy)


def test_manifest_requires_recorded_derived_adaptations(tmp_path: Path) -> None:
    """Catches a modified upstream source without a reviewer-visible reason."""
    copy = _copied_tree(tmp_path)
    manifest = copy / "Sources" / "MCPStdio" / "Upstream" / "manifest.json"
    data = json.loads(manifest.read_text())
    derived = copy / "Sources" / "MCPStdio" / "Derived.swift"
    derived.write_text("public enum Derived {}\n")
    data["files"].append(
        {
            "path": "Derived.swift",
            "origin": "Sources/MCP/Base/ID.swift",
            "upstream_sha256": "519d7804eabbf14299b8f067374bf714aa03303b711d2c4423e0078e8e4ee4da",
            "local_sha256": _sha256(derived),
        }
    )
    manifest.write_text(json.dumps(data))
    with pytest.raises(AssertionError):
        _validate_vendor(copy)


def test_manifest_rejects_non_boolean_local_only(tmp_path: Path) -> None:
    """Catches a truthy string used in place of the local-only boolean."""
    copy = _copied_tree(tmp_path)
    manifest = copy / "Sources" / "MCPStdio" / "Upstream" / "manifest.json"
    data = json.loads(manifest.read_text())
    data["files"][0]["local_only"] = "true"
    manifest.write_text(json.dumps(data))
    with pytest.raises(AssertionError):
        _validate_vendor(copy)


def test_manifest_allows_json_data_encoding_and_file_descriptor_stdio(tmp_path: Path) -> None:
    """Protects local JSON framing and descriptor-based stdio from remote-fetch rules."""
    copy = _copied_tree(tmp_path)
    source_path = copy / "Sources" / "MCPStdio" / "LocalFraming.swift"
    source_path.write_text(
        "let encoded = try JSONEncoder().encode(value)\n"
        "let framed = Data(\"{}\".utf8)\n"
        "let input = FileDescriptor.standardInput\n"
    )
    manifest = copy / "Sources" / "MCPStdio" / "Upstream" / "manifest.json"
    data = json.loads(manifest.read_text())
    data["files"].append(
        {
            "path": "LocalFraming.swift",
            "local_only": True,
            "local_sha256": _sha256(source_path),
        }
    )
    manifest.write_text(json.dumps(data))
    _validate_vendor(copy)


@pytest.mark.parametrize(
    ("path", "source"),
    [
        ("Client/Client.swift", "public actor Client {}\n"),
        ("MCPClient.swift", "public actor MCPClient {}\n"),
        ("Remote.swift", "public struct MCPClient {}\n"),
        ("HTTPClientTransport.swift", "public enum Safe {}\n"),
        ("WebSocketTransport.swift", "public enum Safe {}\n"),
        ("Authorization/Safe.swift", "public enum Safe {}\n"),
        ("HTTPServer/Safe.swift", "public enum Safe {}\n"),
        ("Safe.swift", "import Network\n"),
        ("Safe.swift", "import CFNetwork\n"),
        ("Safe.swift", "let session = URLSession.shared\n"),
        ("Remote.swift", 'let data = try Data(contentsOf: URL(string: "https://example.com")!)\n'),
        ("Remote.swift", 'let data = try Data.init(contentsOf: URL(string: "https://example.com")!)\n'),
        ("Remote.swift", 'let text = try String(contentsOf: URL(string: "https://example.com")!)\n'),
        ("Remote.swift", 'let text = try String.init(contentsOf: URL(string: "https://example.com")!)\n'),
        ("Remote.swift", "let connection = URL.openConnection()\n"),
        ("Remote.swift", "let request = NSURLRequest(url: URL(fileURLWithPath: \"/tmp/x\"))\n"),
        ("Remote.swift", "let request = NSMutableURLRequest(url: URL(fileURLWithPath: \"/tmp/x\"))\n"),
        ("Remote.swift", "let connection = NSURLConnection()\n"),
        ("Safe.swift", "let source = EventSource()\n"),
        ("Safe.swift", "let auth = OAuthToken()\n"),
        ("Safe.swift", "let proxy = HTTPProxy()\n"),
        ("Safe.swift", "let connection = NWConnection()\n"),
        ("Safe.swift", "let fd = socket(0, 0, 0)\n"),
        ("Safe.swift", "let socket = SocketConnection()\n"),
        ("Safe.swift", "public actor Client {}\n"),
    ],
)
def test_manifest_rejects_prohibited_shipping_source(
    tmp_path: Path, path: str, source: str
) -> None:
    """Catches client and network transport surfaces in shipping Swift source."""
    copy = _copied_tree(tmp_path)
    source_path = copy / "Sources" / "MCPStdio" / path
    source_path.parent.mkdir(parents=True, exist_ok=True)
    source_path.write_text(source)
    manifest = copy / "Sources" / "MCPStdio" / "Upstream" / "manifest.json"
    data = json.loads(manifest.read_text())
    data["files"].append(
        {"path": path, "local_only": True, "local_sha256": _sha256(source_path)}
    )
    manifest.write_text(json.dumps(data))
    with pytest.raises(AssertionError):
        _validate_vendor(copy)
