#!/usr/bin/env bash

set -euo pipefail

verify_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
verify_repo_root="$(cd "$verify_script_dir/.." && pwd -P)"
verify_release_root="$verify_repo_root/dist/direct-release"
verify_staged_app="$verify_release_root/staged/LocalOCR Studio.app"
verify_expected_team="DZ8B5454ZN"
verify_plist_buddy="/usr/libexec/PlistBuddy"

validate_arm64_architecture() {
    [[ "${1:-}" == "arm64" ]] || {
        echo "release binaries must contain only the arm64 architecture" >&2
        return 1
    }
}

validate_minimum_macos() {
    local version="${1:-}"
    local major

    [[ "$version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || {
        echo "invalid minimum macOS version: $version" >&2
        return 1
    }
    major="${version%%.*}"
    [[ "$major" -ge 14 ]] || {
        echo "release binaries must require macOS 14 or later" >&2
        return 1
    }
}

validate_install_name() {
    case "${1:-}" in
        /System/Library/?*|/usr/lib/?*|@rpath/libswiftCompatibilitySpan.dylib)
            ;;
        *)
            echo "unapproved dynamic-library install name: ${1:-<empty>}" >&2
            return 1
            ;;
    esac
}

validate_rpath() {
    [[ "${1:-}" == "/usr/lib/swift" ]] || {
        echo "unapproved LC_RPATH: ${1:-<empty>}" >&2
        return 1
    }
}

validate_no_debug_entitlement_text() {
    local entitlements="${1:-}"
    local debug_value

    if debug_value="$(
        printf '%s' "$entitlements" |
            /usr/bin/plutil -extract \
                'com\.apple\.security\.get-task-allow' \
                raw -o - -- - 2>/dev/null
    )"; then
        [[ "$debug_value" != "true" ]] || {
            echo "com.apple.security.get-task-allow must not be true" >&2
            return 1
        }
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
    local binary="$1"
    local dependency_output
    local dependency_line
    local install_name

    dependency_output="$(/usr/bin/otool -L "$binary")"
    while IFS= read -r dependency_line; do
        [[ -n "$dependency_line" ]] || continue
        install_name="$(
            printf '%s\n' "$dependency_line" |
                /usr/bin/awk '{ print $1 }'
        )"
        validate_install_name "$install_name"
        if [[ "$install_name" == "@rpath/libswiftCompatibilitySpan.dylib" ]]; then
            [[ "$dependency_line" == *", weak)" ]] || {
                echo "libswiftCompatibilitySpan.dylib must be weak-linked" >&2
                return 1
            }
        fi
    done < <(
        printf '%s\n' "$dependency_output" |
            /usr/bin/awk 'NR > 1 { sub(/^[[:space:]]+/, ""); print }'
    )
}

verify_binary_rpaths() {
    local binary="$1"
    local load_commands
    local rpath_output
    local rpath

    load_commands="$(/usr/bin/otool -l "$binary")"
    rpath_output="$(
        printf '%s\n' "$load_commands" |
            /usr/bin/awk '
                $1 == "cmd" {
                    if (awaiting_path) {
                        exit 65
                    }
                    awaiting_path = ($2 == "LC_RPATH")
                    next
                }
                awaiting_path && $1 == "path" {
                    print $2
                    awaiting_path = 0
                }
                END {
                    if (awaiting_path) {
                        exit 65
                    }
                }
            '
    )" || {
        echo "could not parse every LC_RPATH in: $binary" >&2
        return 1
    }
    while IFS= read -r rpath; do
        [[ -n "$rpath" ]] || continue
        validate_rpath "$rpath"
    done <<< "$rpath_output"
}

verify_no_private_paths() {
    local binary="$1"
    local strings_output
    local forbidden

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

    verify_direct_release_signatures "$app_path"
    /usr/bin/xcrun stapler validate "$app_path"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$app_path"
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
        "")
            verify_direct_release
            ;;
        *)
            echo "unknown verify-direct-release mode: $1" >&2
            exit 2
            ;;
    esac
fi
