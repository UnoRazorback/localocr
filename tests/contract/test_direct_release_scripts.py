"""Executable policy contract for the direct-distribution release scripts."""

from __future__ import annotations

import subprocess
from pathlib import Path


ROOT = Path(__file__).parents[2]
SCRIPTS = ROOT / "scripts"
EXPECTED_IDENTITY = "Developer ID Application: John Scott Ray (DZ8B5454ZN)"
EXPECTED_TEAM = "DZ8B5454ZN"
EXPECTED_HELPERS = ("localocr", "localocr-mcp")
RELEASE_SCRIPTS = {
    "toolchain": SCRIPTS / "release-toolchain.sh",
    "stage": SCRIPTS / "stage-direct-release.sh",
    "sign": SCRIPTS / "sign-direct-release.sh",
    "notarize": SCRIPTS / "notarize-direct-release.sh",
    "verify": SCRIPTS / "verify-direct-release.sh",
}


def _script(name: str) -> str:
    path = RELEASE_SCRIPTS[name]
    assert path.is_file(), f"missing direct-release script: {path}"
    return path.read_text()


def _run_script_test(script: str, mode: str, value: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["/bin/bash", str(RELEASE_SCRIPTS[script]), mode, value],
        check=False,
        capture_output=True,
        text=True,
    )


def _assert_script_test_accepts(script: str, mode: str, value: str) -> None:
    result = _run_script_test(script, mode, value)
    assert result.returncode == 0, result.stderr


def _assert_script_test_rejects(script: str, mode: str, value: str) -> None:
    result = _run_script_test(script, mode, value)
    assert result.returncode != 0, result.stdout


def test_direct_release_scripts_enforce_immutable_policy() -> None:
    toolchain_script = _script("toolchain")
    stage_script = _script("stage")
    sign_script = _script("sign")
    notarize_script = _script("notarize")
    verify_script = _script("verify")
    release_scripts = (
        toolchain_script,
        stage_script,
        sign_script,
        notarize_script,
        verify_script,
    )

    assert EXPECTED_IDENTITY in sign_script
    assert EXPECTED_TEAM in toolchain_script
    assert "--options" in sign_script and "runtime" in sign_script
    assert "--timestamp" in sign_script
    assert sign_script.index('Contents/Helpers/localocr"') < sign_script.index('STAGED_APP}"')
    assert sign_script.index('Contents/Helpers/localocr-mcp"') < sign_script.index('STAGED_APP}"')
    assert "notarytool submit" in notarize_script
    assert "--keychain-profile" in notarize_script
    assert "LOCALOCR_NOTARY_PROFILE" in notarize_script
    assert "--wait" in notarize_script
    assert "stapler staple" in notarize_script
    assert "stapler validate" in verify_script
    assert "spctl --assess --type execute" in verify_script
    assert "otool -L" in verify_script
    assert "otool -l" in verify_script

    for helper in EXPECTED_HELPERS:
        assert f"Contents/Helpers/{helper}" in sign_script

    for release_script in release_scripts:
        assert "Xcode-beta" not in release_script
        assert "--deep --force" not in release_script
        assert "--apple-id" not in release_script
        assert "--password" not in release_script
        assert "--key " not in release_script
        assert "--key=" not in release_script
        assert "LocalOCR-Notary" not in release_script


def test_toolchain_rejects_nonstable_xcode_paths() -> None:
    _assert_script_test_accepts(
        "toolchain", "--test-developer-dir", "/Applications/Xcode.app/Contents/Developer"
    )
    for developer_dir in (
        "/Applications/Xcode-beta.app/Contents/Developer",
        "/Applications/Xcode-RC.app/Contents/Developer",
        "/Applications/Xcode Preview.app/Contents/Developer",
    ):
        _assert_script_test_rejects("toolchain", "--test-developer-dir", developer_dir)


def test_verifier_rejects_unapproved_rpaths() -> None:
    _assert_script_test_accepts("verify", "--test-rpath", "/usr/lib/swift")
    _assert_script_test_rejects(
        "verify",
        "--test-rpath",
        "/Applications/Xcode.app/Contents/Developer/usr/lib/swift/macosx",
    )


def test_verifier_rejects_unapproved_install_names() -> None:
    for install_name in (
        "/opt/homebrew/lib/libexample.dylib",
        "/usr/local/lib/libexample.dylib",
        "@rpath/third-party.dylib",
    ):
        _assert_script_test_rejects("verify", "--test-install-name", install_name)

    for install_name in (
        "/System/Library/Frameworks/Vision.framework/Versions/A/Vision",
        "/usr/lib/libSystem.B.dylib",
        "@rpath/libswiftCompatibilitySpan.dylib",
    ):
        _assert_script_test_accepts("verify", "--test-install-name", install_name)
