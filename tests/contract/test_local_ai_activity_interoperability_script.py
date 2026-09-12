import os
import shutil
import subprocess
from pathlib import Path

import pytest


SCRIPT = Path("scripts/verify-local-ai-activity-interoperability.sh").resolve()
FIXTURE = Path(
    "tests/LocalOCRIntelligenceTests/Fixtures/LocalAIActivity/v1/"
    "localocr-foundation-models-active.json"
).resolve()


def _write_executable(path: Path, contents: str) -> None:
    path.write_text(contents)
    path.chmod(0o755)


def _make_ang_worktree(tmp_path: Path) -> tuple[Path, str]:
    worktree = tmp_path / "ang-reader"
    fixture = (
        worktree
        / "AI Neural GaugeTests/Fixtures/LocalAIActivity/v1/"
        "localocr-foundation-models-active.json"
    )
    fixture.parent.mkdir(parents=True)
    shutil.copyfile(FIXTURE, fixture)
    project = worktree / "AI Neural Gauge.xcodeproj"
    project.mkdir()
    (project / "project.pbxproj").write_text("// test project\n")
    (worktree / "reader-source.txt").write_text("reader\n")
    subprocess.run(["git", "init", "-q", str(worktree)], check=True)
    subprocess.run(["git", "-C", str(worktree), "add", "."], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(worktree),
            "-c",
            "user.name=Task 8 Contract",
            "-c",
            "user.email=task8@example.invalid",
            "commit",
            "-qm",
            "reader fixture",
        ],
        check=True,
    )
    head = subprocess.run(
        ["git", "-C", str(worktree), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    return worktree, head


def _make_tool_shims(tmp_path: Path) -> tuple[Path, Path]:
    shim_dir = tmp_path / "shims"
    shim_dir.mkdir()
    log = tmp_path / "tool-calls.log"
    _write_executable(
        shim_dir / "swift",
        """#!/bin/bash
set -eu
printf 'swift|%s|%s|%s|%s\\n' "$*" \
  "${LOCAL_AI_ACTIVITY_ACCEPTANCE_CONTAINER-<unset>}" \
  "${LOCAL_AI_ACTIVITY_ACCEPTANCE_EXPECTATION-<unset>}" \
  "${LOCAL_AI_ACTIVITY_ACCEPTANCE_NOW-<unset>}" >> "$SHIM_LOG"
""",
    )
    _write_executable(
        shim_dir / "xcodebuild",
        """#!/bin/bash
set -eu
printf 'xcodebuild|%s|%s|%s|%s\\n' "$*" \
  "${LOCAL_AI_ACTIVITY_ACCEPTANCE_CONTAINER-<unset>}" \
  "${LOCAL_AI_ACTIVITY_ACCEPTANCE_EXPECTATION-<unset>}" \
  "${LOCAL_AI_ACTIVITY_ACCEPTANCE_NOW-<unset>}" >> "$SHIM_LOG"
if [[ " $* " == *" build-for-testing "* ]]; then
  previous=""
  derived=""
  for argument in "$@"; do
    if [[ "$previous" == "-derivedDataPath" ]]; then derived="$argument"; fi
    previous="$argument"
  done
  mkdir -p "$derived/Build/Products"
  printf '%s\\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict><key>AI Neural GaugeTests</key><dict><key>EnvironmentVariables</key><dict/></dict></dict></plist>' \
    > "$derived/Build/Products/Reader.xctestrun"
fi
if [[ " $* " == *" test-without-building "* ]]; then
  case "${SHIM_READER_MODE-success}" in
    success) printf '%s\\n' 'Executed 1 test, with 0 failures' ;;
    skip) printf '%s\\n' 'Test skipped' ;;
    zero) printf '%s\\n' 'Executed 0 tests, with 0 failures' ;;
    change-head)
      if [[ ! -e "$TEST_ANG_REPO/.head-changed" ]]; then
        printf '%s\\n' changed >> "$TEST_ANG_REPO/reader-source.txt"
        touch "$TEST_ANG_REPO/.head-changed"
        git -C "$TEST_ANG_REPO" add reader-source.txt .head-changed
        git -C "$TEST_ANG_REPO" \
          -c user.name='Task 8 Contract' \
          -c user.email=task8@example.invalid \
          commit -qm 'change reader head during acceptance'
      fi
      printf '%s\\n' 'Executed 1 test, with 0 failures'
      ;;
    *) exit 92 ;;
  esac
fi
""",
    )
    return shim_dir, log


def _run_script(
    tmp_path: Path,
    worktree: Path,
    *,
    reader_mode: str = "success",
) -> tuple[subprocess.CompletedProcess[str], Path]:
    shim_dir, log = _make_tool_shims(tmp_path)
    environment = os.environ.copy()
    environment.update(
        {
            "ANG_WORKTREE": str(worktree),
            "PATH": f"{shim_dir}:{environment['PATH']}",
            "SHIM_LOG": str(log),
            "SHIM_READER_MODE": reader_mode,
            "TEST_ANG_REPO": str(worktree),
            "LOCAL_AI_ACTIVITY_ACCEPTANCE_CONTAINER": "inherited-container",
            "LOCAL_AI_ACTIVITY_ACCEPTANCE_EXPECTATION": "inherited-expectation",
            "LOCAL_AI_ACTIVITY_ACCEPTANCE_NOW": "inherited-now",
        }
    )
    result = subprocess.run(
        [str(SCRIPT)],
        cwd=Path.cwd(),
        env=environment,
        capture_output=True,
        text=True,
    )
    return result, log


def test_interoperability_script_has_exact_handshake():
    path = Path("scripts/verify-local-ai-activity-interoperability.sh")
    script = path.read_text()

    assert os.access(path, os.X_OK)
    assert "cmp --" in script
    assert "localocr-foundation-models-active.json" in script
    assert "swift test --filter LocalAIActivityContractTests" in script
    assert "mktemp -d" in script
    assert "trap 'rm -rf -- \"$acceptance_root\"' EXIT" in script
    assert "LOCAL_AI_ACTIVITY_ACCEPTANCE_CONTAINER" in script
    assert "LOCAL_AI_ACTIVITY_ACCEPTANCE_EXPECTATION" in script
    assert "LOCAL_AI_ACTIVITY_ACCEPTANCE_NOW" in script
    for phase in ["active", "success", "cancelled", "failure", "expired_recent"]:
        assert f'run_phase "{phase}"' in script
    for expectation in [
        "active",
        "recent_success",
        "recent_cancelled",
        "recent_failure",
        "expired_recent",
    ]:
        assert f'"{expectation}"' in script
    assert "LocalAIActivityCrossAppProducerTests" in script
    assert "LocalAIActivityCrossAppIntegrationTests" in script
    assert "build-for-testing" in script
    assert "EnvironmentVariables.LOCAL_AI_ACTIVITY_ACCEPTANCE_CONTAINER" in script
    assert "test-without-building" in script
    assert "Test skipped" in script


def test_interoperability_script_rejects_dirty_reader_before_running_tools(tmp_path):
    worktree, _ = _make_ang_worktree(tmp_path)
    (worktree / "dirty.txt").write_text("uncommitted\n")

    result, log = _run_script(tmp_path, worktree)

    assert result.returncode != 0
    assert "ANG_WORKTREE must be clean" in result.stderr
    assert not log.exists()


def test_interoperability_script_seals_clean_head_and_sanitizes_preliminary_tools(tmp_path):
    worktree, head = _make_ang_worktree(tmp_path)

    result, log = _run_script(tmp_path, worktree)

    assert result.returncode == 0, result.stdout + result.stderr
    assert f"AI Neural Gauge reader HEAD: {head}" in result.stdout
    assert f"AI Neural Gauge reader HEAD verified: {head}" in result.stdout
    lines = log.read_text().splitlines()
    preliminary = [
        line
        for line in lines
        if line.startswith("swift|test --filter LocalAIActivityContractTests|")
        or line.startswith("swift|test --filter LocalAIActivityIntegrationTests|")
        or (
            line.startswith("xcodebuild|")
            and "test-without-building" not in line
        )
    ]
    assert len(preliminary) == 4
    assert all(line.endswith("|<unset>|<unset>|<unset>") for line in preliminary)
    build_line = next(line for line in lines if "build-for-testing" in line)
    derived_data = Path(build_line.split(" -derivedDataPath ", 1)[1].split("|", 1)[0])
    assert not derived_data.parent.exists()


def test_interoperability_script_rejects_clean_but_changed_reader_head(tmp_path):
    worktree, original_head = _make_ang_worktree(tmp_path)

    result, _ = _run_script(tmp_path, worktree, reader_mode="change-head")

    assert result.returncode != 0
    assert original_head in result.stderr
    assert "ANG_WORKTREE HEAD changed during acceptance" in result.stderr


@pytest.mark.parametrize(
    ("reader_mode", "expected_error"),
    [
        ("skip", "reader skipped the injected active acceptance phase"),
        ("zero", "reader did not execute exactly one successful active acceptance test"),
    ],
)
def test_interoperability_script_rejects_skipped_or_zero_reader_test(
    tmp_path, reader_mode, expected_error
):
    worktree, _ = _make_ang_worktree(tmp_path)

    result, log = _run_script(tmp_path, worktree, reader_mode=reader_mode)

    assert result.returncode != 0
    assert expected_error in result.stderr
    build_line = next(line for line in log.read_text().splitlines() if "build-for-testing" in line)
    derived_data = Path(build_line.split(" -derivedDataPath ", 1)[1].split("|", 1)[0])
    assert not derived_data.parent.exists()


@pytest.mark.parametrize("missing", ["project", "fixture"])
def test_interoperability_script_rejects_missing_required_reader_path(tmp_path, missing):
    worktree, _ = _make_ang_worktree(tmp_path)
    target = (
        worktree / "AI Neural Gauge.xcodeproj"
        if missing == "project"
        else worktree
        / "AI Neural GaugeTests/Fixtures/LocalAIActivity/v1/"
        "localocr-foundation-models-active.json"
    )
    if target.is_dir():
        shutil.rmtree(target)
    else:
        target.unlink()
    subprocess.run(["git", "-C", str(worktree), "add", "-A"], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(worktree),
            "-c",
            "user.name=Task 8 Contract",
            "-c",
            "user.email=task8@example.invalid",
            "commit",
            "-qm",
            f"remove {missing}",
        ],
        check=True,
    )

    result, log = _run_script(tmp_path, worktree)

    assert result.returncode != 0
    assert f"required AI Neural Gauge {missing}" in result.stderr
    assert not log.exists()
