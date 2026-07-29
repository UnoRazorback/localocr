"""Executable policy contract for the direct-distribution release scripts."""

from __future__ import annotations

import hashlib
import os
import re
import shlex
import shutil
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
WRAPPER_OPTIONS_WITH_VALUES = {
    "command": set(),
    "env": {"-C", "-S", "-u", "--chdir", "--split-string", "--unset"},
    "exec": {"-a"},
    "sudo": {
        "-C",
        "-g",
        "-h",
        "-p",
        "-r",
        "-t",
        "-u",
        "--chdir",
        "--close-from",
        "--group",
        "--host",
        "--other-user",
        "--prompt",
        "--role",
        "--type",
        "--user",
    },
}
NOTARY_GLOBAL_FLAG_OPTIONS = {"--verbose"}
NOTARY_GLOBAL_VALUE_OPTIONS = {"--output-format"}
NOTARY_TERMINAL_OPTIONS = {"-h", "--help", "--version"}
PRIVATE_KEY_REFERENCE = re.compile(r"(?i)\.p8(?=$|[^\w])")
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
            if token_name in WRAPPER_OPTIONS_WITH_VALUES:
                wrapper_name = token_name
                index += 1
                while index < len(command):
                    wrapper_argument = command[index]
                    if re.fullmatch(
                        r"[A-Za-z_][A-Za-z0-9_]*=.*",
                        wrapper_argument,
                    ):
                        index += 1
                        continue
                    if wrapper_argument == "--":
                        index += 1
                        break
                    if not wrapper_argument.startswith("-"):
                        break
                    option_name = wrapper_argument.partition("=")[0]
                    index += 1
                    if (
                        "=" not in wrapper_argument
                        and option_name
                        in WRAPPER_OPTIONS_WITH_VALUES[wrapper_name]
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


def _notarytool_subcommand(command: list[str]) -> str | None:
    index = 1
    while index < len(command):
        token = command[index]
        if token in NOTARY_TERMINAL_OPTIONS:
            return None
        if token in NOTARY_GLOBAL_FLAG_OPTIONS:
            index += 1
            continue
        if token in NOTARY_GLOBAL_VALUE_OPTIONS:
            index += 2
            continue
        if any(
            token.startswith(f"{option}=")
            for option in NOTARY_GLOBAL_VALUE_OPTIONS
        ):
            index += 1
            continue
        if token == "--":
            index += 1
            continue
        if token.startswith("-"):
            return None
        if token not in NOTARY_SUBCOMMANDS:
            return None
        for argument in command[index + 1 :]:
            if argument == "--":
                break
            if argument in NOTARY_TERMINAL_OPTIONS:
                return None
        return token
    return None


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
        subcommand = _notarytool_subcommand(command)
        if subcommand is None:
            continue
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
                or PRIVATE_KEY_REFERENCE.search(token)
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
        signing_flags = [
            token
            for token in codesign_command
            if token == "--sign"
            or token.startswith("--sign=")
            or re.fullmatch(r"-s(?:.+)?", token)
        ]
        assert not signing_flags, (
            f"--deep is forbidden while signing: {codesign_command}"
        )
        assert "--verify" in codesign_command, (
            f"--deep is permitted only while verifying: {codesign_command}"
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
    "reference",
    (
        "/secure/AuthKey.p8?version=1",
        "/secure/AuthKey.p8#release",
        "/secure/AuthKey.p8.backup",
        "https://example.invalid/AuthKey.p8?download=1#current",
    ),
)
def test_credential_guard_rejects_private_key_extension_boundaries(
    reference: str,
) -> None:
    with pytest.raises(AssertionError):
        _assert_no_hard_coded_credentials(f"printf '%s' '{reference}'")


@pytest.mark.parametrize(
    "ordinary_text",
    (
        "p8",
        "ordinary-p8-text",
        "/secure/AuthKey.p8notes",
        "/secure/AuthKey.p8_version",
        "/secure/p8/AuthKey",
    ),
)
def test_credential_guard_does_not_treat_plain_p8_text_as_a_key_reference(
    ordinary_text: str,
) -> None:
    _assert_no_hard_coded_credentials(f"printf '%s' '{ordinary_text}'")


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


@pytest.mark.parametrize("subcommand", ("history", "submit", "log"))
def test_notarytool_policy_rejects_help_operands_as_subcommands(
    subcommand: str,
) -> None:
    misleading_help = (
        f"xcrun notarytool --help {subcommand} "
        '--keychain-profile "$LOCALOCR_NOTARY_PROFILE"'
    )
    with pytest.raises(AssertionError):
        _assert_notarytool_profile_policy(
            misleading_help,
            required_subcommands={subcommand},
        )


@pytest.mark.parametrize("subcommand", ("history", "submit", "log"))
@pytest.mark.parametrize("terminal_option", ("-h", "--help", "--version"))
def test_notarytool_policy_rejects_terminal_options_after_subcommands(
    subcommand: str,
    terminal_option: str,
) -> None:
    per_subcommand_help = (
        f"xcrun notarytool {subcommand} {terminal_option} "
        '--keychain-profile "$LOCALOCR_NOTARY_PROFILE"'
    )
    with pytest.raises(AssertionError):
        _assert_notarytool_profile_policy(
            per_subcommand_help,
            required_subcommands={subcommand},
        )


def test_notarytool_policy_accepts_actual_subcommands_after_global_options() -> None:
    commands = """
xcrun notarytool --verbose history \
  --keychain-profile "$LOCALOCR_NOTARY_PROFILE"
xcrun notarytool --output-format json submit artifact.zip \
  --keychain-profile "$LOCALOCR_NOTARY_PROFILE"
xcrun notarytool --verbose log submission-id notary-log.json \
  --keychain-profile "${LOCALOCR_NOTARY_PROFILE}"
"""
    _assert_notarytool_profile_policy(
        commands,
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
        (
            "sudo /usr/bin/codesign --verify --strict --deep "
            "--sign identity app"
        ),
        (
            "sudo -u root command /usr/bin/codesign --deep "
            "--verify --strict -s identity app"
        ),
        (
            "env RELEASE=1 exec /usr/bin/codesign --verify --strict "
            "--sign=identity app --deep"
        ),
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
sudo -u root /usr/bin/codesign app --verify --deep --strict
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


def _nested_code_fixture(tmp_path: Path) -> Path:
    staged_app = tmp_path / "LocalOCR Studio.app"
    macos_dir = staged_app / "Contents" / "MacOS"
    helpers_dir = staged_app / "Contents" / "Helpers"
    macos_dir.mkdir(parents=True)
    helpers_dir.mkdir()
    (staged_app / "Contents" / "Info.plist").write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LocalOCR</string>
</dict></plist>
"""
    )
    for destination in (
        macos_dir / "LocalOCR",
        helpers_dir / "localocr",
        helpers_dir / "localocr-mcp",
    ):
        shutil.copyfile("/usr/bin/true", destination)
        destination.chmod(0o755)
    return staged_app


def test_signer_rejects_every_unexpected_nested_code_kind(tmp_path: Path) -> None:
    staged_app = _nested_code_fixture(tmp_path)
    accepted = _run_script_test("sign", "--test-nested-code", str(staged_app))
    assert accepted.returncode == 0, accepted.stderr

    unexpected_binary = staged_app / "Contents" / "Resources" / "hidden-tool"
    unexpected_binary.parent.mkdir()
    shutil.copyfile("/usr/bin/true", unexpected_binary)
    unexpected_binary.chmod(0o755)
    rejected_binary = _run_script_test(
        "sign",
        "--test-nested-code",
        str(staged_app),
    )
    assert rejected_binary.returncode != 0
    assert "unexpected nested code" in rejected_binary.stderr
    unexpected_binary.unlink()

    unexpected_framework = (
        staged_app / "Contents" / "Frameworks" / "Hidden.framework"
    )
    unexpected_framework.mkdir(parents=True)
    rejected_framework = _run_script_test(
        "sign",
        "--test-nested-code",
        str(staged_app),
    )
    assert rejected_framework.returncode != 0
    assert "unexpected nested code bundle" in rejected_framework.stderr
    unexpected_framework.rmdir()

    unexpected_xpc = staged_app / "Contents" / "XPCServices" / "Hidden.XPC"
    unexpected_xpc.mkdir(parents=True)
    rejected_xpc = _run_script_test(
        "sign",
        "--test-nested-code",
        str(staged_app),
    )
    assert rejected_xpc.returncode != 0
    assert "unexpected nested code bundle" in rejected_xpc.stderr


def test_signer_compares_nested_code_in_one_physical_path_namespace(
    tmp_path: Path,
) -> None:
    staged_app = _nested_code_fixture(tmp_path)
    physical_path = str(staged_app.resolve())
    assert physical_path.startswith("/private/var/")
    lexical_alias = Path(physical_path.replace("/private/var/", "/var/", 1))
    assert lexical_alias.is_dir()

    result = _run_script_test(
        "sign",
        "--test-nested-code",
        str(lexical_alias),
    )

    assert result.returncode == 0, result.stderr


def test_signer_clears_removable_xattrs_only_from_the_staged_copy(
    tmp_path: Path,
) -> None:
    staged_app = _nested_code_fixture(tmp_path)
    staged_target = staged_app / "Contents" / "Info.plist"
    outside_sentinel = tmp_path / "unsigned-input-sentinel"
    outside_sentinel.write_text("untouched")
    for target in (staged_target, outside_sentinel):
        subprocess.run(
            ["/usr/bin/xattr", "-w", "com.example.removable", "fixture", str(target)],
            check=True,
        )
    trace_file = tmp_path / "codesign-invocations.txt"
    env = os.environ.copy()
    env["LOCALOCR_SIGNING_TRACE_FILE"] = str(trace_file)

    result = _run_script_test(
        "sign",
        "--test-xattr-preflight",
        str(staged_app),
        env=env,
    )

    assert result.returncode == 0, result.stderr
    assert "com.example.removable" not in subprocess.run(
        ["/usr/bin/xattr", str(staged_target)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    assert "com.example.removable" in subprocess.run(
        ["/usr/bin/xattr", str(outside_sentinel)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    assert len(trace_file.read_text().splitlines()) == 1


def test_signer_aborts_on_persistent_hostile_xattr_before_first_trace(
    tmp_path: Path,
) -> None:
    staged_app = _nested_code_fixture(tmp_path)
    first_helper = staged_app / "Contents" / "Helpers" / "localocr"
    helper_before = first_helper.read_bytes()
    trace_file = tmp_path / "codesign-invocations.txt"
    env = os.environ.copy()
    env["LOCALOCR_SIGNING_TRACE_FILE"] = str(trace_file)
    env["LOCALOCR_TEST_REMAINING_XATTRS"] = "com.apple.FinderInfo"

    result = _run_script_test(
        "sign",
        "--test-xattr-preflight",
        str(staged_app),
        env=env,
    )

    assert result.returncode != 0
    assert "code-signing-hostile metadata" in result.stderr
    assert trace_file.is_file()
    assert trace_file.read_text() == ""
    assert first_helper.read_bytes() == helper_before


def test_signer_aborts_when_recursive_metadata_enumerator_fails(
    tmp_path: Path,
) -> None:
    staged_app = _nested_code_fixture(tmp_path)
    first_helper = staged_app / "Contents" / "Helpers" / "localocr"
    helper_before = first_helper.read_bytes()
    trace_file = tmp_path / "codesign-invocations.txt"
    failing_enumerator = tmp_path / "failing-find"
    failing_enumerator.write_text(
        "#!/usr/bin/env bash\n"
        "printf '%s\\0' \"$1/Contents/Info.plist\"\n"
        "exit 73\n"
    )
    failing_enumerator.chmod(0o755)
    env = os.environ.copy()
    env["LOCALOCR_SIGNING_TRACE_FILE"] = str(trace_file)
    env["LOCALOCR_TEST_METADATA_ENUMERATOR"] = str(failing_enumerator)

    result = _run_script_test(
        "sign",
        "--test-xattr-preflight",
        str(staged_app),
        env=env,
    )

    assert result.returncode != 0
    assert "metadata candidate enumeration failed" in result.stderr
    assert trace_file.is_file()
    assert trace_file.read_text() == ""
    assert first_helper.read_bytes() == helper_before


@pytest.mark.parametrize(
    ("hostile_attribute", "later_benign_attribute"),
    (
        ("com.apple.FinderInfo", "com.apple.provenance"),
        ("com.apple.fileprovider.fpfs#P", "com.example.other"),
        ("com.apple.ResourceFork", "com.apple.provenance"),
    ),
)
def test_signer_does_not_mask_hostile_xattr_followed_by_benign_xattr(
    tmp_path: Path,
    hostile_attribute: str,
    later_benign_attribute: str,
) -> None:
    staged_app = _nested_code_fixture(tmp_path)
    first_helper = staged_app / "Contents" / "Helpers" / "localocr"
    helper_before = first_helper.read_bytes()
    trace_file = tmp_path / "codesign-invocations.txt"
    xattr_inspector = tmp_path / "controlled-xattr"
    xattr_inspector.write_text(
        "#!/usr/bin/env bash\n"
        f"printf '%s\\n' {shlex.quote(hostile_attribute)} "
        f"{shlex.quote(later_benign_attribute)}\n"
    )
    xattr_inspector.chmod(0o755)
    env = os.environ.copy()
    env["LOCALOCR_SIGNING_TRACE_FILE"] = str(trace_file)
    env["LOCALOCR_TEST_XATTR_INSPECTOR"] = str(xattr_inspector)

    result = _run_script_test(
        "sign",
        "--test-xattr-preflight",
        str(staged_app),
        env=env,
    )

    assert result.returncode != 0
    assert hostile_attribute in result.stderr
    assert trace_file.is_file()
    assert trace_file.read_text() == ""
    assert first_helper.read_bytes() == helper_before


def test_production_signer_refuses_to_sanitize_an_arbitrary_app(
    tmp_path: Path,
) -> None:
    arbitrary_app = _nested_code_fixture(tmp_path)
    sentinel = arbitrary_app / "Contents" / "Info.plist"
    subprocess.run(
        ["/usr/bin/xattr", "-w", "com.example.must-remain", "fixture", str(sentinel)],
        check=True,
    )
    result = subprocess.run(
        [
            "/bin/bash",
            "-c",
            (
                f"source {shlex.quote(str(RELEASE_SCRIPTS['sign']))}; "
                'STAGED_APP="$1"; preflight_direct_release_signing'
            ),
            "sign-preflight",
            str(arbitrary_app),
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    assert "physical staged app copy" in result.stderr
    assert "com.example.must-remain" in subprocess.run(
        ["/usr/bin/xattr", str(sentinel)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout


@pytest.mark.parametrize(
    "relative_bundle",
    (
        Path("Contents/PlugIns/Unexpected.appex"),
        Path("Contents/Applications/Unexpected.app"),
    ),
)
def test_signer_rejects_unexpected_extension_and_nested_app_directly(
    tmp_path: Path,
    relative_bundle: Path,
) -> None:
    staged_app = _nested_code_fixture(tmp_path)
    (staged_app / relative_bundle).mkdir(parents=True)

    result = _run_script_test("sign", "--test-nested-code", str(staged_app))

    assert result.returncode != 0
    assert "unexpected nested code bundle" in result.stderr


def test_signer_rejects_arbitrary_symlink_directly(tmp_path: Path) -> None:
    staged_app = _nested_code_fixture(tmp_path)
    resources = staged_app / "Contents" / "Resources"
    resources.mkdir()
    (resources / "alias").symlink_to(staged_app / "Contents" / "Info.plist")

    result = _run_script_test("sign", "--test-nested-code", str(staged_app))

    assert result.returncode != 0
    assert "unexpected nested code symlink" in result.stderr


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


def test_stage_cleanup_rejects_symlinked_release_root_without_deleting_target(
    tmp_path: Path,
) -> None:
    repo = tmp_path / "repo"
    dist = repo / "dist"
    outside = tmp_path / "outside"
    unsigned_app = tmp_path / "Unsigned.app"
    dist.mkdir(parents=True)
    outside.mkdir()
    unsigned_app.mkdir()
    sentinel = outside / "must-survive.txt"
    sentinel.write_text("keep")
    (dist / "direct-release").symlink_to(outside, target_is_directory=True)

    result = _run_script_test(
        "stage",
        "--test-cleanup-safety",
        str(repo),
        extra_arguments=(str(unsigned_app),),
    )

    assert result.returncode != 0
    assert "symlink" in result.stderr
    assert sentinel.read_text() == "keep"


def test_stage_cleanup_rejects_physical_input_within_release_root(
    tmp_path: Path,
) -> None:
    repo = tmp_path / "repo"
    unsigned_app = repo / "dist" / "direct-release" / "Unsigned.app"
    unsigned_app.mkdir(parents=True)
    sentinel = unsigned_app / "must-survive.txt"
    sentinel.write_text("keep")

    result = _run_script_test(
        "stage",
        "--test-cleanup-safety",
        str(repo),
        extra_arguments=(str(unsigned_app),),
    )

    assert result.returncode != 0
    assert "inside dist/direct-release" in result.stderr
    assert sentinel.read_text() == "keep"


def test_stage_cleanup_removes_only_canonical_release_root(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    release_root = repo / "dist" / "direct-release"
    unsigned_app = tmp_path / "Unsigned.app"
    release_root.mkdir(parents=True)
    unsigned_app.mkdir()
    (release_root / "generated.txt").write_text("remove")
    repo_sentinel = repo / "must-survive.txt"
    repo_sentinel.write_text("keep")

    result = _run_script_test(
        "stage",
        "--test-cleanup-safety",
        str(repo),
        extra_arguments=(str(unsigned_app),),
    )

    assert result.returncode == 0, result.stderr
    assert not release_root.exists()
    assert repo_sentinel.read_text() == "keep"


def test_stage_resolves_only_safe_bundle_executable_names(tmp_path: Path) -> None:
    unsigned_app = tmp_path / "Unsigned.app"
    macos_dir = unsigned_app / "Contents" / "MacOS"
    macos_dir.mkdir(parents=True)
    (macos_dir / "LocalOCR").write_bytes(b"fixture")
    (unsigned_app / "Contents" / "outside").write_bytes(b"fixture")
    (macos_dir / "subdir").mkdir()
    (macos_dir / "subdir" / "tool").write_bytes(b"fixture")
    (macos_dir / r"subdir\tool").write_bytes(b"fixture")

    accepted = _run_script_test(
        "stage",
        "--test-main-executable",
        str(unsigned_app),
        extra_arguments=("LocalOCR",),
    )
    assert accepted.returncode == 0, accepted.stderr

    for executable_name in ("", ".", "..", "../outside", "subdir/tool", r"subdir\tool"):
        rejected = _run_script_test(
            "stage",
            "--test-main-executable",
            str(unsigned_app),
            extra_arguments=(executable_name,),
        )
        assert rejected.returncode != 0, executable_name
        assert "nonempty basename" in rejected.stderr


def test_stage_rejects_bundle_executable_symlink_escape(tmp_path: Path) -> None:
    unsigned_app = tmp_path / "Unsigned.app"
    macos_dir = unsigned_app / "Contents" / "MacOS"
    outside_executable = tmp_path / "outside-tool"
    macos_dir.mkdir(parents=True)
    outside_executable.write_bytes(b"fixture")
    (macos_dir / "LocalOCR").symlink_to(outside_executable)

    result = _run_script_test(
        "stage",
        "--test-main-executable",
        str(unsigned_app),
        extra_arguments=("LocalOCR",),
    )

    assert result.returncode != 0
    assert "physically inside Contents/MacOS" in result.stderr


def test_stage_uses_confined_native_artifact_directory() -> None:
    expected = ROOT / "dist" / "direct-release" / "native-tools"
    stage_result = _run_script_test(
        "stage",
        "--test-native-artifact-dir",
        str(expected),
    )
    assert stage_result.returncode == 0, stage_result.stderr
    assert stage_result.stdout.strip() == str(expected)
    assert stage_result.stdout.strip() != str(ROOT / "dist" / "native-tools")

    build_result = subprocess.run(
        [
            "/bin/bash",
            str(SCRIPTS / "build-native-tools.sh"),
            "--test-artifact-dir",
            str(expected),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert build_result.returncode == 0, build_result.stderr


@pytest.mark.parametrize("use_explicit_artifact_dir", (False, True))
def test_build_native_tools_publishes_both_helpers_to_selected_directory(
    tmp_path: Path,
    use_explicit_artifact_dir: bool,
) -> None:
    isolated_repo = tmp_path / "repo"
    isolated_scripts = isolated_repo / "scripts"
    direct_release_root = isolated_repo / "dist" / "direct-release"
    stub_bin = tmp_path / "bin"
    isolated_scripts.mkdir(parents=True)
    direct_release_root.mkdir(parents=True)
    stub_bin.mkdir()
    build_script = isolated_scripts / "build-native-tools.sh"
    shutil.copy2(SCRIPTS / "build-native-tools.sh", build_script)

    swift_stub = stub_bin / "swift"
    swift_stub.write_text(
        """#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "package" && "$2" == "clean" ]]; then
    exit 0
fi
if [[ "$1" == "build" ]]; then
    product="${!#}"
    mkdir -p .build/release
    printf '#!/usr/bin/env sh\\nexit 0\\n' > ".build/release/$product"
    chmod 0755 ".build/release/$product"
    exit 0
fi
exit 64
"""
    )
    swift_stub.chmod(0o755)
    otool_stub = stub_bin / "otool"
    otool_stub.write_text("#!/usr/bin/env sh\nexit 0\n")
    otool_stub.chmod(0o755)
    install_name_tool_stub = stub_bin / "install_name_tool"
    install_name_tool_stub.write_text("#!/usr/bin/env sh\nexit 99\n")
    install_name_tool_stub.chmod(0o755)

    default_output = isolated_repo / "dist" / "native-tools"
    explicit_output = direct_release_root / "native-tools"
    expected_output = explicit_output if use_explicit_artifact_dir else default_output
    arguments = ["/bin/bash", str(build_script)]
    if use_explicit_artifact_dir:
        arguments.extend(("--artifact-dir", str(explicit_output)))
    env = os.environ.copy()
    env["PATH"] = f"{stub_bin}:/usr/bin:/bin"

    result = subprocess.run(
        arguments,
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )

    assert result.returncode == 0, result.stderr
    for helper in EXPECTED_HELPERS:
        helper_path = expected_output / helper
        assert helper_path.is_file()
        assert os.access(helper_path, os.X_OK)
    unexpected_output = default_output if use_explicit_artifact_dir else explicit_output
    assert not unexpected_output.exists()


@pytest.mark.parametrize("script", ("stage", "verify"))
def test_release_scripts_require_arm64_and_macos_14_or_later(script: str) -> None:
    _assert_script_test_accepts(script, "--test-architecture", "arm64")
    for architecture in ("x86_64", "arm64 x86_64"):
        _assert_script_test_rejects(script, "--test-architecture", architecture)

    for minimum_version in ("14.0", "14.6", "15.0"):
        _assert_script_test_accepts(script, "--test-minimum-macos", minimum_version)
    for minimum_version in ("13.6", "10.15", ""):
        _assert_script_test_rejects(script, "--test-minimum-macos", minimum_version)


def test_verifier_reads_complete_build_version_output_under_pipefail() -> None:
    result = subprocess.run(
        [
            "/bin/bash",
            "-c",
            (
                "set -euo pipefail; "
                f"source {shlex.quote(str(RELEASE_SCRIPTS['verify']))}; "
                "binary_minimum_macos /usr/bin/codesign"
            ),
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert re.fullmatch(r"\d+(?:\.\d+){1,2}\n", result.stdout)


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


def test_verifier_requires_exact_developer_id_authority_details() -> None:
    accepted = "\n".join(
        (
            "CodeDirectory v=20500 size=10 flags=0x10000(runtime) hashes=1+2 location=embedded",
            f"Authority={EXPECTED_IDENTITY}",
            "Authority=Developer ID Certification Authority",
            "Authority=Apple Root CA",
            "Timestamp=Jul 29, 2026 at 12:46:27 PM",
            f"TeamIdentifier={EXPECTED_TEAM}",
        )
    )
    _assert_script_test_accepts("verify", "--test-signature-details", accepted)

    rejected_vectors = (
        accepted.replace(f"Authority={EXPECTED_IDENTITY}\n", ""),
        accepted.replace(EXPECTED_IDENTITY, "Developer ID Application: Other Person (DZ8B5454ZN)"),
        accepted.replace(
            f"TeamIdentifier={EXPECTED_TEAM}",
            "TeamIdentifier=OTHERTEAM",
        ),
        accepted.replace("Timestamp=Jul 29, 2026 at 12:46:27 PM", "Timestamp=none"),
        accepted.replace("flags=0x10000(runtime)", "flags=0x0(none)"),
    )
    for rejected in rejected_vectors:
        _assert_script_test_rejects(
            "verify",
            "--test-signature-details",
            rejected,
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
        "/usr/lib/../local/libevil.dylib",
        "/usr/lib/./libSystem.B.dylib",
        "/usr/lib//libSystem.B.dylib",
        "/usr/lib/swift/../../libevil.dylib",
        "/System/Library/../Applications/Evil.framework/Evil",
        "/System/Library//Frameworks/Vision.framework/Vision",
        "/System/Library/Frameworks/./Vision.framework/Vision",
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


def _write_download_test_tool_dispatcher(tool_dir: Path) -> None:
    tool_dir.mkdir()
    dispatcher = tool_dir / "dispatcher"
    dispatcher.write_text(
        """#!/usr/bin/env bash
set -euo pipefail
tool="${0##*/}"
trace="${LOCALOCR_TEST_TRACE:?}"
printf '%s' "$tool" >> "$trace"
for argument in "$@"; do
    printf ' %q' "$argument" >> "$trace"
done
printf '\\n' >> "$trace"

case "$tool" in
    shasum)
        exec /usr/bin/shasum "$@"
        ;;
    zipinfo)
        exec /usr/bin/zipinfo "$@"
        ;;
    ditto)
        exec /usr/bin/ditto "$@"
        ;;
    file)
        printf 'Mach-O 64-bit executable arm64\\n'
        ;;
    lipo)
        printf 'arm64\\n'
        ;;
    otool)
        if [[ "$1" == "-L" ]]; then
            printf '%s:\\n' "$2"
            printf '\\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1336.61.1)\\n'
        else
            cat <<'EOF'
