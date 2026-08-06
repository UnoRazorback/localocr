"""Build and security contract for the LocalOCR Studio macOS app project."""

from __future__ import annotations

import plistlib
import re
import shutil
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
RELEASE_TOOLCHAIN = ROOT / "scripts" / "release-toolchain.sh"

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


def test_app_uses_one_app_delegate_managed_window_instead_of_a_window_group() -> None:
    entry_point = _read(APP_ENTRY_POINT)

    assert "WindowGroup" not in entry_point
    assert "@NSApplicationDelegateAdaptor" in entry_point
    assert "applicationShouldHandleReopen" in entry_point
    assert "isReleasedWhenClosed = false" in entry_point


def test_ui_fixtures_are_debug_only_and_require_a_test_session_marker() -> None:
    entry_point = _read(APP_ENTRY_POINT)
    support = _read(UI_TEST_SUPPORT)

    assert "#if DEBUG" in entry_point
    assert "LocalOCRStudioUITestSupport.makeViewIfRequested()" in entry_point
    assert support.startswith("#if DEBUG\n")
    assert support.rstrip().endswith("#endif")
    assert "LOCALOCR_STUDIO_UI_TEST_SESSION" in support
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
        '"$studio_output_candidate"',
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


def test_wrong_minimum_os_fails_before_creating_canonical_output(
    tmp_path: Path,
) -> None:
    script, fake_repo = _copy_build_scripts_to_isolated_repo(tmp_path)
    canonical_app = fake_repo / "dist" / "unsigned-app" / "LocalOCR Studio.app"

    with tempfile.TemporaryDirectory(
        prefix="localocr-studio-build.",
        dir="/tmp",
    ) as temporary_root:
        _write_staged_app(
            Path(temporary_root),
            bundle_identifier="com.rayconsulting.localocr",
            minimum_os="13.0",
        )
        result = _run_sourced_build_function(
            script,
            Path(temporary_root),
            'validate_and_publish_staged_app "$build_root/Staged/LocalOCR Studio.app"',
        )

    assert result.returncode != 0
    assert (
        "LSMinimumSystemVersion mismatch: expected '14.0', found '13.0'"
        in result.stderr
    )
    assert not canonical_app.exists()


def test_failed_staged_validation_preserves_existing_canonical_output(
    tmp_path: Path,
) -> None:
    script, fake_repo = _copy_build_scripts_to_isolated_repo(tmp_path)
    canonical_app = fake_repo / "dist" / "unsigned-app" / "LocalOCR Studio.app"
    canonical_app.mkdir(parents=True)
    known_good_marker = canonical_app / "known-good.txt"
    known_good_marker.write_bytes(b"preserve this release")

    with tempfile.TemporaryDirectory(
        prefix="localocr-studio-build.",
        dir="/tmp",
    ) as temporary_root:
        _write_staged_app(
            Path(temporary_root),
            bundle_identifier="com.example.invalid",
            minimum_os="14.0",
        )
        result = _run_sourced_build_function(
            script,
            Path(temporary_root),
            'validate_and_publish_staged_app "$build_root/Staged/LocalOCR Studio.app"',
        )

    assert result.returncode != 0
    assert "CFBundleIdentifier mismatch" in result.stderr
    assert known_good_marker.read_bytes() == b"preserve this release"
    assert sorted(
        path.relative_to(canonical_app)
        for path in canonical_app.rglob("*")
        if path.is_file()
    ) == [Path("known-good.txt")]


def test_staged_app_symlink_is_rejected_before_bundle_inspection(
    tmp_path: Path,
) -> None:
    script, fake_repo = _copy_build_scripts_to_isolated_repo(tmp_path)
    canonical_app = fake_repo / "dist" / "unsigned-app" / "LocalOCR Studio.app"

    with tempfile.TemporaryDirectory(
        prefix="localocr-studio-build.",
        dir="/tmp",
    ) as temporary_root:
        build_root = Path(temporary_root)
        staged_app = _write_staged_app(
            build_root,
            bundle_identifier="com.rayconsulting.localocr",
            minimum_os="14.0",
        )
        symlink_target = build_root / "Symlink Target.app"
        staged_app.rename(symlink_target)
        staged_app.symlink_to(symlink_target, target_is_directory=True)
        result = _run_sourced_build_function(
            script,
            build_root,
            'validate_and_publish_staged_app "$build_root/Staged/LocalOCR Studio.app"',
        )

    assert result.returncode != 0
    assert "Studio staged app is missing or symlinked" in result.stderr
    assert not canonical_app.exists()


