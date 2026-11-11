#!/bin/bash
# =============================================================================
# workspace.sh - Thin Workspace Wrapper
# Reads TOOLS_VERSION from workspace.conf, ensures the matching library-bundle
# exists in .workspace-tools/, downloads it from GitHub Releases if missing,
# and delegates execution.
# =============================================================================

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
WORKSPACE_CONF="$SCRIPT_DIR/workspace.conf"

DEFAULT_TOOLS_VERSION="1.0.0"
DEFAULT_REPO_URL="https://github.com/BullTronics/workspace-repo-tools"

_trim() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

_read_conf() {
    local target="$1"
    [[ ! -f "$WORKSPACE_CONF" ]] && return 0
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        local line
        line=$(printf '%s' "$raw" | tr -d '\r')
        line=$(_trim "$line")
        [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
        local k="${line%%=*}"
        k=$(_trim "$k")
        if [[ "$k" == "$target" ]]; then
            local v="${line#*=}"
            v=$(_trim "$v")
            v="${v#\"}"; v="${v%\"}"
            v="${v#\'}"; v="${v%\'}"
            printf '%s' "$v"
            return 0
        fi
    done < "$WORKSPACE_CONF"
}

TOOLS_VERSION=$(_read_conf "TOOLS_VERSION")
[[ -z "$TOOLS_VERSION" ]] && TOOLS_VERSION="$DEFAULT_TOOLS_VERSION"

TOOLS_REPO_URL=$(_read_conf "TOOLS_REPO_URL")
[[ -z "$TOOLS_REPO_URL" ]] && TOOLS_REPO_URL="$DEFAULT_REPO_URL"
TOOLS_REPO_URL="${TOOLS_REPO_URL%/}"

TOOLS_RELEASE_BASE_URL=$(_read_conf "TOOLS_RELEASE_BASE_URL")
TOOLS_RELEASE_BASE_URL="${TOOLS_RELEASE_BASE_URL%/}"

if [[ -n "${WORKSPACE_RELEASE_URL:-}" ]]; then
    RELEASES_BASE="${WORKSPACE_RELEASE_URL%/}"
elif [[ -n "$TOOLS_RELEASE_BASE_URL" ]]; then
    RELEASES_BASE="$TOOLS_RELEASE_BASE_URL"
else
    RELEASES_BASE="$TOOLS_REPO_URL/releases"
fi

STATE_DIR="$SCRIPT_DIR/.workspace-tools"
BUNDLE_NAME="library-bundle-${TOOLS_VERSION}.sh"
BUNDLE_PATH="$STATE_DIR/$BUNDLE_NAME"

_http_get() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 20 "$url" -o "$dest" 2>/dev/null
        return $?
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 20 -O "$dest" "$url" 2>/dev/null
        return $?
    fi
    return 1
}

_verify_bundle_sha() {
    local sums_file="$1" target_file="$2" asset="$3"
    [[ ! -f "$sums_file" ]] && return 0
    local expected actual=""
    expected=$(awk -v n="$asset" '{ f=$2; sub(/^\.\//,"",f); sub(/^\*/,"",f); if (f==n) { print tolower($1); exit } }' "$sums_file")
    [[ -z "$expected" ]] && return 0
    if command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$target_file" | awk '{print tolower($1)}')
    elif command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$target_file" | awk '{print tolower($1)}')
    fi
    if [[ -n "$actual" && "$actual" != "$expected" ]]; then
        echo "ERROR: SHA-256 verification failed for $asset." >&2
        return 1
    fi
    return 0
}

if [[ ! -f "$BUNDLE_PATH" ]]; then
    mkdir -p "$STATE_DIR"
    dl_dir="$RELEASES_BASE/download/v${TOOLS_VERSION}"
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrt-dl.XXXXXX")

    echo "Downloading workspace-repo-tools bundle (v${TOOLS_VERSION})..." >&2
    if ! _http_get "$dl_dir/$BUNDLE_NAME" "$tmp_dir/$BUNDLE_NAME"; then
        rm -rf "$tmp_dir"
        echo "ERROR: Failed to download $dl_dir/$BUNDLE_NAME" >&2
        exit 1
    fi

    _http_get "$dl_dir/SHA256SUMS.txt" "$tmp_dir/SHA256SUMS.txt" || true
    if ! _verify_bundle_sha "$tmp_dir/SHA256SUMS.txt" "$tmp_dir/$BUNDLE_NAME" "$BUNDLE_NAME"; then
        rm -rf "$tmp_dir"
        exit 1
    fi

    find "$STATE_DIR" -maxdepth 1 -name 'library-bundle-*.sh' -exec rm -f {} + 2>/dev/null || true
    chmod +x "$tmp_dir/$BUNDLE_NAME"
    mv -f "$tmp_dir/$BUNDLE_NAME" "$BUNDLE_PATH"
    rm -rf "$tmp_dir"
fi

export WORKSPACE_ROOT_DIR="$SCRIPT_DIR"
exec bash "$BUNDLE_PATH" "$@"