Load command 0
      cmd LC_BUILD_VERSION
    minos 14.0
Load command 1
      cmd LC_RPATH
     path /usr/lib/swift (offset 12)
EOF
        fi
        ;;
    strings)
        :
        ;;
    codesign)
        target="${!#}"
        target_name="${target##*/}"
        if [[ "$1" == "--verify" ]]; then
            :
        elif [[ "$1" == "-dv" ]]; then
            team="DZ8B5454ZN"
            if [[ "${LOCALOCR_TEST_BAD_SIGNATURE:-}" == "$target_name" ]]; then
                team="WRONGTEAM"
            fi
            if [[ "${LOCALOCR_TEST_EXTRA_AUTHORITY:-}" == "$target_name" ]]; then
                printf 'Authority=Developer ID Application: Other Person (DZ8B5454ZN)\\n'
            fi
            cat <<EOF
CodeDirectory v=20500 size=10 flags=0x10000(runtime) hashes=1+2 location=embedded
Authority=Developer ID Application: John Scott Ray (DZ8B5454ZN)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=Jul 29, 2026 at 12:46:27 PM
TeamIdentifier=$team
EOF
        elif [[ "$1" == "-d" ]]; then
            if [[ "${LOCALOCR_TEST_DEBUG_ENTITLEMENT:-}" == "$target_name" ]]; then
                printf '<plist><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>\\n'
            elif [[ "${LOCALOCR_TEST_FALSE_DEBUG_ENTITLEMENT:-}" == "$target_name" ]]; then
                printf '<plist><dict><key>com.apple.security.get-task-allow</key><false/></dict></plist>\\n'
            else
                printf '<plist><dict/></plist>\\n'
            fi
        fi
        ;;
    xcrun)
        if [[ "$1" == "--version" ]]; then
            printf 'xcrun version 72.\\n'
        elif [[ "$1" == "stapler" && "$2" == "validate" ]]; then
            printf 'The validate action worked!\\n'
        else
            exit 64
        fi
        ;;
    spctl)
        printf 'accepted\\n'
        ;;
    PlistBuddy)
        printf 'LocalOCR\\n'
        ;;
    sw_vers)
        case "$1" in
            -productVersion) printf '14.7.1\\n' ;;
            -buildVersion) printf '23H222\\n' ;;
            *) exit 64 ;;
        esac
        ;;
    sysctl)
        case "$2" in
            hw.model) printf 'MacFixture1,1\\n' ;;
            machdep.cpu.brand_string) printf 'Apple Test Chip\\n' ;;
            *) exit 64 ;;
        esac
        ;;
    uname)
        printf 'arm64\\n'
        ;;
    date)
        printf '2026-07-29T18:00:00Z\\n'
        ;;
    sleep)
        :
        ;;
    *)
        exit 64
        ;;
