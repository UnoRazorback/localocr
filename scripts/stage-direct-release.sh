#!/usr/bin/env bash

set -euo pipefail

stage_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
stage_repo_root="$(cd "$stage_script_dir/.." && pwd -P)"
# shellcheck source=scripts/release-toolchain.sh
source "$stage_script_dir/release-toolchain.sh"

release_root="$stage_repo_root/dist/direct-release"
evidence_dir="$release_root/evidence"
staged_app="$release_root/staged/LocalOCR Studio.app"
native_tools_dir="$release_root/native-tools"
plist_buddy="/usr/libexec/PlistBuddy"
physical_unsigned_app=""
expected_main_executable_name="LocalOCR Studio"

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

canonicalize_release_paths() {
    local repo_path="${1:-}"
    local app_path="${2:-}"
    local physical_repo
    local physical_dist
    local physical_release_root
    local resolved_app_path

    [[ "$app_path" == /* && "$app_path" == *.app ]] || {
        echo "LOCALOCR_UNSIGNED_APP must be an absolute .app path" >&2
        return 1
    }
    [[ -d "$app_path" ]] || {
        echo "unsigned app not found: $app_path" >&2
        return 1
    }
    [[ -d "$repo_path" ]] || {
        echo "release repository not found: $repo_path" >&2
        return 1
    }

    physical_repo="$(cd "$repo_path" && pwd -P)"
    resolved_app_path="$(cd "$app_path" && pwd -P)"
    [[ ! -L "$physical_repo/dist" ]] || {
        echo "dist must not be a symlink" >&2
        return 1
    }
    /bin/mkdir -p "$physical_repo/dist"
    physical_dist="$(cd "$physical_repo/dist" && pwd -P)"
    [[ "$physical_dist" == "$physical_repo/dist" ]] || {
        echo "dist resolves outside the physical repository" >&2
        return 1
    }
    [[ ! -L "$physical_dist/direct-release" ]] || {
        echo "direct-release must not be a symlink" >&2
        return 1
    }
    if [[ -e "$physical_dist/direct-release" ]]; then
        [[ -d "$physical_dist/direct-release" ]] || {
            echo "direct-release exists but is not a directory" >&2
            return 1
        }
        physical_release_root="$(cd "$physical_dist/direct-release" && pwd -P)"
    else
        physical_release_root="$physical_dist/direct-release"
    fi
    [[ "$physical_release_root" == "$physical_repo/dist/direct-release" ]] || {
        echo "direct-release resolves outside the physical repository" >&2
        return 1
    }
    case "$resolved_app_path" in
        "$physical_release_root"|"$physical_release_root"/*)
            echo "unsigned app must not be physically inside dist/direct-release" >&2
            return 1
            ;;
    esac

    stage_repo_root="$physical_repo"
    release_root="$physical_release_root"
    evidence_dir="$release_root/evidence"
    staged_app="$release_root/staged/LocalOCR Studio.app"
    native_tools_dir="$release_root/native-tools"
    physical_unsigned_app="$resolved_app_path"
}

clean_release_root() {
    local physical_dist

    physical_dist="$(cd "$stage_repo_root/dist" && pwd -P)"
    [[ "$physical_dist" == "$stage_repo_root/dist" ]] || {
        echo "refusing cleanup because dist escaped the physical repository" >&2
        return 1
    }
    [[ ! -L "$physical_dist/direct-release" ]] || {
        echo "refusing cleanup of a symlinked direct-release directory" >&2
        return 1
    }
    if [[ -e "$physical_dist/direct-release" ]]; then
        [[ "$(cd "$physical_dist/direct-release" && pwd -P)" == "$release_root" ]] || {
            echo "refusing cleanup of a noncanonical direct-release directory" >&2
            return 1
        }
    fi
    /bin/rm -rf -- "$release_root"
}

resolve_main_executable() {
    local app_path="${1:-}"
    local executable_name="${2:-}"
    local physical_app
    local physical_macos_dir
    local executable_path
    local physical_executable

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

    physical_app="$(cd "$app_path" && pwd -P)"
    [[ -d "$physical_app/Contents/MacOS" ]] || {
        echo "unsigned app Contents/MacOS directory not found" >&2
        return 1
    }
    physical_macos_dir="$(cd "$physical_app/Contents/MacOS" && pwd -P)"
    [[ "$physical_macos_dir" == "$physical_app/Contents/MacOS" ]] || {
        echo "Contents/MacOS must remain physically inside the unsigned app" >&2
        return 1
    }
    executable_path="$physical_macos_dir/$executable_name"
    [[ -f "$executable_path" ]] || {
        echo "unsigned app main executable not found: $executable_path" >&2
        return 1
    }
    physical_executable="$(/bin/realpath "$executable_path")"
    case "$physical_executable" in
        "$physical_macos_dir"/*) ;;
        *)
            echo "main executable must remain physically inside Contents/MacOS" >&2
            return 1
            ;;
    esac
    printf '%s\n' "$physical_executable"
}

plist_value() {
    "$plist_buddy" -c "Print :$2" "$1"
}

require_expected_plist_value() {
    local key="$1"
    local actual="$2"
    local expected="$3"

    [[ "$actual" == "$expected" ]] || {
        echo "$key mismatch: expected '$expected', found '$actual'" >&2
        return 1
    }
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

validate_canonical_system_install_name() {
    local install_name="$1"
    local relative_path
    local component
    local -a components

    case "$install_name" in
        /System/Library/?*)
            relative_path="${install_name#/System/Library/}"
            ;;
        /usr/lib/?*)
            relative_path="${install_name#/usr/lib/}"
            ;;
        *)
            return 1
            ;;
    esac
    [[ "$install_name" != *//* && "$install_name" != */ ]] || return 1
    IFS=/ read -r -a components <<< "$relative_path"
    for component in "${components[@]}"; do
        [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || {
            return 1
        }
    done
}

validate_install_name() {
    local install_name="${1:-}"

    if [[ "$install_name" == "@rpath/libswiftCompatibilitySpan.dylib" ]]; then
        return 0
    fi
    validate_canonical_system_install_name "$install_name" || {
        echo "unapproved dynamic-library install name: ${install_name:-<empty>}" >&2
        return 1
    }
}

validate_rpath() {
    [[ "${1:-}" == "/usr/lib/swift" ]] || {
        echo "unapproved LC_RPATH: ${1:-<empty>}" >&2
        return 1
    }
}

validate_release_binary() {
    local binary="$1"
    local file_description
    local architectures
    local minimum_macos

    [[ -f "$binary" && ! -L "$binary" ]] || {
        echo "release binary is missing or symlinked: $binary" >&2
        return 1
    }
    file_description="$(/usr/bin/file -b "$binary")"
    [[ "$file_description" == *"Mach-O 64-bit executable arm64"* ]] || {
        echo "release binary is not an arm64 Mach-O executable: $binary" >&2
        return 1
    }
    architectures="$(/usr/bin/lipo -archs "$binary")"
    validate_arm64_architecture "$architectures"
    minimum_macos="$(binary_minimum_macos "$binary")"
    validate_minimum_macos "$minimum_macos"
}

validate_binary_dependencies() {
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

binary_rpaths() {
    local binary="$1"
    local load_commands

    load_commands="$(/usr/bin/otool -l "$binary")"
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
}

validate_binary_rpaths() {
    local binary="$1"
    local allow_removable_framework_rpath="${2:-false}"
    local rpath_output
    local rpath

    rpath_output="$(binary_rpaths "$binary")" || {
        echo "could not parse every LC_RPATH in: $binary" >&2
        return 1
    }
    while IFS= read -r rpath; do
        [[ -n "$rpath" ]] || continue
        if [[
            "$allow_removable_framework_rpath" == true &&
            "$rpath" == "@executable_path/../Frameworks"
        ]]; then
            continue
        fi
        validate_rpath "$rpath"
    done <<< "$rpath_output"
}

remove_removable_framework_rpath() {
    local binary="$1"
    local rpath_output

    rpath_output="$(binary_rpaths "$binary")" || {
        echo "could not parse every LC_RPATH in: $binary" >&2
        return 1
    }
    if /usr/bin/grep -F -x -q \
        "@executable_path/../Frameworks" <<< "$rpath_output"
    then
        /usr/bin/install_name_tool \
            -delete_rpath "@executable_path/../Frameworks" \
            "$binary"
    fi
}

reject_private_user_paths() {
    local app_path="$1"
    local candidate
    local grep_status
    local scan_statuses
    local enumeration_status
    local inspection_status

    {
        /usr/bin/find "$app_path/Contents" -type f \
            ! -path "$app_path/Contents/MacOS/*" \
            ! -path "$app_path/Contents/Helpers/*" \
            -print0 |
            while IFS= read -r -d '' candidate; do
                if /usr/bin/grep -a -F -q -- "/Users/" "$candidate"; then
                    echo "app resource contains a private /Users/ path: $candidate" >&2
                    exit 1
                else
                    grep_status=$?
                    [[ "$grep_status" -eq 1 ]] || {
                        echo "could not inspect app resources for private paths: $candidate" >&2
                        exit 1
                    }
                fi
            done
        scan_statuses="${PIPESTATUS[*]}"
    } || :
    enumeration_status="${scan_statuses%% *}"
    inspection_status="${scan_statuses#* }"
    [[ "$enumeration_status" -eq 0 ]] || {
        echo "could not enumerate app resources for private paths" >&2
        return 1
    }
    [[ "$inspection_status" -eq 0 ]] || {
        echo "could not inspect app resources for private paths" >&2
        return 1
    }
}

reject_unsigned_app_helpers() {
    local app_path="$1"
    local unexpected_helper=""

    if [[ -d "$app_path/Contents/Helpers" ]]; then
        unexpected_helper="$(
            /usr/bin/find "$app_path/Contents/Helpers" \
                -mindepth 1 -maxdepth 1 -print -quit
        )" || {
            echo "could not inspect unsigned app helpers" >&2
            return 1
        }
    fi
    [[ -z "$unexpected_helper" ]] || {
        echo "unsigned app contains an unexpected helper: $unexpected_helper" >&2
        return 1
    }
}

