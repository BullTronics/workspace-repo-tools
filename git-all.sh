#!/bin/sh

# ============================================================
# git-all.sh
#
# Manage multiple independent Git repositories configured in repos.csv.
#
# Requirements:
#   - Git
#   - POSIX sh + awk
#
# Platforms:
#   - Linux
#   - macOS
#   - Windows Git Bash (or use git-all.bat / git-all.ps1 natively)
# ============================================================

set -u

# ------------------------------------------------------------
# Paths & Workspace Configuration
# ------------------------------------------------------------

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONFIG_FILE="$SCRIPT_DIR/repos.csv"
WORKSPACE_CONF="$SCRIPT_DIR/workspace.conf"

trim() {
    val="$1"
    val=${val#"${val%%[![:space:]]*}"}
    val=${val%"${val##*[![:space:]]}"}
    printf '%s' "$val"
}

strip_quotes() {
    val="$1"
    case "$val" in
        \"*\")
            val=${val#\"}
            val=${val%\"}
            ;;
        \'*\')
            val=${val#\'}
            val=${val%\'}
            ;;
    esac
    printf '%s' "$val"
}

load_workspace_dir() {
    rel_dir="workspace"

    if [ -f "$WORKSPACE_CONF" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line=$(printf '%s' "$line" | tr -d '\r')
            line=$(trim "$line")
            case "$line" in
                ""|\#*)
                    continue
                    ;;
            esac
            case "$line" in
                WORKSPACE_DIR=*)
                    raw_val=${line#WORKSPACE_DIR=}
                    raw_val=$(trim "$raw_val")
                    raw_val=$(strip_quotes "$raw_val")
                    if [ -n "$raw_val" ]; then
                        rel_dir="$raw_val"
                    fi
                    ;;
            esac
        done < "$WORKSPACE_CONF"
    fi

    case "$rel_dir" in
        /*|[A-Za-z]:*|..|../*|*/../*|*/..|*\\*)
            printf '%s\n' "Invalid WORKSPACE_DIR in workspace.conf: $rel_dir" >&2
            exit 1
            ;;
    esac

    WORKSPACE_DIR="$SCRIPT_DIR/$rel_dir"
}

load_workspace_dir

# ------------------------------------------------------------
# Colors
# ------------------------------------------------------------

if [ -t 1 ]; then
    RED=$(printf '\033[31m')
    GREEN=$(printf '\033[32m')
    YELLOW=$(printf '\033[33m')
    BLUE=$(printf '\033[34m')
    RESET=$(printf '\033[0m')
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    RESET=''
fi

# ------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------

info() {
    printf '%s\n' "${BLUE}$*${RESET}"
}

success() {
    printf '%s\n' "${GREEN}$*${RESET}"
}

warning() {
    printf '%s\n' "${YELLOW}$*${RESET}"
}

error() {
    printf '%s\n' "${RED}$*${RESET}" >&2
}

# ------------------------------------------------------------
# Usage
# ------------------------------------------------------------

usage() {
    cat <<EOF
git-all.sh - manage multiple Git repositories

Usage:

  ./git-all.sh [--repo <name>] <command> [args...]

Commands:

  clone                         Clone all repositories from repos.csv
  pull [git-args...]            Run 'git pull' in every repository
  fetch [git-args...]           Run 'git fetch' in every repository
  status [-all | <repository>]  Show concise dirty summary, '-all', or detailed status
  log [git-args...]             Show latest commit from every repository
  branch [git-args...]          Show current branch for every repository
  checkout <branch>             Checkout a branch in every repository
  exec <git-command> [args...]  Run an arbitrary Git command in every repository

Options:

  -r, --repo <name>             Limit command to repositories matching exact path or suffix

Examples:

  ./git-all.sh clone
  ./git-all.sh pull --rebase
  ./git-all.sh fetch --prune
  ./git-all.sh status
  ./git-all.sh status -all
  ./git-all.sh status backend-repo
  ./git-all.sh --repo backend-repo pull
  ./git-all.sh checkout main
  ./git-all.sh exec remote -v

EOF
}

# ------------------------------------------------------------
# Dependency check
# ------------------------------------------------------------

check_dependencies() {
    if ! command -v git >/dev/null 2>&1; then
        error "Git was not found."
        error ""
        error "Please install Git and make sure it is in PATH."
        exit 1
    fi
}

# ------------------------------------------------------------
# Path & CSV Helpers
# ------------------------------------------------------------

validate_rel_path() {
    p="$1"
    row_num="$2"

    if [ -z "$p" ]; then
        error "Row $row_num: missing path."
        return 1
    fi

    case "$p" in
        /*)
            error "Row $row_num: absolute paths are not allowed: $p"
            return 1
            ;;
        [A-Za-z]:*)
            error "Row $row_num: absolute Windows paths are not allowed: $p"
            return 1
            ;;
        *\\*)
            error "Row $row_num: use '/' instead of '\\' in path: $p"
            return 1
            ;;
        ..|../*|*/../*|*/..)
            error "Row $row_num: path escapes workspace: $p"
            return 1
            ;;
    esac

    return 0
}

matches_repo_filter() {
    repo_rel="$1"
    filter="$2"

    if [ -z "$filter" ]; then
        return 0
    fi
    if [ "$repo_rel" = "$filter" ]; then
        return 0
    fi
    case "$repo_rel" in
        */"$filter")
            return 0
            ;;
    esac
    return 1
}

# Strips comments/blank lines, validates header, writes normalized data rows to $1
prepare_repos_rows() {
    out_file="$1"

    if [ ! -f "$CONFIG_FILE" ]; then
        error "repos.csv not found:"
        error "  $CONFIG_FILE"
        exit 1
    fi

    header_found=0
    : > "$out_file"

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        line=$(printf '%s' "$raw_line" | tr -d '\r')
        trimmed=$(trim "$line")

        case "$trimmed" in
            ""|\#*)
                continue
                ;;
        esac

        if [ "$header_found" -eq 0 ]; then
            header_found=1
            normalized_header=$(printf '%s' "$trimmed" | tr -d '[:space:]')
            if [ "$normalized_header" != "url,path" ] && [ "$normalized_header" != "url,path,branch" ]; then
                error "Invalid repos.csv header."
                error ""
                error "Expected:"
                error "  url,path   or   url,path,branch"
                error ""
                error "Found:"
                error "  $trimmed"
                exit 1
            fi
            continue
        fi

        printf '%s\n' "$line" >> "$out_file"
    done < "$CONFIG_FILE"

    if [ "$header_found" -eq 0 ]; then
        error "repos.csv is empty or missing header (url,path[,branch])."
        exit 1
    fi
}

# ------------------------------------------------------------
# Run command across repositories
# ------------------------------------------------------------

run_repositories() {
    repo_filter="$1"
    shift
    command_name="$1"
    shift

    TEMP_FILE="${TMPDIR:-/tmp}/git-all-$$.tmp"

    cleanup() {
        rm -f "$TEMP_FILE"
    }

    trap cleanup EXIT HUP INT TERM

    prepare_repos_rows "$TEMP_FILE"

    total=0
    matched=0
    successful=0
    skipped=0
    failed=0

    while IFS=',' read -r raw_url raw_path raw_branch _extra; do
        url=$(trim "$raw_url")
        path=$(trim "$raw_path")
        branch=$(trim "${raw_branch:-}")

        if [ -z "$url" ] && [ -z "$path" ]; then
            continue
        fi

        total=$((total + 1))

        if [ -z "$url" ]; then
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
        repo_path="$WORKSPACE_DIR/$path"

        printf '\n'
        printf '%s\n' "============================================================"
        printf '%s\n' "Repository : $path"
        printf '%s\n' "URL        : $url"
        if [ -n "$branch" ] && [ "$command_name" = "clone" ]; then
            printf '%s\n' "Branch     : $branch"
        fi
        printf '%s\n' "============================================================"

        if [ "$command_name" = "clone" ]; then
            if [ -e "$repo_path" ]; then
                if git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
                    warning "Already cloned. Skipping."
                    skipped=$((skipped + 1))
                    continue
                fi

                error "Path exists but is not a Git repository:"
                error "  $repo_path"
                failed=$((failed + 1))
                continue
            fi

            parent_dir=$(dirname "$repo_path")
            if ! mkdir -p "$parent_dir"; then
                error "Could not create parent directory:"
                error "  $parent_dir"
                failed=$((failed + 1))
                continue
            fi

            info "Cloning..."
            if [ -n "$branch" ]; then
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
            warning "Repository not found:"
            warning "  $repo_path"
            warning "Run './git-all.sh clone' first."
            skipped=$((skipped + 1))
            continue
        fi

        info "Running:"
        info "  git $command_name $*"

        if git -C "$repo_path" "$command_name" "$@"; then
            success "✓ Success"
            successful=$((successful + 1))
        else
            error "✗ Failed"
            failed=$((failed + 1))
        fi

    done < "$TEMP_FILE"

    cleanup
    trap - EXIT HUP INT TERM

    if [ -n "$repo_filter" ] && [ "$matched" -eq 0 ]; then
        error "No repository matching '$repo_filter' found in repos.csv."
        exit 1
    fi

    printf '\n'
    printf '%s\n' "============================================================"
    printf '%s\n' "Summary"
    printf '%s\n' "============================================================"
    printf 'Matched    : %s\n' "$matched"
    printf 'Successful : %s\n' "$successful"
    printf 'Skipped    : %s\n' "$skipped"
    printf 'Failed     : %s\n' "$failed"

    if [ "$failed" -gt 0 ]; then
        exit 1
    fi
}

# ------------------------------------------------------------
# Show summary or detailed status of repositories
# ------------------------------------------------------------

status_repositories() {
    repo_filter="$1"
    shift

    target_repo="$repo_filter"
    show_all=0

    if [ "$#" -gt 0 ]; then
        if [ "$1" = "-all" ] || [ "$1" = "--all" ]; then
            show_all=1
        else
            target_repo="$1"
        fi
    fi

    TEMP_FILE="${TMPDIR:-/tmp}/git-all-$$.tmp"

    cleanup() {
        rm -f "$TEMP_FILE"
    }

    trap cleanup EXIT HUP INT TERM

    prepare_repos_rows "$TEMP_FILE"

    repo_found=0
    row_num=0

    while IFS=',' read -r raw_url raw_path _raw_branch _extra; do
        url=$(trim "$raw_url")
        path=$(trim "$raw_path")

        if [ -z "$url" ] && [ -z "$path" ]; then
            continue
        fi

        row_num=$((row_num + 1))
        if ! validate_rel_path "$path" "$row_num" >/dev/null 2>&1; then
            continue
        fi

        repo_path="$WORKSPACE_DIR/$path"

        if [ -n "$target_repo" ]; then
            if ! matches_repo_filter "$path" "$target_repo"; then
                continue
            fi

            repo_found=$((repo_found + 1))

            printf '\n'
            printf '%s\n' "============================================================"
            printf '%s\n' "Repository : $path"
            printf '%s\n' "URL        : $url"
            printf '%s\n' "============================================================"

            if ! git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
                warning "Repository not found:"
                warning "  $repo_path"
                warning "Run './git-all.sh clone' first."
                continue
            fi

            info "Running:"
            info "  git status"

            if ! git -C "$repo_path" status; then
                error "✗ Failed"
            fi
            continue
        fi

        if ! git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
            if [ "$show_all" -eq 1 ]; then
                printf '%s\n' "$path - not cloned"
            fi
            continue
        fi

        status_info=$(git -C "$repo_path" status -sb --porcelain 2>/dev/null | awk '
            BEGIN {
                branch = "unknown"
                ahead = 0
                behind = 0
                updated = 0
                new = 0
                untracked = 0
                deleted = 0
                renamed = 0
            }
            {
                sub(/\r$/, "", $0)
            }
            /^## / {
                br = $2
                split(br, parts, "\\.\\.\\.")
                branch = parts[1]

                if ($0 ~ /ahead [0-9]+/) {
                    match($0, /ahead [0-9]+/)
                    ahead_str = substr($0, RSTART, RLENGTH)
                    split(ahead_str, a_parts, " ")
                    ahead = a_parts[2]
                }
                if ($0 ~ /behind [0-9]+/) {
                    match($0, /behind [0-9]+/)
                    behind_str = substr($0, RSTART, RLENGTH)
                    split(behind_str, b_parts, " ")
                    behind = b_parts[2]
                }
                next
            }
            /^ M|^M / { updated++ }
            /^ A|^A / { new++ }
            /^\?\?/   { untracked++ }
            /^ D|^D / { deleted++ }
            /^ R|^R / { renamed++ }
            END {
                has_changes = (updated > 0 || new > 0 || untracked > 0 || deleted > 0 || renamed > 0 || ahead > 0 || behind > 0)
                printf "%s|%d|%d|%d|%d|%d|%d|%d|%d\n", branch, ahead, behind, updated, new, untracked, deleted, renamed, has_changes
            }
        ')

        IFS='|' read -r branch ahead behind updated new untracked deleted renamed has_changes <<EOF
$status_info
EOF

        if [ "$has_changes" -eq 0 ] && [ "$show_all" -eq 0 ]; then
            continue
        fi

        out_line="$path - $branch"
        if [ "$has_changes" -eq 0 ]; then
            out_line="$out_line - uptodate"
        else
            if [ "$ahead" -gt 0 ]; then
                out_line="$out_line - ahead $ahead"
            fi
            if [ "$behind" -gt 0 ]; then
                out_line="$out_line - behind $behind"
            fi
            if [ "$updated" -gt 0 ]; then
                out_line="$out_line - $updated updated files"
            fi
            if [ "$new" -gt 0 ]; then
                out_line="$out_line - $new new files"
            fi
            if [ "$untracked" -gt 0 ]; then
                out_line="$out_line - $untracked untracked files"
            fi
            if [ "$deleted" -gt 0 ]; then
                out_line="$out_line - $deleted deleted files"
            fi
            if [ "$renamed" -gt 0 ]; then
                out_line="$out_line - $renamed renamed files"
            fi
        fi

        printf '%s\n' "$out_line"

    done < "$TEMP_FILE"

    cleanup
    trap - EXIT HUP INT TERM

    if [ -n "$target_repo" ] && [ "$repo_found" -eq 0 ]; then
        error "No repository matching '$target_repo' found."
        exit 1
    fi
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

check_dependencies

REPO_FILTER=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -r|--repo)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                error "Option '$1' requires a repository name or path."
                exit 1
            fi
            REPO_FILTER="$2"
            shift 2
            ;;
        --repo=*)
            REPO_FILTER=${1#--repo=}
            if [ -z "$REPO_FILTER" ]; then
                error "Option '--repo=' requires a repository name or path."
                exit 1
            fi
            shift
            ;;
        *)
            break
            ;;
    esac
done

if [ "$#" -eq 0 ]; then
    usage
    exit 0
fi

COMMAND="$1"
shift

case "$COMMAND" in

    clone)
        if [ "$#" -ne 0 ]; then
            error "Usage: ./git-all.sh [--repo <name>] clone"
            exit 1
        fi
        run_repositories "$REPO_FILTER" clone
        ;;

    pull)
        run_repositories "$REPO_FILTER" pull "$@"
        ;;

    fetch)
        run_repositories "$REPO_FILTER" fetch "$@"
        ;;

    status)
        status_repositories "$REPO_FILTER" "$@"
        ;;

    log)
        run_repositories "$REPO_FILTER" log --oneline -1 "$@"
        ;;

    branch)
        run_repositories "$REPO_FILTER" branch --show-current "$@"
        ;;

    checkout)
        if [ "$#" -ne 1 ]; then
            error "Usage: ./git-all.sh [--repo <name>] checkout <branch>"
            exit 1
        fi
        run_repositories "$REPO_FILTER" checkout "$1"
        ;;

    exec)
        if [ "$#" -eq 0 ]; then
            error "Usage: ./git-all.sh [--repo <name>] exec <git-command> [args...]"
            exit 1
        fi
        run_repositories "$REPO_FILTER" "$@"
        ;;

    help|-h|--help)
        usage
        ;;

    *)
        error "Unknown command: $COMMAND"
        printf '\n'
        usage
        exit 1
        ;;

esac
