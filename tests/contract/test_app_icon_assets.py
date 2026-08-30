"""Release contract for the branded LocalOCR Studio macOS app icon."""

from __future__ import annotations

import json
import struct
from pathlib import Path


ROOT = Path(__file__).parents[2]
ASSET_CATALOG = ROOT / "App" / "Assets.xcassets"
APP_ICON_SET = ASSET_CATALOG / "AppIcon.appiconset"
PROJECT_SPEC = ROOT / "project.yml"
PROJECT_FILE = ROOT / "LocalOCR Studio.xcodeproj" / "project.pbxproj"
BUILD_SCRIPT = ROOT / "scripts" / "build-unsigned-studio-app.sh"

EXPECTED_RENDITIONS = {
    ("16x16", "1x"): ("AppIcon-16.png", (16, 16)),
    ("16x16", "2x"): ("AppIcon-16@2x.png", (32, 32)),
    ("32x32", "1x"): ("AppIcon-32.png", (32, 32)),
    ("32x32", "2x"): ("AppIcon-32@2x.png", (64, 64)),
    ("128x128", "1x"): ("AppIcon-128.png", (128, 128)),
    ("128x128", "2x"): ("AppIcon-128@2x.png", (256, 256)),
    ("256x256", "1x"): ("AppIcon-256.png", (256, 256)),
    ("256x256", "2x"): ("AppIcon-256@2x.png", (512, 512)),
    ("512x512", "1x"): ("AppIcon-512.png", (512, 512)),
    ("512x512", "2x"): ("AppIcon-512@2x.png", (1024, 1024)),
}


def _png_dimensions(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    assert data.startswith(b"\x89PNG\r\n\x1a\n"), f"not a PNG: {path}"
    assert data[12:16] == b"IHDR", f"missing PNG IHDR: {path}"
    return struct.unpack(">II", data[16:24])


def test_app_icon_catalog_has_every_macos_rendition() -> None:
    root_manifest = json.loads((ASSET_CATALOG / "Contents.json").read_text())
    icon_manifest = json.loads((APP_ICON_SET / "Contents.json").read_text())

    assert root_manifest["info"] == {"author": "xcode", "version": 1}
    assert icon_manifest["info"] == {"author": "xcode", "version": 1}

    renditions = {
        (entry["size"], entry["scale"]): entry["filename"]
        for entry in icon_manifest["images"]
        if entry["idiom"] == "mac"
    }
    assert renditions == {
        key: expected[0] for key, expected in EXPECTED_RENDITIONS.items()
    }

    for key, (filename, expected_dimensions) in EXPECTED_RENDITIONS.items():
        path = APP_ICON_SET / filename
        assert path.stat().st_size > 500, f"empty or placeholder icon rendition: {key}"
        assert _png_dimensions(path) == expected_dimensions


def test_app_icon_catalog_is_a_declared_app_resource() -> None:
    project_spec = PROJECT_SPEC.read_text()
    project_file = PROJECT_FILE.read_text()

    assert "ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon" in project_spec
    assert "Assets.xcassets" in project_file
    assert "Assets.xcassets in Resources" in project_file
    assert "PBXResourcesBuildPhase" in project_file


def test_unsigned_release_build_refuses_an_iconless_app_bundle() -> None:
    script = BUILD_SCRIPT.read_text()

    assert "validate_studio_app_icon" in script
    assert 'Print :CFBundleIconName' in script
    assert 'Contents/Resources/AppIcon.icns' in script
    assert 'Contents/Resources/Assets.car' in script
    assert 'validate_studio_app_icon "$app_path"' in script
