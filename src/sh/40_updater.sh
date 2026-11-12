# =============================================================================
# library-bundle (Unix / macOS / Linux) - Module: 40_updater.sh
# =============================================================================

UPDATE_CACHE_FILE="$TOOLS_STATE_DIR/update-cache"

write_update_cache() {
    local last_check="$1"
    local last_attempt="$2"
    local remote_ver="$3"
    local update_avail="$4"

    mkdir -p "$TOOLS_STATE_DIR"
    local tmp_cache="${UPDATE_CACHE_FILE}.tmp.$$"
    cat <<EOF > "$tmp_cache"
LAST_CHECK_EPOCH=$last_check
LAST_ATTEMPT_EPOCH=$last_attempt
REMOTE_VERSION=$remote_ver
UPDATE_AVAILABLE=$update_avail
EOF
    mv -f "$tmp_cache" "$UPDATE_CACHE_FILE"
}

fetch_release_meta() {
    local tag_override="${1:-}"
    local dest_file="$2"
    local timeout_secs="${3:-3}"

    local meta_url
    if [[ -n "$tag_override" ]]; then
        meta_url="$RELEASES_BASE_URL/download/$tag_override/release-meta.env"
    else
        meta_url="$RELEASES_BASE_URL/latest/download/release-meta.env"
    fi

    http_fetch_url "$meta_url" "$dest_file" "$timeout_secs"
}

refresh_update_cache() {
    local timeout_secs="${1:-2}"
    local now
    now=$(date +%s)

    local prev_check prev_ver prev_avail
    prev_check=$(read_kv_value "$UPDATE_CACHE_FILE" "LAST_CHECK_EPOCH")
    prev_ver=$(read_kv_value "$UPDATE_CACHE_FILE" "REMOTE_VERSION")
    prev_avail=$(read_kv_value "$UPDATE_CACHE_FILE" "UPDATE_AVAILABLE")
    [[ -z "$prev_check" ]] && prev_check="0"
    [[ -z "$prev_avail" ]] && prev_avail="false"

    local tmp_meta
    tmp_meta=$(mktemp "${TMPDIR:-/tmp}/wrt-meta.XXXXXX")
    if ! fetch_release_meta "" "$tmp_meta" "$timeout_secs"; then
        rm -f "$tmp_meta"
        write_update_cache "$prev_check" "$now" "$prev_ver" "$prev_avail"
        return 1
    fi

    local remote_ver
    remote_ver=$(read_kv_value "$tmp_meta" "VERSION")
    rm -f "$tmp_meta"

    if ! is_valid_semver_string "$remote_ver"; then
        write_update_cache "$prev_check" "$now" "$prev_ver" "$prev_avail"
        return 1
    fi

    if is_version_newer "$remote_ver" "$TOOLS_VERSION"; then
        write_update_cache "$now" "$now" "$remote_ver" "true"
    else
        write_update_cache "$now" "$now" "$remote_ver" "false"
    fi
    return 0
}

print_update_banner() {
    local remote_ver="$1"
    echo ""
    echo -e "  ${YELLOW}🔔 Update available for workspace-repo-tools${RESET} ${CYAN}($TOOLS_VERSION -> $remote_ver)${RESET}"
    echo -e "     Run ${BOLD}./workspace.sh update${RESET} to upgrade."
    echo ""
}

check_for_updates_banner() {
    local mode="${1:---bg}"
    if [[ "$DISABLE_AUTO_UPDATE_CHECK" == "true" || "${WORKSPACE_NO_UPDATE_CHECK:-0}" == "1" || "${WORKSPACE_UPDATE_CHECKED:-0}" == "1" ]]; then
        return 0
    fi

    local now interval_secs
    now=$(date +%s)
    interval_secs=$((UPDATE_CHECK_INTERVAL_HOURS * 3600))

    local last_check="0" last_attempt="0" remote_ver="" update_avail="false"
    if [[ -f "$UPDATE_CACHE_FILE" ]]; then
        local raw_line line k v
        while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
            line="${raw_line//$'\r'/}"
            [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
            k="${line%%=*}"; v="${line#*=}"
            case "$k" in
                LAST_CHECK_EPOCH)   [[ "$v" =~ ^[0-9]+$ ]] && last_check="$v" ;;
                LAST_ATTEMPT_EPOCH) [[ "$v" =~ ^[0-9]+$ ]] && last_attempt="$v" ;;
                REMOTE_VERSION)     remote_ver="$v" ;;
                UPDATE_AVAILABLE)   update_avail="$v" ;;
            esac
        done < "$UPDATE_CACHE_FILE"
    fi

    local needs_refresh=0
    if [[ $last_check -eq 0 || $((now - last_check)) -ge $interval_secs ]]; then
        if [[ $last_attempt -eq 0 || $((now - last_attempt)) -ge 900 ]]; then
            needs_refresh=1
        fi
    fi

    if [[ $needs_refresh -eq 1 ]]; then
        if [[ "$mode" == "--bg" ]]; then
            local self_bundle
            self_bundle=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
            (WORKSPACE_ROOT_DIR="$SCRIPT_DIR" bash "$self_bundle" __refresh-cache >/dev/null 2>&1) &
            disown $! 2>/dev/null || true
        else
            refresh_update_cache 2 >/dev/null 2>&1 || true
            remote_ver=$(read_kv_value "$UPDATE_CACHE_FILE" "REMOTE_VERSION")
            update_avail=$(read_kv_value "$UPDATE_CACHE_FILE" "UPDATE_AVAILABLE")
        fi
    fi

    if [[ "$update_avail" == "true" && -n "$remote_ver" ]] && is_version_newer "$remote_ver" "$TOOLS_VERSION"; then
        print_update_banner "$remote_ver"
    fi
}