def test_publication_failure_preserves_existing_canonical_app(
    tmp_path: Path,
) -> None:
    script, fake_repo = _copy_build_scripts_to_isolated_repo(tmp_path)
    output_root = fake_repo / "dist" / "unsigned-app"
    canonical_app = output_root / "LocalOCR Studio.app"
    (canonical_app / "Contents" / "Resources").mkdir(parents=True)
    (canonical_app / "Contents" / "Info.plist").write_bytes(b"known-good-plist")
    (canonical_app / "Contents" / "Resources" / "receipt.txt").write_bytes(
        b"preserve this known-good release exactly",
    )
    known_good_bytes = _snapshot_file_bytes(canonical_app)

    with tempfile.TemporaryDirectory(
        prefix="localocr-studio-build.",
        dir="/tmp",
    ) as temporary_root:
        build_root = Path(temporary_root)
        _write_staged_app(
            build_root,
            bundle_identifier="com.rayconsulting.localocr",
            minimum_os="14.0",
            compile_arm64_executable=True,
        )
        result = _run_sourced_build_function(
            script,
            build_root,
            """
atomically_exchange_apps() {
    case "$1" in
        "$output_root"/.LocalOCR\\ Studio.app.candidate.*) ;;
        *) return 99 ;;
    esac
    [[ -d "$1" && ! -L "$1" && "$2" == "$output_app" ]] || return 99
    return 75
}
validate_and_publish_staged_app "$build_root/Staged/LocalOCR Studio.app"
""",
        )

    assert result.returncode != 0
    assert _snapshot_file_bytes(canonical_app) == known_good_bytes
    assert not list(output_root.glob(".LocalOCR Studio.app.candidate.*"))


def test_publish_test_option_is_not_a_production_command(tmp_path: Path) -> None:
    script, fake_repo = _copy_build_scripts_to_isolated_repo(tmp_path)
    canonical_app = fake_repo / "dist" / "unsigned-app" / "LocalOCR Studio.app"

    with tempfile.TemporaryDirectory(
        prefix="localocr-studio-build.",
        dir="/tmp",
    ) as temporary_root:
        _write_staged_app(
            Path(temporary_root),
            bundle_identifier="com.rayconsulting.localocr",
            minimum_os="13.0",
        )
        result = subprocess.run(
            [str(script), "--test-publish-staged-app", temporary_root],
            check=False,
            capture_output=True,
            text=True,
        )

    assert result.returncode == 2
    assert (
        "unknown unsigned Studio build option: --test-publish-staged-app"
        in result.stderr
    )
    assert not canonical_app.exists()


def _run_sourced_build_function(
    script: Path,
    build_root: Path,
    function_body: str,
) -> subprocess.CompletedProcess[str]:
    source_and_run = f"""
set -euo pipefail
source "$1"
set_validated_build_root "$2"
{function_body}
"""
    return subprocess.run(
        ["/bin/bash", "-c", source_and_run, "_", str(script), str(build_root)],
        check=False,
        capture_output=True,
        text=True,
    )


def _copy_build_scripts_to_isolated_repo(
    tmp_path: Path,
) -> tuple[Path, Path]:
    fake_repo = tmp_path / "isolated-repo"
    scripts_directory = fake_repo / "scripts"
    scripts_directory.mkdir(parents=True)
    copied_build_script = scripts_directory / BUILD_SCRIPT.name
    shutil.copy2(BUILD_SCRIPT, copied_build_script)
    shutil.copy2(
        RELEASE_TOOLCHAIN,
        scripts_directory / RELEASE_TOOLCHAIN.name,
    )
    return copied_build_script, fake_repo


def _write_staged_app(
    build_root: Path,
    *,
    bundle_identifier: str,
    minimum_os: str,
    compile_arm64_executable: bool = False,
) -> Path:
    staged_app = build_root / "Staged" / "LocalOCR Studio.app"
    contents = staged_app / "Contents"
    executable = contents / "MacOS" / "LocalOCR Studio"
    executable.parent.mkdir(parents=True)
    with (contents / "Info.plist").open("wb") as plist:
        plistlib.dump(
            {
                "CFBundleIdentifier": bundle_identifier,
                "CFBundleShortVersionString": "0.2.0",
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": minimum_os,
            },
            plist,
        )
    if compile_arm64_executable:
        subprocess.run(
            [
                "/usr/bin/clang",
                "-arch",
                "arm64",
                "-x",
                "c",
                "-o",
                str(executable),
                "-",
            ],
            input="int main(void) { return 0; }\n",
            check=True,
            capture_output=True,
            text=True,
        )
    else:
        executable.write_bytes(b"validation must stop before architecture checks")
        executable.chmod(0o755)
    return staged_app


def _snapshot_file_bytes(root: Path) -> dict[Path, bytes]:
    return {
        path.relative_to(root): path.read_bytes()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }
