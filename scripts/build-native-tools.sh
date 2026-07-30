#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
default_artifact_dir="$repo_root/dist/native-tools"
direct_release_artifact_dir="$repo_root/dist/direct-release/native-tools"
artifact_dir="$default_artifact_dir"
system_swift_rpath="/usr/lib/swift"

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

cd "$repo_root"
swift package clean
swift build -c release --product localocr
swift build -c release --product localocr-mcp

rm -rf -- "$artifact_dir"
mkdir -p "$artifact_dir"
cp ".build/release/localocr" "$artifact_dir/localocr"
cp ".build/release/localocr-mcp" "$artifact_dir/localocr-mcp"

release_rpaths() {
    otool -l "$1" | awk '
        $1 == "cmd" && $2 == "LC_RPATH" { expect_path = 1; next }
        expect_path && $1 == "path" { print $2; expect_path = 0 }
    '
}

sanitize_copied_artifact() {
    local binary="$1"
    local rpath

    case "$binary" in
        "$artifact_dir/localocr"|"$artifact_dir/localocr-mcp") ;;
        *)
            echo "refusing to edit an unexpected artifact: $binary" >&2
            exit 1
            ;;
    esac

    while IFS= read -r rpath; do
        [[ -n "$rpath" ]] || continue
        if [[ "$rpath" != "$system_swift_rpath" ]]; then
            install_name_tool -delete_rpath "$rpath" "$binary"
        fi
    done < <(release_rpaths "$binary")
}

sanitize_copied_artifact "$artifact_dir/localocr"
sanitize_copied_artifact "$artifact_dir/localocr-mcp"