validate_exact_staged_helpers() {
    local app_path="$1"
    local helpers_dir="$app_path/Contents/Helpers"
    local helper
    local unexpected_helper

    [[ -d "$helpers_dir" && ! -L "$helpers_dir" ]] || {
        echo "staged Helpers directory is missing or symlinked" >&2
        return 1
    }
    unexpected_helper="$(
        /usr/bin/find "$helpers_dir" -mindepth 1 -maxdepth 1 \
            ! -name localocr ! -name localocr-mcp -print -quit
    )" || {
        echo "could not inspect staged helpers" >&2
        return 1
    }
    [[ -z "$unexpected_helper" ]] || {
        echo "unexpected staged helper: $unexpected_helper" >&2
        return 1
    }
    for helper in localocr localocr-mcp; do
        validate_release_binary "$helpers_dir/$helper"
        validate_binary_dependencies "$helpers_dir/$helper"
        validate_binary_rpaths "$helpers_dir/$helper"
    done
}

validate_nested_code_allowlist() {
    local app_path="$1"
    local include_helpers="${2:-false}"
    local candidate
    local file_description
    local relative_candidate
    local scan_statuses
    local enumeration_status
    local inspection_status

    {
        /usr/bin/find "$app_path/Contents" -type f -print0 |
            while IFS= read -r -d '' candidate; do
                file_description="$(/usr/bin/file -b "$candidate")" || {
                    echo "could not inspect app code candidate: $candidate" >&2
                    exit 1
                }
                [[ "$file_description" == *"Mach-O"* ]] || continue
                relative_candidate="${candidate#"$app_path"/}"
                case "$relative_candidate" in
                    "Contents/MacOS/$expected_main_executable_name")
                        ;;
                    Contents/Helpers/localocr|Contents/Helpers/localocr-mcp)
                        [[ "$include_helpers" == true ]] || {
                            echo "unexpected nested code: $relative_candidate" >&2
                            exit 1
                        }
                        ;;
                    *)
                        echo "unexpected nested code: $relative_candidate" >&2
                        exit 1
                        ;;
                esac
            done
        scan_statuses="${PIPESTATUS[*]}"
    } || :
    enumeration_status="${scan_statuses%% *}"
    inspection_status="${scan_statuses#* }"
    [[ "$enumeration_status" -eq 0 ]] || {
        echo "could not enumerate app code candidates" >&2
        return 1
    }
    [[ "$inspection_status" -eq 0 ]] || return 1
}

