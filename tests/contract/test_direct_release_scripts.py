"""Executable policy contract for the direct-distribution release scripts."""

from __future__ import annotations

import os
import re
import shlex
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).parents[2]
SCRIPTS = ROOT / "scripts"
EXPECTED_IDENTITY = "Developer ID Application: John Scott Ray (DZ8B5454ZN)"
EXPECTED_TEAM = "DZ8B5454ZN"
EXPECTED_HELPERS = ("localocr", "localocr-mcp")
EXPECTED_NOTARY_PROFILE_REFERENCES = {
    "$LOCALOCR_NOTARY_PROFILE",
    "${LOCALOCR_NOTARY_PROFILE}",
}
EXPECTED_SECOND_MAC_FIELDS = (
    "Release version:",
    "Build:",
    "Release commit:",
    "Download URL:",
    "ZIP SHA-256:",
    "Test date and time:",
    "Mac model:",
    "Processor:",
    "macOS version:",
    "Gatekeeper result:",
    "Stapled ticket result:",
    "App launch result:",
    "CLI version result:",
    "MCP initialization result:",
    "OCR smoke input type:",
    "OCR smoke result:",
    "Tester:",
    "Overall result: PASS or FAIL",
)
RELEASE_SCRIPTS = {
    "toolchain": SCRIPTS / "release-toolchain.sh",
    "stage": SCRIPTS / "stage-direct-release.sh",
    "sign": SCRIPTS / "sign-direct-release.sh",
    "notarize": SCRIPTS / "notarize-direct-release.sh",
    "verify": SCRIPTS / "verify-direct-release.sh",
    "download": SCRIPTS / "test-downloaded-release.sh",
}
PREPUBLICATION_SCRIPTS = (
    SCRIPTS / "build-native-tools.sh",
    *RELEASE_SCRIPTS.values(),
)
SECOND_MAC_RECORD = ROOT / "docs" / "release" / "second-mac-acceptance.md"
FORBIDDEN_BETA_RECORDS = (
    "MCP-MacVision-Beta-Metrics.csv",
    "MCP-MacVision-Feedback-Log.csv",
)


def _script(name: str) -> str:
    path = RELEASE_SCRIPTS[name]
    assert path.is_file(), f"missing direct-release script: {path}"
    return path.read_text()


def _run_script_test(
    script: str,
    mode: str,
    value: str,
    *,
    extra_arguments: tuple[str, ...] = (),
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "/bin/bash",
            str(RELEASE_SCRIPTS[script]),
            mode,
            value,
            *extra_arguments,
        ],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )


def _assert_script_test_accepts(script: str, mode: str, value: str) -> None:
    result = _run_script_test(script, mode, value)
    assert result.returncode == 0, result.stderr


def _assert_script_test_rejects(script: str, mode: str, value: str) -> None:
    result = _run_script_test(script, mode, value)
    assert result.returncode != 0, result.stdout


def _logical_shell_commands(script: str) -> list[list[str]]:
    logical_lines = re.sub(r"\\\n[ \t]*", " ", script).splitlines()
    commands: list[list[str]] = []
    for line in logical_lines:
        try:
            tokens = shlex.split(line, comments=True, posix=True)
        except ValueError:
            continue
        if tokens:
            commands.append(tokens)
    return commands


def _assert_notary_profile_is_environment_backed(
    script: str,
    *,
    required: bool,
) -> None:
    profile_arguments: list[str] = []
    for command in _logical_shell_commands(script):
        for index, token in enumerate(command):
            if token == "--keychain-profile":
                assert index + 1 < len(command), "missing --keychain-profile argument"
                profile_arguments.append(command[index + 1])
            elif token.startswith("--keychain-profile="):
                profile_arguments.append(token.partition("=")[2])

    if required:
        assert profile_arguments, "notarization must use --keychain-profile"
    assert set(profile_arguments) <= EXPECTED_NOTARY_PROFILE_REFERENCES
    assert not re.search(
        r"(?m)^\s*(?:export\s+)?LOCALOCR_NOTARY_PROFILE\s*=",
        script,
    ), "the repository must not assign a notary profile"