esac
"""
    )
    dispatcher.chmod(0o755)
    for tool in (
        "shasum",
        "zipinfo",
        "ditto",
        "file",
        "lipo",
        "otool",
        "strings",
        "codesign",
        "xcrun",
        "spctl",
        "PlistBuddy",
        "sw_vers",
        "sysctl",
        "uname",
        "date",
        "sleep",
    ):
        (tool_dir / tool).symlink_to(dispatcher)


def _create_download_release_fixture(tmp_path: Path) -> tuple[Path, Path]:
    fixture_root = tmp_path / "fixture-root"
    app = fixture_root / "LocalOCR Studio.app"
    macos = app / "Contents" / "MacOS"
    helpers = app / "Contents" / "Helpers"
    macos.mkdir(parents=True)
    helpers.mkdir()
    (app / "Contents" / "Info.plist").write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LocalOCR</string>
</dict></plist>
"""
    )
    main = macos / "LocalOCR"
    main.write_text("#!/bin/bash\nexit 0\n")
    main.chmod(0o755)
    cli = helpers / "localocr"
    cli.write_text(
        """#!/bin/bash
set -euo pipefail
printf 'localocr %s\\n' "$*" >> "${LOCALOCR_TEST_TRACE:?}"
if [[ "${1:-}" == "--version" ]]; then
    printf '%s\\n' "${LOCALOCR_TEST_CLI_VERSION:-${LOCALOCR_RELEASE_VERSION:?}}"
    exit 0
fi
case "${1:-}" in
    ocr|image)
        printf '{"text":"controlled fixture output"}\\n'
        ;;
    *)
        exit 64
        ;;
esac
"""
    )
    cli.chmod(0o755)
    mcp = helpers / "localocr-mcp"
    mcp.write_text(
        """#!/bin/bash
set -euo pipefail
request="$(/bin/cat)"
printf '%s\\n' "$request" > "${LOCALOCR_TEST_MCP_REQUEST:?}"
printf 'localocr-mcp initialize\\n' >> "${LOCALOCR_TEST_TRACE:?}"
version="${LOCALOCR_TEST_MCP_VERSION:-${LOCALOCR_RELEASE_VERSION:?}}"
printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"localocr-mcp","version":"%s"}}}\\n' "$version"
"""
    )
    mcp.chmod(0o755)

    archive = tmp_path / "downloaded candidate.zip"
    subprocess.run(
        ["/usr/bin/ditto", "-c", "-k", "--keepParent", str(app), str(archive)],
        check=True,
    )
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    checksum = tmp_path / "published checksum.sha256"
    checksum.write_text(f"{digest}  {archive.name}\n")
    return archive, checksum