reject_tree_symlinks() {
    local tree="$1"
    local symlink

    symlink="$(/usr/bin/find "$tree" -type l -print -quit)" || {
        echo "could not enumerate symlinks before metadata mutation" >&2
        return 1
    }
    [[ -z "$symlink" ]] || {
        echo "release app tree contains a symlink: $symlink" >&2
        return 1
    }
}

clear_staged_app_xattrs() {
    local app_path="$1"
    local controlled_trace_file="${2:-}"

    reject_tree_symlinks "$app_path"
    if [[ -n "$controlled_trace_file" ]]; then
        printf '%s\n' "$app_path" >> "$controlled_trace_file"
        return 0
    fi
    /usr/bin/xattr -cr "$app_path"
}

record_staged_pre_signing_hashes() {
    local staged_main_executable="$staged_app/Contents/MacOS/$expected_main_executable_name"
    local localocr_binary="$staged_app/Contents/Helpers/localocr"
    local localocr_mcp_binary="$staged_app/Contents/Helpers/localocr-mcp"
    local staged_main_hash
    local localocr_hash
    local localocr_mcp_hash

    staged_main_hash="$(/usr/bin/shasum -a 256 "$staged_main_executable" | /usr/bin/awk '{ print $1 }')"
    localocr_hash="$(/usr/bin/shasum -a 256 "$localocr_binary" | /usr/bin/awk '{ print $1 }')"
    localocr_mcp_hash="$(/usr/bin/shasum -a 256 "$localocr_mcp_binary" | /usr/bin/awk '{ print $1 }')"
    {
        printf '%s  %s\n' "$staged_main_hash" "staged/LocalOCR Studio.app/Contents/MacOS/$expected_main_executable_name"
        printf '%s  %s\n' "$localocr_hash" "staged/LocalOCR Studio.app/Contents/Helpers/localocr"
        printf '%s  %s\n' "$localocr_mcp_hash" "staged/LocalOCR Studio.app/Contents/Helpers/localocr-mcp"
    } > "$evidence_dir/pre-signing-sha256.txt"
}