cmd_check_update() {
    echo -e "${CYAN}Checking latest release at: $RELEASES_BASE_URL/latest/download/release-meta.env...${RESET}"
    local tmp_meta
    tmp_meta=$(mktemp "${TMPDIR:-/tmp}/wrt-meta.XXXXXX")
    if ! fetch_release_meta "" "$tmp_meta" 8; then
        rm -f "$tmp_meta"
        error "Could not fetch release metadata from $RELEASES_BASE_URL"
        return 1
    fi

    local remote_ver remote_schema schema_notes
    remote_ver=$(read_kv_value "$tmp_meta" "VERSION")
    remote_schema=$(read_kv_value "$tmp_meta" "CONFIG_SCHEMA_VERSION")
    schema_notes=$(read_kv_value "$tmp_meta" "SCHEMA_NOTES")
    rm -f "$tmp_meta"

    if ! is_valid_semver_string "$remote_ver"; then
        error "Invalid release metadata received."
        return 1
    fi

    local now
    now=$(date +%s)

    if is_version_newer "$remote_ver" "$TOOLS_VERSION"; then
        write_update_cache "$now" "$now" "$remote_ver" "true"
        print_update_banner "$remote_ver"
        if [[ -n "$remote_schema" && "$remote_schema" != "$CONFIG_SCHEMA_VERSION" ]]; then
            warning "Config schema update included: $CONFIG_SCHEMA_VERSION -> $remote_schema"
        fi
        if [[ -n "$schema_notes" ]]; then
            echo "  Notes: $schema_notes"
            echo ""
        fi
    else
        write_update_cache "$now" "$now" "$remote_ver" "false"
        success "✓ Up to date (version: $TOOLS_VERSION)"
    fi
    return 0
}

