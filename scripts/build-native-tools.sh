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
artifact_candidate=""
artifact_candidate_identity=""

validate_no_network_framework_dependency() {
    release_validate_binary_dependencies "$1" || return 1
    release_validate_no_network_symbols "$1"
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

    case "$candidate" in
        "$direct_release_artifact_dir") ;;
        "$repo_root/dist"/.direct-release.candidate.*/native-tools)
            case "$(/usr/bin/basename "$(/usr/bin/dirname "$candidate")")" in
                .direct-release.candidate.*) ;;
                *) return 1 ;;
            esac
            ;;
        *)
            echo "explicit artifact directory must be a validated direct-release native-tools path" >&2
            return 1
            ;;
    esac
    [[ ! -L "$repo_root/dist" && ! -L "$repo_root/dist/direct-release" ]] || {
        echo "explicit artifact directory contains a symlinked release component" >&2
        return 1
    }
    if [[ "$allow_missing_parent" == "true" && ! -e "$(/usr/bin/dirname "$candidate")" ]]; then
        return 0
    fi
    [[ -d "$(/usr/bin/dirname "$candidate")" ]] || {
        echo "validated release candidate must exist before building release artifacts" >&2
        return 1
    }
    physical_dist="$(cd "$repo_root/dist" && pwd -P)"
    physical_direct_release="$(cd "$(/usr/bin/dirname "$candidate")" && pwd -P)"
    [[ "$physical_dist" == "$repo_root/dist" ]] || {
        echo "dist resolves outside the physical repository" >&2
        return 1
    }
    case "$physical_direct_release" in
        "$physical_dist/direct-release"|"$physical_dist"/.direct-release.candidate.*) ;;
        *)
            echo "direct-release candidate resolves outside the physical repository" >&2
            return 1
            ;;
    esac
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
    "$default_artifact_dir"|"$direct_release_artifact_dir"|\
    "$repo_root/dist"/.direct-release.candidate.*/native-tools) ;;
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

release_validate_mcp_source_policy "$repo_root"
select_release_swift_toolchain
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

validate_artifact_candidate_path() {
    local candidate="${1:-}"

    case "$candidate" in
        "$artifact_parent"/.native-tools.candidate.*) ;;
        *) return 1 ;;
    esac
    [[ "$(/usr/bin/dirname "$candidate")" == "$artifact_parent" ]] || return 1
    [[ -d "$candidate" && ! -L "$candidate" ]] || return 1
    [[ "$(cd "$candidate" && pwd -P)" == "$candidate" ]]
}

cleanup_artifact_candidate() {
    local candidate_name
    local current_parent_identity

    [[ -n "$artifact_candidate" ]] || return 0
    if [[ ! -e "$artifact_candidate" && ! -L "$artifact_candidate" ]]; then
        artifact_candidate=""
        artifact_candidate_identity=""
        return 0
    fi
    validate_artifact_candidate_path "$artifact_candidate" || return 1
    candidate_name="$(/usr/bin/basename "$artifact_candidate")"
    (
        cd "$artifact_parent" || exit 1
        current_parent_identity="$(/usr/bin/stat -f '%d:%i' .)" || exit 1
        [[ "$current_parent_identity" == "$artifact_parent_identity" ]] || {
            echo "artifact output parent identity changed before candidate cleanup" >&2
            exit 1
        }
        release_cleanup_anchored_directory \
            "$candidate_name" \
            "$artifact_candidate_identity" \
            "$artifact_parent_identity"
    ) || return 1
    artifact_candidate=""
    artifact_candidate_identity=""
}

create_artifact_candidate() {
    validate_artifact_output_identity || return 1
    artifact_candidate="$(
        /usr/bin/mktemp -d "$artifact_parent/.native-tools.candidate.XXXXXX"
    )" || return 1
    validate_artifact_candidate_path "$artifact_candidate" || return 1
    artifact_candidate_identity="$(
        /usr/bin/swift "$release_path_guard" \
            token-directory "$artifact_candidate"
    )" || return 1
}

copy_native_products_to_artifact_candidate() {
    local current_candidate_identity

    (
        cd "$artifact_candidate" || exit 1
        current_candidate_identity="$(/usr/bin/stat -f '%d:%i' .)" || exit 1
        [[ "$current_candidate_identity" == "$artifact_candidate_identity" ]] || {
            echo "artifact candidate identity changed before copy" >&2
            exit 1
        }
        /bin/cp "$native_release_dir/localocr" ./localocr
        /bin/cp "$native_release_dir/localocr-mcp" ./localocr-mcp
    )
}

publish_artifact_candidate() {
    local candidate_name
    local publication_result

    validate_artifact_output_identity || return 1
    validate_artifact_candidate_path "$artifact_candidate" || return 1
    candidate_name="$(/usr/bin/basename "$artifact_candidate")"
    publication_result="$(
        release_publish_directory_atomically \
            "$artifact_candidate" \
            "$artifact_dir" \
            "$artifact_parent_identity" \
            "$artifact_candidate_identity" \
            "$artifact_output_identity"
    )" || {
        echo "could not atomically publish validated native artifacts" >&2
        return 1
    }
    case "$publication_result" in
        moved)
            [[ "$artifact_output_identity" == "missing" ]] || return 1
            ;;
        exchanged)
            [[ "$artifact_output_identity" != "missing" ]] || return 1
            (
                cd "$artifact_parent" || exit 1
                release_cleanup_anchored_directory \
                    "$candidate_name" \
                    "$artifact_output_identity" \
                    "$artifact_parent_identity"
            ) || return 1
            ;;
        *)
            echo "unexpected native artifact publication result" >&2
            return 1
            ;;
    esac
    artifact_output_identity="$artifact_candidate_identity"
    artifact_candidate=""
    artifact_candidate_identity=""
    validate_artifact_output_identity
}

cd "$repo_root"
"$release_xcode_swift_path" package clean
"$release_xcode_swift_path" build \
    --disable-automatic-resolution \
    -c release \
    --product localocr
"$release_xcode_swift_path" build \
    --disable-automatic-resolution \
    -c release \
    --product localocr-mcp
release_validate_mcp_source_policy "$repo_root"

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
    release_validate_binary_architecture_and_target \
        "$native_release_dir/$product"
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
create_artifact_candidate
trap 'cleanup_artifact_candidate || true' EXIT
copy_native_products_to_artifact_candidate
validate_artifact_candidate_path "$artifact_candidate"
validate_native_release_identity

sanitize_copied_artifact() {
    local binary="$1"

    case "$binary" in
        "$artifact_candidate/localocr"|"$artifact_candidate/localocr-mcp") ;;
        *)
            echo "refusing to edit an unexpected artifact: $binary" >&2
            exit 1
            ;;
    esac
    validate_artifact_candidate_path "$artifact_candidate"
    sanitize_validated_release_binary "$binary" "$binary" false true
}

sanitize_copied_artifact "$artifact_candidate/localocr"
sanitize_copied_artifact "$artifact_candidate/localocr-mcp"
validate_local_intelligence_candidate_binary "$artifact_candidate/localocr"
validate_local_intelligence_candidate_binary "$artifact_candidate/localocr-mcp"
validate_artifact_candidate_path "$artifact_candidate"
validate_artifact_output_identity
validate_native_release_identity
publish_artifact_candidate
trap - EXIT
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
