"""Build and security contract for the LocalOCR Studio macOS app project."""

from __future__ import annotations

import plistlib
import re
import shlex
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest


ROOT = Path(__file__).parents[2]
PACKAGE_MANIFEST = ROOT / "Package.swift"
INTELLIGENCE_PROVIDER = (
    ROOT / "Sources" / "LocalOCRIntelligence" / "FoundationModelsIntelligenceProvider.swift"
)
INTELLIGENCE_GENERATED_TYPES = (
    ROOT / "Sources" / "LocalOCRIntelligence" / "FoundationModelsGeneratedTypes.swift"
)
INTELLIGENCE_ENVIRONMENT = (
    ROOT / "Sources" / "LocalOCRIntelligence" / "LocalIntelligenceEnvironment.swift"
)
MCP_ENTRY_POINT = ROOT / "Sources" / "LocalOCRMCPExecutable" / "main.swift"
ROOT_VIEW = ROOT / "Sources" / "LocalOCRStudioKit" / "LocalOCRStudioView.swift"
RESULT_VIEW = ROOT / "Sources" / "LocalOCRStudioKit" / "StudioResultView.swift"
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
BATCH_WORKSPACE = ROOT / "Sources" / "LocalOCRStudioKit" / "BatchWorkspaceView.swift"
BATCH_STATUS_VIEWS = ROOT / "Sources" / "LocalOCRStudioKit" / "BatchStatusViews.swift"
BUILD_SCRIPT = ROOT / "scripts" / "build-unsigned-studio-app.sh"
RELEASE_TOOLCHAIN = ROOT / "scripts" / "release-toolchain.sh"
RELEASE_PATH_GUARD = ROOT / "scripts" / "release-path-guard.swift"

