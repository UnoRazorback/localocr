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
}

run_studio_build() {
    local built_app
    local derived_data
    local executable
    local temporary_build_root

    select_release_developer_dir

    temporary_build_root="$(/usr/bin/mktemp -d /tmp/localocr-studio-build.XXXXXX)"
    set_validated_build_root "$temporary_build_root"
    validate_build_root
    trap cleanup_build_root EXIT

    derived_data="$build_root/DerivedData"
    /bin/mkdir "$derived_data"

    "$release_xcodebuild_path" test \
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

    prepare_output_root
    if [[ -e "$output_app" ]]; then
        [[ -d "$output_app" && ! -L "$output_app" ]] || {
            echo "existing unsigned Studio app is not a physical directory" >&2
            exit 1
        }
        /bin/rm -rf -- "$output_app"
    fi
    /usr/bin/ditto "$built_app" "$output_app"

    export LOCALOCR_EXPECTED_BUNDLE_ID="com.rayconsulting.localocr"
    export LOCALOCR_RELEASE_VERSION="0.2.0"
    export LOCALOCR_RELEASE_BUILD="1"
    validate_release_bundle_metadata "$output_app"

    executable="$output_app/Contents/MacOS/LocalOCR Studio"
    [[ -f "$executable" && -x "$executable" && ! -L "$executable" ]] || {
        echo "unsigned Studio executable is missing or invalid" >&2
        exit 1
    }
    /usr/bin/lipo "$executable" -verify_arch arm64
    [[ "$(/usr/bin/lipo -archs "$executable")" == "arm64" ]] || {
        echo "unsigned Studio executable is not arm64-only" >&2
        exit 1
    }
    [[ ! -e "$output_app/Contents/_CodeSignature" ]] || {
        echo "Studio app unexpectedly contains a code signature" >&2
        exit 1
    }

    printf 'Built unsigned Studio app: %s\n' "$output_app"
}

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
