#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
# shellcheck source=scripts/release-toolchain.sh
source "$script_dir/release-toolchain.sh"
default_artifact_dir="$repo_root/dist/native-tools"
direct_release_artifact_dir="$repo_root/dist/direct-release/native-tools"
artifact_dir="$default_artifact_dir"
artifact_parent=""
artifact_parent_identity=""
artifact_output_identity=""
native_release_dir=""
native_release_identity=""

validate_no_network_framework_dependency() {
    local binary="$1"
    local dependency

    while IFS= read -r dependency; do
        case "$dependency" in
            /System/Library/Frameworks/CFNetwork.framework/Versions/A/CFNetwork|\
            /System/Library/Frameworks/Network.framework/Versions/A/Network)
                echo "network framework dependency is forbidden in local-only candidate: $binary: $dependency" >&2
                return 1
                ;;
        esac
    done < <(
        /usr/bin/otool -L "$binary" |
            /usr/bin/awk 'NR > 1 { sub(/^[[:space:]]+/, ""); print $1 }'
    )
}

validate_local_intelligence_candidate_binary() {
    local binary="$1"
    local minimum_macos

    release_validate_binary_policy "$binary" false true || return 1
    validate_no_network_framework_dependency "$binary" || return 1
    minimum_macos="$(release_binary_minimum_macos "$binary")" || return 1
    [[ "$minimum_macos" == "14.0" ]] || {
        echo "Local Intelligence candidate binaries must target macOS 14.0 exactly: $binary targets $minimum_macos" >&2
        return 1
    }
}

validate_direct_release_artifact_dir() {
    local candidate="${1:-}"
    local allow_missing_parent="${2:-false}"
    local physical_dist
    local physical_direct_release

    [[ "$candidate" == "$direct_release_artifact_dir" ]] || {
        echo "explicit artifact directory must be dist/direct-release/native-tools" >&2
        return 1
    }
    [[ ! -L "$repo_root/dist" && ! -L "$repo_root/dist/direct-release" ]] || {
        echo "explicit artifact directory contains a symlinked release component" >&2
        return 1
    }
    if [[ "$allow_missing_parent" == "true" && ! -e "$repo_root/dist/direct-release" ]]; then
        return 0
    fi
    [[ -d "$repo_root/dist/direct-release" ]] || {
        echo "dist/direct-release must exist before building release artifacts" >&2
        return 1
    }
    physical_dist="$(cd "$repo_root/dist" && pwd -P)"
    physical_direct_release="$(cd "$repo_root/dist/direct-release" && pwd -P)"
    [[ "$physical_dist" == "$repo_root/dist" ]] || {
        echo "dist resolves outside the physical repository" >&2
        return 1
    }
    [[ "$physical_direct_release" == "$physical_dist/direct-release" ]] || {
        echo "direct-release resolves outside the physical repository" >&2
        return 1
    }
    [[ ! -L "$candidate" ]] || {
        echo "explicit artifact directory must not be a symlink" >&2
        return 1
    }
    if [[ -e "$candidate" ]]; then
        [[ -d "$candidate" && "$(cd "$candidate" && pwd -P)" == "$physical_direct_release/native-tools" ]] || {
            echo "explicit artifact directory resolves outside dist/direct-release" >&2
            return 1
        }
    fi
}

case "${1:-}" in
    "")
        [[ "$#" -eq 0 ]] || exit 2
        artifact_dir="$default_artifact_dir"
        ;;
    --artifact-dir)
        [[ "$#" -eq 2 ]] || exit 2
        validate_direct_release_artifact_dir "$2"
        artifact_dir="$2"
        ;;
    --test-artifact-dir)
        [[ "$#" -eq 2 ]] || exit 2
        validate_direct_release_artifact_dir "$2" true
        exit 0
        ;;
    *)
        echo "unknown build-native-tools mode: $1" >&2
        exit 2
        ;;
esac

case "$artifact_dir" in
    "$default_artifact_dir"|"$direct_release_artifact_dir") ;;
    *)
        echo "refusing to remove an unexpected artifact directory: $artifact_dir" >&2
        exit 1
        ;;
