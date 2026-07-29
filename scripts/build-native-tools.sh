#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
artifact_dir="$repo_root/dist/native-tools"

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