def _run_download_release_fixture(
    tmp_path: Path,
    archive: Path,
    checksum: Path,
    *,
    extra_env: dict[str, str] | None = None,
    temp_parent: Path | None = None,
) -> tuple[subprocess.CompletedProcess[str], Path, Path]:
    tool_dir = tmp_path / "controlled-tools"
    _write_download_test_tool_dispatcher(tool_dir)
    trace = tmp_path / "tool-trace.txt"
    mcp_request = tmp_path / "mcp-request.json"
    extraction_parent = temp_parent or (tmp_path / "fresh-extractions")
    if temp_parent is None:
        extraction_parent.mkdir()
    env = os.environ.copy()
    env.update(
        {
            "LOCALOCR_RELEASE_VERSION": "0.2.0",
            "LOCALOCR_TEST_TRACE": str(trace),
            "LOCALOCR_TEST_MCP_REQUEST": str(mcp_request),
            "LOCALOCR_TEST_TEMP_PARENT": str(extraction_parent),
        }
    )
    if extra_env:
        env.update(extra_env)
    harness = """
source "$1"
tool_dir="$2"
shift 2
download_shasum="$tool_dir/shasum"
download_zipinfo="$tool_dir/zipinfo"
download_ditto="$tool_dir/ditto"
download_file="$tool_dir/file"
download_lipo="$tool_dir/lipo"
download_otool="$tool_dir/otool"
download_strings="$tool_dir/strings"
download_codesign="$tool_dir/codesign"
download_xcrun="$tool_dir/xcrun"
download_spctl="$tool_dir/spctl"
download_plist_buddy="$tool_dir/PlistBuddy"
download_sw_vers="$tool_dir/sw_vers"
download_sysctl="$tool_dir/sysctl"
download_uname="$tool_dir/uname"
download_date="$tool_dir/date"
download_sleep="$tool_dir/sleep"
download_temp_parent="$LOCALOCR_TEST_TEMP_PARENT"
download_main "$@"
"""
    result = subprocess.run(
        [
            "/bin/bash",
            "-c",
            harness,
            "download-test",
            str(RELEASE_SCRIPTS["download"]),
            str(tool_dir),
            str(archive),
            str(checksum),
        ],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )
    return result, trace, mcp_request


