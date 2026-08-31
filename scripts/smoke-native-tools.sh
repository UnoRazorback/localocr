#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
artifact_dir="$repo_root/dist/native-tools"
cli="$artifact_dir/localocr"
mcp="$artifact_dir/localocr-mcp"
model_bridge="$artifact_dir/localocr-model-bridge"
mcp_exchange="$script_dir/mcp-smoke-exchange.py"
fixture="$repo_root/tests/LocalOCRCoreTests/Fixtures/mixed.pdf"
system_swift_rpath="/usr/lib/swift"
compatibility_span="@rpath/libswiftCompatibilitySpan.dylib"
stderr_file="$(mktemp -t localocr-mcp-smoke.XXXXXX)"
test_home_root=""
test_home_parent=""
test_home_name=""
test_home_identity=""
test_home_parent_identity=""

cleanup() {
    rm -f -- "$stderr_file"
    [[ -n "$test_home_root" ]] || return
    [[ -n "$test_home_parent" && -n "$test_home_name" ]] || return
    (
        cd "$test_home_parent" || exit 1
        [[ "$(/usr/bin/stat -f '%d:%i' .)" == "$test_home_parent_identity" ]] || {
            echo "temporary MCP home parent identity changed; refusing cleanup" >&2
            exit 1
        }
        [[ -d "$test_home_name" && ! -L "$test_home_name" ]] || {
            echo "temporary MCP home changed type; refusing cleanup" >&2
            exit 1
        }
        [[ "$(/usr/bin/stat -f '%d:%i' "$test_home_name")" == "$test_home_identity" ]] || {
            echo "temporary MCP home identity changed; refusing cleanup" >&2
            exit 1
        }
        /usr/bin/find "$test_home_name" -depth -delete
    )
}

trap cleanup EXIT

