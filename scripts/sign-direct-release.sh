#!/usr/bin/env bash

set -euo pipefail

sign_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/release-toolchain.sh
source "$sign_script_dir/release-toolchain.sh"
# shellcheck source=scripts/verify-direct-release.sh
source "$sign_script_dir/verify-direct-release.sh"

readonly SIGNING_IDENTITY="Developer ID Application: John Scott Ray (DZ8B5454ZN)"
STAGED_APP="$sign_script_dir/../dist/direct-release/staged/LocalOCR Studio.app"

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
            "$allowed_main"|Contents/Helpers/localocr|Contents/Helpers/localocr-mcp)
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

record_signing_order() {
    local app_path="$1"
    local -a codesign_prefix=(
        /usr/bin/codesign
        --force
        --sign
        "$SIGNING_IDENTITY"
        --options
        runtime
        --timestamp
    )

    : > "${LOCALOCR_SIGNING_TRACE_FILE:?LOCALOCR_SIGNING_TRACE_FILE is required}"
    trace_codesign_invocation \
        "${codesign_prefix[@]}" \
        "$app_path/Contents/Helpers/localocr"
    trace_codesign_invocation \
        "${codesign_prefix[@]}" \
        "$app_path/Contents/Helpers/localocr-mcp"
    trace_codesign_invocation "${codesign_prefix[@]}" "$app_path"
}

preflight_direct_release_signing() {
    local main_executable
    local helper

    [[ "$SIGNING_IDENTITY" == "$release_signing_identity" ]] || {
        echo "signing identity constants disagree" >&2
        return 1
    }
    validate_signing_identity
    verify_expected_nested_code "$STAGED_APP"
    main_executable="$(resolve_staged_main_executable "$STAGED_APP")"
    for helper in localocr localocr-mcp; do
        verify_binary_policy "$STAGED_APP/Contents/Helpers/$helper"
    done
    verify_binary_policy "$main_executable"
}

sign_direct_release() {
    preflight_direct_release_signing

    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
        --options runtime --timestamp \
        "$STAGED_APP/Contents/Helpers/localocr"
    verify_signature "$STAGED_APP/Contents/Helpers/localocr"
    verify_hardened_runtime "$STAGED_APP/Contents/Helpers/localocr"
    verify_no_debug_entitlement "$STAGED_APP/Contents/Helpers/localocr"

    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
        --options runtime --timestamp \
        "$STAGED_APP/Contents/Helpers/localocr-mcp"
    verify_signature "$STAGED_APP/Contents/Helpers/localocr-mcp"
    verify_hardened_runtime "$STAGED_APP/Contents/Helpers/localocr-mcp"
    verify_no_debug_entitlement "$STAGED_APP/Contents/Helpers/localocr-mcp"

    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
        --options runtime --timestamp \
        "$STAGED_APP"
    verify_signature "$STAGED_APP"
    verify_hardened_runtime "$STAGED_APP"
    verify_no_debug_entitlement "$STAGED_APP"

    /usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
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
        "")
            sign_direct_release
            ;;
        *)
            echo "unknown sign-direct-release mode: $1" >&2
            exit 2
            ;;
    esac
fi