stage_direct_release() {
    local source_info_plist
    local main_executable_name
    local unsigned_main_executable
    local staged_info_plist
    local helper

    validate_release_inputs
    canonicalize_release_paths "$stage_repo_root" "$LOCALOCR_UNSIGNED_APP"
    source_info_plist="$physical_unsigned_app/Contents/Info.plist"
    [[ -f "$source_info_plist" ]] || {
        echo "unsigned app Info.plist not found: $source_info_plist" >&2
        return 1
    }
    reject_tree_symlinks "$physical_unsigned_app"
    validate_release_bundle_metadata "$physical_unsigned_app"
    main_executable_name="$(plist_value "$source_info_plist" CFBundleExecutable)"
    require_expected_plist_value \
        CFBundleExecutable \
        "$main_executable_name" \
        "$expected_main_executable_name"
    unsigned_main_executable="$(
        resolve_main_executable "$physical_unsigned_app" "$main_executable_name"
    )"
    validate_release_binary "$unsigned_main_executable"
    validate_binary_dependencies "$unsigned_main_executable"
    validate_binary_rpaths "$unsigned_main_executable" true
    reject_unsigned_app_helpers "$physical_unsigned_app"
    validate_nested_code_allowlist "$physical_unsigned_app"
    reject_private_user_paths "$physical_unsigned_app"

    clean_release_root
    /bin/mkdir -p "$evidence_dir"

    configure_release_developer_dir
    "$stage_script_dir/build-native-tools.sh" --artifact-dir "$native_tools_dir"
    for helper in localocr localocr-mcp; do
        [[ -f "$native_tools_dir/$helper" ]] || {
            echo "native helper not found after build: $helper" >&2
            return 1
        }
        validate_release_binary "$native_tools_dir/$helper"
    done
    /bin/mkdir -p "$(/usr/bin/dirname "$staged_app")"
    /usr/bin/ditto "$physical_unsigned_app" "$staged_app"
    /bin/mkdir -p "$staged_app/Contents/Helpers"
    /usr/bin/ditto "$native_tools_dir/localocr" "$staged_app/Contents/Helpers/localocr"
    /usr/bin/ditto "$native_tools_dir/localocr-mcp" "$staged_app/Contents/Helpers/localocr-mcp"
    /bin/chmod 0755 \
        "$staged_app/Contents/Helpers/localocr" \
        "$staged_app/Contents/Helpers/localocr-mcp"
    remove_removable_framework_rpath \
        "$staged_app/Contents/MacOS/$expected_main_executable_name"
    reject_tree_symlinks "$staged_app"
    clear_staged_app_xattrs "$staged_app"

    staged_info_plist="$staged_app/Contents/Info.plist"
    require_expected_plist_value \
        CFBundleIdentifier \
        "$(plist_value "$staged_info_plist" CFBundleIdentifier)" \
        "$LOCALOCR_EXPECTED_BUNDLE_ID"
    require_expected_plist_value \
        CFBundleShortVersionString \
        "$(plist_value "$staged_info_plist" CFBundleShortVersionString)" \
        "$LOCALOCR_RELEASE_VERSION"
    require_expected_plist_value \
        CFBundleVersion \
        "$(plist_value "$staged_info_plist" CFBundleVersion)" \
        "$LOCALOCR_RELEASE_BUILD"

    require_expected_plist_value \
        CFBundleExecutable \
        "$(plist_value "$staged_info_plist" CFBundleExecutable)" \
        "$expected_main_executable_name"
    validate_release_binary \
        "$staged_app/Contents/MacOS/$expected_main_executable_name"
    validate_binary_dependencies \
        "$staged_app/Contents/MacOS/$expected_main_executable_name"
    validate_binary_rpaths \
        "$staged_app/Contents/MacOS/$expected_main_executable_name"
    validate_exact_staged_helpers "$staged_app"
    validate_nested_code_allowlist "$staged_app" true
    reject_private_user_paths "$staged_app"
    record_staged_pre_signing_hashes
}

