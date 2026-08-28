#!/usr/bin/env bash

set -euo pipefail

verify_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
verify_repo_root="$(cd "$verify_script_dir/.." && pwd -P)"
# shellcheck source=scripts/release-toolchain.sh
source "$verify_script_dir/release-toolchain.sh"
verify_release_root="$verify_repo_root/dist/direct-release"
verify_staged_app="$verify_release_root/staged/LocalOCR Studio.app"
verify_expected_team="DZ8B5454ZN"
verify_expected_authority="Developer ID Application: John Scott Ray (DZ8B5454ZN)"
verify_plist_buddy="/usr/libexec/PlistBuddy"
verify_final_test_mode=0
verify_final_trace_file=""
verify_final_test_fail_step=""

validate_arm64_architecture() {
    [[ "${1:-}" == "arm64" ]] || {
        echo "release binaries must contain only the arm64 architecture" >&2
        return 1
    }
}

validate_minimum_macos() {
    local version="${1:-}"

    [[ "$version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || {
        echo "invalid minimum macOS version: $version" >&2
        return 1
    }
    [[ "$version" == "14.0" ]] || {
        echo "Local Intelligence release binaries must target macOS 14.0 exactly" >&2
        return 1
    }
}

validate_canonical_system_install_name() {
    release_validate_canonical_system_install_name "$1"
}

validate_install_name() {
    release_validate_local_only_install_name "${1:-}"
}

validate_rpath() {
    release_validate_rpath_value "${1:-}" false
}

validate_no_debug_entitlement_text() {
    local entitlements="${1:-}"

    [[ -n "$entitlements" ]] || return 0
    printf '%s' "$entitlements" |
        /usr/bin/plutil -lint -- - >/dev/null 2>&1 || {
        echo "signature entitlements are malformed" >&2
        return 1
    }
    if printf '%s' "$entitlements" |
        /usr/bin/plutil -extract \
            'com\.apple\.security\.get-task-allow' \
            raw -o - -- - >/dev/null 2>&1
    then
        echo "com.apple.security.get-task-allow must be completely absent" >&2
        return 1
    fi
}

binary_minimum_macos() {
    /usr/bin/otool -l "$1" |
        /usr/bin/awk '
            $1 == "cmd" && $2 == "LC_BUILD_VERSION" {
                in_build_version = 1
                next
            }
            in_build_version && $1 == "minos" && !printed {
                print $2
                printed = 1
                in_build_version = 0
            }
        '
}

verify_binary_architecture_and_target() {
    local binary="$1"
    local file_description
    local architectures
    local minimum_macos

    [[ -f "$binary" && ! -L "$binary" ]] || {
        echo "release binary is missing or symlinked: $binary" >&2
        return 1
    }
    file_description="$(/usr/bin/file -b "$binary")"
    [[ "$file_description" == *"Mach-O"* ]] || {
        echo "release binary is not Mach-O: $binary" >&2
        return 1
    }
    architectures="$(/usr/bin/lipo -archs "$binary")"
    validate_arm64_architecture "$architectures"
    minimum_macos="$(binary_minimum_macos "$binary")"
    validate_minimum_macos "$minimum_macos"
}

verify_binary_dependencies() {
    release_validate_binary_dependencies "$1"
}

verify_binary_rpaths() {
    release_validate_binary_rpaths "$1" false
}

verify_no_private_paths() {
    local binary="$1"
    local strings_output
    local forbidden

    release_reject_private_user_path "$binary"
    strings_output="$(/usr/bin/strings -a "$binary")"
    for forbidden in \
        "/Applications/Xcode" \
        "/Users/" \
        "$verify_repo_root" \
        "/opt/homebrew" \
        "/usr/local" \
        ".venv" \
        "python" \
        "pyobjc" \
        "pymupdf" \
        "ruby"
    do
        if /usr/bin/grep -F -i -q -- "$forbidden" <<< "$strings_output"; then
            echo "private or non-native build path marker found in $binary: $forbidden" >&2
            return 1
        fi
    done
}

verify_signature() {
    local code_object="$1"

    /usr/bin/codesign --verify --strict --verbose=2 "$code_object"
}

signature_details() {
    /usr/bin/codesign -dv --verbose=4 "$1" 2>&1
}

verify_hardened_runtime() {
    local code_object="$1"
    local details

    details="$(signature_details "$code_object")"
    validate_signature_details "$details" "$code_object"
}

validate_signature_details() {
    local details="$1"
    local code_object="${2:-signature details}"

    /usr/bin/grep -F -x -q \
        "Authority=$verify_expected_authority" <<< "$details" || {
        echo "signature has the wrong Developer ID authority: $code_object" >&2
        return 1
    }
    /usr/bin/grep -F -x -q \
        "TeamIdentifier=$verify_expected_team" <<< "$details" || {
        echo "signature has the wrong TeamIdentifier: $code_object" >&2
        return 1
    }
    /usr/bin/grep -E -q \
        '^Timestamp=.+$' <<< "$details" || {
        echo "signature has no trusted timestamp: $code_object" >&2
        return 1
    }
    ! /usr/bin/grep -F -x -q "Timestamp=none" <<< "$details" || {
        echo "signature timestamp is not trusted: $code_object" >&2
        return 1
    }
    /usr/bin/grep -E -q \
        ' flags=0x10000\(runtime\)' <<< "$details" || {
        echo "signature does not have Hardened Runtime flag 0x10000: $code_object" >&2
        return 1
    }
}

verify_no_debug_entitlement() {
    local code_object="$1"
    local entitlements

    entitlements="$(
        /usr/bin/codesign -d --entitlements :- "$code_object" 2>/dev/null
    )"
    validate_no_debug_entitlement_text "$entitlements"
}