def _download_evidence_files(checksum: Path) -> list[Path]:
    return sorted(
        checksum.parent.glob("localocr-downloaded-release-evidence-*.txt")
    )


def test_downloaded_release_requires_exactly_two_absolute_file_arguments(
    tmp_path: Path,
) -> None:
    script = RELEASE_SCRIPTS["download"]
    for arguments in (
        (),
        ("relative.zip", "relative.sha256"),
        (str(tmp_path / "only.zip"),),
        (
            str(tmp_path / "one.zip"),
            str(tmp_path / "one.sha256"),
            str(tmp_path / "extra"),
        ),
    ):
        result = subprocess.run(
            ["/bin/bash", str(script), *arguments],
            check=False,
            capture_output=True,
            text=True,
        )
        assert result.returncode != 0


def test_downloaded_release_verifies_checksum_before_fresh_extraction_and_runs_all_gates(
    tmp_path: Path,
) -> None:
    archive, checksum = _create_download_release_fixture(tmp_path)

    result, trace_file, mcp_request = _run_download_release_fixture(
        tmp_path,
        archive,
        checksum,
    )

    assert result.returncode == 0, result.stderr
    trace = trace_file.read_text().splitlines()
    checksum_index = next(
        index
        for index, line in enumerate(trace)
        if line.startswith("shasum -a 256 ")
    )
    extraction_index = next(
        index
        for index, line in enumerate(trace)
        if line.startswith("ditto -x -k ")
    )
    assert checksum_index < extraction_index
    assert sum(line.startswith("file -b ") for line in trace) == 3
    assert sum(line.startswith("lipo -archs ") for line in trace) == 3
    assert sum(line.startswith("otool -L ") for line in trace) == 3
    assert sum(line.startswith("otool -l ") for line in trace) == 6
    assert sum(line.startswith("strings -a ") for line in trace) == 3
    assert any("stapler validate" in line for line in trace)
    assert any(line.startswith("spctl --assess --type execute") for line in trace)
    for code_object in ("localocr", "localocr-mcp", "LocalOCR\\ Studio.app"):
        assert any(
            line.startswith("codesign -dv --verbose=4 ")
            and line.endswith(code_object)
            for line in trace
        )
        assert any(
            line.startswith("codesign -d --entitlements :- ")
            and line.endswith(code_object)
            for line in trace
        )
    assert '"method":"initialize"' in mcp_request.read_text()
    assert '"version":"1.0"' in mcp_request.read_text()
    assert not any(
        line.startswith("localocr ocr ") or line.startswith("localocr image ")
        for line in trace
    )
    evidence_files = _download_evidence_files(checksum)
    assert len(evidence_files) == 1
    evidence = evidence_files[0].read_text()
    assert "UTC timestamp: 2026-07-29T18:00:00Z" in evidence
    assert "Toolchain: xcrun version 72." in evidence
    assert "macOS version: 14.7.1 (23H222)" in evidence
    assert "Mac model: MacFixture1,1" in evidence
    assert "Processor: Apple Test Chip" in evidence
    assert "CPU architecture: arm64" in evidence
    assert f"ZIP SHA-256: {hashlib.sha256(archive.read_bytes()).hexdigest()}" in evidence
    assert "OCR smoke input type: not supplied" in evidence
    assert "OCR smoke result: SKIPPED" in evidence
    assert "Overall result: PASS" in evidence
    assert list((tmp_path / "fresh-extractions").iterdir()) == []


