#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
artifact_dir="$repo_root/dist/native-tools"
cli="$artifact_dir/localocr"
mcp="$artifact_dir/localocr-mcp"
fixture="$repo_root/tests/LocalOCRCoreTests/Fixtures/mixed.pdf"
stderr_file="$(mktemp -t localocr-mcp-smoke.XXXXXX)"

trap 'rm -f -- "$stderr_file"' EXIT

reject_binary_content() {
    local binary="$1"
    local dependencies
    local urls

    if [[ ! -f "$binary" || ! -x "$binary" ]]; then
        echo "missing executable release artifact: $binary" >&2
        exit 1
    fi

    file "$binary"
    if ! file -b "$binary" | grep -q 'Mach-O'; then
        echo "release artifact is not Mach-O: $binary" >&2
        exit 1
    fi

    otool -L "$binary"
    dependencies="$(otool -L "$binary" | sed '1d')"
    for forbidden in '.venv' 'python' 'ruby' '/opt/homebrew' '/usr/local' "$repo_root"; do
        if printf '%s\n' "$dependencies" | grep -Fqi -- "$forbidden"; then
            echo "forbidden runtime dependency in $binary: $forbidden" >&2
            exit 1
        fi
    done

    if urls="$(strings "$binary" | grep -E 'https?://')"; then
        # These two loopback-origin prefixes are retained by the pinned MCP
        # SDK's HTTPRequestValidation support. localocr-mcp starts only
        # StdioTransport; this project never instantiates an HTTP transport.
        local unexpected_urls
        unexpected_urls="$(printf '%s\n' "$urls" | grep -Fxv -e 'http://127.0.0.1:' -e 'http://localhost:' || true)"
        if [[ -z "$unexpected_urls" ]]; then
            return
        fi

        echo "release artifact contains untraced URL strings: $binary" >&2
        printf '%s\n' "$unexpected_urls" >&2
        exit 1
    fi
}

reject_binary_content "$cli"
reject_binary_content "$mcp"

inspection="$($cli inspect "$fixture" --json)"
if ! printf '%s\n' "$inspection" | grep -q '"pages":2'; then
    echo "native CLI inspection did not return the fixture page count" >&2
    exit 1
fi

initialize_request='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"native-tools-smoke","version":"1.0"}}}'
# Keep stdin open briefly so the stdio transport can finish the response before EOF.
initialize_response="$( { printf '%s\n' "$initialize_request"; sleep 1; } | "$mcp" 2>"$stderr_file")"
if ! printf '%s\n' "$initialize_response" | grep -q '"serverInfo"'; then
    echo "native MCP server did not complete initialization" >&2
    exit 1
fi
if ! printf '%s\n' "$initialize_response" | grep -q '"version":"0.2.0"'; then
    echo "native MCP server did not negotiate version 0.2.0" >&2
    exit 1
fi
if [[ -s "$stderr_file" ]]; then
    echo "native MCP server wrote diagnostics during initialization" >&2
    cat "$stderr_file" >&2
    exit 1
fi