def _assert_codesign_deep_policy(script: str) -> None:
    for command in _logical_shell_commands(script):
        codesign_indexes = [
            index
            for index, token in enumerate(command)
            if Path(token).name == "codesign"
        ]
        for index in codesign_indexes:
            codesign_command = command[index:]
            if "--deep" not in codesign_command:
                continue
            assert "--verify" in codesign_command, (
                f"--deep is forbidden while signing: {codesign_command}"
            )
            assert "--strict" in codesign_command, (
                f"--deep verification must also be strict: {codesign_command}"
            )


def test_direct_release_scripts_enforce_immutable_policy() -> None:
    toolchain_script = _script("toolchain")
    stage_script = _script("stage")
    sign_script = _script("sign")
    notarize_script = _script("notarize")
    verify_script = _script("verify")
    download_script = _script("download")
    release_scripts = (
        toolchain_script,
        stage_script,
        sign_script,
        notarize_script,
        verify_script,
        download_script,
    )

    assert EXPECTED_IDENTITY in sign_script
    assert EXPECTED_TEAM in toolchain_script
    assert "--options" in sign_script and "runtime" in sign_script
    assert "--timestamp" in sign_script
    assert "notarytool submit" in notarize_script
    assert "--wait" in notarize_script
    assert "stapler staple" in notarize_script
    assert "stapler validate" in verify_script
    assert "spctl --assess --type execute" in verify_script
    assert "otool -L" in verify_script
    assert "otool -l" in verify_script

    for helper in EXPECTED_HELPERS:
        assert f"Contents/Helpers/{helper}" in sign_script
        assert helper in download_script

    _assert_codesign_deep_policy(sign_script)
    _assert_codesign_deep_policy(verify_script)

    assert "shasum -a 256" in download_script
    assert "stapler validate" in download_script
    assert "spctl --assess --type execute" in download_script
    assert "--version" in download_script
    assert "LOCALOCR_RELEASE_VERSION" in download_script

    forbidden_credential_pattern = re.compile(
        r"(?i)(?:"
        r"--apple-id\b|--password\b|--issuer\b|--key-id\b|--key(?:\s|=)|"
        r"BEGIN (?:RSA |EC )?PRIVATE KEY|\.p8\b"
        r")"
    )
    forbidden_xcode_pattern = re.compile(
        r"(?i)\bXcode(?:[-_ ]*)(?:beta|rc|preview)\b"
    )
    for release_script in release_scripts:
        assert not forbidden_credential_pattern.search(release_script)
        assert not forbidden_xcode_pattern.search(release_script)
        _assert_notary_profile_is_environment_backed(
            release_script,
            required=release_script == notarize_script,
        )

    assert "--entitlements" not in sign_script


def test_signing_dry_run_records_nested_first_invocation_order(tmp_path: Path) -> None:
    staged_app = tmp_path / "LocalOCR Studio.app"
    (staged_app / "Contents" / "Helpers").mkdir(parents=True)
    trace_file = tmp_path / "codesign-invocations.txt"
    env = os.environ.copy()
    env["LOCALOCR_SIGNING_TRACE_FILE"] = str(trace_file)

    result = _run_script_test(
        "sign",
        "--test-signing-order",
        str(staged_app),
        env=env,
    )

    assert result.returncode == 0, result.stderr
    assert trace_file.is_file(), "signing dry run did not write its invocation trace"
    invocations = [
        shlex.split(line)
        for line in trace_file.read_text().splitlines()
        if line.strip()
    ]
    expected_prefix = [
        "/usr/bin/codesign",
        "--force",
        "--sign",
        EXPECTED_IDENTITY,
        "--options",
        "runtime",
        "--timestamp",
    ]
    assert invocations == [
        [*expected_prefix, str(staged_app / "Contents" / "Helpers" / "localocr")],
        [*expected_prefix, str(staged_app / "Contents" / "Helpers" / "localocr-mcp")],
        [*expected_prefix, str(staged_app)],
    ]


