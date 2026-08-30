#!/usr/bin/env bash

set -euo pipefail

studio_build_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
studio_repo_root="$(cd "$studio_build_script_dir/.." && pwd -P)"
# shellcheck source=release-toolchain.sh
source "$studio_build_script_dir/release-toolchain.sh"

project_path="$studio_repo_root/LocalOCR Studio.xcodeproj"
scheme_name="LocalOCR Studio"
output_root="$studio_repo_root/dist/unsigned-app"
output_app="$output_root/LocalOCR Studio.app"
build_root=""
studio_physical_tmp_root="$(cd /tmp && pwd -P)"
studio_bundle_identifier="com.rayconsulting.localocr"
studio_release_version="0.3.0"
studio_release_build="3"
studio_minimum_os="14.0"
studio_output_candidate=""
studio_output_candidate_identity=""
studio_output_root_identity=""

validate_no_network_framework_dependency() {
    release_validate_binary_dependencies "$1" || return 1
    release_validate_no_network_symbols "$1"
}

validate_local_intelligence_candidate_binary() {
    local binary="$1"
    local minimum_macos

    release_validate_binary_policy "$binary" true true || return 1
    validate_no_network_framework_dependency "$binary" || return 1
    minimum_macos="$(release_binary_minimum_macos "$binary")" || return 1
    [[ "$minimum_macos" == "$studio_minimum_os" ]] || {
        echo "Local Intelligence Studio candidate must target macOS $studio_minimum_os exactly: found $minimum_macos" >&2
        return 1
    }
}

set_validated_build_root() {
    local candidate="${1:-}"
    local physical_candidate

    case "$candidate" in
        /tmp/localocr-studio-build.*) ;;
        *) return 1 ;;
    esac
    [[ -d "$candidate" && ! -L "$candidate" ]] || return 1
    physical_candidate="$(cd "$candidate" && pwd -P)"
    [[ "$(/usr/bin/dirname "$physical_candidate")" == "$studio_physical_tmp_root" ]] || {
        return 1
    }
    case "$(/usr/bin/basename "$physical_candidate")" in
        localocr-studio-build.*) ;;
        *) return 1 ;;
    esac
    build_root="$physical_candidate"
}

validate_build_root() {
    [[ -n "$build_root" ]] || return 1
    [[ "$(/usr/bin/dirname "$build_root")" == "$studio_physical_tmp_root" ]] || {
        return 1
    }
    case "$(/usr/bin/basename "$build_root")" in
        localocr-studio-build.*) ;;
        *) return 1 ;;
    esac
    [[ -d "$build_root" && ! -L "$build_root" ]] || return 1
    [[ "$(cd "$build_root" && pwd -P)" == "$build_root" ]]
}

cleanup_build_root() {
    [[ -n "$build_root" ]] || return 0
    if validate_build_root; then
        /bin/rm -rf -- "$build_root"
    else
        echo "refusing to clean an unvalidated Studio build root: $build_root" >&2
        return 1
    fi
}

validate_output_candidate_path() {
    local candidate="${1:-}"

    case "$candidate" in
        "$output_root"/.LocalOCR\ Studio.app.candidate.*) ;;
        *) return 1 ;;
    esac
    [[ "$(/usr/bin/dirname "$candidate")" == "$output_root" ]] || return 1
    [[ -d "$candidate" && ! -L "$candidate" ]] || return 1
    [[ "$(cd "$candidate" && pwd -P)" == "$candidate" ]]
}

cleanup_output_candidate() {
    local candidate_name
    local current_root_identity

    [[ -n "$studio_output_candidate" ]] || return 0
    if [[ ! -e "$studio_output_candidate" && ! -L "$studio_output_candidate" ]]; then
        studio_output_candidate=""
        studio_output_candidate_identity=""
        return 0
    fi
    candidate_name="$(/usr/bin/basename "$studio_output_candidate")" || return 1
    case "$candidate_name" in
        .LocalOCR\ Studio.app.candidate.*) ;;
        *) return 1 ;;
    esac
    if [[
        -n "$studio_output_root_identity" &&
        -n "$studio_output_candidate_identity"
    ]] && (
        cd "$output_root" || exit 1
        current_root_identity="$(/usr/bin/stat -f '%d:%i' .)" || exit 1
        [[ "$current_root_identity" == "$studio_output_root_identity" ]] || exit 1
        release_cleanup_anchored_directory \
            "$candidate_name" "$studio_output_candidate_identity"
    ); then
        studio_output_candidate=""
        studio_output_candidate_identity=""
    else
        echo "refusing to clean an unvalidated Studio output candidate: $studio_output_candidate" >&2
        return 1
    fi
}