def test_downloaded_release_checksum_failure_never_extracts(
    tmp_path: Path,
) -> None:
    archive, checksum = _create_download_release_fixture(tmp_path)
    checksum.write_text(f"{'0' * 64}  {archive.name}\n")

    result, trace_file, _ = _run_download_release_fixture(
        tmp_path,
        archive,
        checksum,
    )

    assert result.returncode != 0
    trace = trace_file.read_text().splitlines()
    assert any(line.startswith("shasum -a 256 ") for line in trace)
    assert not any(line.startswith("ditto -x -k ") for line in trace)
    assert list((tmp_path / "fresh-extractions").iterdir()) == []
    evidence = _download_evidence_files(checksum)[0].read_text()
    assert "Checksum verification: FAIL" in evidence
    assert "Overall result: FAIL" in evidence


def test_downloaded_release_rejects_traversal_archive_before_extraction(
    tmp_path: Path,
) -> None:
    import zipfile

    archive = tmp_path / "adversarial.zip"
    with zipfile.ZipFile(archive, "w") as package:
        package.writestr("../outside-must-not-exist", "bad")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    checksum = tmp_path / "adversarial.sha256"
    checksum.write_text(f"{digest}  {archive.name}\n")
    outside = tmp_path / "outside-must-not-exist"

    result, trace_file, _ = _run_download_release_fixture(
        tmp_path,
        archive,
        checksum,
    )

    assert result.returncode != 0
    assert not outside.exists()
    assert not any(
        line.startswith("ditto -x -k ")
        for line in trace_file.read_text().splitlines()
    )
    evidence = _download_evidence_files(checksum)[0].read_text()
    assert "Archive path safety: FAIL" in evidence


@pytest.mark.parametrize(
    "extra_env",
    (
        {"LOCALOCR_TEST_BAD_SIGNATURE": "localocr-mcp"},
        {"LOCALOCR_TEST_EXTRA_AUTHORITY": "localocr"},
        {"LOCALOCR_TEST_DEBUG_ENTITLEMENT": "LocalOCR Studio.app"},
        {"LOCALOCR_TEST_FALSE_DEBUG_ENTITLEMENT": "localocr"},
        {"LOCALOCR_TEST_CLI_VERSION": "9.9.9"},
        {"LOCALOCR_TEST_MCP_VERSION": "9.9.9"},
    ),
)
def test_downloaded_release_fails_closed_on_signature_entitlement_and_version_mismatches(
    tmp_path: Path,
    extra_env: dict[str, str],
) -> None:
    archive, checksum = _create_download_release_fixture(tmp_path)

    result, _, _ = _run_download_release_fixture(
        tmp_path,
        archive,
        checksum,
        extra_env=extra_env,
    )

    assert result.returncode != 0
    evidence = _download_evidence_files(checksum)[0].read_text()
    assert "Overall result: FAIL" in evidence


def test_downloaded_release_optional_smoke_records_type_not_content_or_paths(
    tmp_path: Path,
) -> None:
    archive, checksum = _create_download_release_fixture(tmp_path)
    smoke_input = tmp_path / "customer-987654-private-scan.png"
    smoke_input.write_text("PRIVATE-DOCUMENT-CONTENT-DO-NOT-RECORD")
    before = hashlib.sha256(smoke_input.read_bytes()).hexdigest()

    result, trace_file, _ = _run_download_release_fixture(
        tmp_path,
        archive,
        checksum,
        extra_env={"LOCALOCR_SMOKE_INPUT": str(smoke_input)},
    )

    assert result.returncode == 0, result.stderr
    assert hashlib.sha256(smoke_input.read_bytes()).hexdigest() == before
    assert any(
        line.startswith("localocr image ") for line in trace_file.read_text().splitlines()
    )
    evidence = _download_evidence_files(checksum)[0].read_text()
    assert "OCR smoke input type: PNG image" in evidence
    assert "OCR smoke result: PASS" in evidence
    for forbidden in (
        str(tmp_path),
        archive.name,
        checksum.name,
        smoke_input.name,
        "PRIVATE-DOCUMENT-CONTENT-DO-NOT-RECORD",
    ):
        assert forbidden not in evidence


def test_downloaded_release_cleanup_refuses_unconfined_temp_path(
    tmp_path: Path,
) -> None:
    archive, checksum = _create_download_release_fixture(tmp_path)
    outside = tmp_path / "outside-extraction"
    outside.mkdir()
    sentinel = outside / "must-survive.txt"
    sentinel.write_text("keep")
    controlled_parent = tmp_path / "controlled-parent-link"
    controlled_parent.symlink_to(outside, target_is_directory=True)

    result, _, _ = _run_download_release_fixture(
        tmp_path,
        archive,
        checksum,
        temp_parent=controlled_parent,
    )

    assert result.returncode != 0
    assert sentinel.read_text() == "keep"


def test_prepublication_scripts_do_not_touch_beta_metrics() -> None:
    for path in PREPUBLICATION_SCRIPTS:
        assert path.is_file(), f"missing pre-publication script: {path}"
        script = path.read_text()
        for beta_record in FORBIDDEN_BETA_RECORDS:
            assert beta_record not in script


def _run_notarization_flow_test(
    tmp_path: Path,
    submission_result: dict[str, str],
    *,
    fail_step: str = "",
    preexisting_final: bool = False,
    profile: str = "controlled-test-profile",
    release_version: str = "0.2.0",
    release_build: str = "42",
    create_staged_app: bool = True,
) -> tuple[subprocess.CompletedProcess[str], list[str], Path]:
    submission_json = tmp_path / "submission-result.json"
    release_root = tmp_path / "localocr-notarize-test.fixture"
    trace_file = release_root / "notarization-trace.txt"
    release_root.mkdir(exist_ok=True)
    (release_root / ".localocr-notarize-test-root").write_text(
        "LOCALOCR NOTARIZATION TEST ROOT\n"
    )
    if create_staged_app:
        (release_root / "staged" / "LocalOCR Studio.app").mkdir(parents=True)
    if preexisting_final:
        final_dir = release_root / "final"
        final_dir.mkdir(parents=True)
        (final_dir / "LocalOCR-Studio-0.2.0-42.zip").write_text("stale")
        (final_dir / "LocalOCR-Studio-0.2.0-42.sha256").write_text("stale")
    submission_json.write_text(
        "{"
        f'"id": "{submission_result["id"]}", '
        f'"status": "{submission_result["status"]}"'
        "}\n"
    )
    env = os.environ.copy()
    env.update(
        {
            "LOCALOCR_NOTARY_PROFILE": profile,
            "LOCALOCR_RELEASE_VERSION": release_version,
            "LOCALOCR_RELEASE_BUILD": release_build,
            "LOCALOCR_TEST_FAIL_STEP": fail_step,
        }
    )

    result = _run_script_test(
        "notarize",
        "--test-workflow",
        str(submission_json),
        extra_arguments=(str(trace_file), str(release_root)),
        env=env,
    )
    trace = trace_file.read_text().splitlines() if trace_file.is_file() else []
    return result, trace, release_root


