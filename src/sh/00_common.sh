#!/bin/bash
# =============================================================================
# library-bundle (Unix / macOS / Linux) - Module: 00_common.sh
# =============================================================================

BUNDLE_VERSION="@VERSION@"
BUNDLE_SCHEMA_VERSION="@CONFIG_SCHEMA_VERSION@"

if [[ -n "${WORKSPACE_ROOT_DIR:-}" ]]; then
    SCRIPT_DIR=$(cd "$WORKSPACE_ROOT_DIR" && pwd)
elif [[ "$(basename "$(dirname "$0")")" == ".workspace-tools" ]]; then
    SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
else
    SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
fi

TOOLS_STATE_DIR="$SCRIPT_DIR/.workspace-tools"
mkdir -p "$TOOLS_STATE_DIR"

# Colors
if [[ -t 1 ]]; then
    RED=$(printf '\033[31m')
    GREEN=$(printf '\033[32m')
    YELLOW=$(printf '\033[33m')
    BLUE=$(printf '\033[34m')
    CYAN=$(printf '\033[36m')
    MAGENTA=$(printf '\033[35m')
    WHITE=$(printf '\033[1;37m')
    BOLD=$(printf '\033[1m')
    GRAY=$(printf '\033[0;90m')
    RESET=$(printf '\033[0m')
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    MAGENTA=''
    WHITE=''
    BOLD=''
    GRAY=''
    RESET=''
fi

info()    { printf '%s\n' "${BLUE}$*${RESET}"; }
success() { printf '%s\n' "${GREEN}$*${RESET}"; }
warning() { printf '%s\n' "${YELLOW}$*${RESET}"; }
error()   { printf '%s\n' "${RED}$*${RESET}" >&2; }

trim_ws() {
    local val="$1"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    printf '%s' "$val"
}

