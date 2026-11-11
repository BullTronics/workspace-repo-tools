# =============================================================================
# library-bundle (Unix / macOS / Linux) - Module: 20_git.sh
# =============================================================================

check_git_dependency() {
    if ! command -v git >/dev/null 2>&1; then
        error "Git was not found. Please install Git and make sure it is in PATH."
        exit 1
    fi
}

run_git_repositories() {
    check_git_dependency
    local repo_filter="$1"
    shift
    local command_name="$1"
    shift

    local tmp_rows
    tmp_rows="${TMPDIR:-/tmp}/workspace-git-$$.tmp"
    trap 'rm -f "$tmp_rows"' EXIT HUP INT TERM

    prepare_repos_rows "$tmp_rows"

    local total=0 matched=0 successful=0 skipped=0 failed=0

    while IFS=',' read -r raw_url raw_path raw_branch _extra; do
        local url path branch
        url=$(trim_ws "$raw_url")
        path=$(trim_ws "$raw_path")
        branch=$(trim_ws "${raw_branch:-}")

        [[ -z "$url" && -z "$path" ]] && continue
        total=$((total + 1))

        if [[ -z "$url" ]]; then
            error "Row $total: missing URL."
            failed=$((failed + 1))
            continue
        fi

        if ! validate_rel_path "$path" "$total"; then
            failed=$((failed + 1))
            continue
        fi

        if ! matches_repo_filter "$path" "$repo_filter"; then
            continue
        fi

        matched=$((matched + 1))
        local repo_path="$WORKSPACE_DIR/$path"

        printf '\n'
        printf '%s\n' "============================================================"
        printf '%s\n' "Repository : $path"
        printf '%s\n' "URL        : $url"
        if [[ -n "$branch" && "$command_name" == "clone" ]]; then
            printf '%s\n' "Branch     : $branch"
        fi
        printf '%s\n' "============================================================"

        if [[ "$command_name" == "clone" ]]; then
            if [[ -e "$repo_path" ]]; then
                if git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
                    warning "Already cloned. Skipping."
                    skipped=$((skipped + 1))
                    continue
                fi
                error "Path exists but is not a Git repository: $repo_path"
                failed=$((failed + 1))
                continue
            fi

            local parent_dir
            parent_dir=$(dirname "$repo_path")
            if ! mkdir -p "$parent_dir"; then
                error "Could not create parent directory: $parent_dir"
                failed=$((failed + 1))
                continue
            fi

            info "Cloning..."
            if [[ -n "$branch" ]]; then
                if git clone -b "$branch" "$url" "$repo_path"; then
                    success "✓ Clone successful"
                    successful=$((successful + 1))
                else
                    error "✗ Clone failed"
                    failed=$((failed + 1))
                fi
            else
                if git clone "$url" "$repo_path"; then
                    success "✓ Clone successful"
                    successful=$((successful + 1))
                else
                    error "✗ Clone failed"
                    failed=$((failed + 1))
                fi
            fi
            continue
        fi

        if ! git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
            warning "Repository not found: $repo_path"
            warning "Run './workspace.sh clone' first."
            skipped=$((skipped + 1))
            continue
        fi

        info "Running: git $command_name $*"
        if git -C "$repo_path" "$command_name" "$@"; then
            success "✓ Success"
            successful=$((successful + 1))
        else
            error "✗ Failed"
            failed=$((failed + 1))
        fi
    done < "$tmp_rows"

    rm -f "$tmp_rows"
    trap - EXIT HUP INT TERM

    if [[ -n "$repo_filter" && $matched -eq 0 ]]; then
        error "No repository matching '$repo_filter' found in repos.csv."
        return 1
    fi

    printf '\n'
    printf '%s\n' "============================================================"
    printf '%s\n' "Summary"
    printf '%s\n' "============================================================"
    printf 'Matched    : %s\n' "$matched"
    printf 'Successful : %s\n' "$successful"
    printf 'Skipped    : %s\n' "$skipped"
    printf 'Failed     : %s\n' "$failed"

    [[ $failed -eq 0 ]]
}

