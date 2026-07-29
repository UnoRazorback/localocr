#!/usr/bin/env bash

set -euo pipefail

notarize_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
notarize_repo_root="$(cd "$notarize_script_dir/.." && pwd -P)"
# shellcheck source=scripts/release-toolchain.sh
source "$notarize_script_dir/release-toolchain.sh"
# shellcheck source=scripts/verify-direct-release.sh
source "$notarize_script_dir/verify-direct-release.sh"

NOTARIZE_RELEASE_ROOT="$notarize_repo_root/dist/direct-release"
STAGED_APP="$NOTARIZE_RELEASE_ROOT/staged/LocalOCR Studio.app"
EVIDENCE_DIR="$NOTARIZE_RELEASE_ROOT/evidence"
SUBMISSION_ZIP=""
NOTARY_SUBMIT_JSON=""
NOTARY_LOG_JSON=""
FINAL_DIR=""
FINAL_ZIP=""
FINAL_CHECKSUM=""
FINAL_ZIP_PARTIAL=""
FINAL_CHECKSUM_PARTIAL=""
FINAL_TEMP_ROOT=""
FINAL_EXTRACTION_DIR=""

notarize_test_mode=0
notarize_test_submission_json=""
notarize_trace_file=""
notarize_test_fail_step=""

configure_notarization_base_paths() {
    STAGED_APP="$NOTARIZE_RELEASE_ROOT/staged/LocalOCR Studio.app"
    EVIDENCE_DIR="$NOTARIZE_RELEASE_ROOT/evidence"
    FINAL_DIR="$NOTARIZE_RELEASE_ROOT/final"
    FINAL_TEMP_ROOT="$NOTARIZE_RELEASE_ROOT/tmp"
}

configure_notarization_paths() {
    local artifact_name

    if [[ "$notarize_test_mode" -eq 1 ]]; then
        artifact_name="TEST-ONLY-NOT-A-RELEASE-${LOCALOCR_RELEASE_VERSION}-${LOCALOCR_RELEASE_BUILD}.fakezip"
        FINAL_CHECKSUM="$FINAL_DIR/TEST-ONLY-NOT-A-RELEASE-${LOCALOCR_RELEASE_VERSION}-${LOCALOCR_RELEASE_BUILD}.test-sha256"
    else
        artifact_name="LocalOCR-Studio-${LOCALOCR_RELEASE_VERSION}-${LOCALOCR_RELEASE_BUILD}.zip"
        FINAL_CHECKSUM="$FINAL_DIR/${artifact_name%.zip}.sha256"
    fi
    SUBMISSION_ZIP="$NOTARIZE_RELEASE_ROOT/submission/$artifact_name"
    NOTARY_SUBMIT_JSON="$EVIDENCE_DIR/notary-submit.json"
    NOTARY_LOG_JSON="$EVIDENCE_DIR/notary-log.json"
    FINAL_ZIP="$FINAL_DIR/$artifact_name"
}