cleanup_studio_build_artifacts() {
    local cleanup_failed=false

    cleanup_output_candidate || cleanup_failed=true
    cleanup_build_root || cleanup_failed=true
    [[ "$cleanup_failed" == false ]]
}

prepare_output_root() {
    local dist_root="$studio_repo_root/dist"
    local directory

    [[ -d "$studio_repo_root" && ! -L "$studio_repo_root" ]] || {
        echo "Studio repository root must be a physical directory" >&2
        return 1
    }

    for directory in "$dist_root" "$output_root"; do
        [[ ! -L "$directory" ]] || {
            echo "Studio output directory must not be a symlink: $directory" >&2
            return 1
        }
        if [[ -e "$directory" ]]; then
            [[ -d "$directory" ]] || {
                echo "Studio output path must be a directory: $directory" >&2
                return 1
            }
            [[ "$(cd "$directory" && pwd -P)" == "$directory" ]] || {
                echo "Studio output directory escaped the repository: $directory" >&2
                return 1
            }
        else
            /bin/mkdir "$directory"
        fi
    done
    studio_output_root_identity="$(
        /usr/bin/swift "$release_path_guard" token-directory "$output_root"
    )"
}

validate_studio_minimum_os() {
    local app_path="$1"
    local info_plist="$app_path/Contents/Info.plist"
    local actual_minimum_os

    actual_minimum_os="$(
        "$release_plist_buddy" -c "Print :LSMinimumSystemVersion" "$info_plist"
    )" || {
        echo "could not read LSMinimumSystemVersion from Studio Info.plist" >&2
        return 1
    }
    [[ "$actual_minimum_os" == "$studio_minimum_os" ]] || {
        echo "LSMinimumSystemVersion mismatch: expected '$studio_minimum_os', found '$actual_minimum_os'" >&2
        return 1
    }
}

validate_studio_app_icon() {
    local app_path="$1"
    local info_plist="$app_path/Contents/Info.plist"
    local icon_name
    local icon_file="$app_path/Contents/Resources/AppIcon.icns"
    local asset_catalog="$app_path/Contents/Resources/Assets.car"

    icon_name="$(
        "$release_plist_buddy" -c "Print :CFBundleIconName" "$info_plist"
    )" || {
        echo "could not read CFBundleIconName from Studio Info.plist" >&2
        return 1
    }
    [[ "$icon_name" == "AppIcon" ]] || {
        echo "CFBundleIconName mismatch: expected 'AppIcon', found '$icon_name'" >&2
        return 1
    }
    for icon_resource in "$icon_file" "$asset_catalog"; do
        [[ -f "$icon_resource" && ! -L "$icon_resource" && -s "$icon_resource" ]] || {
            echo "Studio app icon resource is missing or invalid: $icon_resource" >&2
            return 1
        }
    done
}

validate_studio_app_bundle() {
    local app_path="$1"
    local executable="$app_path/Contents/MacOS/LocalOCR Studio"

    export LOCALOCR_EXPECTED_BUNDLE_ID="$studio_bundle_identifier"
    export LOCALOCR_RELEASE_VERSION="$studio_release_version"
    export LOCALOCR_RELEASE_BUILD="$studio_release_build"
    validate_release_bundle_metadata "$app_path"
    validate_studio_minimum_os "$app_path"
    validate_studio_app_icon "$app_path"

    [[ -f "$executable" && -x "$executable" && ! -L "$executable" ]] || {
        echo "unsigned Studio executable is missing or invalid" >&2
        return 1
    }
    /usr/bin/lipo "$executable" -verify_arch arm64
    [[ "$(/usr/bin/lipo -archs "$executable")" == "arm64" ]] || {
        echo "unsigned Studio executable is not arm64-only" >&2
        return 1
    }
    [[ ! -e "$app_path/Contents/_CodeSignature" ]] || {
        echo "Studio app unexpectedly contains a code signature" >&2
        return 1
    }
}

validate_sanitized_studio_app_bundle() {
    local app_path="$1"
    local executable="$app_path/Contents/MacOS/LocalOCR Studio"

    validate_studio_app_bundle "$app_path" || return 1
    validate_local_intelligence_candidate_binary "$executable" || return 1
}

