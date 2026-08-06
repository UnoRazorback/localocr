#!/usr/bin/env bash

set -euo pipefail

download_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/verify-direct-release.sh
source "$download_script_dir/verify-direct-release.sh"

download_shasum="/usr/bin/shasum"
download_zipinfo="/usr/bin/zipinfo"
download_ditto="/usr/bin/ditto"
download_file="/usr/bin/file"
download_lipo="/usr/bin/lipo"
download_otool="/usr/bin/otool"
download_strings="/usr/bin/strings"
download_codesign="/usr/bin/codesign"
download_xcrun="/usr/bin/xcrun"
download_spctl="/usr/sbin/spctl"
download_plist_buddy="/usr/libexec/PlistBuddy"
download_sw_vers="/usr/bin/sw_vers"
download_sysctl="/usr/sbin/sysctl"
download_uname="/usr/bin/uname"
download_date="/bin/date"
download_sleep="/bin/sleep"
download_evidence_awk="/usr/bin/awk"
download_evidence_mv="/bin/mv"
download_cleanup_rm="/bin/rm"
download_evidence_writer=""
download_temp_parent="/private/tmp"

download_zip=""
download_checksum_file=""
download_expected_checksum=""
download_actual_checksum=""
download_evidence_file=""
download_extraction_root=""
download_physical_temp_parent=""
download_extracted_app=""
download_evidence_write_failed=0

download_validate_arguments() {
    [[ "$#" -eq 2 ]] || {
        echo "usage: test-downloaded-release.sh /absolute/release.zip /absolute/release.sha256" >&2
        return 2
    }
    case "$1" in
        /*) ;;
        *)
            echo "downloaded ZIP path must be absolute" >&2
            return 2
            ;;
    esac
    case "$2" in
        /*) ;;
        *)
            echo "checksum path must be absolute" >&2
            return 2
            ;;
    esac
    [[ -f "$1" && ! -L "$1" ]] || {
        echo "downloaded ZIP must be a physical regular file" >&2
        return 2
    }
    [[ -f "$2" && ! -L "$2" ]] || {
        echo "checksum must be a physical regular file" >&2
        return 2
    }
}

download_read_expected_checksum() {
    local checksum_line
    local checksum_line_count
    local checksum_name
    local zip_name

    checksum_line_count="$(
        /usr/bin/awk 'NF { count += 1 } END { print count + 0 }' \
            "$download_checksum_file"
    )"
    [[ "$checksum_line_count" -eq 1 ]] || {
        echo "checksum file must contain exactly one nonempty record" >&2
        return 1
    }
    checksum_line="$(/usr/bin/awk 'NF { print; exit }' "$download_checksum_file")"
    [[ "$checksum_line" =~ ^([[:xdigit:]]{64})[[:space:]]+[\*]?(.*)$ ]] || {
        echo "checksum file does not contain a SHA-256 record" >&2
        return 1
    }
    download_expected_checksum="$(
        printf '%s' "${BASH_REMATCH[1]}" |
            /usr/bin/tr '[:upper:]' '[:lower:]'
    )"
    checksum_name="${BASH_REMATCH[2]}"
    zip_name="$(/usr/bin/basename "$download_zip")"
    [[ -n "$checksum_name" && "$checksum_name" == "$zip_name" ]] || {
        echo "checksum record must name the downloaded ZIP basename" >&2
        return 1
    }
    case "$checksum_name" in
        */*|*\\*)
            echo "checksum record must not contain a path" >&2
            return 1
            ;;
    esac
}