esac

validate_artifact_output_path() {
    local dist_dir="$repo_root/dist"

    [[ ! -L "$dist_dir" && ! -L "$artifact_dir" ]] || {
        echo "artifact output path contains a symlinked component" >&2
        return 1
    }
    if [[ ! -e "$dist_dir" ]]; then
        [[ "$artifact_dir" == "$default_artifact_dir" ]] || {
            echo "artifact output parent is missing" >&2
            return 1
        }
        /bin/mkdir "$dist_dir"
    fi
    [[ -d "$dist_dir" && "$(cd "$dist_dir" && pwd -P)" == "$dist_dir" ]] || {
        echo "artifact output path escaped the physical repository" >&2
        return 1
    }
    artifact_parent="$(/usr/bin/dirname "$artifact_dir")"
    [[ -d "$artifact_parent" && ! -L "$artifact_parent" ]] || {
        echo "artifact output path contains a symlinked component" >&2
        return 1
    }
    [[ "$(cd "$artifact_parent" && pwd -P)" == "$artifact_parent" ]] || {
        echo "artifact output path escaped the physical repository" >&2
        return 1
    }
    if [[ -e "$artifact_dir" ]]; then
        [[ -d "$artifact_dir" && "$(cd "$artifact_dir" && pwd -P)" == "$artifact_dir" ]] || {
            echo "artifact output directory is not a physical directory" >&2
            return 1
        }
    fi
}

validate_artifact_output_path
artifact_parent="$(/usr/bin/dirname "$artifact_dir")"
artifact_parent_identity="$(
    /usr/bin/swift "$release_path_guard" token-directory "$artifact_parent"
)"
if [[ -e "$artifact_dir" ]]; then
    artifact_output_identity="$(
        /usr/bin/swift "$release_path_guard" token-directory "$artifact_dir"
    )"
else
    artifact_output_identity="missing"
fi

validate_artifact_output_identity() {
    local current_parent_identity
    local current_output_identity

    validate_artifact_output_path || return 1
    current_parent_identity="$(
        /usr/bin/swift "$release_path_guard" token-directory "$artifact_parent"
    )" || return 1
    [[ "$current_parent_identity" == "$artifact_parent_identity" ]] || {
        echo "artifact output parent identity changed during the build" >&2
        return 1
    }
    if [[ "$artifact_output_identity" == "missing" ]]; then
        [[ ! -e "$artifact_dir" && ! -L "$artifact_dir" ]] || {
            echo "artifact output appeared during the build" >&2
            return 1
        }
        return 0
    fi
    current_output_identity="$(
        /usr/bin/swift "$release_path_guard" token-directory "$artifact_dir"
    )" || return 1
    [[ "$current_output_identity" == "$artifact_output_identity" ]] || {
        echo "artifact output identity changed during the build" >&2
        return 1
    }
}

replace_artifact_output_with_empty_directory() {
    local artifact_name
    local current_parent_identity

    artifact_name="$(/usr/bin/basename "$artifact_dir")"
    (
        cd "$artifact_parent" || exit 1
        current_parent_identity="$(/usr/bin/stat -f '%d:%i' .)" || exit 1
        [[ "$current_parent_identity" == "$artifact_parent_identity" ]] || {
            echo "artifact output parent identity changed before cleanup" >&2
            exit 1
        }
        if [[ -e "$artifact_name" || -L "$artifact_name" ]]; then
            [[ "$artifact_output_identity" != "missing" ]] || {
                echo "artifact output appeared before cleanup" >&2
                exit 1
            }
            [[ -d "$artifact_name" && ! -L "$artifact_name" ]] || {
                echo "artifact output became invalid before cleanup" >&2
                exit 1
            }
            release_cleanup_anchored_directory \
                "$artifact_name" \
                "$artifact_output_identity" \
                "$artifact_parent_identity" || {
                echo "artifact output identity changed before cleanup" >&2
                exit 1
            }
        else
            [[ "$artifact_output_identity" == "missing" ]] || {
                echo "artifact output disappeared before cleanup" >&2
                exit 1
            }
        fi
        /bin/mkdir "$artifact_name"
    )
}

