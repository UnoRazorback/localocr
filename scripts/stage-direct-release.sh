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
            in_build_version && $1 == "minos" {
                print $2
                exit
            }
        '
}

validate_release_helper() {
    local helper="$1"
    local file_description
    local architectures
    local minimum_macos

    file_description="$(/usr/bin/file -b "$helper")"
    [[ "$file_description" == *"Mach-O 64-bit executable arm64"* ]] || {
        echo "release helper is not an arm64 Mach-O executable: $helper" >&2
        return 1
    }
    architectures="$(/usr/bin/lipo -archs "$helper")"
    validate_arm64_architecture "$architectures"
    minimum_macos="$(binary_minimum_macos "$helper")"
    validate_minimum_macos "$minimum_macos"
}

record_pre_signing_hashes() {
    local unsigned_main_executable="$1"
    local localocr_binary="$native_tools_dir/localocr"
    local localocr_mcp_binary="$native_tools_dir/localocr-mcp"
    local unsigned_hash
    local localocr_hash
    local localocr_mcp_hash

    unsigned_hash="$(/usr/bin/shasum -a 256 "$unsigned_main_executable" | /usr/bin/awk '{ print $1 }')"
    localocr_hash="$(/usr/bin/shasum -a 256 "$localocr_binary" | /usr/bin/awk '{ print $1 }')"
    localocr_mcp_hash="$(/usr/bin/shasum -a 256 "$localocr_mcp_binary" | /usr/bin/awk '{ print $1 }')"
    {
        printf '%s  %s\n' "$unsigned_hash" "unsigned-app/Contents/MacOS/$(/usr/bin/basename "$unsigned_main_executable")"
        printf '%s  %s\n' "$localocr_hash" "native-tools/localocr"
        printf '%s  %s\n' "$localocr_mcp_hash" "native-tools/localocr-mcp"
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
    main_executable_name="$(plist_value "$source_info_plist" CFBundleExecutable)"
    unsigned_main_executable="$(
        resolve_main_executable "$physical_unsigned_app" "$main_executable_name"
    )"

    clean_release_root
    /bin/mkdir -p "$evidence_dir"

    configure_release_developer_dir
    "$stage_script_dir/build-native-tools.sh" --artifact-dir "$native_tools_dir"
    for helper in localocr localocr-mcp; do
        [[ -f "$native_tools_dir/$helper" ]] || {
            echo "native helper not found after build: $helper" >&2
            return 1
        }
        validate_release_helper "$native_tools_dir/$helper"
    done
    record_pre_signing_hashes "$unsigned_main_executable"

    /bin/mkdir -p "$(/usr/bin/dirname "$staged_app")"
    /usr/bin/ditto "$physical_unsigned_app" "$staged_app"
    /bin/mkdir -p "$staged_app/Contents/Helpers"
    /usr/bin/ditto "$native_tools_dir/localocr" "$staged_app/Contents/Helpers/localocr"
    /usr/bin/ditto "$native_tools_dir/localocr-mcp" "$staged_app/Contents/Helpers/localocr-mcp"
    /bin/chmod 0755 \
        "$staged_app/Contents/Helpers/localocr" \
        "$staged_app/Contents/Helpers/localocr-mcp"
    /usr/bin/xattr -cr "$staged_app"

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

    validate_release_helper "$staged_app/Contents/Helpers/localocr"
    validate_release_helper "$staged_app/Contents/Helpers/localocr-mcp"
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
    "")
        stage_direct_release
        ;;
    *)
        echo "unknown stage-direct-release mode: $1" >&2
        exit 2
        ;;
esac