download_system_value() {
    local label="$1"
    shift
    local value

    value="$("$@")" || {
        echo "could not collect $label for acceptance evidence" >&2
        return 1
    }
    [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || {
        echo "invalid $label value for acceptance evidence" >&2
        return 1
    }
    printf '%s\n' "$value"
}

download_initialize_evidence() {
    local evidence_dir
    local timestamp
    local timestamp_slug
    local toolchain
    local macos_version
    local macos_build
    local mac_model
    local processor
    local architecture

    timestamp="$(download_system_value "UTC timestamp" "$download_date" -u '+%Y-%m-%dT%H:%M:%SZ')"
    toolchain="$(download_system_value "toolchain" "$download_xcrun" --version)"
    macos_version="$(download_system_value "macOS version" "$download_sw_vers" -productVersion)"
    macos_build="$(download_system_value "macOS build" "$download_sw_vers" -buildVersion)"
    mac_model="$(download_system_value "Mac model" "$download_sysctl" -n hw.model)"
    processor="$(download_system_value "processor" "$download_sysctl" -n machdep.cpu.brand_string)"
    architecture="$(download_system_value "CPU architecture" "$download_uname" -m)"
    evidence_dir="$(cd "$(/usr/bin/dirname "$download_checksum_file")" && pwd -P)"
    timestamp_slug="${timestamp//[-:]/}"
    download_evidence_file="$evidence_dir/localocr-downloaded-release-evidence-${timestamp_slug}-$$.txt"
    umask 077
    (
        set -o noclobber
        : > "$download_evidence_file"
    ) || {
        echo "could not create a new acceptance evidence file" >&2
        return 1
    }
    {
        printf 'LocalOCR downloaded release acceptance evidence\n'
        printf 'UTC timestamp: %s\n' "$timestamp"
        printf 'Toolchain: %s\n' "$toolchain"
        printf 'macOS version: %s (%s)\n' "$macos_version" "$macos_build"
        printf 'Mac model: %s\n' "$mac_model"
        printf 'Processor: %s\n' "$processor"
        printf 'CPU architecture: %s\n' "$architecture"
        printf 'ZIP SHA-256: pending\n'
        printf 'Release version: %s\n' "${LOCALOCR_RELEASE_VERSION:-not supplied}"
    } >> "$download_evidence_file"
}

download_replace_evidence_checksum() {
    local replacement_file

    replacement_file="${download_evidence_file}.checksum.$$"
    # shellcheck disable=SC2016
    "$download_evidence_awk" \
        -v checksum="$download_actual_checksum" \
        '$0 == "ZIP SHA-256: pending" {
            print "ZIP SHA-256: " checksum
            next
        }
        { print }' \
        "$download_evidence_file" > "$replacement_file" || return 1
    "$download_evidence_mv" -f -- \
        "$replacement_file" "$download_evidence_file" || return 1
}

download_record_result() {
    local label="$1"
    local result="$2"

    if [[ -n "$download_evidence_writer" ]]; then
        "$download_evidence_writer" \
            "$label" "$result" "$download_evidence_file" || {
            download_evidence_write_failed=1
            return 1
        }
    else
        printf '%s: %s\n' "$label" "$result" >> "$download_evidence_file" || {
            download_evidence_write_failed=1
            return 1
        }
    fi
}

download_run_gate() {
    local label="$1"
    shift

    if "$@"; then
        download_record_result "$label" "PASS" || return 1
        return 0
    fi
    download_record_result "$label" "FAIL" || return 1
    return 1
}

download_verify_checksum() {
    # Required production check: shasum -a 256 before any extraction.
    download_actual_checksum="$(
        "$download_shasum" -a 256 "$download_zip" |
            /usr/bin/awk '{ print $1 }'
    )" || return
    [[ "$download_actual_checksum" =~ ^[0-9a-f]{64}$ ]] || {
        echo "could not compute downloaded ZIP SHA-256" >&2
        return 1
    }
    download_replace_evidence_checksum || return
    [[ "$download_actual_checksum" == "$download_expected_checksum" ]] || {
        echo "downloaded ZIP SHA-256 does not match the published checksum" >&2
        return 1
    }
}