merge_gitignore_from_file() {
    local src_gitignore="$1"
    local dst_gitignore="$SCRIPT_DIR/.gitignore"

    [[ ! -f "$src_gitignore" ]] && return 0

    if [[ ! -f "$dst_gitignore" ]]; then
        cp "$src_gitignore" "$dst_gitignore"
        echo "  + Created .gitignore"
        return 0
    fi

    local missing_lines=()
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        local line trimmed
        line=$(printf '%s' "$raw_line" | tr -d '\r')
        trimmed=$(trim_ws "$line")
        [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
        if ! grep -Fqx "$line" "$dst_gitignore" 2>/dev/null; then
            missing_lines+=("$line")
        fi
    done < "$src_gitignore"

    if [[ ${#missing_lines[@]} -gt 0 ]]; then
        {
            printf '\n# Added by workspace-repo-tools update\n'
            printf '%s\n' "${missing_lines[@]}"
        } >> "$dst_gitignore"
        echo "  ~ Updated .gitignore (+${#missing_lines[@]} rule(s))"
    else
        echo "  = .gitignore already up to date"
    fi
}

inspect_config_schema_changes() {
    local stage_dir="$1"
    local remote_schema="$2"
    local schema_notes="$3"
    local warnings=()

    if [[ -n "$remote_schema" && "$remote_schema" != "$CONFIG_SCHEMA_VERSION" ]]; then
        warnings+=("CONFIG_SCHEMA_VERSION changed ($CONFIG_SCHEMA_VERSION -> $remote_schema).")
    fi
    [[ -n "$schema_notes" ]] && warnings+=("Release schema notes: $schema_notes")

    # Check for new keys in workspace.conf.default
    if [[ -f "$stage_dir/workspace.conf.default" && -f "$WORKSPACE_CONF" ]]; then
        while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
            local line k
            line=$(printf '%s' "$raw_line" | tr -d '\r')
            line=$(trim_ws "$line")
            [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
            k=$(trim_ws "${line%%=*}")
            if ! grep -Eq "^[[:space:]]*$k[[:space:]]*=" "$WORKSPACE_CONF" 2>/dev/null; then
                warnings+=("workspace.conf is missing new key: $line")
            fi
        done < "$stage_dir/workspace.conf.default"
    fi

    # Check header compatibility for repos.csv & services.csv
    if [[ -f "$stage_dir/services.csv.default" && -f "$SERVICES_CSV" ]]; then
        local exp_svc cur_svc
        exp_svc=$(grep -v -E '^[[:space:]]*(#|$)' "$stage_dir/services.csv.default" | head -n 1 | tr -d '\r ')
        cur_svc=$(grep -v -E '^[[:space:]]*(#|$)' "$SERVICES_CSV" | head -n 1 | tr -d '\r ')
        if [[ -n "$exp_svc" && "$exp_svc" != "$cur_svc" ]]; then
            warnings+=("services.csv header differs from latest schema. Expected: $exp_svc")
        fi
    fi

    if [[ -f "$stage_dir/repos.csv.default" && -f "$REPOS_CSV" ]]; then
        local exp_rep cur_rep
        exp_rep=$(grep -v -E '^[[:space:]]*(#|$)' "$stage_dir/repos.csv.default" | head -n 1 | tr -d '\r ')
        cur_rep=$(grep -v -E '^[[:space:]]*(#|$)' "$REPOS_CSV" | head -n 1 | tr -d '\r ')
        if [[ -n "$exp_rep" && "$exp_rep" != "$cur_rep" && "$cur_rep" != "url,path" ]]; then
            warnings+=("repos.csv header differs from latest schema. Expected: $exp_rep")
        fi
    fi

    if [[ ${#warnings[@]} -gt 0 ]]; then
        echo ""
        warning "⚠️  Config structure updates detected — please review your config files:"
        local w
        for w in "${warnings[@]}"; do
            echo "   - $w"
        done
    fi
}

cmd_update() {
    local dry_run=0 auto_yes=0 force_flag=0 target_tag=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)  dry_run=1; shift ;;
            -y|--yes)   auto_yes=1; shift ;;
            -f|--force) force_flag=1; shift ;;
            --version)
                [[ $# -lt 2 || -z "$2" ]] && { error "Option '--version' requires a version or tag (e.g. 1.1.0 or v1.1.0)."; return 1; }
                target_tag="$2"
                [[ "$target_tag" != v* ]] && target_tag="v$target_tag"
                shift 2
                ;;
            *)
                error "Unknown update option: $1"
                return 1
                ;;
        esac
    done

    # 1. Strict Git preflight checks (1: git installed, 2: git repo root, 3: clean working tree)
    check_git_clean_repo "$SCRIPT_DIR" || return 1

    local stage_dir
    stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrt-update.XXXXXX")

    local rc=0
    _cmd_update_with_stage "$stage_dir" "$dry_run" "$auto_yes" "$force_flag" "$target_tag" || rc=$?
    rm -rf "$stage_dir"
    return "$rc"
}

_cmd_update_with_stage() {
    local stage_dir="$1"
    local dry_run="$2"
    local auto_yes="$3"
    local force_flag="$4"
    local target_tag="$5"

    echo -e "${CYAN}Checking release metadata...${RESET}"
    if ! fetch_release_meta "$target_tag" "$stage_dir/release-meta.env" 10; then
        error "Failed to fetch release metadata from $RELEASES_BASE_URL"
        return 1
    fi

    local remote_ver remote_tag remote_schema schema_notes
    remote_ver=$(read_kv_value "$stage_dir/release-meta.env" "VERSION")
    remote_tag=$(read_kv_value "$stage_dir/release-meta.env" "TAG")
    remote_schema=$(read_kv_value "$stage_dir/release-meta.env" "CONFIG_SCHEMA_VERSION")
    schema_notes=$(read_kv_value "$stage_dir/release-meta.env" "SCHEMA_NOTES")
    [[ -z "$remote_tag" ]] && remote_tag="v$remote_ver"

    if ! is_valid_semver_string "$remote_ver"; then
        error "Invalid VERSION in release-meta.env: '$remote_ver'"
        return 1
    fi

    if [[ $force_flag -eq 0 && -z "$target_tag" ]] && ! is_version_newer "$remote_ver" "$TOOLS_VERSION"; then
        local now
        now=$(date +%s)
        write_update_cache "$now" "$now" "$remote_ver" "false"
        success "✓ Already up to date (version: $TOOLS_VERSION)."
        return 0
    fi

    local dl_base="$RELEASES_BASE_URL/download/$remote_tag"
    echo -e "${CYAN}Downloading release $remote_tag ($dl_base)...${RESET}"

    http_fetch_url "$dl_base/SHA256SUMS.txt" "$stage_dir/SHA256SUMS.txt" 10 || true

    local bundle_sh="library-bundle-${remote_ver}.sh"
    local bundle_ps1="library-bundle-${remote_ver}.ps1"
    local bundle_bat="library-bundle-${remote_ver}.bat"

    local f
    for f in workspace.sh workspace.ps1 workspace.bat "$bundle_sh" "$bundle_ps1" "$bundle_bat"; do
        if ! http_fetch_url "$dl_base/$f" "$stage_dir/$f" 20; then
            error "Failed to download release asset: $dl_base/$f"
            return 1
        fi
        verify_sha256_manifest "$stage_dir/SHA256SUMS.txt" "$stage_dir/$f" "$f" || return 1
    done

    for f in gitignore.default workspace.conf.default repos.csv.default services.csv.default; do
        http_fetch_url "$dl_base/$f" "$stage_dir/$f" 10 || true
        verify_sha256_manifest "$stage_dir/SHA256SUMS.txt" "$stage_dir/$f" "$f" || return 1
    done

    echo ""
    echo -e "${BOLD}Update Plan:${RESET} $TOOLS_VERSION -> $remote_ver"
    echo "  ~ workspace.sh, workspace.ps1, workspace.bat"
    echo "  ~ .workspace-tools/$bundle_sh, $bundle_ps1, $bundle_bat"
    echo "  ~ workspace.conf (TOOLS_VERSION=$remote_ver, CONFIG_SCHEMA_VERSION=${remote_schema:-$CONFIG_SCHEMA_VERSION})"
    echo "  ~ .gitignore (merged from latest release)"
    echo "  = Preserved user files: repos.csv, services.csv, custom workspace.conf settings, $WORKSPACE_REL_DIR/"
    echo ""

    if [[ $dry_run -eq 1 ]]; then
        inspect_config_schema_changes "$stage_dir" "$remote_schema" "$schema_notes"
        info "Dry run complete. No files were modified."
        return 0
    fi

    if [[ $auto_yes -eq 0 ]]; then
        printf "Proceed with update? [y/N] "
        read -r reply
        case "$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')" in
            y|yes) ;;
            *) echo "Update cancelled."; return 0 ;;
        esac
    fi

    # Install new versioned bundles and clean up older bundles
    mkdir -p "$TOOLS_STATE_DIR"
    find "$TOOLS_STATE_DIR" -maxdepth 1 -name 'library-bundle-*' -exec rm -f {} + 2>/dev/null || true

    cp "$stage_dir/$bundle_sh" "$TOOLS_STATE_DIR/$bundle_sh"
    cp "$stage_dir/$bundle_ps1" "$TOOLS_STATE_DIR/$bundle_ps1"
    cp "$stage_dir/$bundle_bat" "$TOOLS_STATE_DIR/$bundle_bat"
    chmod +x "$TOOLS_STATE_DIR/$bundle_sh"

    # Update .gitignore
    merge_gitignore_from_file "$stage_dir/gitignore.default"

    # Check schema before updating CONFIG_SCHEMA_VERSION in workspace.conf
    inspect_config_schema_changes "$stage_dir" "$remote_schema" "$schema_notes"

    # Update version fields in workspace.conf cleanly
    set_kv_value "$WORKSPACE_CONF" "TOOLS_VERSION" "$remote_ver"
    if [[ -n "$remote_schema" ]]; then
        set_kv_value "$WORKSPACE_CONF" "CONFIG_SCHEMA_VERSION" "$remote_schema"
    fi

    # Update unified wrappers
    cp "$stage_dir/workspace.ps1" "$SCRIPT_DIR/workspace.ps1"
    cp "$stage_dir/workspace.bat" "$SCRIPT_DIR/workspace.bat"
    cp "$stage_dir/workspace.sh" "$SCRIPT_DIR/workspace.sh.new.$$"
    chmod +x "$SCRIPT_DIR/workspace.sh.new.$$"
    mv -f "$SCRIPT_DIR/workspace.sh.new.$$" "$SCRIPT_DIR/workspace.sh"

    local now
    now=$(date +%s)
    write_update_cache "$now" "$now" "$remote_ver" "false"

    rm -rf "$stage_dir"

    echo ""
    success "✓ Updated workspace-repo-tools integration to version $remote_ver!"
    echo ""
    echo "Next steps:"
    echo "  1. Verify your workspace (e.g., run './workspace.sh status' and './workspace.sh repo-status')"
    echo "  2. Update workspace.conf / repos.csv / services.csv if any schema notices appeared above"
    echo "  3. Commit the integration update with:"
    echo "     git add workspace.sh workspace.ps1 workspace.bat workspace.conf .gitignore"
    echo "     git commit -m \"update integration of $TOOLS_REPO_URL to version : $remote_ver\""
    echo ""
    exit 0
}

