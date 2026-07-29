#!/usr/bin/env bash

set -euo pipefail

release_toolchain_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
release_repo_root="$(cd "$release_toolchain_script_dir/.." && pwd)"
release_developer_dir="/Applications/Xcode.app/Contents/Developer"
release_signing_identity="Developer ID Application: John Scott Ray (DZ8B5454ZN)"
release_plist_buddy="/usr/libexec/PlistBuddy"

release_evidence_dir() {
    printf '%s\n' "$release_repo_root/dist/direct-release/evidence"
}

validate_release_developer_dir() {
    local candidate="${1:-}"
    local normalized

    [[ "$candidate" == "$release_developer_dir" ]] || {
        echo "release builds require the stable Xcode developer directory" >&2
        return 1
    }

    normalized="$(printf '%s' "$candidate" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    case "$normalized" in
        *beta*|*rc*|*preview*)
            echo "prerelease developer directories are not allowed" >&2
            return 1
            ;;
    esac
}

configure_release_developer_dir() {
    local resolved_developer_dir
    local xcodebuild_path
    local evidence_dir
    local version_file
    local version_file_partial

    DEVELOPER_DIR="$release_developer_dir"
    export DEVELOPER_DIR
    validate_release_developer_dir "$DEVELOPER_DIR"

    [[ -d "$DEVELOPER_DIR" ]] || {
        echo "stable Xcode developer directory not found: $DEVELOPER_DIR" >&2
        return 1
    }
    resolved_developer_dir="$(cd "$DEVELOPER_DIR" && pwd -P)"
    validate_release_developer_dir "$resolved_developer_dir"

    xcodebuild_path="$DEVELOPER_DIR/usr/bin/xcodebuild"
    [[ -x "$xcodebuild_path" ]] || {
        echo "xcodebuild not found in stable Xcode: $xcodebuild_path" >&2
        return 1
    }

    evidence_dir="$(release_evidence_dir)"
    version_file="$evidence_dir/xcode-version.txt"
    [[ ! -L "$release_repo_root/dist" ]] || {
        echo "release dist directory must not be a symlink" >&2
        return 1
    }
    /bin/mkdir -p "$evidence_dir"
    [[ "$(cd "$evidence_dir" && pwd -P)" == "$evidence_dir" ]] || {
        echo "release evidence directory must be physical" >&2
        return 1
    }
    [[ ! -L "$version_file" ]] || {
        echo "Xcode evidence leaf must not be a symlink" >&2
        return 1
    }
    [[ ! -e "$version_file" || -f "$version_file" ]] || {
        echo "Xcode evidence leaf must be a regular file" >&2
        return 1
    }
    version_file_partial="$(/usr/bin/mktemp "$evidence_dir/.xcode-version.XXXXXX")"
    "$xcodebuild_path" -version > "$version_file_partial" || {
        /bin/rm -f -- "$version_file_partial"
        return 1
    }
    [[ "$(/usr/bin/awk 'END { print NR }' "$version_file_partial")" -eq 2 ]] || {
        /bin/rm -f -- "$version_file_partial"
        echo "expected xcodebuild -version to produce exactly two lines" >&2
        return 1
    }
    /bin/mv -f -- "$version_file_partial" "$version_file"
}

validate_release_inputs() {
    local variable_name

    for variable_name in \
        LOCALOCR_UNSIGNED_APP \
        LOCALOCR_RELEASE_VERSION \
        LOCALOCR_RELEASE_BUILD \
        LOCALOCR_EXPECTED_BUNDLE_ID
    do
        [[ -n "${!variable_name:-}" ]] || {
            echo "required release input is missing: $variable_name" >&2
            return 1
        }
    done
}

validate_release_bundle_metadata() {
    local app_path="$1"
    local info_plist="$app_path/Contents/Info.plist"
    local key
    local expected
    local actual

    : "${LOCALOCR_EXPECTED_BUNDLE_ID:?LOCALOCR_EXPECTED_BUNDLE_ID is required}"
    : "${LOCALOCR_RELEASE_VERSION:?LOCALOCR_RELEASE_VERSION is required}"
    : "${LOCALOCR_RELEASE_BUILD:?LOCALOCR_RELEASE_BUILD is required}"
    [[ -d "$app_path" && ! -L "$app_path" ]] || {
        echo "release app is missing or symlinked: $app_path" >&2
        return 1
    }
    [[ -f "$info_plist" && ! -L "$info_plist" ]] || {
        echo "release Info.plist is missing or symlinked" >&2
        return 1
    }
    for key in \
        CFBundleIdentifier \
        CFBundleShortVersionString \
        CFBundleVersion
    do
        case "$key" in
            CFBundleIdentifier) expected="$LOCALOCR_EXPECTED_BUNDLE_ID" ;;
            CFBundleShortVersionString) expected="$LOCALOCR_RELEASE_VERSION" ;;
            CFBundleVersion) expected="$LOCALOCR_RELEASE_BUILD" ;;
        esac
        actual="$("$release_plist_buddy" -c "Print :$key" "$info_plist")" || {
            echo "could not read $key from release Info.plist" >&2
            return 1
        }
        [[ "$actual" == "$expected" ]] || {
            echo "$key mismatch: expected '$expected', found '$actual'" >&2
            return 1
        }
    done
}

validate_signing_identity() {
    local identity_list
    local matching_identity_count

    identity_list="$(/usr/bin/security find-identity -v -p codesigning)"
    matching_identity_count="$(
        printf '%s\n' "$identity_list" |
            /usr/bin/awk -v expected="\"$release_signing_identity\"" '
                index($0, expected) {
                    suffix = substr($0, index($0, expected))
                    if (suffix == expected) {
                        count += 1
                    }
                }
                END { print count + 0 }
            '
    )"
    [[ "$matching_identity_count" -eq 1 ]] || {
        echo "expected exactly one valid Developer ID Application identity" >&2
        return 1
    }
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --test-developer-dir)
            [[ "$#" -eq 2 ]] || exit 2
            validate_release_developer_dir "$2"
            ;;
        --test-bundle-metadata)
            [[ "$#" -eq 2 ]] || exit 2
            validate_release_bundle_metadata "$2"
            ;;
        "")
            configure_release_developer_dir
            ;;
        *)
            echo "unknown release-toolchain mode: $1" >&2
            exit 2
            ;;
    esac
fi