download_validate_archive_paths() {
    local archive_listing
    local entry
    local relative_entry
    local component
    local -a components
    local entry_count=0

    archive_listing="$("$download_zipinfo" -1 "$download_zip")" || {
        echo "downloaded ZIP could not be listed" >&2
        return 1
    }
    [[ -n "$archive_listing" ]] || {
        echo "downloaded ZIP is empty" >&2
        return 1
    }
    while IFS= read -r entry; do
        entry_count=$((entry_count + 1))
        [[ -n "$entry" && "$entry" != /* && "$entry" != *\\* ]] || {
            echo "downloaded ZIP contains an unsafe path" >&2
            return 1
        }
        case "$entry" in
            "LocalOCR Studio.app"|"LocalOCR Studio.app/"|"LocalOCR Studio.app/"*)
                ;;
            *)
                echo "downloaded ZIP contains an unexpected top-level path" >&2
                return 1
                ;;
        esac
        relative_entry="${entry%/}"
        IFS=/ read -r -a components <<< "$relative_entry"
        for component in "${components[@]}"; do
            [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || {
                echo "downloaded ZIP contains a traversal component" >&2
                return 1
            }
        done
    done <<< "$archive_listing"
    [[ "$entry_count" -gt 0 ]]
}

download_create_fresh_extraction() {
    [[ -d "$download_temp_parent" && ! -L "$download_temp_parent" ]] || {
        echo "temporary extraction parent is missing or symlinked" >&2
        return 1
    }
    download_physical_temp_parent="$(cd "$download_temp_parent" && pwd -P)"
    [[ "$download_physical_temp_parent" == "$download_temp_parent" ]] || {
        echo "temporary extraction parent must be a physical path" >&2
        return 1
    }
    download_extraction_root="$(
        /usr/bin/mktemp -d \
            "$download_physical_temp_parent/localocr-downloaded-release.XXXXXX"
    )"
    [[ -d "$download_extraction_root" && ! -L "$download_extraction_root" ]] || {
        echo "could not create a fresh physical extraction directory" >&2
        return 1
    }
    [[ -z "$(/usr/bin/find "$download_extraction_root" -mindepth 1 -print -quit)" ]] || {
        echo "fresh extraction directory was not empty" >&2
        return 1
    }
}

download_extract_archive() {
    # Required production extraction: ditto -x -k into a new confined directory.
    "$download_ditto" -x -k "$download_zip" "$download_extraction_root"
}

download_validate_extracted_tree() {
    local physical_root
    local physical_app
    local top_level_count
    local symlink

    physical_root="$(cd "$download_extraction_root" && pwd -P)"
    [[ "$physical_root" == "$download_extraction_root" ]] || {
        echo "extraction root is not physical" >&2
        return 1
    }
    top_level_count="$(
        /usr/bin/find "$physical_root" -mindepth 1 -maxdepth 1 -print |
            /usr/bin/awk 'END { print NR + 0 }'
    )"
    [[ "$top_level_count" -eq 1 ]] || {
        echo "downloaded ZIP must extract exactly one top-level app" >&2
        return 1
    }
    download_extracted_app="$physical_root/LocalOCR Studio.app"
    [[ -d "$download_extracted_app" && ! -L "$download_extracted_app" ]] || {
        echo "downloaded ZIP did not contain the expected physical app" >&2
        return 1
    }
    physical_app="$(cd "$download_extracted_app" && pwd -P)"
    [[ "$physical_app" == "$download_extracted_app" ]] || {
        echo "extracted app escaped the extraction directory" >&2
        return 1
    }
    symlink="$(/usr/bin/find "$physical_root" -type l -print -quit)"
    [[ -z "$symlink" ]] || {
        echo "downloaded ZIP contains a symlink" >&2
        return 1
    }
}

download_resolve_main_executable() {
    local executable_name
    local executable_path
    local physical_macos_dir
    local physical_executable

    executable_name="$(
        "$download_plist_buddy" -c "Print :CFBundleExecutable" \
            "$download_extracted_app/Contents/Info.plist"
    )" || return
    [[ -n "$executable_name" && "$executable_name" != "." && "$executable_name" != ".." ]] || {
        echo "CFBundleExecutable must be a nonempty basename" >&2
        return 1
    }
    case "$executable_name" in
        */*|*\\*)
            echo "CFBundleExecutable must be a basename" >&2
            return 1
            ;;
    esac
    physical_macos_dir="$(cd "$download_extracted_app/Contents/MacOS" && pwd -P)"
    executable_path="$physical_macos_dir/$executable_name"
    [[ -f "$executable_path" && ! -L "$executable_path" ]] || {
        echo "extracted main executable is missing or symlinked" >&2
        return 1
    }
    physical_executable="$(/bin/realpath "$executable_path")"
    case "$physical_executable" in
        "$physical_macos_dir"/*)
            printf '%s\n' "$physical_executable"
            ;;
        *)
            echo "extracted main executable escaped Contents/MacOS" >&2
            return 1
            ;;
    esac
}

download_binary_minimum_macos() {
    "$download_otool" -l "$1" |
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

download_verify_binary_architecture_and_target() {
    local binary="$1"
    local description
    local architectures
    local minimum_macos

    [[ -f "$binary" && ! -L "$binary" ]] || {
        echo "release binary is missing or symlinked" >&2
        return 1
    }
    description="$("$download_file" -b "$binary")" || return
    [[ "$description" == *"Mach-O"* ]] || {
        echo "release binary is not Mach-O" >&2
        return 1
    }
    architectures="$("$download_lipo" -archs "$binary")" || return
    validate_arm64_architecture "$architectures" || return
    minimum_macos="$(download_binary_minimum_macos "$binary")" || return
    validate_minimum_macos "$minimum_macos" || return
}

download_verify_binary_dependencies() {
    local binary="$1"
    local dependency_output
    local dependency_line
    local install_name

    # Required production inspection: otool -L.
    dependency_output="$("$download_otool" -L "$binary")" || return
    while IFS= read -r dependency_line; do
        [[ -n "$dependency_line" ]] || continue
        install_name="$(printf '%s\n' "$dependency_line" | /usr/bin/awk '{ print $1 }')"
        validate_install_name "$install_name" || return
        if [[ "$install_name" == "@rpath/libswiftCompatibilitySpan.dylib" ]]; then
            [[ "$dependency_line" == *", weak)" ]] || {
                echo "libswiftCompatibilitySpan.dylib must be weak-linked" >&2
                return 1
            }
        fi
    done < <(
        printf '%s\n' "$dependency_output" |
            /usr/bin/awk 'NR > 1 { sub(/^[[:space:]]+/, ""); print }'
    )
}

download_verify_binary_rpaths() {
    local binary="$1"
    local load_commands
    local rpath_output
    local rpath

    # Required production inspection: otool -l.
    load_commands="$("$download_otool" -l "$binary")" || return
    rpath_output="$(
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
    )" || {
        echo "could not parse every LC_RPATH" >&2
        return 1
    }
    while IFS= read -r rpath; do
        [[ -n "$rpath" ]] || continue
        validate_rpath "$rpath" || return
    done <<< "$rpath_output"
}

download_verify_no_forbidden_strings() {
    local binary="$1"
    local strings_output
    local forbidden

    strings_output="$("$download_strings" -a "$binary")" || return
    for forbidden in \
        "/Applications/Xcode" \
        "/Users/" \
        "/opt/homebrew" \
        "/usr/local" \
        ".venv" \
        "python" \
        "pyobjc" \
        "pymupdf" \
        "ruby"
    do
        if /usr/bin/grep -F -i -q -- "$forbidden" <<< "$strings_output"; then
            echo "private or non-native marker found in release binary" >&2
            return 1
        fi
    done
}

download_verify_binary_policy() {
    download_verify_binary_architecture_and_target "$1" || return
    download_verify_binary_dependencies "$1" || return
    download_verify_binary_rpaths "$1" || return
    download_verify_no_forbidden_strings "$1" || return
}

download_verify_signed_object() {
    local code_object="$1"
    local details
    local entitlements
    local leaf_authority
    local team_identifier_count
    local timestamp_count
    local code_directory_count

    "$download_codesign" --verify --strict --verbose=2 "$code_object" || return
    details="$("$download_codesign" -dv --verbose=4 "$code_object" 2>&1)" || return
    validate_signature_details "$details" "downloaded code object" || return
    leaf_authority="$(
        printf '%s\n' "$details" |
            /usr/bin/awk '/^Authority=/ { print; exit }'
    )"
    [[ "$leaf_authority" == "Authority=$verify_expected_authority" ]] || {
        echo "downloaded code object has an unexpected leaf authority" >&2
        return 1
    }
    team_identifier_count="$(
        printf '%s\n' "$details" |
            /usr/bin/awk '/^TeamIdentifier=/ { count += 1 } END { print count + 0 }'
    )"
    [[ "$team_identifier_count" -eq 1 ]] || {
        echo "downloaded code object must have exactly one team identifier" >&2
        return 1
    }
    timestamp_count="$(
        printf '%s\n' "$details" |
            /usr/bin/awk '/^Timestamp=/ { count += 1 } END { print count + 0 }'
    )"
    [[ "$timestamp_count" -eq 1 ]] || {
        echo "downloaded code object must have exactly one secure timestamp" >&2
        return 1
    }
    code_directory_count="$(
        printf '%s\n' "$details" |
            /usr/bin/awk '/^CodeDirectory / { count += 1 } END { print count + 0 }'
    )"
    [[ "$code_directory_count" -eq 1 ]] || {
        echo "downloaded code object must have one Hardened Runtime CodeDirectory" >&2
        return 1
    }
    entitlements="$(
        "$download_codesign" -d --entitlements :- "$code_object" 2>/dev/null
    )" || return
    validate_no_debug_entitlement_text "$entitlements" || return
    if /usr/bin/grep -F -q \
        "com.apple.security.get-task-allow" <<< "$entitlements"
    then
        echo "downloaded code object contains the debug entitlement" >&2
        return 1
    fi
}

download_verify_signature_and_binary_policy() {
    local main_executable
    local helper

    validate_release_bundle_metadata "$download_extracted_app" || return
    main_executable="$(download_resolve_main_executable)" || return
    for helper in localocr localocr-mcp; do
        download_verify_binary_policy \
            "$download_extracted_app/Contents/Helpers/$helper" || return
        download_verify_signed_object \
            "$download_extracted_app/Contents/Helpers/$helper" || return
    done
    download_verify_binary_policy "$main_executable" || return
    download_verify_signed_object "$download_extracted_app" || return
    "$download_codesign" --verify --deep --strict --verbose=2 \
        "$download_extracted_app" || return
}

download_validate_stapled_ticket() {
    "$download_xcrun" stapler validate "$download_extracted_app"
}

download_require_gatekeeper_acceptance() {
    # Required production gate: spctl --assess --type execute.
    "$download_spctl" --assess --type execute --verbose=2 \
        "$download_extracted_app"
}

download_verify_release_version_input() {
    validate_release_metadata_inputs
}

download_verify_cli_version() {
    local actual_version

    actual_version="$(
        "$download_extracted_app/Contents/Helpers/localocr" --version
    )" || return
    [[ "$actual_version" == "$LOCALOCR_RELEASE_VERSION" ]] || {
        echo "localocr version did not match LOCALOCR_RELEASE_VERSION" >&2
        return 1
    }
}

download_verify_mcp_initialization() {
    local mcp_binary="$download_extracted_app/Contents/Helpers/localocr-mcp"
    local request_file="$download_extraction_root/mcp-initialize-request.json"
    local response_file="$download_extraction_root/mcp-initialize-response.json"
    local stderr_file="$download_extraction_root/mcp-initialize.stderr"
    local mcp_pid
    local mcp_status=0
    local server_version

    printf '%s\n' \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"downloaded-release-verifier","version":"1.0"}}}' \
        > "$request_file"
    {
        /bin/cat "$request_file"
        "$download_sleep" 1
    } | "$mcp_binary" > "$response_file" 2> "$stderr_file" &
    mcp_pid=$!
    for _ in {1..50}; do
        if ! /bin/kill -0 "$mcp_pid" 2>/dev/null; then
            break
        fi
        "$download_sleep" 0.1
    done
    if /bin/kill -0 "$mcp_pid" 2>/dev/null; then
        /bin/kill "$mcp_pid" 2>/dev/null || true
        wait "$mcp_pid" 2>/dev/null || true
        echo "localocr-mcp initialization timed out" >&2
        return 1
    fi
    wait "$mcp_pid" || mcp_status=$?
    [[ "$mcp_status" -eq 0 && ! -s "$stderr_file" ]] || {
        echo "localocr-mcp initialization failed" >&2
        return 1
    }
    server_version="$(
        /usr/bin/plutil -extract result.serverInfo.version raw -o - -- \
            "$response_file" 2>/dev/null
    )" || {
        echo "localocr-mcp returned an invalid initialization response" >&2
        return 1
    }
    [[ "$server_version" == "$LOCALOCR_RELEASE_VERSION" ]] || {
        echo "localocr-mcp version did not match LOCALOCR_RELEASE_VERSION" >&2
        return 1
    }
}

download_smoke_input_type() {
    local input="$1"
    local extension

    extension="${input##*.}"
    extension="$(printf '%s' "$extension" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    case "$extension" in
        pdf) printf 'PDF\n' ;;
        png) printf 'PNG image\n' ;;
        jpg|jpeg) printf 'JPEG image\n' ;;
        heic|heif) printf 'HEIC image\n' ;;
        tif|tiff) printf 'TIFF image\n' ;;
        bmp) printf 'BMP image\n' ;;
        gif) printf 'GIF image\n' ;;
        webp) printf 'WebP image\n' ;;
        *) return 1 ;;
    esac
}

download_run_optional_smoke() {
    local input="${LOCALOCR_SMOKE_INPUT:-}"
    local input_type
    local command
    local checksum_before
    local checksum_after
    local command_status=0
    local output_file="$download_extraction_root/ocr-smoke-output.json"

    if [[ -z "$input" ]]; then
        download_record_result "OCR smoke input type" "not supplied"
        download_record_result "OCR smoke result" "SKIPPED"
        return 0
    fi
    case "$input" in
        /*) ;;
        *)
            echo "LOCALOCR_SMOKE_INPUT must be an absolute path" >&2
            download_record_result "OCR smoke input type" "invalid"
            download_record_result "OCR smoke result" "FAIL"
            return 1
            ;;
    esac
    [[ -f "$input" && ! -L "$input" ]] || {
        echo "LOCALOCR_SMOKE_INPUT must be a physical regular file" >&2
        download_record_result "OCR smoke input type" "invalid"
        download_record_result "OCR smoke result" "FAIL"
        return 1
    }
    input_type="$(download_smoke_input_type "$input")" || {
        echo "LOCALOCR_SMOKE_INPUT must be a PDF or supported image fixture" >&2
        download_record_result "OCR smoke input type" "unsupported"
        download_record_result "OCR smoke result" "FAIL"
        return 1
    }
    download_record_result "OCR smoke input type" "$input_type"
    checksum_before="$(
        "$download_shasum" -a 256 "$input" |
            /usr/bin/awk '{ print $1 }'
    )" || {
        echo "could not verify OCR smoke input before the command" >&2
        download_record_result "OCR smoke input immutability" "FAIL"
        download_record_result "OCR smoke result" "FAIL"
        return 1
    }
    if [[ "$input_type" == "PDF" ]]; then
        command="ocr"
    else
        command="image"
    fi
    if LOCALOCR_CACHE_DIR="$download_extraction_root/ocr-cache" \
        "$download_extracted_app/Contents/Helpers/localocr" \
        "$command" "$input" --no-cache --json > "$output_file"
    then
        command_status=0
    else
        command_status=$?
    fi
    checksum_after="$("$download_shasum" -a 256 "$input" | /usr/bin/awk '{ print $1 }')" || {
        echo "could not verify OCR smoke input after the command" >&2
        download_record_result "OCR smoke input immutability" "FAIL"
        if [[ "$command_status" -eq 0 ]]; then
            download_record_result "OCR smoke command result" "PASS"
        else
            download_record_result "OCR smoke command result" "FAIL"
        fi
        download_record_result "OCR smoke result" "FAIL"
        return 1
    }
    if [[ "$checksum_before" != "$checksum_after" ]]; then
        download_record_result "OCR smoke input immutability" "FAIL"
        if [[ "$command_status" -eq 0 ]]; then
            download_record_result "OCR smoke command result" "PASS"
        else
            download_record_result "OCR smoke command result" "FAIL"
        fi
        echo "OCR smoke input changed during verification" >&2
        download_record_result "OCR smoke result" "FAIL"
        return 1
    fi
    download_record_result "OCR smoke input immutability" "PASS"
    [[ "$command_status" -eq 0 ]] || {
        download_record_result "OCR smoke command result" "FAIL"
        echo "OCR smoke command failed" >&2
        download_record_result "OCR smoke result" "FAIL"
        return 1
    }
    download_record_result "OCR smoke command result" "PASS"
    [[ -s "$output_file" ]] || {
        echo "OCR smoke command produced no result" >&2
        download_record_result "OCR smoke result" "FAIL"
        return 1
    }
    download_record_result "OCR smoke result" "PASS"
}

download_cleanup() {
    local physical_extraction

    [[ -n "$download_extraction_root" ]] || return 0
    [[ -d "$download_physical_temp_parent" && ! -L "$download_physical_temp_parent" ]] || {
        echo "refusing cleanup because the temporary parent is unsafe" >&2
        return 1
    }
    [[ -d "$download_extraction_root" && ! -L "$download_extraction_root" ]] || {
        echo "refusing cleanup because the extraction root is unsafe" >&2
        return 1
    }
    physical_extraction="$(cd "$download_extraction_root" && pwd -P)"
    case "$physical_extraction" in
        "$download_physical_temp_parent"/localocr-downloaded-release.*)
            "$download_cleanup_rm" -rf -- "$physical_extraction" || return 1
            download_extraction_root=""
            ;;
        *)
            echo "refusing to remove an unconfined extraction directory" >&2
            return 1
            ;;
    esac
}

download_finish() {
    local status="$1"

    [[ "$download_evidence_write_failed" -eq 0 ]] || status=1
    if download_cleanup; then
        download_record_result "Temporary cleanup" "PASS" || status=1
    else
        download_record_result "Temporary cleanup" "FAIL" || true
        status=1
    fi
    [[ "$download_evidence_write_failed" -eq 0 ]] || status=1
    if [[ "$status" -eq 0 ]]; then
        if ! download_validate_evidence_completeness; then
            status=1
        elif ! download_record_result "Overall result" "PASS"; then
            status=1
        fi
    fi
    if [[ "$status" -ne 0 ]]; then
        download_record_result "Overall result" "FAIL" || true
    fi
    [[ "$download_evidence_write_failed" -eq 0 ]] || status=1
    printf 'Evidence file: %s\n' "$download_evidence_file"
    return "$status"
}

download_validate_evidence_completeness() {
    local label
    local count

    [[ "$download_evidence_write_failed" -eq 0 ]] || return 1
    ! /usr/bin/grep -F -q "ZIP SHA-256: pending" "$download_evidence_file" || {
        echo "acceptance evidence still has a pending checksum" >&2
        return 1
    }
    for label in \
        "Release version input" \
        "Checksum verification" \
        "Archive path safety" \
        "Fresh extraction directory" \
        "Archive extraction" \
        "Extraction confinement" \
        "Signature and binary policy" \
        "Stapled ticket" \
        "Gatekeeper assessment" \
        "CLI version" \
        "MCP initialization" \
        "OCR smoke input type" \
        "OCR smoke result" \
        "Temporary cleanup"
    do
        count="$(
            /usr/bin/awk -v prefix="$label: " \
                'index($0, prefix) == 1 { count += 1 } END { print count + 0 }' \
                "$download_evidence_file"
        )" || return 1
        [[ "$count" -eq 1 ]] || {
            echo "acceptance evidence is incomplete for: $label" >&2
            return 1
        }
    done
    ! /usr/bin/grep -E -q ': FAIL$' "$download_evidence_file"
}

download_main() {
    download_validate_arguments "$@"
    download_zip="$1"
    download_checksum_file="$2"
    download_read_expected_checksum
    download_verify_release_version_input
    select_release_developer_dir
    download_initialize_evidence
    download_record_result "Release version input" "PASS"
    if ! download_run_gate "Checksum verification" download_verify_checksum; then
        download_finish 1
        return
    fi
    if ! download_run_gate "Archive path safety" download_validate_archive_paths; then
        download_finish 1
        return
    fi
    if ! download_run_gate "Fresh extraction directory" download_create_fresh_extraction; then
        download_finish 1
        return
    fi
    if ! download_run_gate "Archive extraction" download_extract_archive; then
        download_finish 1
        return
    fi
    if ! download_run_gate "Extraction confinement" download_validate_extracted_tree; then
        download_finish 1
        return
    fi
    if ! download_run_gate "Signature and binary policy" download_verify_signature_and_binary_policy; then
        download_finish 1
        return
    fi
    if ! download_run_gate "Stapled ticket" download_validate_stapled_ticket; then
        download_finish 1
        return
    fi
    if ! download_run_gate "Gatekeeper assessment" download_require_gatekeeper_acceptance; then
        download_finish 1
        return
    fi
    if ! download_run_gate "CLI version" download_verify_cli_version; then
        download_finish 1
        return
    fi
    if ! download_run_gate "MCP initialization" download_verify_mcp_initialization; then
        download_finish 1
        return
    fi
    if ! download_run_optional_smoke; then
        download_finish 1
        return
    fi
    download_finish 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    download_main "$@"
fi
