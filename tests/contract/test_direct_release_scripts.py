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
EXPECTED_QUOTED_NOTARY_PROFILE_ARGUMENTS = {
    '"$LOCALOCR_NOTARY_PROFILE"',
    '"${LOCALOCR_NOTARY_PROFILE}"',
}
NOTARY_SUBCOMMANDS = {"history", "log", "submit"}
FORBIDDEN_CREDENTIAL_FLAGS = {
    "--apple-id",
    "--issuer",
    "--key",
    "--key-id",
    "--password",
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


def _shell_command_segments(
    script: str,
    *,
    preserve_quotes: bool = False,
) -> list[list[str]]:
    logical_lines = re.sub(r"\\\n[ \t]*", " ", script).splitlines()
    commands: list[list[str]] = []
    for line in logical_lines:
        try:
            lexer = shlex.shlex(
                line,
                posix=not preserve_quotes,
                punctuation_chars=";&|()",
            )
            lexer.whitespace_split = True
            lexer.commenters = "#"
            tokens = list(lexer)
        except ValueError:
            continue
        command: list[str] = []
        for token in tokens:
            if token in {"{", "}"} or (
                token and set(token) <= set(";&|()")
            ):
                if command:
                    commands.append(command)
                    command = []
                continue
            command.append(token)
        if command:
            commands.append(command)
    return commands


def _executable_invocations(
    script: str,
    executable: str,
    *,
    preserve_quotes: bool = False,
) -> list[list[str]]:
    invocations: list[list[str]] = []
    for command in _shell_command_segments(
        script,
        preserve_quotes=preserve_quotes,
    ):
        index = 0
        while index < len(command):
            token = command[index]
            if (
                token in {"!", "do", "elif", "else", "if", "then", "time"}
                or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", token)
            ):
                index += 1
                continue
            token_name = Path(token.strip("\"'")).name
            if token_name in {"command", "env", "exec"}:
                index += 1
                while index < len(command) and (
                    command[index].startswith("-")
                    or re.fullmatch(
                        r"[A-Za-z_][A-Za-z0-9_]*=.*",
                        command[index],
                    )
                ):
                    index += 1
                continue
            if token_name == executable:
                invocations.append(command[index:])
            elif token_name == "xcrun":
                tool_index = index + 1
                while (
                    tool_index < len(command)
                    and command[tool_index].startswith("-")
                ):
                    tool_index += 1
                if (
                    tool_index < len(command)
                    and Path(command[tool_index].strip("\"'")).name == executable
                ):
                    invocations.append(command[tool_index:])
            break
    return invocations


def _assignment_tokens(script: str) -> list[tuple[str, str]]:
    assignments: list[tuple[str, str]] = []
    for command in _shell_command_segments(script):
        for token in command:
            match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", token)
            if match:
                assignments.append((match.group(1), match.group(2)))
    return assignments


def _profile_argument(command: list[str]) -> str | None:
    profile_arguments: list[str] = []
    for index, token in enumerate(command):
        if token == "--keychain-profile":
            assert index + 1 < len(command), "missing --keychain-profile argument"
            profile_arguments.append(command[index + 1])
        elif token.startswith("--keychain-profile="):
            profile_arguments.append(token)
    assert len(profile_arguments) <= 1, (
        f"multiple --keychain-profile arguments in one command: {command}"
    )
    return profile_arguments[0] if profile_arguments else None


def _assert_notarytool_profile_policy(
    script: str,
    *,
    required_subcommands: set[str],
) -> None:
    found_subcommands: set[str] = set()
    for command in _executable_invocations(
        script,
        "notarytool",
        preserve_quotes=True,
    ):
        subcommands = NOTARY_SUBCOMMANDS.intersection(command[1:])
        if not subcommands:
            continue
        assert len(subcommands) == 1, f"ambiguous notarytool invocation: {command}"
        subcommand = subcommands.pop()
        found_subcommands.add(subcommand)
        profile_argument = _profile_argument(command)
        assert profile_argument in EXPECTED_QUOTED_NOTARY_PROFILE_ARGUMENTS, (
            f"notarytool {subcommand} must consume LOCALOCR_NOTARY_PROFILE: {command}"
        )

    assert required_subcommands <= found_subcommands, (
        f"missing notarytool commands: {required_subcommands - found_subcommands}"
    )


def _assert_no_hard_coded_credentials(script: str) -> None:
    secret_assignment_name = re.compile(
        r"(?i)(?:"
        r"LOCALOCR_NOTARY_PROFILE|"
        r"APPLE_(?:ID|PASSWORD)|"
        r"NOTARY_(?:PROFILE|PASSWORD|CREDENTIALS?|.*KEY.*)|"
        r"(?:PRIVATE|API|AUTH).*KEY.*|"
        r"KEY.*(?:FILE|PATH)"
        r")"
    )
    for name, value in _assignment_tokens(script):
        if name == "LOCALOCR_NOTARY_PROFILE":
            raise AssertionError(
                "the repository must not assign LOCALOCR_NOTARY_PROFILE"
            )
        if value and secret_assignment_name.fullmatch(name):
            raise AssertionError(
                f"hard-coded credential assignment is forbidden: {name}"
            )

    for command in _shell_command_segments(script):
        for token in command:
            if token in FORBIDDEN_CREDENTIAL_FLAGS or any(
                token.startswith(f"{flag}=")
                for flag in FORBIDDEN_CREDENTIAL_FLAGS
            ):
                raise AssertionError(
                    f"repository credential flag is forbidden: {token}"
                )
            if (
                "BEGIN PRIVATE KEY" in token
                or "BEGIN RSA PRIVATE KEY" in token
                or "BEGIN EC PRIVATE KEY" in token
                or token.lower().endswith(".p8")
            ):
                raise AssertionError(
                    f"private-key material/reference is forbidden: {token}"
                )
            if (
                "LOCALOCR_NOTARY_PROFILE" in token
                and token not in EXPECTED_NOTARY_PROFILE_REFERENCES
            ):
                raise AssertionError(
                    f"default/derived notary profile expansion is forbidden: {token}"
                )


def _assert_codesign_deep_policy(script: str) -> None:
    for codesign_command in _executable_invocations(script, "codesign"):
        if "--deep" not in codesign_command:
            continue
        assert "--verify" in codesign_command, (
            f"--deep is forbidden while signing: {codesign_command}"
        )
        assert "--strict" in codesign_command, (
            f"--deep verification must also be strict: {codesign_command}"
        )


@pytest.mark.parametrize(
    "script",
    (
        'LOCALOCR_NOTARY_PROFILE="Hardcoded"',
        'readonly LOCALOCR_NOTARY_PROFILE="Hardcoded"',
        'declare -r LOCALOCR_NOTARY_PROFILE="Hardcoded"',
        'typeset LOCALOCR_NOTARY_PROFILE="Hardcoded"',
        'export LOCALOCR_NOTARY_PROFILE="Hardcoded"',
        ': "${LOCALOCR_NOTARY_PROFILE:-Hardcoded}"',
        ': "${LOCALOCR_NOTARY_PROFILE:=Hardcoded}"',
        'NOTARY_PROFILE="Hardcoded"',
        'NOTARY_PRIVATE_KEY="/secure/AuthKey"',
        'AUTH_KEY_PATH="/secure/AuthKey"',
        'PRIVATE_KEY_PEM="-----BEGIN PRIVATE KEY-----"',
        'PRIVATE_KEY_FILE="/secure/AuthKey.p8"',
    ),
)
def test_credential_guard_rejects_assignment_and_expansion_bypasses(
    script: str,
) -> None:
    with pytest.raises(AssertionError):
        _assert_no_hard_coded_credentials(script)


def test_credential_guard_permits_public_release_metadata() -> None:
    _assert_no_hard_coded_credentials(
        """
APPLE_TEAM_ID="DZ8B5454ZN"
NOTARY_SUBMISSION_ID="submission-id"
[[ -n "$LOCALOCR_NOTARY_PROFILE" ]]
"""
    )


@pytest.mark.parametrize(
    "profile_argument",
    (
        "Hardcoded",
        "$NOTARY_PROFILE",
        "${NOTARY_PROFILE}",
        "${LOCALOCR_NOTARY_PROFILE:-Hardcoded}",
        "${LOCALOCR_NOTARY_PROFILE:=Hardcoded}",
    ),
)
def test_notarytool_policy_rejects_hard_coded_or_indirect_profiles(
    profile_argument: str,
) -> None:
    script = (
        "xcrun notarytool submit artifact.zip "
        f'--keychain-profile "{profile_argument}" --wait'
    )
    with pytest.raises(AssertionError):
        _assert_notarytool_profile_policy(
            script,
            required_subcommands={"submit"},
        )


def test_notarytool_policy_requires_profile_on_actual_required_commands() -> None:
    unrelated_reference = """
printf '%s' --keychain-profile "$LOCALOCR_NOTARY_PROFILE"
echo notarytool submit --keychain-profile "$LOCALOCR_NOTARY_PROFILE"
xcrun notarytool history --output-format json
xcrun notarytool submit artifact.zip --wait
xcrun notarytool log submission-id notary-log.json
"""
    with pytest.raises(AssertionError):
        _assert_notarytool_profile_policy(
            unrelated_reference,
            required_subcommands=NOTARY_SUBCOMMANDS,
        )
    with pytest.raises(AssertionError):
        _assert_notarytool_profile_policy(
            (
                "xcrun notarytool submit artifact.zip "
                "--keychain-profile $LOCALOCR_NOTARY_PROFILE"
            ),
            required_subcommands={"submit"},
        )

    valid_commands = """
xcrun notarytool history --keychain-profile "$LOCALOCR_NOTARY_PROFILE" \
  --output-format json
xcrun notarytool submit artifact.zip --wait \
  --keychain-profile "${LOCALOCR_NOTARY_PROFILE}"
false || xcrun notarytool log submission-id \
  --keychain-profile "$LOCALOCR_NOTARY_PROFILE" notary-log.json
"""
    _assert_notarytool_profile_policy(
        valid_commands,
        required_subcommands=NOTARY_SUBCOMMANDS,
    )


@pytest.mark.parametrize(
    "script",
    (
        "/usr/bin/codesign --deep --force --sign identity app",
        "/usr/bin/codesign --force --sign identity app --deep",
        "true && /usr/bin/codesign --timestamp --deep --sign identity app",
        "{ /usr/bin/codesign --sign identity --deep app; }",
        "(/usr/bin/codesign --sign identity app --deep)",
    ),
)
def test_codesign_policy_rejects_deep_signing_in_compound_commands(
    script: str,
) -> None:
    with pytest.raises(AssertionError):
        _assert_codesign_deep_policy(script)


def test_codesign_policy_permits_only_deep_strict_verification() -> None:
    _assert_codesign_deep_policy(
        """
echo /usr/bin/codesign --deep --sign identity app
prepare && /usr/bin/codesign --strict app --deep --verify; finish
"""
    )
    with pytest.raises(AssertionError):
        _assert_codesign_deep_policy(
            "/usr/bin/codesign --verify app --deep"
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
    assert "--wait" in notarize_script
    assert "stapler staple" in notarize_script
    assert "stapler validate" in verify_script
    assert "spctl --assess --type execute" in verify_script
    assert "otool -L" in verify_script
    assert "otool -l" in verify_script

    for helper in EXPECTED_HELPERS:
        assert f"Contents/Helpers/{helper}" in sign_script
        assert helper in download_script

    assert "shasum -a 256" in download_script
    assert "stapler validate" in download_script
    assert "spctl --assess --type execute" in download_script
    assert "--version" in download_script
    assert "LOCALOCR_RELEASE_VERSION" in download_script

    forbidden_xcode_pattern = re.compile(
        r"(?i)\bXcode(?:[-_ ]*)(?:beta|rc|preview)\b"
    )
    for release_script in release_scripts:
        assert not forbidden_xcode_pattern.search(release_script)
        _assert_no_hard_coded_credentials(release_script)
        _assert_notarytool_profile_policy(
            release_script,
            required_subcommands=(
                NOTARY_SUBCOMMANDS
                if release_script == notarize_script
                else set()
            ),
        )
        _assert_codesign_deep_policy(release_script)

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
