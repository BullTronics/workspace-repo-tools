#!/bin/bash
# =============================================================================
# workspace-repo-tools-updater.sh
# Checks for and applies tooling upgrades from BullTronics/workspace-repo-tools
# while preserving user configuration, repositories, and environment files.
# =============================================================================

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
WORKSPACE_CONF="$SCRIPT_DIR/workspace.conf"
VERSION_FILE="$SCRIPT_DIR/VERSION"
LOCK_FILE="$SCRIPT_DIR/.workspace-tools.lock"
CACHE_FILE="$SCRIPT_DIR/.workspace-tools-cache"
MANIFEST_FILE="$SCRIPT_DIR/updater-manifest.txt"
BACKUPS_ROOT="$SCRIPT_DIR/.workspace-tools-backups"

DEFAULT_UPSTREAM_URL="https://github.com/BullTronics/workspace-repo-tools.git"
DEFAULT_UPSTREAM_BRANCH="main"
DEFAULT_DISABLE_AUTO="false"
DEFAULT_INTERVAL_HOURS="24"

TOOLS_UPSTREAM_URL="$DEFAULT_UPSTREAM_URL"
TOOLS_UPSTREAM_BRANCH="$DEFAULT_UPSTREAM_BRANCH"
TOOLS_RAW_BASE_URL=""
DISABLE_AUTO_UPDATE_CHECK="$DEFAULT_DISABLE_AUTO"
UPDATE_CHECK_INTERVAL_HOURS="$DEFAULT_INTERVAL_HOURS"

# Colors
if [[ -t 1 ]]; then
    RED=$(printf '\033[31m')
    GREEN=$(printf '\033[32m')
    YELLOW=$(printf '\033[33m')
    BLUE=$(printf '\033[34m')
    CYAN=$(printf '\033[36m')
    BOLD=$(printf '\033[1m')
    RESET=$(printf '\033[0m')
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    RESET=''
fi

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

load_updater_conf() {
    local v
    v=$(read_kv_value "$WORKSPACE_CONF" "TOOLS_UPSTREAM_URL")
    [[ -n "$v" ]] && TOOLS_UPSTREAM_URL="$v"

    v=$(read_kv_value "$WORKSPACE_CONF" "TOOLS_UPSTREAM_BRANCH")
    [[ -n "$v" ]] && TOOLS_UPSTREAM_BRANCH="$v"

    v=$(read_kv_value "$WORKSPACE_CONF" "TOOLS_RAW_BASE_URL")
    [[ -n "$v" ]] && TOOLS_RAW_BASE_URL="${v%/}"

    v=$(read_kv_value "$WORKSPACE_CONF" "DISABLE_AUTO_UPDATE_CHECK")
    if [[ -n "$v" ]]; then
        v=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
        if [[ "$v" == "true" || "$v" == "false" ]]; then
            DISABLE_AUTO_UPDATE_CHECK="$v"
        fi
    fi

    v=$(read_kv_value "$WORKSPACE_CONF" "UPDATE_CHECK_INTERVAL_HOURS")
    if [[ -n "$v" && "$v" =~ ^[0-9]+$ ]]; then
        UPDATE_CHECK_INTERVAL_HOURS="$v"
    fi
}

load_updater_conf

usage() {
    cat <<EOF
workspace-repo-tools-updater.sh - check and upgrade workspace-repo-tools

Usage:

  ./workspace-repo-tools-updater.sh <command> [options]

Commands:

  check               Check if an upstream update is available (default)
  upgrade             Download and apply upstream tooling updates safely
  update              Alias for 'upgrade'
  diff                Show line-by-line diff of local vs upstream tooling files
  status | version    Show installed version, lockfile commit, and cache info
  help                Show this help message

Options:

  --dry-run           Show planned upgrade changes without modifying files
  -y, --yes           Apply upgrade without confirmation prompt
  -f, --force         Apply even if already on the latest commit or inside upstream repo
  --commit            Force commit-SHA check via git ls-remote instead of raw VERSION check
  --url <git-url>     Override upstream repository URL
  --raw-url <url>     Override raw base URL for VERSION checks
  --branch <branch>   Override upstream branch (default: main)

Examples:

  ./workspace-repo-tools-updater.sh check
  ./workspace-repo-tools-updater.sh upgrade --dry-run
  ./workspace-repo-tools-updater.sh upgrade --yes
  ./workspace-repo-tools-updater.sh diff

EOF
}

get_local_version() {
    local lock_ver
    lock_ver=$(read_kv_value "$LOCK_FILE" "INSTALLED_VERSION")
    if [[ -n "$lock_ver" ]]; then
        printf '%s' "$lock_ver"
        return 0
    fi
    if [[ -f "$VERSION_FILE" ]]; then
        trim_ws "$(head -n 1 "$VERSION_FILE" | tr -d '\r')"
        return 0
    fi
    printf 'unknown'
}

get_installed_commit() {
    read_kv_value "$LOCK_FILE" "INSTALLED_COMMIT"
}

run_with_timeout() {
    local secs="$1"
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
        return $?
    fi

    if command -v perl >/dev/null 2>&1; then
        perl -e '
            my $t = shift @ARGV;
            $SIG{ALRM} = sub { exit 124 };
            alarm($t);
            my $pid = fork();
            if (!defined $pid) { exit 125; }
            if ($pid == 0) { exec @ARGV; exit 127; }
            $SIG{ALRM} = sub { kill "TERM", $pid; select(undef, undef, undef, 0.2); kill "KILL", $pid; exit 124; };
            waitpid($pid, 0);
            alarm(0);
            exit($? >> 8);
        ' "$secs" "$@"
        return $?
    fi

    "$@"
}