validate_staged_app() {
    local staged_app="$1"
    local staged_parent="$build_root/Staged"
    local expected_staged_app="$staged_parent/LocalOCR Studio.app"

    validate_build_root
    [[ "$staged_app" == "$expected_staged_app" ]] || {
        echo "Studio app must be staged at the validated build-root path" >&2
        return 1
    }
    [[ -d "$staged_parent" && ! -L "$staged_parent" ]] || {
        echo "Studio staging directory is missing or symlinked" >&2
        return 1
    }
    [[ "$(cd "$staged_parent" && pwd -P)" == "$staged_parent" ]] || {
        echo "Studio staging directory escaped the validated build root" >&2
        return 1
    }
    [[ -d "$staged_app" && ! -L "$staged_app" ]] || {
        echo "Studio staged app is missing or symlinked" >&2
        return 1
    }
    [[ "$(cd "$staged_app" && pwd -P)" == "$staged_app" ]] || {
        echo "Studio staged app is not a physical directory" >&2
        return 1
    }

    validate_studio_app_bundle "$staged_app"
}

publish_output_candidate() {
    local candidate_app="$1"
    local candidate_identity
    local candidate_name
    local publication_status
    local target_identity="missing"

    validate_output_candidate_path "$candidate_app"
    validate_sanitized_studio_app_bundle "$candidate_app"
    [[ -n "$studio_output_root_identity" ]] || return 1
    candidate_name="$(/usr/bin/basename "$candidate_app")" || return 1
    case "$candidate_name" in
        .LocalOCR\ Studio.app.candidate.*) ;;
        *) return 1 ;;
    esac
    candidate_identity="$(
        /usr/bin/swift "$release_path_guard" token-directory "$candidate_app"
    )" || return 1
    [[ "$candidate_identity" == "$studio_output_candidate_identity" ]] || {
        echo "Studio output candidate identity changed before publication" >&2
        return 1
    }

    if [[ -e "$output_app" || -L "$output_app" ]]; then
        [[ -d "$output_app" && ! -L "$output_app" ]] || {
            echo "existing unsigned Studio app is not a physical directory" >&2
            return 1
        }
        target_identity="$(
            /usr/bin/swift "$release_path_guard" token-directory "$output_app"
        )" || return 1
    fi

    if (
        local current_candidate_identity
        local current_root_identity
        local current_target_identity
        local publish_result

        cd "$output_root" || exit 1
        current_root_identity="$(/usr/bin/stat -f '%d:%i' .)" || exit 1
        [[ "$current_root_identity" == "$studio_output_root_identity" ]] || {
            echo "Studio output parent identity changed before publication" >&2
            exit 1
        }
        current_candidate_identity="$(
            /usr/bin/stat -f '%d:%i' "./$candidate_name"
        )" || exit 1
        [[ "$current_candidate_identity" == "$candidate_identity" ]] || {
            echo "Studio output candidate identity changed before publication" >&2
            exit 1
        }
        if [[ "$target_identity" == "missing" ]]; then
            [[ ! -e "./LocalOCR Studio.app" && ! -L "./LocalOCR Studio.app" ]] || {
                echo "Studio output target appeared before publication" >&2
                exit 1
            }
        else
            [[ -d "./LocalOCR Studio.app" && ! -L "./LocalOCR Studio.app" ]] || {
                echo "Studio output target changed before publication" >&2
                exit 1
            }
            current_target_identity="$(
                /usr/bin/stat -f '%d:%i' "./LocalOCR Studio.app"
            )" || exit 1
            [[ "$current_target_identity" == "$target_identity" ]] || {
                echo "Studio output target identity changed before publication" >&2
                exit 1
            }
        fi
        if ! publish_result="$(
            release_publish_directory_atomically \
                "$candidate_app" \
                "$output_app" \
                "$studio_output_root_identity" \
                "$candidate_identity" \
                "$target_identity"
        )"; then
            echo "could not atomically publish the validated unsigned Studio app" >&2
            release_cleanup_anchored_directory \
                "$candidate_name" "$candidate_identity" || true
            exit 1
        fi
        case "$publish_result" in
            exchanged)
                [[ "$target_identity" != "missing" ]] || exit 1
                release_cleanup_anchored_directory \
                    "$candidate_name" "$target_identity" || exit 1
                ;;
            moved)
                [[ "$target_identity" == "missing" ]] || exit 1
                [[ ! -e "./$candidate_name" && ! -L "./$candidate_name" ]] || {
                    exit 1
                }
                ;;
            *)
                echo "unexpected Studio directory publication result" >&2
                exit 1
                ;;
        esac
    ); then
        studio_output_candidate=""
        studio_output_candidate_identity=""
        return 0
    else
        publication_status=$?
        studio_output_candidate=""
        studio_output_candidate_identity=""
        return "$publication_status"
    fi
}