def test_toolchain_rejects_nonstable_xcode_paths() -> None:
    _assert_script_test_accepts(
        "toolchain", "--test-developer-dir", "/Applications/Xcode.app/Contents/Developer"
    )
    for developer_dir in (
        "/Applications/Xcode-beta.app/Contents/Developer",
        "/Applications/Xcode-RC.app/Contents/Developer",
        "/Applications/Xcode Preview.app/Contents/Developer",
        "/Applications/XCODE-BETA.app/Contents/Developer",
        "/Applications/Xcode_preview.app/Contents/Developer",
    ):
        _assert_script_test_rejects("toolchain", "--test-developer-dir", developer_dir)


@pytest.mark.parametrize("script", ("stage", "verify"))
def test_release_scripts_require_arm64_and_macos_14_or_later(script: str) -> None:
    _assert_script_test_accepts(script, "--test-architecture", "arm64")
    for architecture in ("x86_64", "arm64 x86_64"):
        _assert_script_test_rejects(script, "--test-architecture", architecture)

    for minimum_version in ("14.0", "14.6", "15.0"):
        _assert_script_test_accepts(script, "--test-minimum-macos", minimum_version)
    for minimum_version in ("13.6", "10.15", ""):
        _assert_script_test_rejects(script, "--test-minimum-macos", minimum_version)


def test_verifier_rejects_debug_entitlement() -> None:
    _assert_script_test_accepts(
        "verify",
        "--test-entitlements",
        "<plist><dict></dict></plist>",
    )
    _assert_script_test_accepts(
        "verify",
        "--test-entitlements",
        (
            "<plist><dict><key>com.apple.security.get-task-allow</key>"
            "<false/></dict></plist>"
        ),
    )
    _assert_script_test_rejects(
        "verify",
        "--test-entitlements",
        (
            "<plist><dict><key>com.apple.security.get-task-allow</key>"
            "<true/></dict></plist>"
        ),
    )


def test_verifier_allows_only_the_system_swift_rpath() -> None:
    _assert_script_test_accepts("verify", "--test-rpath", "/usr/lib/swift")
    for rpath in (
        "",
        "/usr/lib/swift/",
        "/usr/lib",
        "/System/Library",
        "/Applications/Xcode.app/Contents/Developer/usr/lib/swift/macosx",
        "/opt/homebrew/lib",
        "/usr/local/lib",
        "@loader_path/../Frameworks",
        "@executable_path/../Frameworks",
        "/Users/example/lib",
    ):
        _assert_script_test_rejects("verify", "--test-rpath", rpath)


def test_verifier_allows_only_system_install_names_and_compatibility_span() -> None:
    for install_name in (
        "/System/Library/Frameworks/Vision.framework/Versions/A/Vision",
        "/System/Library/PrivateFrameworks/Example.framework/Example",
        "/usr/lib/libSystem.B.dylib",
        "/usr/lib/swift/libswiftCore.dylib",
        "@rpath/libswiftCompatibilitySpan.dylib",
    ):
        _assert_script_test_accepts("verify", "--test-install-name", install_name)

    for install_name in (
        "",
        "/System/Library",
        "/System/LibraryPrivate/Example",
        "/usr/lib",
        "/usr/library/libexample.dylib",
        "/opt/homebrew/lib/libexample.dylib",
        "/usr/local/lib/libexample.dylib",
        "@rpath/third-party.dylib",
        "@rpath/libswiftCompatibilitySpan.dylib.backup",
        "@loader_path/libexample.dylib",
        "@executable_path/libexample.dylib",
        "/Users/example/libexample.dylib",
    ):
        _assert_script_test_rejects("verify", "--test-install-name", install_name)


def test_second_mac_acceptance_record_freezes_required_result_fields() -> None:
    assert SECOND_MAC_RECORD.is_file(), (
        f"missing second-Mac acceptance record: {SECOND_MAC_RECORD}"
    )
    record = SECOND_MAC_RECORD.read_text()
    for field in EXPECTED_SECOND_MAC_FIELDS:
        assert field in record


def test_prepublication_scripts_do_not_touch_beta_metrics() -> None:
    for path in PREPUBLICATION_SCRIPTS:
        assert path.is_file(), f"missing pre-publication script: {path}"
        script = path.read_text()
        for beta_record in FORBIDDEN_BETA_RECORDS:
            assert beta_record not in script