status_git_repositories() {
    check_git_dependency
    local repo_filter="$1"
    shift

    local target_repo="$repo_filter"
    local show_all=0

    if [[ $# -gt 0 ]]; then
        if [[ "$1" == "-all" || "$1" == "--all" ]]; then
            show_all=1
        else
            target_repo="$1"
        fi
    fi

    local tmp_rows
    tmp_rows="${TMPDIR:-/tmp}/workspace-git-$$.tmp"
    trap 'rm -f "$tmp_rows"' EXIT HUP INT TERM
    prepare_repos_rows "$tmp_rows"

    local repo_found=0 row_num=0

    while IFS=',' read -r raw_url raw_path _raw_branch _extra; do
        local url path
        url=$(trim_ws "$raw_url")
        path=$(trim_ws "$raw_path")
        [[ -z "$url" && -z "$path" ]] && continue
        row_num=$((row_num + 1))
        validate_rel_path "$path" "$row_num" >/dev/null 2>&1 || continue

        local repo_path="$WORKSPACE_DIR/$path"

        if [[ -n "$target_repo" ]]; then
            matches_repo_filter "$path" "$target_repo" || continue
            repo_found=$((repo_found + 1))

            printf '\n'
            printf '%s\n' "============================================================"
            printf '%s\n' "Repository : $path"
            printf '%s\n' "URL        : $url"
            printf '%s\n' "============================================================"

            if ! git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
                warning "Repository not found: $repo_path"
                warning "Run './workspace.sh clone' first."
                continue
            fi

            info "Running: git status"
            git -C "$repo_path" status || error "✗ Failed"
            continue
        fi

        if ! git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
            if [[ $show_all -eq 1 ]]; then
                printf '%s\n' "$path - not cloned"
            fi
            continue
        fi

        local status_info
        status_info=$(git -C "$repo_path" status -sb --porcelain 2>/dev/null | awk '
            BEGIN { branch="unknown"; ahead=0; behind=0; updated=0; new=0; untracked=0; deleted=0; renamed=0 }
            { sub(/\r$/, "", $0) }
            /^## / {
                br = $2; split(br, parts, "\\.\\.\\."); branch = parts[1]
                if ($0 ~ /ahead [0-9]+/)  { match($0, /ahead [0-9]+/);  split(substr($0, RSTART, RLENGTH), a, " "); ahead = a[2] }
                if ($0 ~ /behind [0-9]+/) { match($0, /behind [0-9]+/); split(substr($0, RSTART, RLENGTH), b, " "); behind = b[2] }
                next
            }
            /^ M|^M / { updated++ }
            /^ A|^A / { new++ }
            /^\?\?/   { untracked++ }
            /^ D|^D / { deleted++ }
            /^ R|^R / { renamed++ }
            END {
                has = (updated>0 || new>0 || untracked>0 || deleted>0 || renamed>0 || ahead>0 || behind>0)
                printf "%s|%d|%d|%d|%d|%d|%d|%d|%d\n", branch, ahead, behind, updated, new, untracked, deleted, renamed, has
            }
        ')

        local branch ahead behind updated new untracked deleted renamed has_changes
        IFS='|' read -r branch ahead behind updated new untracked deleted renamed has_changes <<EOF
$status_info
EOF

        if [[ "$has_changes" -eq 0 && "$show_all" -eq 0 ]]; then
            continue
        fi

        local out_line="$path - $branch"
        if [[ "$has_changes" -eq 0 ]]; then
            out_line="$out_line - uptodate"
        else
            [[ "$ahead" -gt 0 ]]     && out_line="$out_line - ahead $ahead"
            [[ "$behind" -gt 0 ]]    && out_line="$out_line - behind $behind"
            [[ "$updated" -gt 0 ]]   && out_line="$out_line - $updated updated files"
            [[ "$new" -gt 0 ]]       && out_line="$out_line - $new new files"
            [[ "$untracked" -gt 0 ]] && out_line="$out_line - $untracked untracked files"
            [[ "$deleted" -gt 0 ]]   && out_line="$out_line - $deleted deleted files"
            [[ "$renamed" -gt 0 ]]   && out_line="$out_line - $renamed renamed files"
        fi
        printf '%s\n' "$out_line"
    done < "$tmp_rows"

    rm -f "$tmp_rows"
    trap - EXIT HUP INT TERM

    if [[ -n "$target_repo" && $repo_found -eq 0 ]]; then
        error "No repository matching '$target_repo' found."
        return 1
    fi
    return 0
}