validate_and_publish_staged_app() {
    local staged_app="$1"
    local source_dsym="${2:-}"
    local staged_executable="$staged_app/Contents/MacOS/LocalOCR Studio"

    validate_staged_app "$staged_app"
    if [[ -n "$source_dsym" ]]; then
        release_validate_dsym_matches_binary "$staged_executable" "$source_dsym"
    fi
    sanitize_validated_release_binary \
        "$staged_executable" \
        "$build_root/Staged/LocalOCR Studio.app/Contents/MacOS/LocalOCR Studio" \
        true
    validate_sanitized_studio_app_bundle "$staged_app"
    if [[ -n "$source_dsym" ]]; then
        release_validate_dsym_matches_binary "$staged_executable" "$source_dsym"
    fi
    prepare_output_root
    studio_output_candidate="$(
        /usr/bin/mktemp -d \
            "$output_root/.LocalOCR Studio.app.candidate.XXXXXX"
    )"
    validate_output_candidate_path "$studio_output_candidate"
    studio_output_candidate_identity="$(
        /usr/bin/swift "$release_path_guard" \
            token-directory "$studio_output_candidate"
    )"
    /usr/bin/ditto "$staged_app" "$studio_output_candidate" || {
        cleanup_output_candidate
        return 1
    }
    validate_sanitized_studio_app_bundle "$studio_output_candidate" || {
        cleanup_output_candidate
        return 1
    }
    if [[ -n "$source_dsym" ]]; then
        release_preserve_matching_dsym \
            "$staged_executable" \
            "$source_dsym" \
            "LocalOCR-Studio" || {
            cleanup_output_candidate
            return 1
        }
    fi
    publish_output_candidate "$studio_output_candidate"
}

run_studio_build() {
    local built_app
    local built_dsym
    local derived_data
    local produced_dsym=""
    local staged_app
    local staging_root
    local temporary_build_root

    release_validate_mcp_source_policy "$studio_repo_root"
    select_release_developer_dir

    temporary_build_root="$(/usr/bin/mktemp -d /tmp/localocr-studio-build.XXXXXX)"
    set_validated_build_root "$temporary_build_root"
    validate_build_root
    trap cleanup_studio_build_artifacts EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    derived_data="$build_root/DerivedData"
    /bin/mkdir "$derived_data"

    "$release_xcodebuild_path" build-for-testing \
        -project "$project_path" \
        -scheme "$scheme_name" \
        -destination "platform=macOS,arch=arm64" \
        -derivedDataPath "$derived_data"

    "$release_xcodebuild_path" build \
        -project "$project_path" \
        -scheme "$scheme_name" \
        -configuration Release \
        -destination "platform=macOS,arch=arm64" \
        -derivedDataPath "$derived_data" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        ARCHS=arm64

    built_app="$derived_data/Build/Products/Release/LocalOCR Studio.app"
    [[ -d "$built_app" && ! -L "$built_app" ]] || {
        echo "unsigned Studio app was not produced: $built_app" >&2
        exit 1
    }
    built_dsym="$derived_data/Build/Products/Release/LocalOCR Studio.app.dSYM"
    if [[ -e "$built_dsym" || -L "$built_dsym" ]]; then
        [[ -d "$built_dsym" && ! -L "$built_dsym" ]] || {
            echo "Studio dSYM output is invalid: $built_dsym" >&2
            exit 1
        }
        produced_dsym="$built_dsym"
    fi

    staging_root="$build_root/Staged"
    staged_app="$staging_root/LocalOCR Studio.app"
    /bin/mkdir "$staging_root"
    /usr/bin/ditto "$built_app" "$staged_app"
    validate_and_publish_staged_app "$staged_app" "$produced_dsym"

    printf 'Built unsigned Studio app: %s\n' "$output_app"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --test-build-root)
            [[ "$#" -eq 2 ]] || exit 2
            set_validated_build_root "$2"
            validate_build_root
            ;;
        "")
            run_studio_build
            ;;
        *)
            echo "unknown unsigned Studio build option: $1" >&2
            exit 2
            ;;
    esac
fi
