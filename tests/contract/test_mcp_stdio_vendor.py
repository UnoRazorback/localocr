"""Closed provenance contract for the staged MCPStdio vendor target."""

from __future__ import annotations

import hashlib
import json
import shutil
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
VENDOR = ROOT / "Sources" / "MCPStdio"
MANIFEST = VENDOR / "Upstream" / "manifest.json"
LICENSE = VENDOR / "Upstream" / "LICENSE"
PROVENANCE = VENDOR / "Upstream" / "PROVENANCE.md"
UPSTREAM_COMMIT = "a0ae212ebf6eab5f754c3129608bc5557637e605"


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


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

    actual = {path.relative_to(vendor).as_posix() for path in vendor.rglob("*.swift")}
    entries = {entry["path"]: entry for entry in data["files"]}
    assert len(entries) == len(data["files"])
    assert set(entries) == actual

    adaptations = {entry["path"]: entry for entry in data["adaptations"]}
    for path, entry in entries.items():
        local_path = vendor / path
        assert local_path.is_file()
        assert entry["local_sha256"] == _sha256(local_path)
        assert len(entry["local_sha256"]) == 64
        assert entry["local_sha256"].islower()
        assert entry["local_sha256"].isalnum()

        if entry.get("local_only"):
            assert set(entry) == {"path", "local_only", "local_sha256"}
            continue

        assert entry.get("local_only") is not True
        origin = entry["origin"]
        assert origin.startswith("Sources/MCP/")
        assert ".." not in Path(origin).parts
        upstream_hash = entry["upstream_sha256"]
        assert len(upstream_hash) == 64
        assert upstream_hash.islower()
        assert upstream_hash.isalnum()
        if entry["local_sha256"] != upstream_hash:
            assert path in adaptations
            assert adaptations[path]["reason"].strip()

    assert not (set(adaptations) - set(entries))
    assert (vendor / "Upstream" / "LICENSE").is_file()
    assert (vendor / "Upstream" / "PROVENANCE.md").is_file()

    forbidden = {"HTTPClientTransport.swift", "NetworkTransport.swift"}
    assert not (forbidden & actual)


def _copied_tree(tmp_path: Path) -> Path:
    copy = tmp_path / "localocr"
    shutil.copytree(ROOT, copy, ignore=shutil.ignore_patterns(".build", ".git", ".venv"))
    return copy


def test_package_uses_local_mcp_stdio() -> None:
    """Catches a remote swift-sdk dependency returning before migration completes."""
    package = (ROOT / "Package.swift").read_text()
    assert 'name: "MCPStdio"' in package
    assert 'exclude: ["Upstream"]' in package
    assert "modelcontextprotocol/swift-sdk" not in package
    assert '.product(name: "MCP", package: "swift-sdk")' not in package


def test_manifest_is_closed_and_pinned() -> None:
    """Catches a source added outside the reviewed, pinned manifest."""
    _validate_vendor(ROOT)


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
    data["files"][0]["local_sha256"] = "not-a-sha256"
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
            "origin": "Sources/MCP/Base/Derived.swift",
            "upstream_sha256": "a" * 64,
            "local_sha256": _sha256(derived),
        }
    )
    manifest.write_text(json.dumps(data))
    with pytest.raises(AssertionError):
        _validate_vendor(copy)


def test_manifest_rejects_forbidden_transport_names(tmp_path: Path) -> None:
    """Catches network transport source files entering the stdio-only target."""
    copy = _copied_tree(tmp_path)
    forbidden = copy / "Sources" / "MCPStdio" / "HTTPClientTransport.swift"
    forbidden.write_text("public enum HTTPClientTransport {}\n")
    with pytest.raises(AssertionError):
        _validate_vendor(copy)