case "${1:-}" in
    --test-architecture)
        [[ "$#" -eq 2 ]] || exit 2
        validate_arm64_architecture "$2"
        ;;
    --test-minimum-macos)
        [[ "$#" -eq 2 ]] || exit 2
        validate_minimum_macos "$2"
        ;;
    --test-cleanup-safety)
        [[ "$#" -eq 3 ]] || exit 2
        canonicalize_release_paths "$2" "$3"
        clean_release_root
        ;;
    --test-main-executable)
        [[ "$#" -eq 3 ]] || exit 2
        resolve_main_executable "$2" "$3"
        ;;
    --test-native-artifact-dir)
        [[ "$#" -eq 2 && "$2" == "$native_tools_dir" ]] || exit 1
        printf '%s\n' "$native_tools_dir"
        ;;
    --test-tree-before-xattr)
        [[ "$#" -eq 2 ]] || exit 2
        reject_tree_symlinks "$2"
        clear_staged_app_xattrs "$2" "${LOCALOCR_TEST_XATTR_TRACE:-}"
        ;;
    --test-production-xattr)
        [[ "$#" -eq 2 ]] || exit 2
        clear_staged_app_xattrs "$2"
        ;;
    "")
        stage_direct_release
        ;;
    *)
        echo "unknown stage-direct-release mode: $1" >&2
        exit 2
        ;;
esac