validate_controlled_test_root() {
    local physical_root
    local physical_system_temp
    local system_temp
    local marker="$NOTARIZE_RELEASE_ROOT/.localocr-notarize-test-root"
    local trace_parent

    [[ "$NOTARIZE_RELEASE_ROOT" == /* ]] || {
        echo "test workflow requires a controlled temporary root" >&2
        return 1
    }
    [[ -d "$NOTARIZE_RELEASE_ROOT" && ! -L "$NOTARIZE_RELEASE_ROOT" ]] || {
        echo "test workflow requires a controlled temporary root" >&2
        return 1
    }
    physical_root="$(cd "$NOTARIZE_RELEASE_ROOT" && pwd -P)"
    [[ "$physical_root" == "$NOTARIZE_RELEASE_ROOT" ]] || {
        echo "test workflow requires a physical controlled temporary root" >&2
        return 1
    }
    system_temp="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)"
    [[ -d "$system_temp" && ! -L "$system_temp" ]] || {
        echo "could not resolve the physical system temporary directory" >&2
        return 1
    }
    physical_system_temp="$(cd "$system_temp" && pwd -P)"
    case "$physical_root" in
        "$physical_system_temp"/*) ;;
        *)
            echo "test workflow root must remain under the system temporary directory" >&2
            return 1
            ;;
    esac
    case "$physical_root" in
        "$notarize_repo_root"|"$notarize_repo_root"/*)
            echo "test workflow cannot target the release repository" >&2
            return 1
            ;;
    esac
    [[ "$(/usr/bin/basename "$physical_root")" == localocr-notarize-test.* ]] || {
        echo "test workflow requires a controlled temporary root" >&2
        return 1
    }
    [[ -f "$marker" && ! -L "$marker" ]] || {
        echo "test workflow requires a controlled temporary root marker" >&2
        return 1
    }
    [[ "$(/bin/cat "$marker")" == "LOCALOCR NOTARIZATION TEST ROOT" ]] || {
        echo "test workflow has an invalid controlled temporary root marker" >&2
        return 1
    }
    trace_parent="$(cd "$(/usr/bin/dirname "$notarize_trace_file")" && pwd -P)"
    [[ "$trace_parent" == "$physical_root" && ! -L "$notarize_trace_file" ]] || {
        echo "test workflow trace must remain inside its controlled root" >&2
        return 1
    }
}

validate_notarization_inputs() {
    : "$LOCALOCR_NOTARY_PROFILE"
    : "$LOCALOCR_RELEASE_VERSION"
    : "$LOCALOCR_RELEASE_BUILD"

    [[ -n "$LOCALOCR_NOTARY_PROFILE" ]] || {
        echo "notary keychain profile must be nonempty" >&2
        return 1
    }
    [[ "$LOCALOCR_RELEASE_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
        echo "LOCALOCR_RELEASE_VERSION is not safe for a release filename" >&2
        return 1
    }
    [[ "$LOCALOCR_RELEASE_BUILD" =~ ^[0-9]+$ ]] || {
        echo "LOCALOCR_RELEASE_BUILD must be numeric" >&2
        return 1
    }
    [[ -d "$STAGED_APP" && ! -L "$STAGED_APP" ]] || {
        echo "signed staged app is missing or symlinked: $STAGED_APP" >&2
        return 1
    }
    [[ "$(cd "$STAGED_APP" && pwd -P)" == "$STAGED_APP" ]] || {
        echo "signed staged app must be the physical staged release copy" >&2
        return 1
    }
}

record_notarization_step() {
    [[ "$notarize_test_mode" -eq 1 ]] || return 0
    printf '%s\n' "$1" >> "$notarize_trace_file"
    [[ "$notarize_test_fail_step" != "$1" ]] || {
        echo "controlled notarization failure: $1" >&2
        return 1
    }
}

run_pre_notarization_verification() {
    if [[ "$notarize_test_mode" -eq 1 ]]; then
        record_notarization_step "verify-signed-app" || return
        return 0
    fi
    verify_direct_release_signatures "$STAGED_APP" \
        > "$EVIDENCE_DIR/pre-notarization-verification.txt" 2>&1
}

validate_notary_profile_access() {
    if [[ "$notarize_test_mode" -eq 1 ]]; then
        record_notarization_step "notary-history" || return
        return 0
    fi
    /usr/bin/xcrun notarytool history \
        --keychain-profile "$LOCALOCR_NOTARY_PROFILE" \
        --output-format json > /dev/null
}

create_submission_zip() {
    /bin/rm -f -- "$SUBMISSION_ZIP"
    if [[ "$notarize_test_mode" -eq 1 ]]; then
        record_notarization_step "create-submission-zip" || return
        : > "$SUBMISSION_ZIP"
        return 0
    fi
    /usr/bin/ditto -c -k --keepParent "$STAGED_APP" "$SUBMISSION_ZIP"
}

submit_for_notarization() {
    if [[ "$notarize_test_mode" -eq 1 ]]; then
        record_notarization_step "notary-submit" || return
        /usr/bin/ditto "$notarize_test_submission_json" "$NOTARY_SUBMIT_JSON"
        return 0
    fi
    /usr/bin/xcrun notarytool submit "$SUBMISSION_ZIP" \
        --keychain-profile "$LOCALOCR_NOTARY_PROFILE" \
        --wait \
        --output-format json > "$NOTARY_SUBMIT_JSON"
}

json_field() {
    local json_path="$1"
    local field="$2"

    /usr/bin/plutil -extract "$field" raw -o - -- "$json_path" 2>/dev/null
}

fetch_notarization_log() {
    local submission_id="$1"

    if [[ "$notarize_test_mode" -eq 1 ]]; then
        record_notarization_step "notary-log" || return
        printf '{"id":"%s","status":"Invalid"}\n' "$submission_id" \
            > "$NOTARY_LOG_JSON"
        return 0
    fi
    /usr/bin/xcrun notarytool log "$submission_id" \
        --keychain-profile "$LOCALOCR_NOTARY_PROFILE" \
        "$NOTARY_LOG_JSON"
}

staple_and_assess() {
    if [[ "$notarize_test_mode" -eq 1 ]]; then
        record_notarization_step "stapler-staple" || return
        record_notarization_step "stapler-validate" || return
        record_notarization_step "spctl-assess" || return
        : > "$EVIDENCE_DIR/stapler-staple.txt"
        : > "$EVIDENCE_DIR/stapler-validate.txt"
        : > "$EVIDENCE_DIR/gatekeeper-assessment.txt"
        return 0
    fi
    /usr/bin/xcrun stapler staple "$STAGED_APP" \
        > "$EVIDENCE_DIR/stapler-staple.txt" 2>&1
    /usr/bin/xcrun stapler validate "$STAGED_APP" \
        > "$EVIDENCE_DIR/stapler-validate.txt" 2>&1
    /usr/sbin/spctl --assess --type execute --verbose=2 "$STAGED_APP" \
        > "$EVIDENCE_DIR/gatekeeper-assessment.txt" 2>&1
}

validate_physical_release_root() {
    local physical_release_root

    [[ -d "$NOTARIZE_RELEASE_ROOT" && ! -L "$NOTARIZE_RELEASE_ROOT" ]] || {
        echo "direct-release output root is missing or symlinked" >&2
        return 1
    }
    physical_release_root="$(cd "$NOTARIZE_RELEASE_ROOT" && pwd -P)"
    [[ "$physical_release_root" == "$NOTARIZE_RELEASE_ROOT" ]] || {
        echo "direct-release output root is not physical" >&2
        return 1
    }
}

prepare_confined_output_directory() {
    local directory="$1"
    local label="$2"
    local physical_directory

    [[ "$(/usr/bin/dirname "$directory")" == "$NOTARIZE_RELEASE_ROOT" ]] || {
        echo "$label output directory is not a direct-release child" >&2
        return 1
    }
    [[ ! -L "$directory" ]] || {
        echo "$label output directories must not be symlinks" >&2
        return 1
    }
    /bin/mkdir -p "$directory"
    physical_directory="$(cd "$directory" && pwd -P)"
    [[ "$physical_directory" == "$directory" ]] || {
        echo "$label output directory escaped direct-release" >&2
        return 1
    }
}

prepare_final_directory_for_invalidation() {
    validate_physical_release_root
    prepare_confined_output_directory "$FINAL_DIR" "final"
}

invalidate_all_official_final_candidates() {
    local candidate

    for candidate in \
        "$FINAL_DIR"/LocalOCR-Studio-*.zip \
        "$FINAL_DIR"/LocalOCR-Studio-*.sha256
    do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        [[ -f "$candidate" || -L "$candidate" ]] || {
            echo "official final candidate path is not a file: $candidate" >&2
            return 1
        }
        /bin/rm -f -- "$candidate"
    done
}

prepare_remaining_output_directories() {
    validate_physical_release_root
    prepare_confined_output_directory "$EVIDENCE_DIR" "evidence"
    prepare_confined_output_directory \
        "$NOTARIZE_RELEASE_ROOT/submission" \
        "submission"
    prepare_confined_output_directory "$FINAL_TEMP_ROOT" "final verification"
    [[ "$(/usr/bin/dirname "$NOTARY_SUBMIT_JSON")" == "$EVIDENCE_DIR" ]] || {
        echo "notary evidence paths escaped the evidence directory" >&2
        return 1
    }
    [[ "$(/usr/bin/dirname "$NOTARY_LOG_JSON")" == "$EVIDENCE_DIR" ]] || {
        echo "notary evidence paths escaped the evidence directory" >&2
        return 1
    }
    [[ "$(/usr/bin/dirname "$SUBMISSION_ZIP")" == "$NOTARIZE_RELEASE_ROOT/submission" ]] || {
        echo "submission ZIP escaped the submission directory" >&2
        return 1
    }
}

clear_published_final_candidate() {
    [[ "$(/usr/bin/dirname "$FINAL_ZIP")" == "$FINAL_DIR" ]] || return 1
    [[ "$(/usr/bin/dirname "$FINAL_CHECKSUM")" == "$FINAL_DIR" ]] || return 1
    /bin/rm -f -- "$FINAL_ZIP" "$FINAL_CHECKSUM"
}

cleanup_partial_final_files() {
    local candidate

    for candidate in "$FINAL_ZIP_PARTIAL" "$FINAL_CHECKSUM_PARTIAL"; do
        [[ -n "$candidate" ]] || continue
        case "$candidate" in
            "$FINAL_DIR"/.*) /bin/rm -f -- "$candidate" ;;
            *)
                echo "refusing to remove an unconfined partial artifact" >&2
                return 1
                ;;
        esac
    done
    FINAL_ZIP_PARTIAL=""
    FINAL_CHECKSUM_PARTIAL=""
}

cleanup_final_extraction() {
    local physical_temp_root
    local physical_extraction

    [[ -n "$FINAL_EXTRACTION_DIR" ]] || return 0
    [[ -d "$FINAL_TEMP_ROOT" && ! -L "$FINAL_TEMP_ROOT" ]] || {
        echo "refusing cleanup because final temp root is unsafe" >&2
        return 1
    }
    [[ -d "$FINAL_EXTRACTION_DIR" && ! -L "$FINAL_EXTRACTION_DIR" ]] || {
        echo "refusing cleanup because extraction directory is unsafe" >&2
        return 1
    }
    physical_temp_root="$(cd "$FINAL_TEMP_ROOT" && pwd -P)"
    physical_extraction="$(cd "$FINAL_EXTRACTION_DIR" && pwd -P)"
    case "$physical_extraction" in
        "$physical_temp_root"/final-verification.*)
            /bin/rm -rf -- "$physical_extraction"
            ;;
        *)
            echo "refusing to remove an unconfined extraction directory" >&2
            return 1
            ;;
    esac
    FINAL_EXTRACTION_DIR=""
}

create_final_zip() {
    FINAL_ZIP_PARTIAL="$(/usr/bin/mktemp "$FINAL_DIR/.final-zip.XXXXXX")"
    /bin/rm -f -- "$FINAL_ZIP_PARTIAL"
    if [[ "$notarize_test_mode" -eq 1 ]]; then
        record_notarization_step "create-final-zip" || return
        printf 'controlled stapled LocalOCR Studio archive\n' \
            > "$FINAL_ZIP_PARTIAL"
        return 0
    fi
    /usr/bin/ditto -c -k --keepParent "$STAGED_APP" "$FINAL_ZIP_PARTIAL"
}

create_final_checksum() {
    local final_hash

    FINAL_CHECKSUM_PARTIAL="$(
        /usr/bin/mktemp "$FINAL_DIR/.final-sha256.XXXXXX"
    )"
    if [[ "$notarize_test_mode" -eq 1 ]]; then
        record_notarization_step "create-final-sha256" || return
    fi
    final_hash="$(
        /usr/bin/shasum -a 256 "$FINAL_ZIP_PARTIAL" |
            /usr/bin/awk '{ print $1 }'
    )"
    [[ "$final_hash" =~ ^[0-9a-f]{64}$ ]] || {
        echo "could not compute final ZIP SHA-256" >&2
        return 1
    }
    printf '%s  %s\n' "$final_hash" "$(/usr/bin/basename "$FINAL_ZIP")" \
        > "$FINAL_CHECKSUM_PARTIAL"
}

extract_final_zip() {
    FINAL_EXTRACTION_DIR="$(
        /usr/bin/mktemp -d "$FINAL_TEMP_ROOT/final-verification.XXXXXX"
    )"
    if [[ "$notarize_test_mode" -eq 1 ]]; then
        record_notarization_step "extract-final-zip" || return
        /bin/mkdir -p \
            "$FINAL_EXTRACTION_DIR/LocalOCR Studio.app/Contents/Helpers"
        return 0
    fi
    /usr/bin/ditto -x -k "$FINAL_ZIP_PARTIAL" "$FINAL_EXTRACTION_DIR"
}

verify_extracted_final_zip() {
    local extracted_app="$FINAL_EXTRACTION_DIR/LocalOCR Studio.app"

    [[ -d "$extracted_app" && ! -L "$extracted_app" ]] || {
        echo "final ZIP did not contain the expected physical app" >&2
        return 1
    }
    if [[ "$notarize_test_mode" -eq 1 ]]; then
        verify_final_extracted_release "$extracted_app"
        return
    fi
    verify_final_extracted_release "$extracted_app" \
        > "$EVIDENCE_DIR/final-extracted-verification.txt" 2>&1
}

publish_final_candidate() {
    if [[ "$notarize_test_mode" -eq 1 ]]; then
        record_notarization_step "publish-final-candidate" || return
    fi
    /bin/mv -f -- "$FINAL_ZIP_PARTIAL" "$FINAL_ZIP"
    FINAL_ZIP_PARTIAL=""
    if ! /bin/mv -f -- "$FINAL_CHECKSUM_PARTIAL" "$FINAL_CHECKSUM"; then
        /bin/rm -f -- "$FINAL_ZIP"
        return 1
    fi
    FINAL_CHECKSUM_PARTIAL=""
    (
        cd "$FINAL_DIR"
        /usr/bin/shasum -a 256 -c "$(/usr/bin/basename "$FINAL_CHECKSUM")"
    ) > "$EVIDENCE_DIR/final-checksum-validation.txt" 2>&1
}

build_and_verify_final_candidate() {
    create_final_zip || return
    create_final_checksum || return
    extract_final_zip || return
    verify_extracted_final_zip || return
    publish_final_candidate || return
}

notarize_direct_release() {
    local final_status=0
    local submission_command_status=0
    local submission_id=""
    local submission_status=""

    configure_notarization_base_paths
    if [[ "$notarize_test_mode" -eq 1 ]]; then
        validate_controlled_test_root
    fi
    prepare_final_directory_for_invalidation
    invalidate_all_official_final_candidates
    validate_notarization_inputs
    configure_notarization_paths
    prepare_remaining_output_directories
    /bin/rm -f -- "$NOTARY_SUBMIT_JSON" "$NOTARY_LOG_JSON"
    clear_published_final_candidate

    run_pre_notarization_verification
    validate_notary_profile_access
    create_submission_zip
    submit_for_notarization || submission_command_status=$?

    if [[ -f "$NOTARY_SUBMIT_JSON" ]]; then
        submission_id="$(json_field "$NOTARY_SUBMIT_JSON" id || true)"
        submission_status="$(json_field "$NOTARY_SUBMIT_JSON" status || true)"
    fi

    [[ -n "$submission_id" ]] || {
        echo "notary submission result is missing its submission ID" >&2
        return 1
    }
    [[ -n "$submission_status" ]] || {
        fetch_notarization_log "$submission_id" || true
        echo "notary submission result is missing its status" >&2
        return 1
    }
    if [[ "$submission_command_status" -ne 0 || "$submission_status" != "Accepted" ]]; then
        fetch_notarization_log "$submission_id" || {
            echo "notary submission was not accepted and its log could not be fetched" >&2
            return 1
        }
        echo "notary submission was not accepted: $submission_status" >&2
        return 1
    fi

    staple_and_assess
    build_and_verify_final_candidate || final_status=$?
    cleanup_final_extraction || final_status=$?
    cleanup_partial_final_files || final_status=$?
    if [[ "$final_status" -ne 0 ]]; then
        clear_published_final_candidate
        return "$final_status"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --test-workflow)
            [[ "$#" -eq 4 ]] || exit 2
            notarize_test_mode=1
            notarize_test_submission_json="$2"
            notarize_trace_file="$3"
            NOTARIZE_RELEASE_ROOT="$4"
            notarize_test_fail_step="${LOCALOCR_TEST_FAIL_STEP:-}"
            verify_final_test_mode=1
            verify_final_trace_file="$notarize_trace_file"
            verify_final_test_fail_step="$notarize_test_fail_step"
            validate_controlled_test_root
            : > "$notarize_trace_file"
            notarize_direct_release
            ;;
        "")
            notarize_direct_release
            ;;
        *)
            echo "unknown notarize-direct-release mode: $1" >&2
            exit 2
            ;;
    esac
fi