resolve_staged_main_executable() {
    local app_path="$1"
    local executable_name
    local executable_path
    local physical_macos_dir
    local physical_executable

    [[ -d "$app_path/Contents/MacOS" ]] || {
        echo "staged app Contents/MacOS directory not found" >&2
        return 1
    }
    executable_name="$(
        "$verify_plist_buddy" -c "Print :CFBundleExecutable" \
            "$app_path/Contents/Info.plist"
    )"
    [[ -n "$executable_name" && "$executable_name" != "." && "$executable_name" != ".." ]] || {
        echo "CFBundleExecutable must be a nonempty basename" >&2
        return 1
    }
    case "$executable_name" in
        */*|*\\*)
            echo "CFBundleExecutable must be a nonempty basename" >&2
            return 1
            ;;
    esac
    executable_path="$app_path/Contents/MacOS/$executable_name"
    [[ -f "$executable_path" && ! -L "$executable_path" ]] || {
        echo "staged main executable is missing or symlinked: $executable_path" >&2
        return 1
    }
    physical_macos_dir="$(cd "$app_path/Contents/MacOS" && pwd -P)"
    physical_executable="$(/bin/realpath "$executable_path")"
    case "$physical_executable" in
        "$physical_macos_dir"/*) ;;
        *)
            echo "staged main executable escapes Contents/MacOS" >&2
            return 1
            ;;
    esac
    printf '%s\n' "$physical_executable"
}

verify_binary_policy() {
    verify_binary_architecture_and_target "$1"
    verify_binary_dependencies "$1"
    release_validate_no_network_symbols "$1"
    verify_binary_rpaths "$1"
    verify_no_private_paths "$1"
}

verify_signed_code_object() {
    verify_signature "$1"
    verify_hardened_runtime "$1"
    verify_no_debug_entitlement "$1"
}

verify_direct_release_signatures() {
    local app_path="${1:-$verify_staged_app}"
    local main_executable
    local helper

    validate_release_bundle_metadata "$app_path"
    main_executable="$(resolve_staged_main_executable "$app_path")"
    for helper in localocr localocr-mcp; do
        verify_binary_policy "$app_path/Contents/Helpers/$helper"
        verify_signed_code_object "$app_path/Contents/Helpers/$helper"
    done
    verify_binary_policy "$main_executable"
    verify_signed_code_object "$app_path"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
}

verify_direct_release() {
    local app_path="${1:-$verify_staged_app}"

    configure_release_developer_dir
    verify_direct_release_signatures "$app_path"
    /usr/bin/xcrun stapler validate "$app_path"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$app_path"
}

verify_localocr_version() {
    local app_path="$1"
    local actual_version

    actual_version="$("$app_path/Contents/Helpers/localocr" --version)"
    [[ "$actual_version" == "$LOCALOCR_RELEASE_VERSION" ]] || {
        echo "extracted localocr version mismatch: $actual_version" >&2
        return 1
    }
    printf 'localocr version: %s\n' "$actual_version"
}

verify_mcp_initialization_version() {
    local app_path="$1"
    local mcp_binary="$app_path/Contents/Helpers/localocr-mcp"
    local stderr_file="$app_path/../localocr-mcp-initialization.stderr"
    local initialize_request
    local initialize_response
    local server_version

    initialize_request='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"direct-release-verifier","version":"1.0"}}}'
    : > "$stderr_file"
    initialize_response="$(
        {
            printf '%s\n' "$initialize_request"
            /bin/sleep 1
        } | "$mcp_binary" 2> "$stderr_file"
    )"
    [[ ! -s "$stderr_file" ]] || {
        echo "extracted localocr-mcp wrote initialization diagnostics" >&2
        /bin/cat "$stderr_file" >&2
        return 1
    }
    server_version="$(
        printf '%s\n' "$initialize_response" |
            /usr/bin/plutil -extract result.serverInfo.version raw -o - -- - \
                2>/dev/null
    )" || {
        echo "extracted localocr-mcp returned an invalid initialization response" >&2
        return 1
    }
    [[ "$server_version" == "$LOCALOCR_RELEASE_VERSION" ]] || {
        echo "extracted localocr-mcp version mismatch: $server_version" >&2
        return 1
    }
    printf 'localocr-mcp version: %s\n' "$server_version"
}

record_final_verification_step() {
    local step="$1"

    printf '%s\n' "$step" >> "$verify_final_trace_file"
    [[ "$verify_final_test_fail_step" != "$step" ]] || {
        echo "controlled final verification failure: $step" >&2
        return 1
    }
}

verify_final_extracted_release() {
    local app_path="$1"

    if [[ "$verify_final_test_mode" -eq 1 ]]; then
        record_final_verification_step "extracted-signatures" || return
        record_final_verification_step "extracted-dependencies" || return
        record_final_verification_step "extracted-rpaths" || return
        record_final_verification_step "extracted-stapler-validate" || return
        record_final_verification_step "extracted-spctl-assess" || return
        record_final_verification_step "extracted-localocr-version" || return
        record_final_verification_step "extracted-mcp-initialize-version" || return
        return 0
    fi

    validate_release_bundle_metadata "$app_path"
    verify_direct_release_signatures "$app_path"
    /usr/bin/xcrun stapler validate "$app_path"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$app_path"
    verify_localocr_version "$app_path"
    verify_mcp_initialization_version "$app_path"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --test-architecture)
            [[ "$#" -eq 2 ]] || exit 2
            validate_arm64_architecture "$2"
            ;;
        --test-minimum-macos)
            [[ "$#" -eq 2 ]] || exit 2
            validate_minimum_macos "$2"
            ;;
        --test-entitlements)
            [[ "$#" -eq 2 ]] || exit 2
            validate_no_debug_entitlement_text "$2"
            ;;
        --test-install-name)
            [[ "$#" -eq 2 ]] || exit 2
            validate_install_name "$2"
            ;;
        --test-rpath)
            [[ "$#" -eq 2 ]] || exit 2
            validate_rpath "$2"
            ;;
        --test-signature-details)
            [[ "$#" -eq 2 ]] || exit 2
            validate_signature_details "$2"
            ;;
        "")
            verify_direct_release
            ;;
        *)
            echo "unknown verify-direct-release mode: $1" >&2
            exit 2
            ;;
    esac
fi
