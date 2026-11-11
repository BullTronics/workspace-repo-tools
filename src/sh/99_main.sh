# =============================================================================
# library-bundle (Unix / macOS / Linux) - Module: 99_main.sh
# =============================================================================

write_unified_banner() {
    echo -e "\033[1;36m"
    echo "  ===================================================="
    echo "    $WORKSPACE_NAME - Workspace Control (v$TOOLS_VERSION)"
    echo "  ===================================================="
    echo -e "\033[0m"
}

show_unified_menu() {
    local avail
    avail=$(available_services_csv)
    echo -e "  \033[1;35mRepository Commands:\033[0m"
    echo -e "    \033[1;37mclone                         \033[0;37m- Clone repositories from repos.csv\033[0m"
    echo -e "    \033[1;37mpull [args...]                \033[0;37m- Pull updates across repositories\033[0m"
    echo -e "    \033[1;37mfetch [args...]               \033[0;37m- Fetch remotes across repositories\033[0m"
    echo -e "    \033[1;37mrepo-status [-all | <repo>]   \033[0;37m- Show Git status across repositories\033[0m"
    echo -e "    \033[1;37mlog / branch / checkout       \033[0;37m- Inspect or switch branches across repos\033[0m"
    echo -e "    \033[1;37mexec <git-cmd> [args...]      \033[0;37m- Run an arbitrary Git command across repos\033[0m"
    echo -e "    \033[1;37m--repo <name> <git-cmd>       \033[0;37m- Filter repository Git command to <name>\033[0m"
    echo ""
    echo -e "  \033[1;35mService Commands:\033[0m"
    echo -e "    \033[1;37mstart [svc] [--bg]            \033[0;37m- Start all or single service ($avail)\033[0m"
    echo -e "    \033[1;37mstop [svc]                    \033[0;37m- Stop all or single service\033[0m"
    echo -e "    \033[1;37mrestart [svc] [--bg]          \033[0;37m- Restart all or single service\033[0m"
    echo -e "    \033[1;31mforce-stop                    \033[0;37m- Kill all services & orphaned processes\033[0m"
    echo -e "    \033[1;37mstatus                        \033[0;37m- Show service status\033[0m"
    echo -e "    \033[1;37mlogs <svc> [lines]            \033[0;37m- Show background log output\033[0m"
    echo ""
    echo -e "  \033[1;35mWorkspace Tools:\033[0m"
    echo -e "    \033[1;37mcheck-update                  \033[0;37m- Check for new workspace-repo-tools release\033[0m"
    echo -e "    \033[1;37mupdate [--dry-run] [--yes]    \033[0;37m- Update workspace integration from release\033[0m"
    echo -e "    \033[1;37mversion                       \033[0;37m- Show configured tools & schema version\033[0m"
    echo -e "    \033[1;37mquit / exit / q               \033[0;37m- Stop active services and exit\033[0m"
    echo ""
}

has_active_pids() {
    local f
    for f in "$SCRIPT_DIR/.pids/"*.pid; do
        [[ -e "$f" ]] && return 0
    done
    return 1
}

dispatch_git_command() {
    local repo_filter=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--repo)
                [[ $# -lt 2 || -z "$2" ]] && { error "Option '$1' requires a repository name."; return 1; }
                repo_filter="$2"; shift 2
                ;;
            --repo=*)
                repo_filter="${1#--repo=}"
                [[ -z "$repo_filter" ]] && { error "Option '--repo=' requires a repository name."; return 1; }
                shift
                ;;
            *) break ;;
        esac
    done

    [[ $# -eq 0 ]] && { show_unified_menu; return 0; }
    local gcmd
    gcmd=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    shift

    case "$gcmd" in
        clone)
            [[ $# -ne 0 ]] && { error "Usage: ./workspace.sh [--repo <name>] clone"; return 1; }
            run_git_repositories "$repo_filter" clone
            ;;
        pull|fetch)
            run_git_repositories "$repo_filter" "$gcmd" "$@"
            ;;
        repo-status|repos|status)
            status_git_repositories "$repo_filter" "$@"
            ;;
        log)
            run_git_repositories "$repo_filter" log --oneline -1 "$@"
            ;;
        branch)
            run_git_repositories "$repo_filter" branch --show-current "$@"
            ;;
        checkout)
            [[ $# -ne 1 ]] && { error "Usage: ./workspace.sh [--repo <name>] checkout <branch>"; return 1; }
            run_git_repositories "$repo_filter" checkout "$1"
            ;;
        exec)
            [[ $# -eq 0 ]] && { error "Usage: ./workspace.sh [--repo <name>] exec <git-command> [args...]"; return 1; }
            run_git_repositories "$repo_filter" "$@"
            ;;
        *)
            error "Unknown git subcommand: '$gcmd'"
            return 1
            ;;
    esac
}

dispatch_workspace_command() {
    local raw_cmd="$1"
    local cmd
    cmd=$(printf '%s' "$raw_cmd" | tr '[:upper:]' '[:lower:]')
    shift

    case "$cmd" in
        -r|--repo|--repo=*)
            dispatch_git_command "$raw_cmd" "$@"
            ;;
        git)
            if [[ $# -eq 0 ]]; then
                show_unified_menu
            else
                dispatch_git_command "$@"
            fi
            ;;
        clone|pull|fetch|repo-status|repos|log|branch|checkout|exec)
            dispatch_git_command "$cmd" "$@"
            ;;
        start)
            parse_target_and_mode "${1:-}" "${2:-}"
            local rc=0
            if [[ -z "$PARSED_TARGET" ]]; then
                start_all_services "$PARSED_MODE" || rc=1
            else
                start_service_by_name "$PARSED_TARGET" "$PARSED_MODE" || rc=1
            fi
            write_service_status
            return "$rc"
            ;;
        stop)
            local rc=0
            if [[ -z "${1:-}" || "${1:-}" == "all" ]]; then
                stop_all_services
            else
                stop_service_by_name "$1" || rc=1
            fi
            write_service_status
            return "$rc"
            ;;
        restart)
            parse_target_and_mode "${1:-}" "${2:-}"
            local rc=0
            if [[ -z "$PARSED_TARGET" ]]; then
                stop_all_services
                sleep 1
                start_all_services "$PARSED_MODE" || rc=1
            else
                restart_service_by_name "$PARSED_TARGET" "$PARSED_MODE" || rc=1
            fi
            write_service_status
            return "$rc"
            ;;
        force-stop)
            force_stop_all_services
            ;;
        status)
            write_service_status
            ;;
        logs)
            show_service_logs "${1:-}" "${2:-20}"
            ;;
        check-update|update-check)
            cmd_check_update
            ;;
        update|upgrade)
            cmd_update "$@"
            ;;
        version)
            echo "workspace-repo-tools v$TOOLS_VERSION (schema: $CONFIG_SCHEMA_VERSION, bundle: $BUNDLE_VERSION)"
            ;;
        help|-h|--help)
            write_unified_banner
            check_for_updates_banner "--bg"
            show_unified_menu
            ;;
        *)
            error "Unknown command: '$raw_cmd'. Run './workspace.sh help' for usage."
            return 1
            ;;
    esac
}

# --- Internal Hooks ---
if [[ $# -gt 0 ]]; then
    case "$1" in
        __run-service)
            run_service_entrypoint "${2:-}"
            exit $?
            ;;
        __refresh-cache)
            refresh_update_cache 3 >/dev/null 2>&1 || true
            exit 0
            ;;
    esac
fi

# --- Direct CLI Mode ---
if [[ $# -gt 0 ]]; then
    dispatch_workspace_command "$@"
    rc=$?
    first_lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$first_lc" in
        help|-h|--help|check-update|update-check|update|upgrade|version) ;;
        *) check_for_updates_banner "--bg" ;;
    esac
    exit "$rc"
fi

# --- Interactive REPL Mode ---
cleanup_repl() {
    echo ""
    if has_active_pids; then
        stop_all_services
    fi
    echo -e "  \033[1;36mGoodbye!\033[0m"
    exit 0
}
trap cleanup_repl INT TERM

write_unified_banner
check_for_updates_banner "sync"
export WORKSPACE_UPDATE_CHECKED=1
show_unified_menu

while true; do
    echo -ne "  \033[1;36m${WORKSPACE_PROMPT}> \033[0m"
    if ! read -r input_line; then
        cleanup_repl
    fi

    input_line=$(trim_ws "$input_line")
    [[ -z "$input_line" ]] && continue

    set -f
    # shellcheck disable=SC2086
    set -- $input_line
    set +f

    first_lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    if [[ "$first_lc" == "quit" || "$first_lc" == "exit" || "$first_lc" == "q" ]]; then
        if has_active_pids; then
            stop_all_services
        fi
        echo -e "  \033[1;36mGoodbye!\033[0m"
        echo ""
        exit 0
    fi

    dispatch_workspace_command "$@" || true
done

