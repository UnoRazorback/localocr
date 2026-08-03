"""Build and security contract for the LocalOCR Studio macOS app project."""

from __future__ import annotations

import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).parents[2]
PROJECT_SPEC = ROOT / "project.yml"
XCODE_PROJECT = ROOT / "LocalOCR Studio.xcodeproj"
PROJECT_FILE = XCODE_PROJECT / "project.pbxproj"
SHARED_SCHEME = (
    XCODE_PROJECT
    / "xcshareddata"
    / "xcschemes"
    / "LocalOCR Studio.xcscheme"
)
APP_ENTRY_POINT = ROOT / "App" / "LocalOCRStudioApp.swift"
UI_TEST_SUPPORT = ROOT / "App" / "LocalOCRStudioUITestSupport.swift"
UI_TESTS = ROOT / "AppUITests" / "LocalOCRStudioUITests.swift"
BUILD_SCRIPT = ROOT / "scripts" / "build-unsigned-studio-app.sh"

EXPECTED_SETTINGS = {
    "PRODUCT_BUNDLE_IDENTIFIER": "com.rayconsulting.localocr",
    "PRODUCT_NAME": "LocalOCR Studio",
    "MARKETING_VERSION": "0.2.0",
    "CURRENT_PROJECT_VERSION": "1",
    "MACOSX_DEPLOYMENT_TARGET": "14.0",
    "ARCHS": "arm64",
    "SWIFT_VERSION": "6.0",
    "ENABLE_HARDENED_RUNTIME": "YES",
}
FORBIDDEN_SECURITY_SETTINGS = (
    "CODE_SIGN_ENTITLEMENTS",
    "com.apple.security.network.client",
    "com.apple.security.network.server",
    "com.apple.security.get-task-allow",
)


def _read(path: Path) -> str:
    assert path.is_file(), f"missing required app-project file: {path}"
    return path.read_text()


def _yaml_scalar(source: str, key: str) -> str:
    matches = re.findall(
        rf"(?m)^\s*{re.escape(key)}:\s*[\"']?([^\"'\n]+?)[\"']?\s*$",
        source,
    )
    assert len(matches) == 1, f"expected one {key} setting, found {matches}"
    return matches[0].strip()


def test_required_app_project_files_exist() -> None:
    for path in (
        PROJECT_SPEC,
        PROJECT_FILE,
        SHARED_SCHEME,
        APP_ENTRY_POINT,
        UI_TEST_SUPPORT,
        UI_TESTS,
        BUILD_SCRIPT,
    ):
        assert path.is_file(), f"missing required app-project file: {path}"


def test_project_source_of_truth_has_exact_release_settings() -> None:
    spec = _read(PROJECT_SPEC)

    assert _yaml_scalar(spec, "name") == "LocalOCR Studio"
    for setting, expected in EXPECTED_SETTINGS.items():
        assert _yaml_scalar(spec, setting) == expected

    assert re.search(r"(?m)^\s*macOS:\s*[\"']14\.0[\"']\s*$", spec)
    assert re.search(
        r"(?ms)^packages:\s*\n\s+LocalOCR:\s*\n\s+path:\s*\.\s*$",
        spec,
    )
    assert re.search(
        r"(?ms)^\s+dependencies:\s*\n"
        r"\s+- package:\s*LocalOCR\s*\n"
        r"\s+product:\s*LocalOCRStudioKit\s*$",
        spec,
    )


def test_project_enables_hardening_without_network_or_debug_entitlements() -> None:
    project_sources = "\n".join(
        (
            _read(PROJECT_SPEC),
            _read(PROJECT_FILE),
            _read(APP_ENTRY_POINT),
            _read(UI_TEST_SUPPORT),
        )
    )

    assert "ENABLE_HARDENED_RUNTIME: YES" in project_sources
    for forbidden in FORBIDDEN_SECURITY_SETTINGS:
        assert forbidden not in project_sources
    assert not list((ROOT / "App").glob("*.entitlements"))


def test_generated_project_uses_only_relative_local_package_paths() -> None:
    project = _read(PROJECT_FILE)

    assert "LocalOCRStudioKit" in project
    assert "XCLocalSwiftPackageReference" in project
    assert re.search(r'relativePath = "?[.]"?;', project)
    assert "/Users/" not in project
    assert str(ROOT) not in project


def test_shared_scheme_builds_app_and_runs_ui_tests() -> None:
    scheme = ET.fromstring(_read(SHARED_SCHEME))
    build_names = {
        reference.attrib.get("BlueprintName")
        for reference in scheme.findall(".//BuildActionEntry/BuildableReference")
    }
    test_names = {
        reference.attrib.get("BlueprintName")
        for reference in scheme.findall(".//TestableReference/BuildableReference")
    }

    assert "LocalOCR Studio" in build_names
    assert test_names == {"LocalOCR StudioUITests"}


def test_ui_fixtures_are_debug_only_and_require_the_xctest_marker() -> None:
    entry_point = _read(APP_ENTRY_POINT)
    support = _read(UI_TEST_SUPPORT)

    assert "#if DEBUG" in entry_point
    assert "LocalOCRStudioUITestSupport.makeViewIfRequested()" in entry_point
    assert support.startswith("#if DEBUG\n")
    assert support.rstrip().endswith("#endif")
    assert "XCTestConfigurationFilePath" in support
    assert "LOCALOCR_STUDIO_UI_STATE" in support
    state_definition = re.search(
        r"^    private enum FixtureState:[^{]+\{\n(?P<body>.*?)^    \}",
        support,
        re.DOTALL | re.MULTILINE,
    )
    assert state_definition
    assert set(re.findall(r"\bcase ([A-Za-z][A-Za-z0-9_]*)", state_definition["body"])) == {
        "empty",
        "result",
        "error",
    }


def test_unsigned_build_script_has_stable_toolchain_and_confined_paths() -> None:
    script = _read(BUILD_SCRIPT)

    assert "release-toolchain.sh" in script
    assert "select_release_developer_dir" in script
    assert 'mktemp -d /tmp/localocr-studio-build.XXXXXX' in script
    assert "-derivedDataPath" in script
    assert 'output_root="$studio_repo_root/dist/unsigned-app"' in script
    assert 'output_app="$output_root/LocalOCR Studio.app"' in script
    assert '-destination "platform=macOS,arch=arm64"' in script
    assert "CODE_SIGNING_ALLOWED=NO" in script
    assert "CODE_SIGNING_REQUIRED=NO" in script
    assert "ARCHS=arm64" in script
    assert "validate_release_bundle_metadata" in script
    assert re.search(
        r'/usr/bin/lipo\s+"[$]executable"\s+-verify_arch\s+arm64',
        script,
    )
    assert "/Users/" not in script
    assert "DerivedData" not in script.replace(
        '"$build_root/DerivedData"',
        "",
    )
    assert set(re.findall(r"\brm\s+-rf\s+--\s+([^\s]+)", script)) == {
        '"$build_root"',
        '"$output_app"',
    }


def test_unsigned_build_root_validation_accepts_physical_macos_tmp_only() -> None:
    with tempfile.TemporaryDirectory(
        prefix="localocr-studio-build.",
        dir="/tmp",
    ) as temporary_root:
        accepted = subprocess.run(
            [str(BUILD_SCRIPT), "--test-build-root", temporary_root],
            check=False,
            capture_output=True,
            text=True,
        )
    rejected = subprocess.run(
        [str(BUILD_SCRIPT), "--test-build-root", str(ROOT)],
        check=False,
        capture_output=True,
        text=True,
    )

    assert accepted.returncode == 0, accepted.stderr
    assert rejected.returncode != 0
