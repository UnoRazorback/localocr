#!/bin/bash
set -euo pipefail

: "${ANG_WORKTREE:?set ANG_WORKTREE to the clean AI Neural Gauge reader worktree}"
if [[ ! -d "$ANG_WORKTREE" ]] || { [[ ! -d "$ANG_WORKTREE/.git" ]] && [[ ! -f "$ANG_WORKTREE/.git" ]]; }; then
    echo "ANG_WORKTREE must name an AI Neural Gauge Git worktree" >&2
    exit 64
fi

producer_fixture="tests/LocalOCRIntelligenceTests/Fixtures/LocalAIActivity/v1/localocr-foundation-models-active.json"
reader_project="$ANG_WORKTREE/AI Neural Gauge.xcodeproj"
reader_fixture="$ANG_WORKTREE/AI Neural GaugeTests/Fixtures/LocalAIActivity/v1/localocr-foundation-models-active.json"
if [[ ! -d "$reader_project" ]]; then
    echo "required AI Neural Gauge project is missing: $reader_project" >&2
    exit 64
fi
if [[ ! -f "$reader_fixture" ]]; then
    echo "required AI Neural Gauge fixture is missing: $reader_fixture" >&2
    exit 64
fi
if [[ ! -f "$producer_fixture" ]]; then
    echo "required LocalOCR fixture is missing: $producer_fixture" >&2
    exit 64
fi

reader_status="$(git -C "$ANG_WORKTREE" status --porcelain --untracked-files=normal)"
if [[ -n "$reader_status" ]]; then
    echo "ANG_WORKTREE must be clean before acceptance" >&2
    printf '%s\n' "$reader_status" >&2
    exit 66
fi
reader_head="$(git -C "$ANG_WORKTREE" rev-parse --verify 'HEAD^{commit}')"
printf 'AI Neural Gauge reader HEAD: %s\n' "$reader_head"

unset LOCAL_AI_ACTIVITY_ACCEPTANCE_CONTAINER
unset LOCAL_AI_ACTIVITY_ACCEPTANCE_EXPECTATION
unset LOCAL_AI_ACTIVITY_ACCEPTANCE_NOW

cmp -- "$producer_fixture" "$reader_fixture"
swift test --filter LocalAIActivityContractTests
swift test --filter LocalAIActivityIntegrationTests
(
    cd "$ANG_WORKTREE"
    xcodebuild test \
        -project 'AI Neural Gauge.xcodeproj' \
        -scheme 'AI Neural Gauge' \
        -destination 'platform=macOS' \
        -only-testing:'AI Neural GaugeTests/LocalAIActivityContractTests'
)

acceptance_root="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-activity-acceptance.XXXXXX")"
trap 'rm -rf -- "$acceptance_root"' EXIT
acceptance_derived_data="$acceptance_root/DerivedData"
(
    cd "$ANG_WORKTREE"
    xcodebuild build-for-testing \
        -project 'AI Neural Gauge.xcodeproj' \
        -scheme 'AI Neural Gauge' \
        -destination 'platform=macOS' \
        -derivedDataPath "$acceptance_derived_data"
)
base_xctestrun="$(find "$acceptance_derived_data/Build/Products" -maxdepth 1 -name '*.xctestrun' -print -quit)"
if [[ -z "$base_xctestrun" ]] || [[ ! -f "$base_xctestrun" ]]; then
    echo "AI Neural Gauge build-for-testing did not produce one readable xctestrun file" >&2
    exit 65
fi