def test_notarization_workflow_uses_required_safe_commands() -> None:
    script = _script("notarize")
    verify_script = _script("verify")

    assert "set -x" not in script
    assert "bash -x" not in script
    assert "verify_direct_release_signatures" in script
    assert "ditto -c -k --keepParent" in script
    assert "--wait" in script
    assert "--output-format json" in script
    assert "notary-submit.json" in script
    assert "notary-log.json" in script
    assert "stapler staple" in script
    assert "stapler validate" in script
    assert "spctl --assess --type execute" in script
    assert "shasum -a 256" in script
    assert "mktemp -d" in script
    assert "ditto -x -k" in script
    assert "verify_final_extracted_release" in script
    assert "Contents/Helpers/localocr" in verify_script
    assert "--version" in verify_script
    assert '"method":"initialize"' in verify_script
    assert "codesign --verify --deep --strict" in verify_script
    assert "verify_binary_dependencies" in verify_script
    assert "verify_binary_rpaths" in verify_script
    _assert_notarytool_profile_policy(
        script,
        required_subcommands=NOTARY_SUBCOMMANDS,
    )
    _assert_no_hard_coded_credentials(script)


def test_notarization_accepted_flow_orders_verification_and_apple_gates(
    tmp_path: Path,
) -> None:
    result, trace, release_root = _run_notarization_flow_test(
        tmp_path,
        {"id": "accepted-submission-id", "status": "Accepted"},
    )

    assert result.returncode == 0, result.stderr
    assert trace == [
        "verify-signed-app",
        "notary-history",
        "create-submission-zip",
        "notary-submit",
        "stapler-staple",
        "stapler-validate",
        "spctl-assess",
        "create-final-zip",
        "create-final-sha256",
        "extract-final-zip",
        "extracted-signatures",
        "extracted-dependencies",
        "extracted-rpaths",
        "extracted-stapler-validate",
        "extracted-spctl-assess",
        "extracted-localocr-version",
        "extracted-mcp-initialize-version",
        "publish-final-candidate",
    ]
    evidence = release_root / "evidence"
    assert (evidence / "notary-submit.json").read_text() == (
        '{"id": "accepted-submission-id", "status": "Accepted"}\n'
    )
    assert not (evidence / "notary-log.json").exists()
    final_dir = release_root / "final"
    final_zip = final_dir / "TEST-ONLY-NOT-A-RELEASE-0.2.0-42.fakezip"
    final_checksum = final_dir / "TEST-ONLY-NOT-A-RELEASE-0.2.0-42.test-sha256"
    assert final_zip.is_file()
    assert final_checksum.is_file()
    checksum_result = subprocess.run(
        ["/usr/bin/shasum", "-a", "256", "-c", final_checksum.name],
        cwd=final_dir,
        check=False,
        capture_output=True,
        text=True,
    )
    assert checksum_result.returncode == 0, checksum_result.stderr
    assert not any(final_dir.glob("*.partial*"))
    assert not any((release_root / "tmp").glob("final-verification.*"))
    assert not list(final_dir.glob("LocalOCR-Studio-*"))


def test_notarization_rejection_fetches_log_and_never_staples_or_packages(
    tmp_path: Path,
) -> None:
    result, trace, release_root = _run_notarization_flow_test(
        tmp_path,
        {"id": "rejected-submission-id", "status": "Invalid"},
        preexisting_final=True,
    )

    assert result.returncode != 0
    assert "not accepted" in result.stderr
    assert trace == [
        "verify-signed-app",
        "notary-history",
        "create-submission-zip",
        "notary-submit",
        "notary-log",
    ]
    evidence = release_root / "evidence"
    assert (evidence / "notary-log.json").is_file()
    assert not any((release_root / "final").iterdir())


def test_notarization_requires_a_nonempty_external_profile(
    tmp_path: Path,
) -> None:
    result, trace, release_root = _run_notarization_flow_test(
        tmp_path,
        {"id": "must-not-submit", "status": "Accepted"},
        profile="",
        preexisting_final=True,
    )

    assert result.returncode != 0
    assert "profile must be nonempty" in result.stderr
    assert trace == []
    assert not any((release_root / "final").iterdir())


@pytest.mark.parametrize(
    ("submission_result", "expected_message"),
    (
        ({"id": "", "status": "Accepted"}, "submission ID"),
        ({"id": "submission-id", "status": ""}, "status"),
    ),
)
def test_notarization_rejects_incomplete_submission_json(
    tmp_path: Path,
    submission_result: dict[str, str],
    expected_message: str,
) -> None:
    result, trace, release_root = _run_notarization_flow_test(
        tmp_path,
        submission_result,
    )

    assert result.returncode != 0
    assert expected_message in result.stderr
    assert "stapler-staple" not in trace
    final_dir = release_root / "final"
    assert not final_dir.exists() or not any(final_dir.iterdir())


def test_notarization_rejects_malformed_submission_json_without_final_artifacts(
    tmp_path: Path,
) -> None:
    submission_json = tmp_path / "malformed-submission-result.json"
    release_root = tmp_path / "localocr-notarize-test.malformed"
    trace_file = release_root / "notarization-trace.txt"
    release_root.mkdir()
    (release_root / ".localocr-notarize-test-root").write_text(
        "LOCALOCR NOTARIZATION TEST ROOT\n"
    )
    (release_root / "staged" / "LocalOCR Studio.app").mkdir(parents=True)
    submission_json.write_text('{"id": "broken"')
    env = os.environ.copy()
    env.update(
        {
            "LOCALOCR_NOTARY_PROFILE": "controlled-test-profile",
            "LOCALOCR_RELEASE_VERSION": "0.2.0",
            "LOCALOCR_RELEASE_BUILD": "42",
        }
    )

    result = _run_script_test(
        "notarize",
        "--test-workflow",
        str(submission_json),
        extra_arguments=(str(trace_file), str(release_root)),
        env=env,
    )

    assert result.returncode != 0
    assert "submission ID" in result.stderr
    assert "stapler-staple" not in trace_file.read_text().splitlines()
    final_dir = release_root / "final"
    assert not final_dir.exists() or not any(final_dir.iterdir())


@pytest.mark.parametrize(
    "fail_step",
    (
        "verify-signed-app",
        "notary-history",
        "create-submission-zip",
        "notary-submit",
        "stapler-staple",
        "stapler-validate",
        "spctl-assess",
        "create-final-zip",
        "create-final-sha256",
        "extract-final-zip",
        "extracted-signatures",
        "extracted-dependencies",
        "extracted-rpaths",
        "extracted-stapler-validate",
        "extracted-spctl-assess",
        "extracted-localocr-version",
        "extracted-mcp-initialize-version",
        "publish-final-candidate",
    ),
)
def test_notarization_failure_never_leaves_partial_or_final_candidate(
    tmp_path: Path,
    fail_step: str,
) -> None:
    outside_sentinel = tmp_path / "outside-must-survive.txt"
    outside_sentinel.write_text("keep")
    result, trace, release_root = _run_notarization_flow_test(
        tmp_path,
        {"id": "accepted-submission-id", "status": "Accepted"},
        fail_step=fail_step,
        preexisting_final=True,
    )

    assert result.returncode != 0
    assert fail_step in trace
    final_dir = release_root / "final"
    assert not final_dir.exists() or not any(final_dir.iterdir())
    temp_dir = release_root / "tmp"
    assert not temp_dir.exists() or not any(temp_dir.iterdir())
    assert outside_sentinel.read_text() == "keep"


