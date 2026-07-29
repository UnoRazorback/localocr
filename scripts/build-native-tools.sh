#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
artifact_dir="$repo_root/dist/native-tools"
system_swift_rpath="/usr/lib/swift"

case "$artifact_dir" in
    "$repo_root/dist/native-tools") ;;
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