file_hash() {
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
        cksum "$target" | awk '{print $1 "-" $2}'
    fi
}

normalize_repo_url() {
    local u="$1"
    u=$(printf '%s' "$u" | tr '[:upper:]' '[:lower:]')
    u="${u%/}"
    u="${u%.git}"
    if [[ "$u" == git@github.com:* ]]; then
        u="https://github.com/${u#git@github.com:}"
    fi
    printf '%s' "$u"
}

is_same_upstream_repo() {
    if ! git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        return 1
    fi
    local origin_url
    origin_url=$(git -C "$SCRIPT_DIR" config --get remote.origin.url 2>/dev/null || true)
    [[ -z "$origin_url" ]] && return 1
    local norm_origin norm_upstream
    norm_origin=$(normalize_repo_url "$origin_url")
    norm_upstream=$(normalize_repo_url "$TOOLS_UPSTREAM_URL")
    [[ "$norm_origin" == "$norm_upstream" ]]
}

fetch_remote_head() {
    local timeout_secs="${1:-3}"
    local out
    out=$(GIT_TERMINAL_PROMPT=0 run_with_timeout "$timeout_secs" git ls-remote "$TOOLS_UPSTREAM_URL" "refs/heads/$TOOLS_UPSTREAM_BRANCH" 2>/dev/null) || return 1
    local sha
    sha=$(printf '%s\n' "$out" | awk 'NR==1 {print $1}')
    if [[ "$sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
        printf '%s' "$sha"
        return 0
    fi
    return 1
}

resolve_raw_base_url() {
    if [[ -n "$TOOLS_RAW_BASE_URL" ]]; then
        printf '%s' "${TOOLS_RAW_BASE_URL%/}"
        return 0
    fi

    local u="$TOOLS_UPSTREAM_URL"
    u="${u%/}"
    u="${u%.git}"
    if [[ "$u" == git@github.com:* ]]; then
        u="https://github.com/${u#git@github.com:}"
    fi
    if [[ "$u" == https://github.com/*/* ]]; then
        local owner_repo="${u#https://github.com/}"
        printf 'https://raw.githubusercontent.com/%s/%s' "$owner_repo" "$TOOLS_UPSTREAM_BRANCH"
        return 0
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

    # Numeric components equal: stable > prerelease
    if [[ -n "$l_pre" && -z "$r_pre" ]]; then
        return 0
    fi
    if [[ -n "$l_pre" && -n "$r_pre" && "$r_pre" > "$l_pre" ]]; then
        return 0
    fi
    return 1
}

fetch_remote_version_raw() {
    local timeout_secs="${1:-2}"
    local raw_base
    raw_base=$(resolve_raw_base_url) || return 1
    local version_url="$raw_base/VERSION"
    local raw_out=""

    if command -v curl >/dev/null 2>&1; then
        raw_out=$(curl -fsSL --max-time "$timeout_secs" "$version_url" 2>/dev/null) || return 1
    elif command -v wget >/dev/null 2>&1; then
        raw_out=$(wget -qO- -T "$timeout_secs" "$version_url" 2>/dev/null) || return 1
    else
        return 1
    fi

    local ver
    ver=$(trim_ws "$(printf '%s\n' "$raw_out" | head -n 1 | tr -d '\r')")
    if is_valid_semver_string "$ver"; then
        printf '%s' "$ver"
        return 0
    fi
    return 1
}

clone_upstream_shallow() {
    local dest_dir="$1"
    local timeout_secs="${2:-15}"
    GIT_TERMINAL_PROMPT=0 run_with_timeout "$timeout_secs" git clone --quiet --depth 1 --branch "$TOOLS_UPSTREAM_BRANCH" "$TOOLS_UPSTREAM_URL" "$dest_dir" >/dev/null 2>&1
}

write_cache_file() {
    local last_check="$1"
    local last_attempt="$2"
    local remote_commit="$3"
    local remote_version="$4"
    local matched_commit="$5"
    local update_avail="$6"

    local tmp_cache="${CACHE_FILE}.tmp.$$"
    cat <<EOF > "$tmp_cache"
LAST_CHECK_EPOCH=$last_check
LAST_ATTEMPT_EPOCH=$last_attempt
REMOTE_COMMIT=$remote_commit
REMOTE_VERSION=$remote_version
MATCHED_COMMIT=$matched_commit
UPDATE_AVAILABLE=$update_avail
EOF
    mv -f "$tmp_cache" "$CACHE_FILE"
}

write_lock_file() {
    local ver="$1"
    local commit="$2"
    local now_iso
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date)

    local tmp_lock="${LOCK_FILE}.tmp.$$"
    cat <<EOF > "$tmp_lock"
INSTALLED_VERSION=$ver
INSTALLED_COMMIT=$commit
UPSTREAM_URL=$TOOLS_UPSTREAM_URL
UPSTREAM_BRANCH=$TOOLS_UPSTREAM_BRANCH
UPDATED_AT=$now_iso
EOF
    mv -f "$tmp_lock" "$LOCK_FILE"
}

validate_manifest_rel_path() {
    local p="$1"
    [[ -z "$p" ]] && return 1
    case "$p" in
        /*|[A-Za-z]:*|..|../*|*/../*|*/..|*\\*)
            return 1
            ;;
    esac
    return 0
}

# Populates MANIFEST_FILES, MANIFEST_DIRS, MANIFEST_MERGES from <dir>/updater-manifest.txt or fallback
load_manifest_from_dir() {
    local base_dir="$1"
    local mfile="$base_dir/updater-manifest.txt"

    MANIFEST_FILES=()
    MANIFEST_DIRS=()
    MANIFEST_MERGES=()

    if [[ -f "$mfile" ]]; then
        while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
            local line
            line=$(printf '%s' "$raw_line" | tr -d '\r')
            line=$(trim_ws "$line")
            [[ -z "$line" || "$line" == \#* ]] && continue
            if [[ "$line" == file:* ]]; then
                local p="${line#file:}"
                p=$(trim_ws "$p")
                validate_manifest_rel_path "$p" && MANIFEST_FILES+=("$p")
            elif [[ "$line" == dir:* ]]; then
                local p="${line#dir:}"
                p=$(trim_ws "$p")
                validate_manifest_rel_path "$p" && MANIFEST_DIRS+=("$p")
            elif [[ "$line" == merge_lines:* ]]; then
                local p="${line#merge_lines:}"
                p=$(trim_ws "$p")
                validate_manifest_rel_path "$p" && MANIFEST_MERGES+=("$p")
            fi
        done < "$mfile"
    fi

    if [[ ${#MANIFEST_FILES[@]} -eq 0 && ${#MANIFEST_DIRS[@]} -eq 0 ]]; then
        MANIFEST_FILES=(
            "workspace.sh" "workspace.ps1" "workspace.bat"
            "git-all.sh" "git-all.ps1" "git-all.bat"
            "run-local.sh" "run-local.ps1" "run-local.bat"
            "workspace-repo-tools-updater.sh" "workspace-repo-tools-updater.ps1" "workspace-repo-tools-updater.bat"
            "updater-manifest.txt" "VERSION" "README.md"
        )
        MANIFEST_DIRS=("templates")
        MANIFEST_MERGES=(".gitignore")
    fi
}

# Expands MANIFEST_FILES + MANIFEST_DIRS into REL_UPSTREAM_FILES inside $1
collect_managed_files() {
    local upstream_dir="$1"
    load_manifest_from_dir "$upstream_dir"
    REL_UPSTREAM_FILES=()

    local f
    for f in "${MANIFEST_FILES[@]+"${MANIFEST_FILES[@]}"}"; do
        if [[ -f "$upstream_dir/$f" ]]; then
            REL_UPSTREAM_FILES+=("$f")
        fi
    done

    local d
    for d in "${MANIFEST_DIRS[@]+"${MANIFEST_DIRS[@]}"}"; do
        if [[ -d "$upstream_dir/$d" ]]; then
            while IFS= read -r abs_f; do
                local rel_f="${abs_f#"$upstream_dir"/}"
                validate_manifest_rel_path "$rel_f" && REL_UPSTREAM_FILES+=("$rel_f")
            done < <(find "$upstream_dir/$d" -type f | sort)
        fi
    done
}

compute_missing_merge_lines() {
    local upstream_file="$1"
    local local_file="$2"
    MISSING_MERGE_LINES=()

    [[ ! -f "$upstream_file" ]] && return 0

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        local line
        line=$(printf '%s' "$raw_line" | tr -d '\r')
        local trimmed
        trimmed=$(trim_ws "$line")
        [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue

        if [[ ! -f "$local_file" ]]; then
            MISSING_MERGE_LINES+=("$line")
        elif ! grep -Fqx "$line" "$local_file" 2>/dev/null; then
            MISSING_MERGE_LINES+=("$line")
        fi
    done < "$upstream_file"
}

check_all_managed_match() {
    local upstream_dir="$1"
    collect_managed_files "$upstream_dir"

    local rel
    for rel in "${REL_UPSTREAM_FILES[@]+"${REL_UPSTREAM_FILES[@]}"}"; do
        local h_up h_loc
        h_up=$(file_hash "$upstream_dir/$rel")
        h_loc=$(file_hash "$SCRIPT_DIR/$rel")
        if [[ "$h_up" != "$h_loc" ]]; then
            return 1
        fi
    done

    local mf
    for mf in "${MANIFEST_MERGES[@]+"${MANIFEST_MERGES[@]}"}"; do
        compute_missing_merge_lines "$upstream_dir/$mf" "$SCRIPT_DIR/$mf"
        if [[ ${#MISSING_MERGE_LINES[@]} -gt 0 ]]; then
            return 1
        fi
    done

    return 0
}

print_update_notice() {
    local local_ver="$1"
    local remote_ver="$2"
    local local_sha="$3"
    local remote_sha="$4"

    local ver_hint=""
    if [[ -n "$remote_ver" && "$remote_ver" != "unknown" ]]; then
        if [[ "$local_ver" != "$remote_ver" ]]; then
            ver_hint="$local_ver -> $remote_ver"
        else
            local short_r="${remote_sha:0:7}"
            if [[ -n "$local_sha" ]]; then
                ver_hint="$local_ver (${local_sha:0:7} -> $short_r)"
            else
                ver_hint="$local_ver (new commit $short_r)"
            fi
        fi
    elif [[ -n "$remote_sha" ]]; then
        ver_hint="commit ${remote_sha:0:7}"
    fi

    echo ""
    echo -e "  ${YELLOW}🔔 Update available for workspace-repo-tools${RESET} ${CYAN}($ver_hint)${RESET}"
    echo -e "     Run ${BOLD}./workspace-repo-tools-updater.sh upgrade${RESET} or ${BOLD}./workspace.sh upgrade${RESET} to update."
    echo ""
}

refresh_cache() {
    local timeout_secs="${1:-2}"
    local now
    now=$(date +%s)

    local prev_matched prev_remote prev_rver prev_avail prev_check
    prev_matched=$(read_kv_value "$CACHE_FILE" "MATCHED_COMMIT")
    prev_remote=$(read_kv_value "$CACHE_FILE" "REMOTE_COMMIT")
    prev_rver=$(read_kv_value "$CACHE_FILE" "REMOTE_VERSION")
    prev_avail=$(read_kv_value "$CACHE_FILE" "UPDATE_AVAILABLE")
    prev_check=$(read_kv_value "$CACHE_FILE" "LAST_CHECK_EPOCH")
    [[ -z "$prev_check" ]] && prev_check="0"
    [[ -z "$prev_avail" ]] && prev_avail="false"

    # 1. Fast path: fetch VERSION from raw.githubusercontent.com (or configured TOOLS_RAW_BASE_URL)
    local raw_ver local_ver
    local_ver=$(get_local_version)
    if raw_ver=$(fetch_remote_version_raw "$timeout_secs"); then
        if is_version_newer "$raw_ver" "$local_ver"; then
            write_cache_file "$now" "$now" "" "$raw_ver" "$prev_matched" "true"
        else
            write_cache_file "$now" "$now" "" "$raw_ver" "$prev_matched" "false"
        fi
        return 0
    fi

    # 2. Fallback: Git ls-remote (works for private repos & non-GitHub remotes)
    if ! command -v git >/dev/null 2>&1; then
        write_cache_file "$prev_check" "$now" "$prev_remote" "$prev_rver" "$prev_matched" "$prev_avail"
        return 1
    fi

    local remote_sha
    if ! remote_sha=$(fetch_remote_head "$timeout_secs"); then
        write_cache_file "$prev_check" "$now" "$prev_remote" "$prev_rver" "$prev_matched" "$prev_avail"
        return 1
    fi

    local installed_sha
    installed_sha=$(get_installed_commit)

    if [[ -n "$installed_sha" ]]; then
        if [[ "$installed_sha" == "$remote_sha" ]]; then
            write_cache_file "$now" "$now" "$remote_sha" "$local_ver" "$remote_sha" "false"
            return 0
        fi
        local tmp_dir remote_ver=""
        tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrt-check.XXXXXX")
        if clone_upstream_shallow "$tmp_dir" 8; then
            if [[ -f "$tmp_dir/VERSION" ]]; then
                remote_ver=$(trim_ws "$(head -n 1 "$tmp_dir/VERSION" | tr -d '\r')")
            fi
        fi
        rm -rf "$tmp_dir"
        write_cache_file "$now" "$now" "$remote_sha" "$remote_ver" "$prev_matched" "true"
        return 0
    fi

    if [[ -n "$prev_matched" && "$prev_matched" == "$remote_sha" ]]; then
        write_cache_file "$now" "$now" "$remote_sha" "${prev_rver:-$local_ver}" "$prev_matched" "false"
        return 0
    fi

    local tmp_dir remote_ver=""
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrt-check.XXXXXX")
    if clone_upstream_shallow "$tmp_dir" 10; then
        if [[ -f "$tmp_dir/VERSION" ]]; then
            remote_ver=$(trim_ws "$(head -n 1 "$tmp_dir/VERSION" | tr -d '\r')")
        fi
        if check_all_managed_match "$tmp_dir"; then
            rm -rf "$tmp_dir"
            write_cache_file "$now" "$now" "$remote_sha" "$remote_ver" "$remote_sha" "false"
            return 0
        else
            rm -rf "$tmp_dir"
            write_cache_file "$now" "$now" "$remote_sha" "$remote_ver" "" "true"
            return 0
        fi
    fi
    rm -rf "$tmp_dir"
    write_cache_file "$now" "$now" "$remote_sha" "$prev_rver" "$prev_matched" "true"
    return 0
}

cmd_banner_check() {
    local mode="${1:-sync}"

    if [[ "$DISABLE_AUTO_UPDATE_CHECK" == "true" || "${WORKSPACE_NO_UPDATE_CHECK:-0}" == "1" ]]; then
        return 0
    fi

    local now interval_secs
    now=$(date +%s)
    interval_secs=$((UPDATE_CHECK_INTERVAL_HOURS * 3600))

    local last_check last_attempt remote_commit remote_ver matched_commit update_avail
    last_check=$(read_kv_value "$CACHE_FILE" "LAST_CHECK_EPOCH")
    last_attempt=$(read_kv_value "$CACHE_FILE" "LAST_ATTEMPT_EPOCH")
    remote_commit=$(read_kv_value "$CACHE_FILE" "REMOTE_COMMIT")
    remote_ver=$(read_kv_value "$CACHE_FILE" "REMOTE_VERSION")
    matched_commit=$(read_kv_value "$CACHE_FILE" "MATCHED_COMMIT")
    update_avail=$(read_kv_value "$CACHE_FILE" "UPDATE_AVAILABLE")

    [[ -z "$last_check" || ! "$last_check" =~ ^[0-9]+$ ]] && last_check=0
    [[ -z "$last_attempt" || ! "$last_attempt" =~ ^[0-9]+$ ]] && last_attempt=0

    local needs_refresh=0
    if [[ $last_check -eq 0 || $((now - last_check)) -ge $interval_secs ]]; then
        # Avoid hammering network on repeated offline attempts (15 min cooldown)
        if [[ $last_attempt -eq 0 || $((now - last_attempt)) -ge 900 ]]; then
            needs_refresh=1
        fi
    fi

    if [[ $needs_refresh -eq 1 ]]; then
        if [[ "$mode" == "--bg" ]]; then
            (bash "$0" --refresh-cache >/dev/null 2>&1) &
            disown $! 2>/dev/null || true
        else
            refresh_cache 2 >/dev/null 2>&1 || true
            remote_commit=$(read_kv_value "$CACHE_FILE" "REMOTE_COMMIT")
            remote_ver=$(read_kv_value "$CACHE_FILE" "REMOTE_VERSION")
            matched_commit=$(read_kv_value "$CACHE_FILE" "MATCHED_COMMIT")
            update_avail=$(read_kv_value "$CACHE_FILE" "UPDATE_AVAILABLE")
        fi
    fi

    local installed_sha local_ver_now
    installed_sha=$(get_installed_commit)
    local_ver_now=$(get_local_version)
    if [[ -n "$installed_sha" && -n "$remote_commit" && "$installed_sha" == "$remote_commit" ]]; then
        update_avail="false"
    elif [[ -n "$matched_commit" && -n "$remote_commit" && "$matched_commit" == "$remote_commit" ]]; then
        update_avail="false"
    elif [[ -z "$remote_commit" && -n "$remote_ver" ]] && ! is_version_newer "$remote_ver" "$local_ver_now"; then
        update_avail="false"
    fi

    if [[ "$update_avail" == "true" ]]; then
        print_update_notice "$local_ver_now" "$remote_ver" "$installed_sha" "$remote_commit"
    fi
}

cmd_check() {
    local force_commit="${1:-0}"
    local local_ver installed_sha now
    local_ver=$(get_local_version)
    installed_sha=$(get_installed_commit)
    now=$(date +%s)

    if [[ $force_commit -eq 0 ]]; then
        local raw_base raw_ver
        if raw_base=$(resolve_raw_base_url); then
            echo -e "${CYAN}Checking version via: $raw_base/VERSION...${RESET}"
            if raw_ver=$(fetch_remote_version_raw 5); then
                if ! is_version_newer "$raw_ver" "$local_ver"; then
                    write_cache_file "$now" "$now" "$installed_sha" "$raw_ver" "$installed_sha" "false"
                    echo -e "${GREEN}✓ Up to date${RESET} (version: $local_ver)"
                    return 0
                fi

                write_cache_file "$now" "$now" "" "$raw_ver" "" "true"
                print_update_notice "$local_ver" "$raw_ver" "$installed_sha" ""

                # Best-effort changed-file preview via shallow clone (ignore if offline/restricted)
                if command -v git >/dev/null 2>&1; then
                    local tmp_preview
                    tmp_preview=$(mktemp -d "${TMPDIR:-/tmp}/wrt-preview.XXXXXX")
                    if clone_upstream_shallow "$tmp_preview" 12; then
                        collect_managed_files "$tmp_preview"
                        local changed_preview=()
                        local rel
                        for rel in "${REL_UPSTREAM_FILES[@]+"${REL_UPSTREAM_FILES[@]}"}"; do
                            local h_up h_loc
                            h_up=$(file_hash "$tmp_preview/$rel")
                            h_loc=$(file_hash "$SCRIPT_DIR/$rel")
                            if [[ "$h_up" != "$h_loc" ]]; then
                                [[ "$h_loc" == "MISSING" ]] && changed_preview+=("  + $rel (new)") || changed_preview+=("  ~ $rel (updated)")
                            fi
                        done
                        if [[ ${#changed_preview[@]} -gt 0 ]]; then
                            echo "  Changes available:"
                            printf '%s\n' "${changed_preview[@]}"
                            echo ""
                        fi
                    fi
                    rm -rf "$tmp_preview"
                fi
                return 0
            fi
        fi
    fi

    if ! command -v git >/dev/null 2>&1; then
        echo -e "${RED}ERROR: Git is required to check for updates.${RESET}" >&2
        exit 1
    fi

    echo -e "${CYAN}Checking upstream: $TOOLS_UPSTREAM_URL ($TOOLS_UPSTREAM_BRANCH)...${RESET}"

    local remote_sha
    if ! remote_sha=$(fetch_remote_head 8); then
        echo -e "${RED}ERROR: Could not reach upstream repository: $TOOLS_UPSTREAM_URL${RESET}" >&2
        echo -e "${YELLOW}Hint: Check network connectivity or git credentials (for private repos).${RESET}" >&2
        exit 1
    fi

    local now
    now=$(date +%s)

    if [[ -n "$installed_sha" && "$installed_sha" == "$remote_sha" ]]; then
        write_cache_file "$now" "$now" "$remote_sha" "$local_ver" "$remote_sha" "false"
        echo -e "${GREEN}✓ Up to date${RESET} (version: $local_ver, commit: ${remote_sha:0:7})"
        return 0
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrt-check.XXXXXX")
    trap 'rm -rf "$tmp_dir"' EXIT INT TERM

    if ! clone_upstream_shallow "$tmp_dir" 20; then
        echo -e "${RED}ERROR: Failed to fetch upstream contents from $TOOLS_UPSTREAM_URL${RESET}" >&2
        exit 1
    fi

    local remote_ver="unknown"
    if [[ -f "$tmp_dir/VERSION" ]]; then
        remote_ver=$(trim_ws "$(head -n 1 "$tmp_dir/VERSION" | tr -d '\r')")
    fi

    if [[ -z "$installed_sha" ]] && check_all_managed_match "$tmp_dir"; then
        write_cache_file "$now" "$now" "$remote_sha" "$remote_ver" "$remote_sha" "false"
        echo -e "${GREEN}✓ Up to date${RESET} (version: $remote_ver, commit: ${remote_sha:0:7} - all managed files match upstream)"
        rm -rf "$tmp_dir"
        trap - EXIT INT TERM
        return 0
    fi

    write_cache_file "$now" "$now" "$remote_sha" "$remote_ver" "" "true"

    collect_managed_files "$tmp_dir"
    local changed_list=()
    local rel
    for rel in "${REL_UPSTREAM_FILES[@]+"${REL_UPSTREAM_FILES[@]}"}"; do
        local h_up h_loc
        h_up=$(file_hash "$tmp_dir/$rel")
        h_loc=$(file_hash "$SCRIPT_DIR/$rel")
        if [[ "$h_up" != "$h_loc" ]]; then
            if [[ "$h_loc" == "MISSING" ]]; then
                changed_list+=("  + $rel (new)")
            else
                changed_list+=("  ~ $rel (updated)")
            fi
        fi
    done

    local mf
    for mf in "${MANIFEST_MERGES[@]+"${MANIFEST_MERGES[@]}"}"; do
        compute_missing_merge_lines "$tmp_dir/$mf" "$SCRIPT_DIR/$mf"
        if [[ ${#MISSING_MERGE_LINES[@]} -gt 0 ]]; then
            changed_list+=("  ~ $mf (+${#MISSING_MERGE_LINES[@]} ignore rule(s))")
        fi
    done

    rm -rf "$tmp_dir"
    trap - EXIT INT TERM

    print_update_notice "$local_ver" "$remote_ver" "$installed_sha" "$remote_sha"
    if [[ ${#changed_list[@]} -gt 0 ]]; then
        echo ""
        echo "  Changes available:"
        printf '%s\n' "${changed_list[@]}"
    fi
    echo ""
    return 0
}

cmd_diff() {
    if ! command -v git >/dev/null 2>&1; then
        echo -e "${RED}ERROR: Git is required.${RESET}" >&2
        exit 1
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrt-diff.XXXXXX")
    trap 'rm -rf "$tmp_dir"' EXIT INT TERM

    echo -e "${CYAN}Fetching upstream from $TOOLS_UPSTREAM_URL ($TOOLS_UPSTREAM_BRANCH)...${RESET}"
    if ! clone_upstream_shallow "$tmp_dir" 20; then
        echo -e "${RED}ERROR: Failed to clone upstream repository.${RESET}" >&2
        exit 1
    fi

    collect_managed_files "$tmp_dir"
    local any_diff=0
    local rel
    for rel in "${REL_UPSTREAM_FILES[@]+"${REL_UPSTREAM_FILES[@]}"}"; do
        if [[ ! -f "$SCRIPT_DIR/$rel" ]]; then
            echo -e "${GREEN}[NEW] $rel${RESET}"
            any_diff=1
        elif ! cmp -s "$SCRIPT_DIR/$rel" "$tmp_dir/$rel"; then
            any_diff=1
            diff -u "$SCRIPT_DIR/$rel" "$tmp_dir/$rel" || true
        fi
    done

    if [[ $any_diff -eq 0 ]]; then
        echo -e "${GREEN}No differences in managed tooling files.${RESET}"
    fi

    rm -rf "$tmp_dir"
    trap - EXIT INT TERM
}

cmd_status() {
    local local_ver installed_sha
    local_ver=$(get_local_version)
    installed_sha=$(get_installed_commit)

    local last_check remote_commit remote_ver update_avail
    last_check=$(read_kv_value "$CACHE_FILE" "LAST_CHECK_EPOCH")
    remote_commit=$(read_kv_value "$CACHE_FILE" "REMOTE_COMMIT")
    remote_ver=$(read_kv_value "$CACHE_FILE" "REMOTE_VERSION")
    update_avail=$(read_kv_value "$CACHE_FILE" "UPDATE_AVAILABLE")

    echo ""
    echo -e "${CYAN}workspace-repo-tools Status${RESET}"
    echo "  Installed Version : $local_ver"
    echo "  Installed Commit  : ${installed_sha:-<not locked yet>}"
    echo "  Upstream URL      : $TOOLS_UPSTREAM_URL"
    echo "  Upstream Branch   : $TOOLS_UPSTREAM_BRANCH"
    echo "  Auto-Check        : $( [[ "$DISABLE_AUTO_UPDATE_CHECK" == "true" ]] && echo "disabled" || echo "enabled (every ${UPDATE_CHECK_INTERVAL_HOURS}h)" )"
    if [[ -n "$remote_commit" ]]; then
        echo "  Cached Remote     : ${remote_ver:-unknown} (${remote_commit:0:7})"
    fi
    if [[ -n "$last_check" && "$last_check" != "0" ]]; then
        echo "  Last Check Epoch  : $last_check"
    fi
    if [[ "$update_avail" == "true" ]]; then
        echo -e "  Status            : ${YELLOW}Update available${RESET}"
    else
        echo -e "  Status            : ${GREEN}Up to date (cached)${RESET}"
    fi
    echo ""
}

cmd_upgrade() {
    local dry_run="$1"
    local auto_yes="$2"
    local force_flag="$3"

    if ! command -v git >/dev/null 2>&1; then
        echo -e "${RED}ERROR: Git is required to upgrade.${RESET}" >&2
        exit 1
    fi

    if [[ $force_flag -eq 0 ]] && is_same_upstream_repo; then
        echo -e "${YELLOW}This directory's origin matches $TOOLS_UPSTREAM_URL (upstream template repo).${RESET}"
        echo "Use 'git pull' to update the upstream repo itself, or pass '--force' to run updater anyway."
        exit 1
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrt-upgrade.XXXXXX")
    trap 'rm -rf "$tmp_dir"' EXIT INT TERM

    echo -e "${CYAN}Fetching upstream from $TOOLS_UPSTREAM_URL ($TOOLS_UPSTREAM_BRANCH)...${RESET}"
    if ! clone_upstream_shallow "$tmp_dir" 30; then
        echo -e "${RED}ERROR: Failed to fetch upstream repository from $TOOLS_UPSTREAM_URL${RESET}" >&2
        exit 1
    fi

    local remote_sha remote_ver local_ver installed_sha
    remote_sha=$(git -C "$tmp_dir" rev-parse HEAD)
    remote_ver="unknown"
    if [[ -f "$tmp_dir/VERSION" ]]; then
        remote_ver=$(trim_ws "$(head -n 1 "$tmp_dir/VERSION" | tr -d '\r')")
    fi
    local_ver=$(get_local_version)
    installed_sha=$(get_installed_commit)

    collect_managed_files "$tmp_dir"

    local add_files=()
    local update_files=()
    local rel
    for rel in "${REL_UPSTREAM_FILES[@]+"${REL_UPSTREAM_FILES[@]}"}"; do
        local h_up h_loc
        h_up=$(file_hash "$tmp_dir/$rel")
        h_loc=$(file_hash "$SCRIPT_DIR/$rel")
        if [[ "$h_loc" == "MISSING" ]]; then
            add_files+=("$rel")
        elif [[ "$h_up" != "$h_loc" ]]; then
            update_files+=("$rel")
        fi
    done

    local merge_targets=()
    local mf
    for mf in "${MANIFEST_MERGES[@]+"${MANIFEST_MERGES[@]}"}"; do
        compute_missing_merge_lines "$tmp_dir/$mf" "$SCRIPT_DIR/$mf"
        if [[ ! -f "$SCRIPT_DIR/$mf" ]]; then
            add_files+=("$mf")
        elif [[ ${#MISSING_MERGE_LINES[@]} -gt 0 ]]; then
            merge_targets+=("$mf")
        fi
    done

    # Detect new workspace.conf keys in upstream (advisory only)
    local new_conf_keys=()
    if [[ -f "$tmp_dir/workspace.conf" && -f "$WORKSPACE_CONF" ]]; then
        while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
            local line
            line=$(printf '%s' "$raw_line" | tr -d '\r')
            line=$(trim_ws "$line")
            [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
            local k="${line%%=*}"
            k=$(trim_ws "$k")
            if ! grep -Eq "^[[:space:]]*$k[[:space:]]*=" "$WORKSPACE_CONF" 2>/dev/null; then
                new_conf_keys+=("$line")
            fi
        done < "$tmp_dir/workspace.conf"
    fi

    if [[ ${#add_files[@]} -eq 0 && ${#update_files[@]} -eq 0 && ${#merge_targets[@]} -eq 0 && $force_flag -eq 0 ]]; then
        local now
        now=$(date +%s)
        write_cache_file "$now" "$now" "$remote_sha" "$remote_ver" "$remote_sha" "false"
        if [[ -z "$installed_sha" || "$installed_sha" != "$remote_sha" ]]; then
            write_lock_file "$remote_ver" "$remote_sha"
        fi
        echo -e "${GREEN}✓ Already up to date${RESET} ($remote_ver, commit ${remote_sha:0:7})."
        rm -rf "$tmp_dir"
        trap - EXIT INT TERM
        return 0
    fi

    echo ""
    echo -e "${BOLD}Upgrade Summary:${RESET} $local_ver -> $remote_ver (${remote_sha:0:7})"
    if [[ ${#add_files[@]} -gt 0 ]]; then
        echo -e "  ${GREEN}Files to add:${RESET}"
        for rel in "${add_files[@]}"; do echo "    + $rel"; done
    fi
    if [[ ${#update_files[@]} -gt 0 ]]; then
        echo -e "  ${YELLOW}Files to update (existing modified files backed up):${RESET}"
        for rel in "${update_files[@]}"; do echo "    ~ $rel"; done
    fi
    if [[ ${#merge_targets[@]} -gt 0 ]]; then
        echo -e "  ${BLUE}Files to append missing rules:${RESET}"
        for mf in "${merge_targets[@]}"; do echo "    ~ $mf"; done
    fi
    echo -e "  ${CYAN}Preserved (untouched):${RESET} workspace.conf, repos.csv, services.csv, workspace/, .env*"
    echo ""

    if [[ $dry_run -eq 1 ]]; then
        echo -e "${CYAN}Dry run complete. No files were modified.${RESET}"
        rm -rf "$tmp_dir"
        trap - EXIT INT TERM
        return 0
    fi

    if [[ $auto_yes -eq 0 ]]; then
        printf "Proceed with upgrade? [y/N] "
        read -r reply
        case "$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')" in
            y|yes) ;;
            *)
                echo "Upgrade cancelled."
                rm -rf "$tmp_dir"
                trap - EXIT INT TERM
                return 0
                ;;
        esac
    fi

    local ts backup_dir backup_created=0
    ts=$(date +"%Y%m%d-%H%M%S")
    backup_dir="$BACKUPS_ROOT/$ts"

    ensure_backup_file() {
        local rel_path="$1"
        if [[ -f "$SCRIPT_DIR/$rel_path" ]]; then
            if [[ $backup_created -eq 0 ]]; then
                mkdir -p "$backup_dir"
                backup_created=1
            fi
            mkdir -p "$backup_dir/$(dirname "$rel_path")"
            cp -p "$SCRIPT_DIR/$rel_path" "$backup_dir/$rel_path"
        fi
    }

    local self_update_pending=0

    for rel in "${add_files[@]+"${add_files[@]}"}" "${update_files[@]+"${update_files[@]}"}"; do
        if [[ "$rel" == "workspace-repo-tools-updater.sh" ]]; then
            self_update_pending=1
            continue
        fi
        ensure_backup_file "$rel"
        mkdir -p "$SCRIPT_DIR/$(dirname "$rel")"
        cp "$tmp_dir/$rel" "$SCRIPT_DIR/$rel"
        case "$rel" in
            *.sh) chmod +x "$SCRIPT_DIR/$rel" ;;
        esac
    done

    for mf in "${merge_targets[@]+"${merge_targets[@]}"}"; do
        compute_missing_merge_lines "$tmp_dir/$mf" "$SCRIPT_DIR/$mf"
        if [[ ${#MISSING_MERGE_LINES[@]} -gt 0 ]]; then
            ensure_backup_file "$mf"
            {
                printf '\n# Added by workspace-repo-tools-updater (%s)\n' "$ts"
                printf '%s\n' "${MISSING_MERGE_LINES[@]}"
            } >> "$SCRIPT_DIR/$mf"
        fi
    done

    local now
    now=$(date +%s)
    write_lock_file "$remote_ver" "$remote_sha"
    write_cache_file "$now" "$now" "$remote_sha" "$remote_ver" "$remote_sha" "false"

    if [[ $backup_created -eq 1 ]]; then
        echo -e "${CYAN}Backups saved to: ${backup_dir#$SCRIPT_DIR/}${RESET}"
    fi

    if [[ ${#new_conf_keys[@]} -gt 0 ]]; then
        echo ""
        echo -e "${YELLOW}Note: Upstream workspace.conf includes new optional setting(s) not in your workspace.conf:${RESET}"
        printf '  %s\n' "${new_conf_keys[@]}"
    fi

    if [[ $self_update_pending -eq 1 ]]; then
        ensure_backup_file "workspace-repo-tools-updater.sh"
        local staged_self="$tmp_dir/workspace-repo-tools-updater.sh"
        chmod +x "$staged_self"
        # Group replacement + immediate exit so bash never reads mutated file offsets
        {
            cp "$staged_self" "$SCRIPT_DIR/workspace-repo-tools-updater.sh.new.$$"
            chmod +x "$SCRIPT_DIR/workspace-repo-tools-updater.sh.new.$$"
            mv -f "$SCRIPT_DIR/workspace-repo-tools-updater.sh.new.$$" "$SCRIPT_DIR/workspace-repo-tools-updater.sh"
            rm -rf "$tmp_dir"
            echo -e "${GREEN}✓ Upgrade complete ($remote_ver, commit ${remote_sha:0:7}).${RESET}"
            exit 0
        }
    fi

    rm -rf "$tmp_dir"
    trap - EXIT INT TERM
    echo -e "${GREEN}✓ Upgrade complete ($remote_ver, commit ${remote_sha:0:7}).${RESET}"
    return 0
}

# --- CLI Argument Parsing ---
CMD="check"
DRY_RUN=0
AUTO_YES=0
FORCE_FLAG=0
COMMIT_CHECK=0

if [[ $# -gt 0 ]]; then
    case "$1" in
        --banner-check)
            cmd_banner_check "${2:-sync}"
            exit 0
            ;;
        --refresh-cache)
            refresh_cache 3 >/dev/null 2>&1 || true
            exit 0
            ;;
    esac
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        check|upgrade|update|diff|status|version|help|-h|--help)
            CMD="$1"
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -y|--yes)
            AUTO_YES=1
            shift
            ;;
        -f|--force)
            FORCE_FLAG=1
            shift
            ;;
        --commit)
            COMMIT_CHECK=1
            shift
            ;;
        --url)
            if [[ $# -lt 2 || -z "$2" ]]; then
                echo "Option '--url' requires a repository URL." >&2
                exit 1
            fi
            TOOLS_UPSTREAM_URL="$2"
            shift 2
            ;;
        --raw-url)
            if [[ $# -lt 2 || -z "$2" ]]; then
                echo "Option '--raw-url' requires a base URL." >&2
                exit 1
            fi
            TOOLS_RAW_BASE_URL="${2%/}"
            shift 2
            ;;
        --branch)
            if [[ $# -lt 2 || -z "$2" ]]; then
                echo "Option '--branch' requires a branch name." >&2
                exit 1
            fi
            TOOLS_UPSTREAM_BRANCH="$2"
            shift 2
            ;;
        *)
            echo "Unknown option or command: '$1'. Run with 'help' for usage." >&2
            exit 1
            ;;
    esac
done

case "$CMD" in
    check)
        cmd_check "$COMMIT_CHECK"
        ;;
    upgrade|update)
        cmd_upgrade "$DRY_RUN" "$AUTO_YES" "$FORCE_FLAG"
        ;;
    diff)
        cmd_diff
        ;;
    status|version)
        cmd_status
        ;;
    help|-h|--help)
        usage
        ;;
esac