EXPECTED_SETTINGS = {
    "PRODUCT_BUNDLE_IDENTIFIER": "com.rayconsulting.localocr",
    "PRODUCT_NAME": "LocalOCR Studio",
    "MARKETING_VERSION": "0.3.0",
    "CURRENT_PROJECT_VERSION": "3",
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


def _swift_function_body(source: str, signature: str) -> str:
    signature_start = source.index(signature)
    opening_brace = source.index("{", signature_start)
    depth = 0
    for index in range(opening_brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening_brace + 1 : index]
    raise AssertionError(f"unterminated Swift function: {signature}")


def _assert_fragments_in_order(source: str, fragments: tuple[str, ...]) -> None:
    cursor = 0
    for fragment in fragments:
        position = source.find(fragment, cursor)
        assert position >= 0, f"missing or out-of-order source fragment: {fragment}"
        cursor = position + len(fragment)


FOUNDATION_MODELS_SYMBOLS = (
    "import FoundationModels",
    "FoundationModelsIntelligenceProvider",
    "SystemLanguageModel",
    "LanguageModelSession",
    "GenerationOptions",
    "@Generable",
    "@Guide",
)


def _assert_foundation_models_references_are_compile_guarded(
    source: str,
    source_name: str,
) -> None:
    conditional_stack: list[str] = []
    active_foundation_guards = 0

    for line_number, line in enumerate(source.splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("#if canImport(FoundationModels)"):
            conditional_stack.append("foundation-positive")
            active_foundation_guards += 1
            continue
        if stripped.startswith("#if"):
            conditional_stack.append("other")
            continue
        if stripped.startswith(("#else", "#elseif")):
            if conditional_stack and conditional_stack[-1] == "foundation-positive":
                conditional_stack[-1] = "foundation-negative"
                active_foundation_guards -= 1
            continue
        if stripped.startswith("#endif"):
            assert conditional_stack, f"unmatched #endif in {source_name}:{line_number}"
            if conditional_stack.pop() == "foundation-positive":
                active_foundation_guards -= 1
            continue
        if stripped.startswith("//"):
            continue
        referenced = [symbol for symbol in FOUNDATION_MODELS_SYMBOLS if symbol in line]
        assert not referenced or active_foundation_guards > 0, (
            f"unguarded Foundation Models reference in {source_name}:{line_number}: {referenced}"
        )

    assert not conditional_stack, f"unterminated compile condition in {source_name}"


def _available_block_body(source: str, availability: str) -> str:
    return _swift_function_body(source, f"if #available({availability}, *)")


def test_result_screen_has_a_visible_process_another_reset_action() -> None:
    root_view = _read(ROOT_VIEW)
    result_view = _read(RESULT_VIEW)

    assert "let onProcessAnother: () -> Void" in result_view
    assert 'Button("Process Another Document", action: onProcessAnother)' in result_view
    assert '.accessibilityIdentifier("studio.process-another")' in result_view
    assert "if contract.canProcessAnotherDocument" in result_view
    assert "onProcessAnother: resetToEmpty" in root_view


def test_reset_to_empty_cleans_all_view_state_before_model_clear() -> None:
    reset_body = _swift_function_body(
        _read(ROOT_VIEW),
        "private func resetToEmpty()",
    )

    _assert_fragments_in_order(
        reset_body,
        (
            "lifecycle.performReset {",
            "pendingDropLoad?.cancel()",
            "pendingDropLoad = nil",
            "isDropTargeted = false",
            "actionError = nil",
            "isCreatingSearchablePDF = false",
            "searchableProgress = nil",
            "let task = searchablePDFTask",
            "searchablePDFTask = nil",
            "task?.cancel()",
            "} clearModel: {",
            "model.clear()",
        ),
    )


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


def test_local_intelligence_is_linked_to_every_shipping_surface() -> None:
    manifest = _read(PACKAGE_MANIFEST)

    assert 'platforms: [.macOS(.v14)]' in manifest
    for target in ("LocalOCRStudioKit", "LocalOCRCommandKit", "LocalOCRMCP"):
        target_block = re.search(
            rf'\.target\(\s*name: "{target}",(?P<body>.*?)\n\s*\),',
            manifest,
            re.DOTALL,
        )
        assert target_block, f"missing package target {target}"
        assert '"LocalOCRIntelligence"' in target_block["body"]


def test_foundation_models_symbols_are_compile_and_availability_guarded() -> None:
    provider = _read(INTELLIGENCE_PROVIDER)
    generated_types = _read(INTELLIGENCE_GENERATED_TYPES)
    intelligence_environment = _read(INTELLIGENCE_ENVIRONMENT)
    mcp_entry = _read(MCP_ENTRY_POINT)
    app_entry = _read(APP_ENTRY_POINT)

    guarded_sources = {
        str(INTELLIGENCE_PROVIDER): provider,
        str(INTELLIGENCE_GENERATED_TYPES): generated_types,
        str(INTELLIGENCE_ENVIRONMENT): intelligence_environment,
        str(MCP_ENTRY_POINT): mcp_entry,
        str(APP_ENTRY_POINT): app_entry,
    }
    for source_name, source in guarded_sources.items():
        _assert_foundation_models_references_are_compile_guarded(source, source_name)

    assert "@available(macOS 26.0, *)" in provider
    assert "@available(macOS 26.0, *)" in generated_types
    for entry_source in (mcp_entry, intelligence_environment):
        available_body = _available_block_body(entry_source, "macOS 26.0")
        assert "FoundationModelsIntelligenceProvider()" in available_body


def test_foundation_models_guard_contract_rejects_appended_unguarded_symbols() -> None:
    for source_path in (
        INTELLIGENCE_PROVIDER,
        INTELLIGENCE_GENERATED_TYPES,
        INTELLIGENCE_ENVIRONMENT,
        MCP_ENTRY_POINT,
        APP_ENTRY_POINT,
    ):
        malicious = _read(source_path) + "\nlet leaked = FoundationModelsIntelligenceProvider()\n"
        with pytest.raises(AssertionError, match="unguarded Foundation Models reference"):
            _assert_foundation_models_references_are_compile_guarded(
                malicious,
                str(source_path),
            )


def test_shipping_sources_do_not_import_network_frameworks() -> None:
    shipping_sources = [
        *ROOT.glob("App/**/*.swift"),
        *ROOT.glob("Sources/**/*.swift"),
    ]
    network_import = re.compile(r"(?m)^\s*import\s+(?:CFNetwork|Network)\s*$")

    assert shipping_sources
    assert not [path for path in shipping_sources if network_import.search(_read(path))]


def test_unsigned_studio_build_rejects_source_policy_drift_before_xcodebuild(
    tmp_path: Path,
) -> None:
    copy = tmp_path / "policy-repo"
    shutil.copytree(
        ROOT,
        copy,
        ignore=shutil.ignore_patterns(".build", ".git", ".venv", "dist"),
    )
    vendored_source = copy / "Sources" / "MCPStdio" / "MCPStdio.swift"
    vendored_source.write_text(vendored_source.read_text() + "\npublic let drift = true\n")
    build_script = copy / "scripts" / "build-unsigned-studio-app.sh"
    xcode_marker = tmp_path / "xcodebuild-was-called"

    result = subprocess.run(
        [
            "/bin/bash",
            "-c",
            (
                'source "$1"\n'
                'marker="$2"\n'
                'select_release_developer_dir() { : > "$marker"; return 91; }\n'
                "run_studio_build\n"
            ),
            "unsigned-source-policy",
            str(build_script),
            str(xcode_marker),
        ],
        cwd=copy,
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    assert "MCP stdio source policy rejected" in result.stderr
    assert not xcode_marker.exists(), "Xcode build began before source policy passed"


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
        "resultBusy",
        "intelligenceAvailable",
        "intelligenceRunning",
        "intelligenceResults",
        "intelligenceMacOSUnavailable",
        "intelligenceDeviceIneligible",
        "intelligenceDisabled",
        "intelligenceNotReady",
        "intelligenceUnsupportedLanguage",
        "intelligenceError",
        "modelManager",
        "modelRecovery",
        "error",
        "batchReview",
        "batchProcessing",
        "batchComplete",
        "batchSkippedOnly",
        "batchPlanningFailure",
    }


def test_batch_workspace_contract_is_included_and_privacy_safe() -> None:
    workspace = _read(BATCH_WORKSPACE)
    status_views = _read(BATCH_STATUS_VIEWS)
    entry_point = _read(APP_ENTRY_POINT)

    for identifier in (
        "studio.batch.workspace",
        "studio.batch.add-files",
        "studio.batch.add-folder",
        "studio.batch.choose-output",
        "studio.batch.start",
        "studio.batch.cancel",
        "studio.batch.retry-failed",
        "studio.batch.reveal-output",
        "studio.batch.copy-diagnostics",
        "studio.batch.new",
        "studio.batch.return-single",
    ):
        assert identifier in workspace

    assert "StudioBatchExecutor(client: client)" in entry_point
    assert "StudioViewModel(client: client)" in entry_point
    assert "sourceSHA256" not in workspace
    assert "sourceSHA256" not in status_views
    assert "ProcessInfo.processInfo.environment" not in workspace
    assert "ProcessInfo.processInfo.environment" not in status_views


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
    assert "validate_local_intelligence_candidate_binary" in script
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
    }
    assert "release_cleanup_anchored_directory" in script


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


def test_unsigned_build_strips_only_the_validated_staged_executable(
    tmp_path: Path,
) -> None:
    script, fake_repo = _copy_build_scripts_to_isolated_repo(tmp_path)
    canonical_app = fake_repo / "dist" / "unsigned-app" / "LocalOCR Studio.app"

    with tempfile.TemporaryDirectory(
        prefix="localocr-studio-build.",
        dir="/tmp",
    ) as temporary_root:
        build_root = Path(temporary_root)
        source_product = build_root / "SourceProducts" / "LocalOCR Studio"
        _compile_debug_path_fixture(source_product)
        source_bytes = source_product.read_bytes()
        assert b"/Users/" in source_bytes

        staged_app = _write_staged_app(
            build_root,
            bundle_identifier="com.rayconsulting.localocr",
            minimum_os="14.0",
        )
        staged_executable = staged_app / "Contents" / "MacOS" / "LocalOCR Studio"
        shutil.copy2(source_product, staged_executable)

        result = _run_sourced_build_function(
            script,
            build_root,
            'validate_and_publish_staged_app "$build_root/Staged/LocalOCR Studio.app"',
        )

        assert result.returncode == 0, result.stdout + result.stderr
        assert source_product.read_bytes() == source_bytes

    published_executable = (
        canonical_app / "Contents" / "MacOS" / "LocalOCR Studio"
    )
    assert b"/Users/" not in published_executable.read_bytes()
    symbols = subprocess.run(
        ["/usr/bin/nm", "-ap", str(published_executable)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    assert "/Users/" not in symbols
    assert not list(canonical_app.rglob("*.dSYM"))
    assert not (fake_repo / "dist" / "release-symbols").exists()


def test_unsigned_build_preserves_a_matching_dsym_by_uuid_outside_the_app(
    tmp_path: Path,
) -> None:
    script, fake_repo = _copy_build_scripts_to_isolated_repo(tmp_path)
    canonical_app = fake_repo / "dist" / "unsigned-app" / "LocalOCR Studio.app"
    source_dsym = tmp_path / "LocalOCR Studio.app.dSYM"

    with tempfile.TemporaryDirectory(
        prefix="localocr-studio-build.",
        dir="/tmp",
    ) as temporary_root:
        build_root = Path(temporary_root)
        source_product = build_root / "SourceProducts" / "LocalOCR Studio"
        _compile_debug_path_fixture(source_product)
        _create_matching_dsym(source_product, source_dsym)
        source_symbol_bytes = _snapshot_file_bytes(source_dsym)
        expected_uuid = _macho_uuid(source_product)
        staged_app = _write_staged_app(
            build_root,
            bundle_identifier="com.rayconsulting.localocr",
            minimum_os="14.0",
        )
        shutil.copy2(
            source_product,
            staged_app / "Contents" / "MacOS" / "LocalOCR Studio",
        )

        result = _run_sourced_build_function(
            script,
            build_root,
            (
                'validate_and_publish_staged_app '
                '"$build_root/Staged/LocalOCR Studio.app" '
                f'{str(source_dsym)!r}'
            ),
        )

    assert result.returncode == 0, result.stdout + result.stderr
    published_executable = canonical_app / "Contents" / "MacOS" / "LocalOCR Studio"
    retained_dsym = (
        fake_repo
        / "dist"
        / "release-symbols"
        / f"{expected_uuid}-LocalOCR-Studio.dSYM"
    )
    assert retained_dsym.is_dir()
    assert _macho_uuid(retained_dsym) == _macho_uuid(published_executable)
    assert _snapshot_file_bytes(source_dsym) == source_symbol_bytes
    assert not list(canonical_app.rglob("*.dSYM"))
    assert not list((fake_repo / "dist" / "unsigned-app").glob("*.dSYM"))


def test_unsigned_build_rejects_a_mismatched_dsym_before_publication(
    tmp_path: Path,
) -> None:
    script, fake_repo = _copy_build_scripts_to_isolated_repo(tmp_path)
    canonical_app = fake_repo / "dist" / "unsigned-app" / "LocalOCR Studio.app"
    source_dsym = tmp_path / "mismatched.dSYM"
    other_binary = tmp_path / "other" / "LocalOCR Studio"
    _compile_debug_path_fixture(
        other_binary,
        "int helper(void) { return 1; } int main(void) { return helper(); }\n",
    )
    _create_matching_dsym(other_binary, source_dsym)

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
        staged_executable = staged_app / "Contents" / "MacOS" / "LocalOCR Studio"
        _compile_debug_path_fixture(staged_executable)
        assert _macho_uuid(staged_executable) != _macho_uuid(source_dsym)

        result = _run_sourced_build_function(
            script,
            build_root,
            (
                'validate_and_publish_staged_app '
                '"$build_root/Staged/LocalOCR Studio.app" '
                f'{str(source_dsym)!r}'
            ),
        )

    assert result.returncode != 0
    assert "dSYM UUID does not match release binary UUID" in result.stderr
    assert not canonical_app.exists()
    assert not (fake_repo / "dist" / "release-symbols").exists()


def test_unsigned_build_rejects_a_symlinked_release_symbols_root(
    tmp_path: Path,
) -> None:
    script, fake_repo = _copy_build_scripts_to_isolated_repo(tmp_path)
    outside_symbols = tmp_path / "outside-symbols"
    outside_symbols.mkdir()
    outside_marker = outside_symbols / "must-survive.txt"
    outside_marker.write_text("do not copy symbols here")
    (fake_repo / "dist").mkdir()
    (fake_repo / "dist" / "release-symbols").symlink_to(
        outside_symbols,
        target_is_directory=True,
    )
    source_dsym = tmp_path / "LocalOCR Studio.app.dSYM"

    with tempfile.TemporaryDirectory(
        prefix="localocr-studio-build.",
        dir="/tmp",
    ) as temporary_root:
        build_root = Path(temporary_root)
        source_product = build_root / "SourceProducts" / "LocalOCR Studio"
        _compile_debug_path_fixture(source_product)
        _create_matching_dsym(source_product, source_dsym)
        staged_app = _write_staged_app(
            build_root,
            bundle_identifier="com.rayconsulting.localocr",
            minimum_os="14.0",
        )
        shutil.copy2(
            source_product,
            staged_app / "Contents" / "MacOS" / "LocalOCR Studio",
        )

        result = _run_sourced_build_function(
            script,
            build_root,
            (
                'validate_and_publish_staged_app '
                '"$build_root/Staged/LocalOCR Studio.app" '
                f'{str(source_dsym)!r}'
            ),
        )

    assert result.returncode != 0
    assert "release symbols directory must not be a symlink" in result.stderr
    assert outside_marker.read_text() == "do not copy symbols here"
    assert sorted(outside_symbols.iterdir()) == [outside_marker]


def test_unsigned_build_rejects_a_symlinked_staged_executable_without_editing_target(
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
        staged_executable = staged_app / "Contents" / "MacOS" / "LocalOCR Studio"
        outside_target = build_root / "outside-debug-binary"
        _compile_debug_path_fixture(outside_target)
        outside_bytes = outside_target.read_bytes()
        staged_executable.unlink()
        staged_executable.symlink_to(outside_target)

        result = _run_sourced_build_function(
            script,
            build_root,
            'validate_and_publish_staged_app "$build_root/Staged/LocalOCR Studio.app"',
        )

        assert result.returncode != 0
        assert "unsigned Studio executable is missing or invalid" in result.stderr
        assert outside_target.read_bytes() == outside_bytes

    assert not canonical_app.exists()


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


@pytest.mark.parametrize("existing_target", (False, True))
def test_studio_publisher_fails_closed_when_output_parent_is_swapped_at_startup(
    tmp_path: Path,
    existing_target: bool,
) -> None:
    script, fake_repo = _copy_build_scripts_to_isolated_repo(tmp_path)
    output_root = fake_repo / "dist" / "unsigned-app"
    canonical_app = output_root / "LocalOCR Studio.app"
    detached_root = fake_repo / "dist" / "unsigned-app.detached"
    outside_root = tmp_path / "outside-output"
    output_root.mkdir(parents=True)
    outside_root.mkdir()
    outside_marker = outside_root / "must-survive.txt"
    outside_marker.write_bytes(b"outside output must remain byte-for-byte")
    known_good_bytes: dict[Path, bytes] = {}
    if existing_target:
        (canonical_app / "Contents" / "Resources").mkdir(parents=True)
        (canonical_app / "Contents" / "Resources" / "receipt.txt").write_bytes(
            b"preserve existing Studio output"
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
            f"""
real_release_path_guard="$release_path_guard"
release_publish_directory_atomically() {{
    /bin/mv "$output_root" {shlex.quote(str(detached_root))}
    /bin/ln -s {shlex.quote(str(outside_root))} "$output_root"
    /usr/bin/swift "$real_release_path_guard" publish-directory "$@"
}}
validate_and_publish_staged_app "$build_root/Staged/LocalOCR Studio.app"
""",
        )

    assert result.returncode != 0
    assert output_root.is_symlink()
    assert outside_marker.read_bytes() == b"outside output must remain byte-for-byte"
    assert sorted(outside_root.iterdir()) == [outside_marker]
    assert not list(detached_root.glob(".LocalOCR Studio.app.candidate.*"))
    if existing_target:
        assert _snapshot_file_bytes(
            detached_root / "LocalOCR Studio.app"
        ) == known_good_bytes
    else:
        assert not (detached_root / "LocalOCR Studio.app").exists()


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
release_publish_directory_atomically() {
    [[ "$#" -eq 5 ]] || return 99
    case "$1" in
        "$output_root"/.LocalOCR\\ Studio.app.candidate.*) ;;
        *) return 99 ;;
    esac
    [[
        -d "$1" && ! -L "$1" &&
        "$2" == "$output_app" &&
        "$3" == "$studio_output_root_identity" &&
        "$4" == "$studio_output_candidate_identity" &&
        "$5" != "missing"
    ]] || return 99
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
    shutil.copy2(
        RELEASE_PATH_GUARD,
        scripts_directory / RELEASE_PATH_GUARD.name,
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
    resources = contents / "Resources"
    executable.parent.mkdir(parents=True)
    resources.mkdir()
    with (contents / "Info.plist").open("wb") as plist:
        plistlib.dump(
            {
                "CFBundleIdentifier": bundle_identifier,
                "CFBundleIconName": "AppIcon",
                "CFBundleShortVersionString": "0.3.0",
                "CFBundleVersion": "3",
                "LSMinimumSystemVersion": minimum_os,
            },
            plist,
        )
    (resources / "AppIcon.icns").write_bytes(b"test app icon")
    (resources / "Assets.car").write_bytes(b"test asset catalog")
    if compile_arm64_executable:
        subprocess.run(
            [
                "/usr/bin/clang",
                "-arch",
                "arm64",
                f"-mmacosx-version-min={minimum_os}",
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


def _compile_debug_path_fixture(
    output: Path,
    source_text: str = "int main(void) { return 0; }\n",
) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    source = output.parent / "debug-path-fixture.c"
    source.write_text(source_text)
    subprocess.run(
        [
            "/usr/bin/clang",
            "-g",
            "-arch",
            "arm64",
            "-mmacosx-version-min=14.0",
            f"-ffile-prefix-map={output.parent}=/Users/example/private",
            str(source),
            "-o",
            str(output),
        ],
        check=True,
        capture_output=True,
        text=True,
    )


def _macho_uuid(binary_or_dsym: Path) -> str:
    output = subprocess.run(
        ["/usr/bin/dwarfdump", "--uuid", str(binary_or_dsym)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    matches = re.findall(
        r"(?m)^UUID: ([0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}) "
        r"\(arm64\) ",
        output,
    )
    assert len(matches) == 1, output
    return matches[0]


def _create_matching_dsym(binary: Path, output: Path) -> None:
    subprocess.run(
        ["/usr/bin/dsymutil", str(binary), "-o", str(output)],
        check=True,
        capture_output=True,
        text=True,
    )
    assert output.is_dir()
    assert _macho_uuid(output) == _macho_uuid(binary)


def _snapshot_file_bytes(root: Path) -> dict[Path, bytes]:
    return {
        path.relative_to(root): path.read_bytes()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }
