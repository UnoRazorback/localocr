#!/usr/bin/env bash

set -euo pipefail

sign_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/release-toolchain.sh
source "$sign_script_dir/release-toolchain.sh"
# shellcheck source=scripts/verify-direct-release.sh
source "$sign_script_dir/verify-direct-release.sh"

readonly SIGNING_IDENTITY="Developer ID Application: John Scott Ray (DZ8B5454ZN)"
STAGED_APP="$sign_script_dir/../dist/direct-release/staged/LocalOCR Studio.app"
CODESIGN_COMMAND=()
codesign_command_executor="/usr/bin/codesign"

resolve_physical_staged_app_copy() {
    local app_path="$1"
    local physical_app
    local physical_repo
    local expected_physical_app

    [[ -d "$app_path" && ! -L "$app_path" ]] || {
        echo "staged app is missing or symlinked: $app_path" >&2
        return 1
    }
    physical_repo="$(cd "$sign_script_dir/.." && pwd -P)"
    expected_physical_app="$physical_repo/dist/direct-release/staged/LocalOCR Studio.app"
    physical_app="$(cd "$app_path" && pwd -P)"
    [[ "$physical_app" == "$expected_physical_app" ]] || {
        echo "refusing to sanitize or sign anything except the physical staged app copy" >&2
        return 1
    }
    printf '%s\n' "$physical_app"
}

validate_code_signing_metadata_name() {
    case "${1:-}" in
        com.apple.FinderInfo|com.apple.ResourceFork|com.apple.fileprovider.fpfs#P)
            echo "code-signing-hostile metadata remains: $1" >&2
            return 1
            ;;
    esac
}

verify_candidate_code_signing_xattrs() {
    local candidate="$1"
    local xattr_inspector="${2:-/usr/bin/xattr}"
    local attributes
    local attribute

    attributes="$("$xattr_inspector" "$candidate")" || {
        echo "could not enumerate extended attributes: $candidate" >&2
        return 1
    }
    while IFS= read -r attribute; do
        [[ -n "$attribute" ]] || continue
        validate_code_signing_metadata_name "$attribute" || return 1
    done <<< "$attributes"
}

verify_no_code_signing_hostile_metadata() {
    local physical_app="$1"
    local enumerator="${2:-/usr/bin/find}"
    local xattr_inspector="${3:-/usr/bin/xattr}"
    local candidate
    local metadata_file
    local candidate_list_dir
    local candidate_list
    local inspection_status=0

    if ! metadata_file="$(
        /usr/bin/find "$physical_app" \
            \( -name '.DS_Store' -o -name '._*' \) \
            -print -quit
    )"; then
        echo "metadata-file enumeration failed" >&2
        return 1
    fi
    [[ -z "$metadata_file" ]] || {
        echo "code-signing-hostile metadata file remains: $metadata_file" >&2
        return 1
    }

    candidate_list_dir="$(/usr/bin/mktemp -d /tmp/localocr-sign-metadata.XXXXXX)" || {
        echo "could not create isolated metadata candidate directory" >&2
        return 1
    }
    candidate_list="$candidate_list_dir/candidates.nul"
    if ! "$enumerator" "$physical_app" -print0 > "$candidate_list"; then
        /bin/rm -f -- "$candidate_list"
        /bin/rmdir "$candidate_list_dir"
        echo "metadata candidate enumeration failed" >&2
        return 1
    fi

    while IFS= read -r -d '' candidate; do
        case "$candidate" in
            "$physical_app"|"$physical_app"/*) ;;
            *)
                echo "metadata candidate escaped the staged app: $candidate" >&2
                inspection_status=1
                break
                ;;
        esac
        if ! verify_candidate_code_signing_xattrs "$candidate" "$xattr_inspector"; then
            inspection_status=1
            break
        fi
    done < "$candidate_list"

    /bin/rm -f -- "$candidate_list"
    /bin/rmdir "$candidate_list_dir"
    [[ "$inspection_status" -eq 0 ]]
}

sanitize_staged_app_metadata() {
    local app_path="$1"
    local enumerator="${2:-/usr/bin/find}"
    local xattr_inspector="${3:-/usr/bin/xattr}"
    local physical_app
    local unexpected_symlink

    [[ -d "$app_path" && ! -L "$app_path" ]] || {
        echo "metadata sanitization requires a physical staged app directory" >&2
        return 1
    }
    physical_app="$(cd "$app_path" && pwd -P)"
    if ! unexpected_symlink="$(
        /usr/bin/find "$physical_app" -type l -print -quit
    )"; then
        echo "symlink enumeration failed before metadata sanitization" >&2
        return 1
    fi
    [[ -z "$unexpected_symlink" ]] || {
        echo "refusing metadata sanitization because a symlink remains: $unexpected_symlink" >&2
        return 1
    }

    /usr/bin/xattr -cr "$physical_app" || {
        echo "could not clear extended attributes from staged app copy" >&2
        return 1
    }
    verify_no_code_signing_hostile_metadata \
        "$physical_app" \
        "$enumerator" \
        "$xattr_inspector"
}

require_expected_macho_file() {
    local code_path="$1"
    local file_description

    [[ -f "$code_path" && ! -L "$code_path" ]] || {
        echo "expected nested code is missing or symlinked: $code_path" >&2
        return 1
    }
    file_description="$(/usr/bin/file -b "$code_path")"
    [[ "$file_description" == *"Mach-O"* ]] || {
        echo "expected nested code is not Mach-O: $code_path" >&2
        return 1
    }
}

verify_expected_nested_code() {
    local app_path="$1"
    local physical_app
    local main_executable
    local allowed_main
    local candidate
    local relative_candidate
    local file_description
    local unexpected_bundle
    local unexpected_symlink

    [[ -d "$app_path" && ! -L "$app_path" ]] || {
        echo "staged app is missing or symlinked: $app_path" >&2
        return 1
    }
    physical_app="$(cd "$app_path" && pwd -P)"
    app_path="$physical_app"
    main_executable="$(resolve_staged_main_executable "$app_path")"
    allowed_main="${main_executable#"$app_path"/}"

    require_expected_macho_file "$main_executable"
    require_expected_macho_file "$app_path/Contents/Helpers/localocr"
    require_expected_macho_file "$app_path/Contents/Helpers/localocr-mcp"
    require_expected_macho_file "$app_path/Contents/Helpers/localocr-model-bridge"

    unexpected_symlink="$(
        /usr/bin/find "$app_path/Contents" -type l -print -quit
    )"
    [[ -z "$unexpected_symlink" ]] || {
        echo "unexpected nested code symlink: $unexpected_symlink" >&2
        return 1
    }

    unexpected_bundle="$(
        /usr/bin/find "$app_path/Contents" -mindepth 1 -type d \
            \( -iname '*.framework' -o -iname '*.xpc' -o -iname '*.appex' -o -iname '*.app' \) \
            -print -quit
    )"
    [[ -z "$unexpected_bundle" ]] || {
        echo "unexpected nested code bundle: $unexpected_bundle" >&2
        return 1
    }

    while IFS= read -r -d '' candidate; do
        file_description="$(/usr/bin/file -b "$candidate")"
        [[ "$file_description" == *"Mach-O"* ]] || continue
        relative_candidate="${candidate#"$app_path"/}"
        case "$relative_candidate" in
            "$allowed_main"|Contents/Helpers/localocr|Contents/Helpers/localocr-mcp|Contents/Helpers/localocr-model-bridge)
                ;;
            *)
                echo "unexpected nested code: $relative_candidate" >&2
                return 1
                ;;
        esac
    done < <(/usr/bin/find "$app_path/Contents" -type f -print0)
}

trace_codesign_invocation() {
    local trace_file="${LOCALOCR_SIGNING_TRACE_FILE:-}"
    local argument

    [[ -n "$trace_file" ]] || {
        echo "LOCALOCR_SIGNING_TRACE_FILE is required for signing-order test mode" >&2
        return 1
    }
    for argument in "$@"; do
        printf '%q ' "$argument"
    done >> "$trace_file"
    printf '\n' >> "$trace_file"
}

build_codesign_command() {
    local target="$1"

    CODESIGN_COMMAND=(
        /usr/bin/codesign
        --force
        --sign
        "$SIGNING_IDENTITY"
        --options
        runtime
        --timestamp
        "$target"
    )
}

execute_codesign_command() {
    build_codesign_command "$1"
    if [[ "$codesign_command_executor" == "trace" ]]; then
        trace_codesign_command
    else
        "${CODESIGN_COMMAND[@]}"
    fi
}

trace_codesign_command() {
    trace_codesign_invocation "${CODESIGN_COMMAND[@]}"
}

record_signing_order() {
    local app_path="$1"

    : > "${LOCALOCR_SIGNING_TRACE_FILE:?LOCALOCR_SIGNING_TRACE_FILE is required}"
    codesign_command_executor="trace"
    execute_codesign_command "$app_path/Contents/Helpers/localocr"
    execute_codesign_command "$app_path/Contents/Helpers/localocr-mcp"
    execute_codesign_command "$app_path/Contents/Helpers/localocr-model-bridge"
    execute_codesign_command "$app_path"
}

preflight_direct_release_signing() {
    local physical_staged_app
    local main_executable
    local helper

    [[ "$SIGNING_IDENTITY" == "$release_signing_identity" ]] || {
        echo "signing identity constants disagree" >&2
        return 1
    }
    physical_staged_app="$(resolve_physical_staged_app_copy "$STAGED_APP")"
    STAGED_APP="$physical_staged_app"
    validate_signing_identity
    verify_expected_nested_code "$STAGED_APP"
    main_executable="$(resolve_staged_main_executable "$STAGED_APP")"
    for helper in localocr localocr-mcp localocr-model-bridge; do
        verify_binary_policy \
            "$STAGED_APP/Contents/Helpers/$helper" \
            "$([[ "$helper" == localocr-model-bridge ]] && printf true || printf false)"
    done
    "$sign_script_dir/validate-model-bridge-policy.py" \
        --source-root "$verify_repo_root" \
        --binary "$STAGED_APP/Contents/Helpers/localocr-model-bridge" >/dev/null
    verify_binary_policy "$main_executable"
    sanitize_staged_app_metadata "$STAGED_APP"
    validate_release_bundle_metadata "$STAGED_APP"
}

sign_direct_release() {
    local code_object

    preflight_direct_release_signing
    for code_object in \
        "$STAGED_APP/Contents/Helpers/localocr" \
        "$STAGED_APP/Contents/Helpers/localocr-mcp" \
        "$STAGED_APP/Contents/Helpers/localocr-model-bridge" \
        "$STAGED_APP"
    do
        validate_release_bundle_metadata "$STAGED_APP"
        execute_codesign_command "$code_object"
        verify_signature "$code_object"
        verify_hardened_runtime "$code_object"
        verify_no_debug_entitlement "$code_object"
    done

    /usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
}

test_xattr_preflight() {
    local app_path="$1"
    local trace_file="${LOCALOCR_SIGNING_TRACE_FILE:-}"
    local injected_attribute

    [[ -n "$trace_file" ]] || {
        echo "LOCALOCR_SIGNING_TRACE_FILE is required for xattr preflight test mode" >&2
        return 1
    }
    : > "$trace_file"
    sanitize_staged_app_metadata \
        "$app_path" \
        "${LOCALOCR_TEST_METADATA_ENUMERATOR:-/usr/bin/find}" \
        "${LOCALOCR_TEST_XATTR_INSPECTOR:-/usr/bin/xattr}"
    if [[ -n "${LOCALOCR_TEST_REMAINING_XATTRS:-}" ]]; then
        while IFS= read -r injected_attribute; do
            [[ -n "$injected_attribute" ]] || continue
            validate_code_signing_metadata_name "$injected_attribute"
        done <<< "$LOCALOCR_TEST_REMAINING_XATTRS"
    fi
    trace_codesign_invocation \
        /usr/bin/codesign \
        --force \
        --sign \
        "$SIGNING_IDENTITY" \
        --options runtime \
        --timestamp \
        "$app_path/Contents/Helpers/localocr"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --test-nested-code)
            [[ "$#" -eq 2 ]] || exit 2
            verify_expected_nested_code "$2"
            ;;
        --test-signing-order)
            [[ "$#" -eq 2 ]] || exit 2
            record_signing_order "$2"
            ;;
        --test-xattr-preflight)
            [[ "$#" -eq 2 ]] || exit 2
            test_xattr_preflight "$2"
            ;;
        "")
            sign_direct_release
            ;;
        *)
            echo "unknown sign-direct-release mode: $1" >&2
            exit 2
            ;;
    esac
fi