run_phase() {
    local phase="$1" producer_test="$2" expectation="$3" now="$4" reader_test="$5"
    local phase_xctestrun="$acceptance_derived_data/Build/Products/$phase.xctestrun"
    local reader_log="$acceptance_root/$phase-reader.log"
    local LOCAL_AI_ACTIVITY_ACCEPTANCE_CONTAINER="$acceptance_root/$phase"
    local LOCAL_AI_ACTIVITY_ACCEPTANCE_EXPECTATION="$expectation"
    local LOCAL_AI_ACTIVITY_ACCEPTANCE_NOW="$now"
    export LOCAL_AI_ACTIVITY_ACCEPTANCE_CONTAINER
    export LOCAL_AI_ACTIVITY_ACCEPTANCE_EXPECTATION
    export LOCAL_AI_ACTIVITY_ACCEPTANCE_NOW
    mkdir -p -- "$LOCAL_AI_ACTIVITY_ACCEPTANCE_CONTAINER"
    chmod 0700 "$LOCAL_AI_ACTIVITY_ACCEPTANCE_CONTAINER"
    swift test --filter "LocalAIActivityCrossAppProducerTests/$producer_test"
    cp -- "$base_xctestrun" "$phase_xctestrun"
    plutil -insert 'AI Neural GaugeTests.EnvironmentVariables.LOCAL_AI_ACTIVITY_ACCEPTANCE_CONTAINER' \
        -string "$LOCAL_AI_ACTIVITY_ACCEPTANCE_CONTAINER" "$phase_xctestrun"
    plutil -insert 'AI Neural GaugeTests.EnvironmentVariables.LOCAL_AI_ACTIVITY_ACCEPTANCE_EXPECTATION' \
        -string "$LOCAL_AI_ACTIVITY_ACCEPTANCE_EXPECTATION" "$phase_xctestrun"
    plutil -insert 'AI Neural GaugeTests.EnvironmentVariables.LOCAL_AI_ACTIVITY_ACCEPTANCE_NOW' \
        -string "$LOCAL_AI_ACTIVITY_ACCEPTANCE_NOW" "$phase_xctestrun"
    (
        cd "$ANG_WORKTREE"
        xcodebuild test-without-building \
            -xctestrun "$phase_xctestrun" \
            -destination 'platform=macOS' \
            -only-testing:"AI Neural GaugeTests/LocalAIActivityCrossAppIntegrationTests/$reader_test"
    ) | tee "$reader_log"
    if grep -Fq 'Test skipped' "$reader_log"; then
        echo "AI Neural Gauge reader skipped the injected $phase acceptance phase" >&2
        return 1
    fi
    if ! grep -Fq 'Executed 1 test, with 0 failures' "$reader_log"; then
        echo "AI Neural Gauge reader did not execute exactly one successful $phase acceptance test" >&2
        return 1
    fi
}

run_phase "active" "writeActiveFoundationModelsLease" "active" "2026-08-31T14:00:10Z" "testReadsProducerPhaseFromInjectedContainer"
run_phase "success" "writeEndedSuccessLease" "recent_success" "2026-08-31T14:01:00Z" "testReadsProducerPhaseFromInjectedContainer"
run_phase "cancelled" "writeEndedCancelledLease" "recent_cancelled" "2026-08-31T14:01:00Z" "testReadsProducerPhaseFromInjectedContainer"
run_phase "failure" "writeEndedFailureLease" "recent_failure" "2026-08-31T14:01:00Z" "testReadsProducerPhaseFromInjectedContainer"
run_phase "expired_recent" "writeExpiredRecentLease" "expired_recent" "2026-09-01T14:00:01Z" "testReadsProducerPhaseFromInjectedContainer"

reader_status="$(git -C "$ANG_WORKTREE" status --porcelain --untracked-files=normal)"
if [[ -n "$reader_status" ]]; then
    echo "ANG_WORKTREE became dirty during acceptance" >&2
    printf '%s\n' "$reader_status" >&2
    exit 66
fi
verified_reader_head="$(git -C "$ANG_WORKTREE" rev-parse --verify 'HEAD^{commit}')"
if [[ "$verified_reader_head" != "$reader_head" ]]; then
    echo "ANG_WORKTREE HEAD changed during acceptance: $reader_head -> $verified_reader_head" >&2
    exit 66
fi
printf 'AI Neural Gauge reader HEAD verified: %s\n' "$verified_reader_head"
