#!/usr/bin/env bash

set -euo pipefail

release_toolchain_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
release_repo_root="$(cd "$release_toolchain_script_dir/.." && pwd)"
release_developer_dir="/Applications/Xcode.app/Contents/Developer"
release_signing_identity="Developer ID Application: John Scott Ray (DZ8B5454ZN)"
release_plist_buddy="/usr/libexec/PlistBuddy"
release_xcodebuild_path=""
release_system_swift_rpath="/usr/lib/swift"
release_removable_framework_rpath="@executable_path/../Frameworks"
release_path_guard="$release_toolchain_script_dir/release-path-guard.swift"
release_symbols_root="$release_repo_root/dist/release-symbols"
release_symbols_root_identity=""

release_binary_minimum_macos() {
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

release_validate_binary_architecture_and_target() {
    local binary="$1"
    local file_description
    local architectures
    local minimum_macos
    local minimum_major

    file_description="$(/usr/bin/file -b "$binary")" || {
        echo "could not inspect copied release binary: $binary" >&2
        return 1
    }
    [[ "$file_description" == *"Mach-O 64-bit executable arm64"* ]] || {
        echo "release binary copy is not an arm64 Mach-O executable: $binary" >&2
        return 1
    }
    architectures="$(/usr/bin/lipo -archs "$binary")" || {
        echo "could not inspect copied release binary architecture: $binary" >&2
        return 1
    }
    [[ "$architectures" == "arm64" ]] || {
        echo "release binaries must contain only the arm64 architecture" >&2
        return 1
    }
    minimum_macos="$(release_binary_minimum_macos "$binary")" || {
        echo "could not inspect copied release binary minimum macOS: $binary" >&2
        return 1
    }
    [[ "$minimum_macos" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || {
        echo "invalid minimum macOS version: $minimum_macos" >&2
        return 1
    }
    minimum_major="${minimum_macos%%.*}"
    [[ "$minimum_major" -ge 14 ]] || {
        echo "release binaries must require macOS 14 or later" >&2
        return 1
    }
}

release_validate_canonical_system_install_name() {
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

release_validate_binary_dependencies() {
    local binary="$1"
    local dependency_output
    local dependency_line
    local install_name

    dependency_output="$(/usr/bin/otool -L "$binary")" || {
        echo "could not inspect copied release binary dependencies: $binary" >&2
        return 1
    }
    while IFS= read -r dependency_line; do
        [[ -n "$dependency_line" ]] || continue
        install_name="$(
            printf '%s\n' "$dependency_line" |
                /usr/bin/awk '{ print $1 }'
        )"
        if [[ "$install_name" == "@rpath/libswiftCompatibilitySpan.dylib" ]]; then
            [[ "$dependency_line" == *", weak)" ]] || {
                echo "libswiftCompatibilitySpan.dylib must be weak-linked" >&2
                return 1
            }
            continue
        fi
        release_validate_canonical_system_install_name "$install_name" || {
            echo "unapproved dynamic-library install name: ${install_name:-<empty>}" >&2
            return 1
        }
    done < <(
        printf '%s\n' "$dependency_output" |
            /usr/bin/awk 'NR > 1 { sub(/^[[:space:]]+/, ""); print }'
    )
}

release_binary_rpaths() {
    local binary="$1"
    local load_commands

    load_commands="$(/usr/bin/otool -l "$binary")" || {
        echo "could not inspect copied release binary load commands: $binary" >&2
        return 1
    }
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

release_validate_binary_rpaths() {
    local binary="$1"
    local allow_framework_rpath="${2:-false}"
    local rpaths
    local rpath

    rpaths="$(release_binary_rpaths "$binary")" || {
        echo "could not parse every LC_RPATH in: $binary" >&2
        return 1
    }
    while IFS= read -r rpath; do
        [[ -n "$rpath" ]] || continue
        if [[
            "$allow_framework_rpath" == true &&
            "$rpath" == "$release_removable_framework_rpath"
        ]]; then
            continue
        fi
        [[ "$rpath" == "$release_system_swift_rpath" ]] || {
            echo "unapproved LC_RPATH: $rpath" >&2
            return 1
        }
    done <<< "$rpaths"
}

release_reject_private_user_path() {
    local binary="$1"
    local grep_status

    if /usr/bin/grep -a -F -q -- "/Users/" "$binary"; then
        echo "release binary contains a private /Users/ path: $binary" >&2
        return 1
    else
        grep_status=$?
        [[ "$grep_status" -eq 1 ]] || {
            echo "could not inspect release binary for private paths: $binary" >&2
            return 1
        }
    fi
}

release_validate_binary_policy() {
    local binary="$1"
    local allow_framework_rpath="${2:-false}"
    local reject_private_path="${3:-true}"

    release_validate_binary_architecture_and_target "$binary" || return 1
    release_validate_binary_dependencies "$binary" || return 1
    release_validate_binary_rpaths "$binary" "$allow_framework_rpath" || return 1
    if [[ "$reject_private_path" == true ]]; then
        release_reject_private_user_path "$binary" || return 1
    fi
}

release_macho_arm64_uuid() {
    local binary_or_dsym="${1:-}"
    local uuid_output
    local uuid_line
    local uuid=""
    local uuid_count=0

    [[ -n "$binary_or_dsym" ]] || return 1
    uuid_output="$(/usr/bin/dwarfdump --uuid "$binary_or_dsym")" || {
        echo "could not read Mach-O UUID: $binary_or_dsym" >&2
        return 1
    }
    while IFS= read -r uuid_line; do
        [[ -n "$uuid_line" ]] || continue
        if [[ "$uuid_line" =~ ^UUID:\ ([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})\ \(arm64\)\ .+$ ]]; then
            uuid="${BASH_REMATCH[1]}"
            uuid_count=$((uuid_count + 1))
        else
            echo "unexpected Mach-O UUID record: $uuid_line" >&2
            return 1
        fi
    done <<< "$uuid_output"
    [[ "$uuid_count" -eq 1 ]] || {
        echo "release symbols require exactly one arm64 Mach-O UUID" >&2
        return 1
    }
    printf '%s\n' "$uuid"
}

release_validate_symbol_tree() {
    local dsym="${1:-}"
    local invalid_entry

    [[ -d "$dsym" && ! -L "$dsym" ]] || {
        echo "release dSYM is missing or symlinked: $dsym" >&2
        return 1
    }
    if ! invalid_entry="$(
        /usr/bin/find "$dsym" \! -type d \! -type f -print -quit
    )"; then
        echo "could not inspect release dSYM tree: $dsym" >&2
        return 1
    fi
    [[ -z "$invalid_entry" ]] || {
        echo "release dSYM contains a symlink or special file: $invalid_entry" >&2
        return 1
    }
}

release_validate_physical_dsym() {
    local dsym="${1:-}"
    local physical_dsym

    [[ "$dsym" == /* ]] || {
        echo "release dSYM path must be absolute" >&2
        return 1
    }
    release_validate_symbol_tree "$dsym" || return 1
    physical_dsym="$(cd "$dsym" && pwd -P)" || return 1
    [[ "$physical_dsym" == "$dsym" ]] || {
        echo "release dSYM escaped its validated physical path: $dsym" >&2
        return 1
    }
}

release_validate_dsym_matches_binary() {
    local binary="${1:-}"
    local dsym="${2:-}"
    local binary_uuid
    local dsym_uuid

    [[ -f "$binary" && ! -L "$binary" ]] || {
        echo "release binary for dSYM validation is missing or symlinked" >&2
        return 1
    }
    release_validate_physical_dsym "$dsym" || return 1
    binary_uuid="$(release_macho_arm64_uuid "$binary")" || return 1
    dsym_uuid="$(release_macho_arm64_uuid "$dsym")" || return 1
    [[ "$binary_uuid" == "$dsym_uuid" ]] || {
        echo "dSYM UUID does not match release binary UUID" >&2
        return 1
    }
}

release_prepare_symbols_root() {
    local dist_root="$release_repo_root/dist"
    local dist_identity
    local current_identity

    [[ -d "$dist_root" && ! -L "$dist_root" ]] || {
        echo "release symbols parent must be a physical dist directory" >&2
        return 1
    }
    [[ "$(cd "$dist_root" && pwd -P)" == "$dist_root" ]] || {
        echo "release symbols parent escaped the physical repository" >&2
        return 1
    }
    [[ ! -L "$release_symbols_root" ]] || {
        echo "release symbols directory must not be a symlink" >&2
        return 1
    }
    if [[ ! -e "$release_symbols_root" ]]; then
        dist_identity="$(
            /usr/bin/swift "$release_path_guard" token-directory "$dist_root"
        )" || return 1
        (
            cd "$dist_root" || exit 1
            current_identity="$(/usr/bin/stat -f '%d:%i' .)" || exit 1
            [[ "$current_identity" == "$dist_identity" ]] || {
                echo "release symbols parent identity changed before creation" >&2
                exit 1
            }
            [[ ! -e release-symbols && ! -L release-symbols ]] || {
                echo "release symbols output appeared before creation" >&2
                exit 1
            }
            /bin/mkdir release-symbols
        ) || return 1
    fi
    [[ -d "$release_symbols_root" && ! -L "$release_symbols_root" ]] || {
        echo "release symbols output must be a physical directory" >&2
        return 1
    }
    [[ "$(cd "$release_symbols_root" && pwd -P)" == "$release_symbols_root" ]] || {
        echo "release symbols directory escaped the repository" >&2
        return 1
    }
    release_symbols_root_identity="$(
        /usr/bin/swift "$release_path_guard" \
            token-directory "$release_symbols_root"
    )"
}

release_validate_symbols_root_identity() {
    local expected_identity="${1:-}"
    local current_identity

    [[ -n "$expected_identity" ]] || return 1
    [[ -d "$release_symbols_root" && ! -L "$release_symbols_root" ]] || {
        echo "release symbols directory disappeared or became a symlink" >&2
        return 1
    }
    [[ "$(cd "$release_symbols_root" && pwd -P)" == "$release_symbols_root" ]] || {
        echo "release symbols directory escaped the repository" >&2
        return 1
    }
    current_identity="$(
        /usr/bin/swift "$release_path_guard" \
            token-directory "$release_symbols_root"
    )" || return 1
    [[ "$current_identity" == "$expected_identity" ]] || {
        echo "release symbols directory identity changed during publication" >&2
        return 1
    }
}

release_cleanup_symbol_snapshot_root() {
    local snapshot_root="${1:-}"

    case "$snapshot_root" in
        /private/tmp/localocr-release-symbols.*) ;;
        *) return 1 ;;
    esac
    [[ -d "$snapshot_root" && ! -L "$snapshot_root" ]] || return 1
    [[ "$(cd "$snapshot_root" && pwd -P)" == "$snapshot_root" ]] || return 1
    /bin/rm -rf -- "$snapshot_root"
}

release_preserve_matching_dsym() {
    local binary="${1:-}"
    local source_dsym="${2:-}"
    local symbol_label="${3:-}"
    local binary_uuid
    local source_identity
    local snapshot_root
    local snapshot_dsym
    local symbols_identity
    local output_name
    local output_dsym

    [[ -n "$source_dsym" ]] || return 0
    case "$symbol_label" in
        localocr|localocr-mcp|LocalOCR-Studio) ;;
        *)
            echo "unexpected release symbol label: $symbol_label" >&2
            return 1
            ;;
    esac
    release_validate_dsym_matches_binary "$binary" "$source_dsym" || return 1
    binary_uuid="$(release_macho_arm64_uuid "$binary")" || return 1
    source_identity="$(
        /usr/bin/swift "$release_path_guard" \
            token-directory "$source_dsym"
    )" || return 1
    snapshot_root="$(
        /usr/bin/mktemp -d /private/tmp/localocr-release-symbols.XXXXXX
    )" || {
        echo "could not create a private dSYM snapshot directory" >&2
        return 1
    }
    /bin/chmod 700 "$snapshot_root" || {
        release_cleanup_symbol_snapshot_root "$snapshot_root" || true
        return 1
    }
    snapshot_dsym="$snapshot_root/symbol.dSYM"
    /usr/bin/ditto "$source_dsym" "$snapshot_dsym" || {
        release_cleanup_symbol_snapshot_root "$snapshot_root" || true
        return 1
    }
    [[ "$source_identity" == "$(
        /usr/bin/swift "$release_path_guard" \
            token-directory "$source_dsym"
    )" ]] || {
        echo "release dSYM source identity changed during snapshot" >&2
        release_cleanup_symbol_snapshot_root "$snapshot_root" || true
        return 1
    }
    release_validate_dsym_matches_binary "$binary" "$snapshot_dsym" || {
        release_cleanup_symbol_snapshot_root "$snapshot_root" || true
        return 1
    }

    release_prepare_symbols_root || {
        release_cleanup_symbol_snapshot_root "$snapshot_root" || true
        return 1
    }
    symbols_identity="$release_symbols_root_identity"
    output_name="$binary_uuid-$symbol_label.dSYM"
    output_dsym="$release_symbols_root/$output_name"
    (
        local current_identity
        local candidate_path
        local candidate_name
        local publish_result

        cd "$release_symbols_root" || exit 1
        current_identity="$(/usr/bin/stat -f '%d:%i' .)" || exit 1
        [[ "$current_identity" == "$symbols_identity" ]] || {
            echo "release symbols directory identity changed before copy" >&2
            exit 1
        }
        candidate_path="$(
            /usr/bin/mktemp -d ".release-symbol.$binary_uuid.$symbol_label.XXXXXX"
        )" || exit 1
        candidate_name="${candidate_path#./}"
        case "$candidate_name" in
            .release-symbol."$binary_uuid"."$symbol_label".*) ;;
            *) exit 1 ;;
        esac
        [[ ! -e "$candidate_name.dSYM" && ! -L "$candidate_name.dSYM" ]] || {
            /bin/rm -rf -- "$candidate_name"
            exit 1
        }
        /bin/mv "$candidate_name" "$candidate_name.dSYM" || {
            /bin/rm -rf -- "$candidate_name"
            exit 1
        }
        candidate_name="$candidate_name.dSYM"
        /usr/bin/ditto "$snapshot_dsym" "$candidate_name" || {
            /bin/rm -rf -- "$candidate_name"
            exit 1
        }
        release_validate_symbol_tree "$candidate_name" || {
            /bin/rm -rf -- "$candidate_name"
            exit 1
        }
        [[ "$(release_macho_arm64_uuid "$candidate_name")" == "$binary_uuid" ]] || {
            echo "copied dSYM UUID changed before publication" >&2
            /bin/rm -rf -- "$candidate_name"
            exit 1
        }
        publish_result="$(
            /usr/bin/swift "$release_path_guard" publish-directory \
                "$release_symbols_root/$candidate_name" \
                "$output_dsym" \
                "$symbols_identity"
        )" || {
            /bin/rm -rf -- "$candidate_name"
            exit 1
        }
        if [[ "$publish_result" == "exchanged" ]]; then
            /bin/rm -rf -- "$candidate_name"
        else
            [[ "$publish_result" == "moved" ]] || exit 1
        fi
    ) || {
        release_cleanup_symbol_snapshot_root "$snapshot_root" || true
        return 1
    }
    release_validate_symbols_root_identity "$symbols_identity" || {
        release_cleanup_symbol_snapshot_root "$snapshot_root" || true
        return 1
    }
    release_validate_dsym_matches_binary "$binary" "$output_dsym" || {
        release_cleanup_symbol_snapshot_root "$snapshot_root" || true
        return 1
    }
    release_cleanup_symbol_snapshot_root "$snapshot_root" || {
        echo "could not clean private dSYM snapshot directory" >&2
        return 1
    }
}

sanitize_validated_release_binary() {
    local binary="${1:-}"
    local expected_binary="${2:-}"
    local allow_framework_rpath="${3:-false}"
    local remove_non_system_rpaths="${4:-false}"
    local parent
    local physical_parent
    local physical_binary
    local rpath
    local sanitize_root
    local working_binary
    local target_identity
    local working_identity

    cleanup_sanitize_root() {
        local candidate_root="${1:-}"

        case "$candidate_root" in
            /private/tmp/localocr-release-sanitize.*) ;;
            *) return 1 ;;
        esac
        [[ -d "$candidate_root" && ! -L "$candidate_root" ]] || return 1
        [[ "$(cd "$candidate_root" && pwd -P)" == "$candidate_root" ]] || return 1
        /bin/rm -rf -- "$candidate_root"
    }

    [[ -n "$binary" && "$binary" == "$expected_binary" ]] || {
        echo "refusing to sanitize an unexpected release binary" >&2
        return 1
    }
    [[ "$binary" == /* && -f "$binary" && -x "$binary" && ! -L "$binary" ]] || {
        echo "release binary copy is missing, symlinked, or not executable: $binary" >&2
        return 1
    }
    parent="$(/usr/bin/dirname "$binary")"
    [[ -d "$parent" && ! -L "$parent" ]] || {
        echo "release binary parent is missing or symlinked: $parent" >&2
        return 1
    }
    physical_parent="$(cd "$parent" && pwd -P)" || return 1
    [[ "$physical_parent" == "$parent" ]] || {
        echo "release binary parent is not a physical validated path: $parent" >&2
        return 1
    }
    physical_binary="$(/bin/realpath "$binary")" || return 1
    [[ "$physical_binary" == "$binary" ]] || {
        echo "release binary copy escaped its validated path: $binary" >&2
        return 1
    }
    [[ -f "$release_path_guard" && ! -L "$release_path_guard" ]] || {
        echo "release path guard is missing or symlinked" >&2
        return 1
    }

    sanitize_root="$(/usr/bin/mktemp -d /private/tmp/localocr-release-sanitize.XXXXXX)" || {
        echo "could not create a private release sanitizer directory" >&2
        return 1
    }
    /bin/chmod 700 "$sanitize_root" || {
        cleanup_sanitize_root "$sanitize_root" || true
        return 1
    }
    working_binary="$sanitize_root/binary"
    target_identity="$(
        /usr/bin/swift "$release_path_guard" \
            snapshot-file "$binary" "$working_binary"
    )" || {
        cleanup_sanitize_root "$sanitize_root" || true
        return 1
    }
    if [[ "$remove_non_system_rpaths" == true ]]; then
        while IFS= read -r rpath; do
            [[ -n "$rpath" ]] || continue
            if [[ "$rpath" != "$release_system_swift_rpath" ]]; then
                /usr/bin/install_name_tool \
                    -delete_rpath "$rpath" "$working_binary" || {
                    cleanup_sanitize_root "$sanitize_root" || true
                    return 1
                }
            fi
        done < <(release_binary_rpaths "$working_binary")
    fi
    working_identity="$(
        /usr/bin/swift "$release_path_guard" token-file "$working_binary"
    )" || {
        cleanup_sanitize_root "$sanitize_root" || true
        return 1
    }
    release_validate_binary_policy \
        "$working_binary" "$allow_framework_rpath" false || {
        cleanup_sanitize_root "$sanitize_root" || true
        return 1
    }
    [[ "$(/usr/bin/swift "$release_path_guard" token-file "$working_binary")" == "$working_identity" ]] || {
        echo "release sanitizer working copy changed before strip" >&2
        cleanup_sanitize_root "$sanitize_root" || true
        return 1
    }
    /usr/bin/strip -S "$working_binary" || {
        echo "could not strip private release working copy" >&2
        cleanup_sanitize_root "$sanitize_root" || true
        return 1
    }
    working_identity="$(
        /usr/bin/swift "$release_path_guard" token-file "$working_binary"
    )" || {
        cleanup_sanitize_root "$sanitize_root" || true
        return 1
    }
    release_validate_binary_policy \
        "$working_binary" "$allow_framework_rpath" true || {
        cleanup_sanitize_root "$sanitize_root" || true
        return 1
    }
    /usr/bin/swift "$release_path_guard" \
        commit-file "$working_binary" "$binary" \
        "$target_identity" "$working_identity" || {
        echo "release binary identity changed before sanitized commit: $binary" >&2
        cleanup_sanitize_root "$sanitize_root" || true
        return 1
    }
    release_validate_binary_policy "$binary" "$allow_framework_rpath" true || {
        cleanup_sanitize_root "$sanitize_root" || true
        return 1
    }
    cleanup_sanitize_root "$sanitize_root" || {
        echo "could not clean private release sanitizer directory" >&2
        return 1
    }
}

release_evidence_dir() {
    printf '%s\n' "$release_repo_root/dist/direct-release/evidence"
}

validate_release_developer_dir() {
    local candidate="${1:-}"
    local normalized

    [[ "$candidate" == "$release_developer_dir" ]] || {
        echo "release builds require the stable Xcode developer directory" >&2
        return 1
    }

    normalized="$(printf '%s' "$candidate" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    case "$normalized" in
        *beta*|*rc*|*preview*)
            echo "prerelease developer directories are not allowed" >&2
            return 1
            ;;
    esac
}

select_release_developer_dir() {
    local resolved_developer_dir

    DEVELOPER_DIR="$release_developer_dir"
    export DEVELOPER_DIR
    validate_release_developer_dir "$DEVELOPER_DIR"

    [[ -d "$DEVELOPER_DIR" && ! -L "$DEVELOPER_DIR" ]] || {
        echo "stable Xcode developer directory is missing or symlinked: $DEVELOPER_DIR" >&2
        return 1
    }
    resolved_developer_dir="$(cd "$DEVELOPER_DIR" && pwd -P)"
    validate_release_developer_dir "$resolved_developer_dir"

    release_xcodebuild_path="$DEVELOPER_DIR/usr/bin/xcodebuild"
    [[ -x "$release_xcodebuild_path" && ! -L "$release_xcodebuild_path" ]] || {
        echo "xcodebuild not found as a physical stable-Xcode executable: $release_xcodebuild_path" >&2
        return 1
    }
}

prepare_release_evidence_directory() {
    local requested_repo_root="${1:-$release_repo_root}"
    local physical_repo
    local dist_dir
    local release_dir
    local evidence_dir
    local directory
    local label

    [[ -d "$requested_repo_root" && ! -L "$requested_repo_root" ]] || {
        echo "release repository root must be a physical directory" >&2
        return 1
    }
    physical_repo="$(cd "$requested_repo_root" && pwd -P)"
    [[ "$physical_repo" == "$requested_repo_root" ]] || {
        echo "release repository root must not escape through a symlink" >&2
        return 1
    }
    dist_dir="$physical_repo/dist"
    release_dir="$dist_dir/direct-release"
    evidence_dir="$release_dir/evidence"

    for directory in "$dist_dir" "$release_dir" "$evidence_dir"; do
        case "$directory" in
            "$dist_dir") label="dist" ;;
            "$release_dir") label="dist/direct-release" ;;
            "$evidence_dir") label="dist/direct-release/evidence" ;;
        esac
        [[ ! -L "$directory" ]] || {
            echo "$label must not be a symlink" >&2
            return 1
        }
        if [[ -e "$directory" ]]; then
            [[ -d "$directory" ]] || {
                echo "$label must be a directory" >&2
                return 1
            }
            [[ "$(cd "$directory" && pwd -P)" == "$directory" ]] || {
                echo "$label must remain physically inside the release repository" >&2
                return 1
            }
        else
            /bin/mkdir "$directory" || return 1
        fi
    done
    printf '%s\n' "$evidence_dir"
}

record_release_toolchain_evidence() {
    local evidence_dir
    local version_file
    local version_file_partial

    [[ -n "$release_xcodebuild_path" ]] || {
        echo "stable Xcode must be selected before recording evidence" >&2
        return 1
    }
    evidence_dir="$(prepare_release_evidence_directory)" || return
    version_file="$evidence_dir/xcode-version.txt"
    [[ ! -L "$version_file" ]] || {
        echo "Xcode evidence leaf must not be a symlink" >&2
        return 1
    }
    [[ ! -e "$version_file" || -f "$version_file" ]] || {
        echo "Xcode evidence leaf must be a regular file" >&2
        return 1
    }
    version_file_partial="$(/usr/bin/mktemp "$evidence_dir/.xcode-version.XXXXXX")"
    "$release_xcodebuild_path" -version > "$version_file_partial" || {
        /bin/rm -f -- "$version_file_partial"
        return 1
    }
    [[ "$(/usr/bin/awk 'END { print NR }' "$version_file_partial")" -eq 2 ]] || {
        /bin/rm -f -- "$version_file_partial"
        echo "expected xcodebuild -version to produce exactly two lines" >&2
        return 1
    }
    /bin/mv -f -- "$version_file_partial" "$version_file"
}

configure_release_developer_dir() {
    select_release_developer_dir
    record_release_toolchain_evidence
}

validate_release_inputs() {
    local variable_name

    for variable_name in \
        LOCALOCR_UNSIGNED_APP \
        LOCALOCR_RELEASE_VERSION \
        LOCALOCR_RELEASE_BUILD \
        LOCALOCR_EXPECTED_BUNDLE_ID
    do
        [[ -n "${!variable_name:-}" ]] || {
            echo "required release input is missing: $variable_name" >&2
            return 1
        }
    done
}

validate_release_metadata_inputs() {
    local variable_name
    local bundle_component
    local -a bundle_components

    for variable_name in \
        LOCALOCR_EXPECTED_BUNDLE_ID \
        LOCALOCR_RELEASE_VERSION \
        LOCALOCR_RELEASE_BUILD
    do
        [[ -n "${!variable_name:-}" ]] || {
            echo "required release metadata input is missing: $variable_name" >&2
            return 1
        }
    done
    IFS=. read -r -a bundle_components <<< "$LOCALOCR_EXPECTED_BUNDLE_ID"
    [[ "${#bundle_components[@]}" -ge 2 ]] || {
        echo "LOCALOCR_EXPECTED_BUNDLE_ID has an invalid format" >&2
        return 1
    }
    for bundle_component in "${bundle_components[@]}"; do
        [[ "$bundle_component" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || {
            echo "LOCALOCR_EXPECTED_BUNDLE_ID has an invalid format" >&2
            return 1
        }
    done
    [[ "$LOCALOCR_RELEASE_VERSION" =~ ^[0-9]+([.][0-9]+){1,3}([+-][0-9A-Za-z.-]+)?$ ]] || {
        echo "LOCALOCR_RELEASE_VERSION has an invalid format" >&2
        return 1
    }
    [[ "$LOCALOCR_RELEASE_BUILD" =~ ^[0-9]+$ ]] || {
        echo "LOCALOCR_RELEASE_BUILD has an invalid format" >&2
        return 1
    }
}

validate_release_bundle_metadata() {
    local app_path="$1"
    local info_plist="$app_path/Contents/Info.plist"
    local key
    local expected
    local actual

    validate_release_metadata_inputs || return
    [[ -d "$app_path" && ! -L "$app_path" ]] || {
        echo "release app is missing or symlinked: $app_path" >&2
        return 1
    }
    [[ -f "$info_plist" && ! -L "$info_plist" ]] || {
        echo "release Info.plist is missing or symlinked" >&2
        return 1
    }
    for key in \
        CFBundleIdentifier \
        CFBundleShortVersionString \
        CFBundleVersion
    do
        case "$key" in
            CFBundleIdentifier) expected="$LOCALOCR_EXPECTED_BUNDLE_ID" ;;
            CFBundleShortVersionString) expected="$LOCALOCR_RELEASE_VERSION" ;;
            CFBundleVersion) expected="$LOCALOCR_RELEASE_BUILD" ;;
        esac
        actual="$("$release_plist_buddy" -c "Print :$key" "$info_plist")" || {
            echo "could not read $key from release Info.plist" >&2
            return 1
        }
        [[ "$actual" == "$expected" ]] || {
            echo "$key mismatch: expected '$expected', found '$actual'" >&2
            return 1
        }
    done
}

validate_signing_identity() {
    local identity_list
    local matching_identity_count

    identity_list="$(/usr/bin/security find-identity -v -p codesigning)"
    matching_identity_count="$(
        printf '%s\n' "$identity_list" |
            /usr/bin/awk -v expected="\"$release_signing_identity\"" '
                index($0, expected) {
                    suffix = substr($0, index($0, expected))
                    if (suffix == expected) {
                        count += 1
                    }
                }
                END { print count + 0 }
            '
    )"
    [[ "$matching_identity_count" -eq 1 ]] || {
        echo "expected exactly one valid Developer ID Application identity" >&2
        return 1
    }
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --test-developer-dir)
            [[ "$#" -eq 2 ]] || exit 2
            validate_release_developer_dir "$2"
            ;;
        --test-bundle-metadata)
            [[ "$#" -eq 2 ]] || exit 2
            validate_release_bundle_metadata "$2"
            ;;
        --test-evidence-directory)
            [[ "$#" -eq 2 ]] || exit 2
            release_repo_root="$2"
            prepare_release_evidence_directory
            ;;
        "")
            configure_release_developer_dir
            ;;
        *)
            echo "unknown release-toolchain mode: $1" >&2
            exit 2
            ;;
    esac
fi