copy_native_products_to_artifact_output() {
    local current_output_identity

    (
        cd "$artifact_dir" || exit 1
        current_output_identity="$(/usr/bin/stat -f '%d:%i' .)" || exit 1
        [[ "$current_output_identity" == "$artifact_output_identity" ]] || {
            echo "artifact output identity changed before copy" >&2
            exit 1
        }
        /bin/cp "$native_release_dir/localocr" ./localocr
        /bin/cp "$native_release_dir/localocr-mcp" ./localocr-mcp
    )
}

cd "$repo_root"
swift package clean
swift build -c release --product localocr
swift build -c release --product localocr-mcp

[[ -d "$repo_root/.build" && ! -L "$repo_root/.build" ]] || {
    echo "SwiftPM build root is missing or symlinked" >&2
    exit 1
}
[[ "$(cd "$repo_root/.build" && pwd -P)" == "$repo_root/.build" ]] || {
    echo "SwiftPM build root escaped the physical repository" >&2
    exit 1
}
native_release_dir="$(cd "$repo_root/.build/release" && pwd -P)" || {
    echo "SwiftPM release output directory is missing" >&2
    exit 1
}
case "$native_release_dir" in
    "$repo_root/.build/"*) ;;
    *)
        echo "SwiftPM release output escaped the build root" >&2
        exit 1
        ;;
esac
native_release_identity="$(
    /usr/bin/swift "$release_path_guard" token-directory "$native_release_dir"
)"

validate_native_release_identity() {
    local current_identity

    [[ -d "$native_release_dir" && ! -L "$native_release_dir" ]] || {
        echo "SwiftPM release output changed during artifact publication" >&2
        return 1
    }
    current_identity="$(
        /usr/bin/swift "$release_path_guard" token-directory "$native_release_dir"
    )" || return 1
    [[ "$current_identity" == "$native_release_identity" ]] || {
        echo "SwiftPM release output identity changed during artifact publication" >&2
        return 1
    }
}

for product in localocr localocr-mcp; do
    validate_no_network_framework_dependency "$native_release_dir/$product"
    product_dsym="$native_release_dir/$product.dSYM"
    if [[ -e "$product_dsym" || -L "$product_dsym" ]]; then
        release_validate_dsym_matches_binary \
            "$native_release_dir/$product" \
            "$product_dsym"
    fi
done

validate_artifact_output_identity
validate_native_release_identity
replace_artifact_output_with_empty_directory
validate_artifact_output_path
artifact_output_identity="$(
    /usr/bin/swift "$release_path_guard" token-directory "$artifact_dir"
)"
validate_artifact_output_identity
validate_native_release_identity
copy_native_products_to_artifact_output
validate_artifact_output_identity
validate_native_release_identity

sanitize_copied_artifact() {
    local binary="$1"

    case "$binary" in
        "$artifact_dir/localocr"|"$artifact_dir/localocr-mcp") ;;
        *)
            echo "refusing to edit an unexpected artifact: $binary" >&2
            exit 1
            ;;
    esac
    validate_artifact_output_identity
    sanitize_validated_release_binary "$binary" "$binary" false true
}

sanitize_copied_artifact "$artifact_dir/localocr"
sanitize_copied_artifact "$artifact_dir/localocr-mcp"
validate_local_intelligence_candidate_binary "$artifact_dir/localocr"
validate_local_intelligence_candidate_binary "$artifact_dir/localocr-mcp"
validate_artifact_output_identity

for product in localocr localocr-mcp; do
    product_dsym="$native_release_dir/$product.dSYM"
    if [[ -e "$product_dsym" || -L "$product_dsym" ]]; then
        release_preserve_matching_dsym \
            "$artifact_dir/$product" \
            "$product_dsym" \
            "$product"
        validate_artifact_output_identity
    fi
done