strip_outer_quotes() {
    local val="$1"
    if [[ "$val" == \"*\" && "$val" == *\" && ${#val} -ge 2 ]]; then
        val="${val#\"}"
        val="${val%\"}"
    elif [[ "$val" == \'*\' && "$val" == *\' && ${#val} -ge 2 ]]; then
        val="${val#\'}"
        val="${val%\'}"
    fi
    printf '%s' "$val"
}

slugify_name() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g'
}

read_kv_value() {
    local file="$1"
    local target_key="$2"
    [[ ! -f "$file" ]] && return 0

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        local line
        line=$(printf '%s' "$raw_line" | tr -d '\r')
        line=$(trim_ws "$line")
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" == *=* ]]; then
            local key="${line%%=*}"
            local val="${line#*=}"
            key=$(trim_ws "$key")
            if [[ "$key" == "$target_key" ]]; then
                val=$(trim_ws "$val")
                strip_outer_quotes "$val"
                return 0
            fi
        fi
    done < "$file"
}

# Updates KEY=VALUE in-place in a config file (or appends it if missing)
set_kv_value() {
    local file="$1"
    local target_key="$2"
    local new_val="$3"

    if [[ ! -f "$file" ]]; then
        printf '%s=%s\n' "$target_key" "$new_val" > "$file"
        return 0
    fi

    local tmp_f="${file}.tmp.$$"
    local found=0
    : > "$tmp_f"

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        local line
        line=$(printf '%s' "$raw_line" | tr -d '\r')
        local trimmed
        trimmed=$(trim_ws "$line")
        if [[ -n "$trimmed" && "$trimmed" != \#* && "$trimmed" == *=* ]]; then
            local k="${trimmed%%=*}"
            k=$(trim_ws "$k")
            if [[ "$k" == "$target_key" ]]; then
                if [[ $found -eq 0 ]]; then
                    printf '%s=%s\n' "$target_key" "$new_val" >> "$tmp_f"
                    found=1
                fi
                continue
            fi
        fi
        printf '%s\n' "$line" >> "$tmp_f"
    done < "$file"

    if [[ $found -eq 0 ]]; then
        printf '%s=%s\n' "$target_key" "$new_val" >> "$tmp_f"
    fi

    mv -f "$tmp_f" "$file"
}

file_sha256() {
    local target="$1"
    if [[ ! -f "$target" ]]; then
        printf 'MISSING'
        return 0
    fi
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$target" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$target" | awk '{print $1}'
    else
        return 1
    fi
}

verify_sha256_manifest() {
    local sums_file="$1"
    local local_file="$2"
    local asset_name="$3"

    [[ ! -f "$sums_file" ]] && return 0
    local expected actual
    expected=$(awk -v name="$asset_name" '{
        f=$2; sub(/^\.\//, "", f); sub(/^\*/, "", f);
        if (f == name) { print tolower($1); exit }
    }' "$sums_file")
    [[ -z "$expected" ]] && return 0

    actual=$(file_sha256 "$local_file") || return 0
    actual=$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')
    if [[ "$actual" != "$expected" ]]; then
        error "Checksum mismatch for $asset_name!"
        error "  Expected: $expected"
        error "  Actual:   $actual"
        return 1
    fi
    return 0
}

http_fetch_url() {
    local url="$1"
    local dest="$2"
    local timeout_secs="${3:-10}"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time "$timeout_secs" "$url" -o "$dest" 2>/dev/null
        return $?
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T "$timeout_secs" -O "$dest" "$url" 2>/dev/null
        return $?
    fi
    return 1
}

is_valid_semver_string() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)*([-+][A-Za-z0-9._-]+)?$ ]]
}

# Returns 0 if $1 (remote) > $2 (local), 1 otherwise
is_version_newer() {
    local remote="$1"
    local local_v="$2"

    is_valid_semver_string "$remote" || return 1
    if [[ -z "$local_v" || "$local_v" == "unknown" ]] || ! is_valid_semver_string "$local_v"; then
        return 0
    fi
    [[ "$remote" == "$local_v" ]] && return 1

    local r_base="${remote%%+*}"
    local l_base="${local_v%%+*}"
    local r_pre="" l_pre=""
    if [[ "$r_base" == *-* ]]; then
        r_pre="${r_base#*-}"
        r_base="${r_base%%-*}"
    fi
    if [[ "$l_base" == *-* ]]; then
        l_pre="${l_base#*-}"
        l_base="${l_base%%-*}"
    fi

    local IFS='.'
    local r_parts=($r_base)
    local l_parts=($l_base)
    local max_len=${#r_parts[@]}
    [[ ${#l_parts[@]} -gt $max_len ]] && max_len=${#l_parts[@]}

    local i
    for ((i = 0; i < max_len; i++)); do
        local rv="${r_parts[$i]:-0}"
        local lv="${l_parts[$i]:-0}"
        if [[ 10#$rv -gt 10#$lv ]]; then
            return 0
        elif [[ 10#$rv -lt 10#$lv ]]; then
            return 1
        fi
    done

    if [[ -n "$l_pre" && -z "$r_pre" ]]; then
        return 0
    fi
    if [[ -n "$l_pre" && -n "$r_pre" && "$r_pre" > "$l_pre" ]]; then
        return 0
    fi
    return 1
}

# Strict Git preflight checks shared by install/update
check_git_clean_repo() {
    local dir="$1"

    if ! command -v git >/dev/null 2>&1; then
        error "Git was not found. Please install Git and make sure it is in PATH."
        return 1
    fi

    if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        error "Current directory is not a Git repository:"
        error "  $dir"
        error "Please run 'git init' (or run inside your workspace Git repository root)."
        return 1
    fi

    local top_level phys_top phys_dir
    top_level=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
    phys_top=$(cd "$top_level" && pwd -P)
    phys_dir=$(cd "$dir" && pwd -P)
    if [[ "$phys_top" != "$phys_dir" ]]; then
        error "Please run from the root of your Git repository:"
        error "  Repo root:   $phys_top"
        error "  Current dir: $phys_dir"
        return 1
    fi

    local pending
    pending=$(git -C "$dir" status --porcelain 2>/dev/null)
    if [[ -n "$pending" ]]; then
        error "Current Git repository has pending uncommitted or untracked changes:"
        printf '%s\n' "$pending" >&2
        error ""
        error "Please stage and commit (or stash) pending changes before proceeding."
        return 1
    fi

    return 0
}