reject_symlink_path() {
    local candidate="$1"
    local component=""
    local part

    [[ "$candidate" == /* ]] || return 1
    IFS='/' read -r -a path_parts <<< "${candidate#/}"
    for part in "${path_parts[@]}"; do
        [[ -n "$part" ]] || continue
        component="$component/$part"
        [[ ! -L "$component" ]] || return 1
    done
}

require_json_lines() {
    local response="$1"

    if ! printf '%s\n' "$response" | /usr/bin/python3 -c '
import json
import sys

for number, raw_line in enumerate(sys.stdin.buffer, start=1):
    if not raw_line.endswith(b"\n"):
        raise SystemExit(f"stdout line {number} was not newline-delimited")
    try:
        value = json.loads(raw_line[:-1])
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"stdout line {number} was not exactly one JSON object: {error}")
    if not isinstance(value, dict):
        raise SystemExit(f"stdout line {number} was not a JSON object")
'; then
        echo "native MCP stdout contained a malformed JSON-RPC line" >&2
        exit 1
    fi
}

require_single_response() {
    local response="$1"
    local request_id="$2"
    local count

    if ! count="$(printf '%s\n' "$response" | /usr/bin/python3 -c '
import json
import sys

target = int(sys.argv[1])
count = 0
for number, raw_line in enumerate(sys.stdin.buffer, start=1):
    try:
        value = json.loads(raw_line)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"stdout line {number} was not exactly one JSON object: {error}")
    if not isinstance(value, dict):
        raise SystemExit(f"stdout line {number} was not a JSON object")
    if value.get("id") == target:
        count += 1
print(count)
' "$request_id")"; then
        echo "native MCP stdout could not be parsed for request ID $request_id" >&2
        exit 1
    fi
    if [[ "$count" != "1" ]]; then
        echo "native MCP did not emit exactly one response for request ID $request_id" >&2
        exit 1
    fi
}

smoke_json_parser_self_test() {
    local valid='{"jsonrpc":"2.0","id":1,"result":{}}'
    local concatenated='{"jsonrpc":"2.0","id":1,"result":{}}{"jsonrpc":"2.0","id":2,"result":{}}'
    local nested_id='{"jsonrpc":"2.0","result":{"id":1}}'

    require_json_lines "$valid"
    require_single_response "$valid" 1
    if (require_json_lines "$concatenated") >/dev/null 2>&1; then
        echo "native MCP stdout parser accepted concatenated JSON objects" >&2
        exit 1
    fi
    if (require_single_response "$nested_id" 1) >/dev/null 2>&1; then
        echo "native MCP stdout parser counted a nested ID as a response ID" >&2
        exit 1
    fi
}

smoke_json_parser_self_test

release_rpaths() {
    otool -l "$1" | awk '
        $1 == "cmd" && $2 == "LC_RPATH" { expect_path = 1; next }
        expect_path && $1 == "path" { print $2; expect_path = 0 }
    '
}

reject_binary_content() {
    local binary="$1"
    local dependencies
    local install_name
    local rpath
    local has_compatibility_span=false
    local urls
    local raw_strings
    local forbidden_string

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
    while IFS= read -r install_name; do
        [[ -n "$install_name" ]] || continue
        case "$install_name" in
            /System/Library/*|/usr/lib/*) ;;
            "$compatibility_span") has_compatibility_span=true ;;
            *)
                echo "unapproved dylib install name in $binary: $install_name" >&2
                exit 1
                ;;
        esac
    done < <(printf '%s\n' "$dependencies" | awk '{ print $1 }')

    while IFS= read -r rpath; do
        [[ -n "$rpath" ]] || continue
        if [[ "$rpath" != "$system_swift_rpath" ]]; then
            echo "unapproved dylib RPATH in $binary: $rpath" >&2
            exit 1
        fi
    done < <(release_rpaths "$binary")

    if [[ "$has_compatibility_span" == true ]]; then
        if ! release_rpaths "$binary" | grep -Fxq "$system_swift_rpath"; then
            echo "$compatibility_span is missing its system Swift RPATH" >&2
            exit 1
        fi
        # The real CLI and MCP executions below prove dynamic-loader resolution.
        # macOS may serve this system library from the shared cache rather than
        # an ordinary on-disk file.
    fi

    if /usr/bin/grep -a -F -q -- '/Users/' "$binary"; then
        echo "release artifact contains a private /Users/ path: $binary" >&2
        exit 1
    fi

    raw_strings="$(strings "$binary")"
    for forbidden_string in \
        '.venv' \
        'python' \
        'pyobjc' \
        'pymupdf' \
        'ruby' \
        '/opt/homebrew' \
        '/usr/local' \
        "$repo_root" \
        '/Users/'; do
        if printf '%s\n' "$raw_strings" | grep -Fqi -- "$forbidden_string"; then
            echo "release artifact contains forbidden embedded runtime or machine string: $binary ($forbidden_string)" >&2
            printf '%s\n' "$raw_strings" | grep -Fi -- "$forbidden_string" >&2 || true
            exit 1
        fi
    done

    if [[ "$binary" == "$model_bridge" ]]; then
        "$script_dir/validate-model-bridge-policy.py" \
            --source-root "$repo_root" \
            --binary "$binary" >/dev/null
        return
    fi

    if urls="$(printf '%s\n' "$raw_strings" | grep -E 'https?://')"; then
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
reject_binary_content "$model_bridge"

model_bridge_request='{"version":1,"id":901,"action":"status","provider":"ollama","model":null,"expectedIdentity":null,"operation":null,"prompt":null,"fields":[],"timeoutMilliseconds":1000}'
model_bridge_response="$(printf '%s\n' "$model_bridge_request" | "$model_bridge")"
require_json_lines "$model_bridge_response"
require_single_response "$model_bridge_response" 901
if ! printf '%s\n' "$model_bridge_response" | \
    /usr/bin/grep -Fq '"code":"invalid_request"'
then
    echo "native model bridge did not complete the bounded wire-protocol smoke" >&2
    exit 1
fi

[[ -d "$repo_root/.build" && ! -L "$repo_root/.build" ]] || {
    echo "native build root is missing or symlinked" >&2
    exit 1
}
reject_symlink_path "$repo_root/.build" || {
    echo "native build root contains a symlinked path component" >&2
    exit 1
}
test_home_root="$(mktemp -d "$repo_root/.build/localocr-mcp-smoke-home.XXXXXX")"
chmod 700 "$test_home_root"
[[ "$(cd "$test_home_root" && pwd -P)" == "$test_home_root" ]] || {
    echo "temporary MCP home is not a physical directory" >&2
    exit 1
}
reject_symlink_path "$test_home_root" || {
    echo "temporary MCP home contains a symlinked path component" >&2
    exit 1
}
[[ "$(/usr/bin/stat -f '%Lp' "$test_home_root")" == "700" ]] || {
    echo "temporary MCP home is not mode 0700" >&2
    exit 1
}
test_home_parent="$(/usr/bin/dirname "$test_home_root")"
test_home_name="$(/usr/bin/basename "$test_home_root")"
test_home_identity="$(/usr/bin/stat -f '%d:%i' "$test_home_root")"
test_home_parent_identity="$(/usr/bin/stat -f '%d:%i' "$test_home_parent")"

inspection="$("$cli" inspect "$fixture" --json)"
if ! printf '%s\n' "$inspection" | grep -q '"pages":2'; then
    echo "native CLI inspection did not return the fixture page count" >&2
    exit 1
fi

initialize_request='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"native-tools-smoke","version":"1.0"}}}'
initialized_notification='{"jsonrpc":"2.0","method":"notifications/initialized"}'
list_tools_request='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
blocked_call_request="{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"get_pdf_page_count\",\"arguments\":{\"file_path\":\"$test_home_root/missing.pdf\"}}}"
# Keep stdin open until every expected response arrives or the bounded exchange times out.
initialize_response="$(
    printf '%s\n' \
        "$initialize_request" \
        "$initialized_notification" \
        "$list_tools_request" \
        "$blocked_call_request" |
        CFFIXED_USER_HOME="$test_home_root" \
        HOME="$test_home_root" \
        LOCALOCR_CACHE_DIR="$test_home_root/cache" \
        "$mcp_exchange" \
            --timeout 10 \
            --expect-id 1 \
            --expect-id 2 \
            --expect-id 3 \
            -- "$mcp" \
            2>"$stderr_file"
)"
require_json_lines "$initialize_response"
require_single_response "$initialize_response" 1
require_single_response "$initialize_response" 2
require_single_response "$initialize_response" 3
if ! printf '%s\n' "$initialize_response" | grep -q '"serverInfo"'; then
    echo "native MCP server did not complete initialization" >&2
    exit 1
fi
if ! printf '%s\n' "$initialize_response" | grep -q '"version":"0.3.1"'; then
    echo "native MCP server did not negotiate version 0.3.1" >&2
    exit 1
fi
tools_response="$(printf '%s\n' "$initialize_response" | grep '"id":2')"
for tool_name in \
    extract_document_fields \
    get_pdf_page_count \
    inspect_pdf \
    make_searchable_pdf \
    ocr_image \
    ocr_pdf \
    ocr_pdf_batch \
    organize_document \
    summarize_document; do
    if ! printf '%s\n' "$tools_response" | grep -q "\"name\":\"$tool_name\""; then
        echo "native MCP tools/list omitted $tool_name" >&2
        exit 1
    fi
done
if [[ "$(printf '%s\n' "$tools_response" | grep -o '"name":"[^"]*"' | wc -l | tr -d ' ')" != "9" ]]; then
    echo "native MCP tools/list did not expose exactly nine tools" >&2
    exit 1
fi
if ! printf '%s\n' "$initialize_response" | grep -Fq '\"code\":\"external_data_acknowledgment_required\"'; then
    echo "native MCP document call was not blocked without acknowledgment" >&2
    exit 1
fi
if [[ -s "$stderr_file" ]]; then
    echo "native MCP server wrote diagnostics during initialization" >&2
    cat "$stderr_file" >&2
    exit 1
fi

consent_directory="$test_home_root/Library/Application Support/com.rayconsulting.localocr"
mkdir -m 700 "$test_home_root/Library"
mkdir -m 700 "$test_home_root/Library/Application Support"
mkdir -m 700 "$consent_directory"
consent_receipt="$consent_directory/mcp-consent.json"
printf '%s' '{"schema_version":1,"policy_version":1,"accepted_at":"2026-08-27T00:00:00Z","external_provider_risk_accepted":true,"document_tool_access_accepted":true}' > "$consent_receipt"
chmod 600 "$consent_receipt"
for private_directory in \
    "$test_home_root" \
    "$test_home_root/Library" \
    "$test_home_root/Library/Application Support" \
    "$consent_directory"; do
    [[ -d "$private_directory" && ! -L "$private_directory" ]] || {
        echo "temporary consent path contains a symlink or non-directory" >&2
        exit 1
    }
    [[ "$(/usr/bin/stat -f '%Lp' "$private_directory")" == "700" ]] || {
        echo "temporary consent directory is not mode 0700" >&2
        exit 1
    }
done
[[ -f "$consent_receipt" && ! -L "$consent_receipt" ]] || {
    echo "temporary consent receipt is not a physical regular file" >&2
    exit 1
}
[[ "$(/usr/bin/stat -f '%Lp' "$consent_receipt")" == "600" ]] || {
    echo "temporary consent receipt is not mode 0600" >&2
    exit 1
}

: > "$stderr_file"
compatibility_page_count_request="{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"get_pdf_page_count\",\"arguments\":{\"file_path\":\"$fixture\"}}}"
compatibility_inspect_request="{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"inspect_pdf\",\"arguments\":{\"file_path\":\"$fixture\"}}}"
compatibility_response="$(
    printf '%s\n' \
        "$initialize_request" \
        "$initialized_notification" \
        "$compatibility_page_count_request" \
        "$compatibility_inspect_request" |
        CFFIXED_USER_HOME="$test_home_root" \
        HOME="$test_home_root" \
        LOCALOCR_CACHE_DIR="$test_home_root/cache" \
        "$mcp_exchange" \
            --timeout 10 \
            --expect-id 1 \
            --expect-id 11 \
            --expect-id 12 \
            -- "$mcp" \
            2>"$stderr_file"
)"
require_json_lines "$compatibility_response"
require_single_response "$compatibility_response" 1
require_single_response "$compatibility_response" 11
require_single_response "$compatibility_response" 12
if ! printf '%s\n' "$compatibility_response" | grep '"id":11' | grep -Fq '"text":"2"'; then
    echo "native MCP page-count compatibility call failed with current acknowledgment" >&2
    exit 1
fi
if ! printf '%s\n' "$compatibility_response" | grep '"id":12' | grep -Fq '\"pages\":2'; then
    echo "native MCP inspection compatibility call failed with current acknowledgment" >&2
    exit 1
fi
if printf '%s\n' "$compatibility_response" | grep -q 'external_data_acknowledgment_required'; then
    echo "native MCP rejected the isolated current acknowledgment" >&2
    exit 1
fi
if [[ -s "$stderr_file" ]]; then
    echo "native MCP server wrote diagnostics during compatibility calls" >&2
    cat "$stderr_file" >&2
    exit 1
fi