def test_notarization_refuses_symlinked_temp_root_without_touching_target(
    tmp_path: Path,
) -> None:
    submission_json = tmp_path / "submission-result.json"
    release_root = tmp_path / "localocr-notarize-test.symlink"
    trace_file = release_root / "notarization-trace.txt"
    outside = tmp_path / "outside"
    outside.mkdir()
    sentinel = outside / "must-survive.txt"
    sentinel.write_text("keep")
    release_root.mkdir()
    (release_root / ".localocr-notarize-test-root").write_text(
        "LOCALOCR NOTARIZATION TEST ROOT\n"
    )
    (release_root / "staged" / "LocalOCR Studio.app").mkdir(parents=True)
    (release_root / "tmp").symlink_to(outside, target_is_directory=True)
    submission_json.write_text(
        '{"id": "must-not-submit", "status": "Accepted"}\n'
    )
    env = os.environ.copy()
    env.update(
        {
            "LOCALOCR_NOTARY_PROFILE": "controlled-test-profile",
            "LOCALOCR_RELEASE_VERSION": "0.2.0",
            "LOCALOCR_RELEASE_BUILD": "42",
        }
    )

    result = _run_script_test(
        "notarize",
        "--test-workflow",
        str(submission_json),
        extra_arguments=(str(trace_file), str(release_root)),
        env=env,
    )

    assert result.returncode != 0
    assert "must not be symlinks" in result.stderr
    assert trace_file.read_text() == ""
    assert sentinel.read_text() == "keep"


@pytest.mark.parametrize(
    ("profile", "release_version", "release_build", "create_staged_app"),
    (
        ("", "0.2.0", "42", True),
        ("controlled-test-profile", "../escape", "42", True),
        ("controlled-test-profile", "0.2.0", "not-numeric", True),
        ("controlled-test-profile", "0.2.0", "42", False),
    ),
)
def test_notarization_invalidates_stale_official_candidate_before_early_failure(
    tmp_path: Path,
    profile: str,
    release_version: str,
    release_build: str,
    create_staged_app: bool,
) -> None:
    outside_sentinel = tmp_path / "outside-must-survive.txt"
    outside_sentinel.write_text("keep")
    result, trace, release_root = _run_notarization_flow_test(
        tmp_path,
        {"id": "must-not-submit", "status": "Accepted"},
        profile=profile,
        release_version=release_version,
        release_build=release_build,
        create_staged_app=create_staged_app,
        preexisting_final=True,
    )

    assert result.returncode != 0
    assert trace == []
    assert not any((release_root / "final").iterdir())
    assert outside_sentinel.read_text() == "keep"


@pytest.mark.parametrize("symlink_name", ("evidence", "submission"))
def test_notarization_rejects_symlinked_output_directory_without_outside_mutation(
    tmp_path: Path,
    symlink_name: str,
) -> None:
    submission_json = tmp_path / "submission-result.json"
    release_root = tmp_path / f"localocr-notarize-test.{symlink_name}"
    trace_file = release_root / "notarization-trace.txt"
    outside = tmp_path / f"outside-{symlink_name}"
    outside.mkdir()
    sentinel = outside / "must-survive.txt"
    sentinel.write_text("keep")
    release_root.mkdir()
    (release_root / ".localocr-notarize-test-root").write_text(
        "LOCALOCR NOTARIZATION TEST ROOT\n"
    )
    (release_root / "staged" / "LocalOCR Studio.app").mkdir(parents=True)
    final_dir = release_root / "final"
    final_dir.mkdir()
    (final_dir / "LocalOCR-Studio-stale.zip").write_text("stale")
    (final_dir / "LocalOCR-Studio-stale.sha256").write_text("stale")
    (release_root / symlink_name).symlink_to(outside, target_is_directory=True)
    submission_json.write_text(
        '{"id": "must-not-submit", "status": "Accepted"}\n'
    )
    env = os.environ.copy()
    env.update(
        {
            "LOCALOCR_NOTARY_PROFILE": "controlled-test-profile",
            "LOCALOCR_RELEASE_VERSION": "0.2.0",
            "LOCALOCR_RELEASE_BUILD": "42",
        }
    )

    result = _run_script_test(
        "notarize",
        "--test-workflow",
        str(submission_json),
        extra_arguments=(str(trace_file), str(release_root)),
        env=env,
    )

    assert result.returncode != 0
    assert "must not be symlinks" in result.stderr
    assert trace_file.read_text() == ""
    assert not any(final_dir.iterdir())
    assert sentinel.read_text() == "keep"


def test_notarization_test_mode_rejects_repo_release_root_without_mutation(
    tmp_path: Path,
) -> None:
    submission_json = tmp_path / "submission-result.json"
    trace_file = tmp_path / "notarization-trace.txt"
    release_root = ROOT / "dist" / "direct-release"
    existed_before = release_root.exists()
    tree_before = (
        sorted(
            (
                str(path.relative_to(release_root)),
                path.lstat().st_mode,
                path.lstat().st_size,
                path.lstat().st_mtime_ns,
            )
            for path in release_root.rglob("*")
        )
        if existed_before
        else []
    )
    submission_json.write_text(
        '{"id": "must-not-submit", "status": "Accepted"}\n'
    )
    env = os.environ.copy()
    env.update(
        {
            "LOCALOCR_NOTARY_PROFILE": "controlled-test-profile",
            "LOCALOCR_RELEASE_VERSION": "0.2.0",
            "LOCALOCR_RELEASE_BUILD": "42",
        }
    )

    result = _run_script_test(
        "notarize",
        "--test-workflow",
        str(submission_json),
        extra_arguments=(str(trace_file), str(release_root)),
        env=env,
    )

    assert result.returncode != 0
    assert "system temporary directory" in result.stderr
    assert release_root.exists() == existed_before
    tree_after = (
        sorted(
            (
                str(path.relative_to(release_root)),
                path.lstat().st_mode,
                path.lstat().st_size,
                path.lstat().st_mtime_ns,
            )
            for path in release_root.rglob("*")
        )
        if release_root.exists()
        else []
    )
    assert tree_after == tree_before


def test_notarization_test_mode_rejects_unmarked_arbitrary_temp_without_mutation(
    tmp_path: Path,
) -> None:
    submission_json = tmp_path / "submission-result.json"
    trace_file = tmp_path / "notarization-trace.txt"
    release_root = tmp_path / "arbitrary"
    final_dir = release_root / "final"
    final_dir.mkdir(parents=True)
    stale_zip = final_dir / "LocalOCR-Studio-stale.zip"
    stale_checksum = final_dir / "LocalOCR-Studio-stale.sha256"
    stale_zip.write_text("keep")
    stale_checksum.write_text("keep")
    submission_json.write_text(
        '{"id": "must-not-submit", "status": "Accepted"}\n'
    )
    env = os.environ.copy()
    env.update(
        {
            "LOCALOCR_NOTARY_PROFILE": "controlled-test-profile",
            "LOCALOCR_RELEASE_VERSION": "0.2.0",
            "LOCALOCR_RELEASE_BUILD": "42",
        }
    )

    result = _run_script_test(
        "notarize",
        "--test-workflow",
        str(submission_json),
        extra_arguments=(str(trace_file), str(release_root)),
        env=env,
    )

    assert result.returncode != 0
    assert "controlled temporary root" in result.stderr
    assert stale_zip.read_text() == "keep"
    assert stale_checksum.read_text() == "keep"
