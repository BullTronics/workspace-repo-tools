#!/bin/bash
# =============================================================================
# Unified Workspace Entrypoint (Unix / macOS / Linux)
# Delegates Git multi-repo actions to git-all.sh and service actions to run-local.sh.
# =============================================================================

cd "$(dirname "$0")" || exit 1
SCRIPT_DIR=$(pwd)

WORKSPACE_CONF="$SCRIPT_DIR/workspace.conf"
GIT_ALL="$SCRIPT_DIR/git-all.sh"
RUN_LOCAL="$SCRIPT_DIR/run-local.sh"
UPDATER="$SCRIPT_DIR/workspace-repo-tools-updater.sh"

WORKSPACE_NAME="Workspace"
WORKSPACE_PROMPT="workspace"

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

load_branding() {
    [[ ! -f "$WORKSPACE_CONF" ]] && return 0
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        local line
        line=$(printf '%s' "$raw_line" | tr -d '\r')
        line=$(trim_ws "$line")
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" == *=* ]]; then
            local key="${line%%=*}"
            local val="${line#*=}"
            key=$(trim_ws "$key")
            val=$(trim_ws "$val")
            val=$(strip_outer_quotes "$val")
            case "$key" in
                WORKSPACE_NAME)   [[ -n "$val" ]] && WORKSPACE_NAME="$val" ;;
                WORKSPACE_PROMPT) [[ -n "$val" ]] && WORKSPACE_PROMPT="$val" ;;
            esac
        fi
    done < "$WORKSPACE_CONF"
}

load_branding

write_banner() {
    echo -e "\033[1;36m"
    echo "  ===================================================="
    echo "    $WORKSPACE_NAME - Workspace Control"
    echo "  ===================================================="
    echo -e "\033[0m"
}

check_for_updates_banner() {
    local mode="${1:---bg}"
    if [[ "${WORKSPACE_UPDATE_CHECKED:-0}" == "1" ]]; then
        return 0
    fi
    if [[ -f "$UPDATER" ]]; then
        bash "$UPDATER" --banner-check "$mode" || true
    fi
}

show_menu() {
    echo -e "  \033[1;35mRepository Commands (git-all.sh):\033[0m"
    echo -e "    \033[1;37mclone                         \033[0;37m- Clone repositories from repos.csv\033[0m"
    echo -e "    \033[1;37mpull [args...]                \033[0;37m- Pull updates across repositories\033[0m"
    echo -e "    \033[1;37mfetch [args...]               \033[0;37m- Fetch remotes across repositories\033[0m"
    echo -e "    \033[1;37mrepo-status [-all | <repo>]   \033[0;37m- Show Git status across repositories\033[0m"
    echo -e "    \033[1;37mlog / branch / checkout       \033[0;37m- Inspect or switch branches across repos\033[0m"
    echo -e "    \033[1;37mexec <git-cmd> [args...]      \033[0;37m- Run an arbitrary Git command across repos\033[0m"
    echo -e "    \033[1;37mgit <git-all-args...>         \033[0;37m- Pass any flags/command directly to git-all.sh\033[0m"
    echo ""
    echo -e "  \033[1;35mService Commands (run-local.sh):\033[0m"
    echo -e "    \033[1;37mstart [svc] [--bg]            \033[0;37m- Start all or a single service\033[0m"
    echo -e "    \033[1;37mstop [svc]                    \033[0;37m- Stop all or a single service\033[0m"
    echo -e "    \033[1;37mrestart [svc] [--bg]          \033[0;37m- Restart all or a single service\033[0m"
    echo -e "    \033[1;31mforce-stop                    \033[0;37m- Force stop all services & orphaned processes\033[0m"
    echo -e "    \033[1;37mstatus                        \033[0;37m- Show running service status\033[0m"
    echo -e "    \033[1;37mlogs <svc> [lines]            \033[0;37m- Show background log output\033[0m"
    echo ""
    echo -e "  \033[1;35mWorkspace Tooling:\033[0m"
    echo -e "    \033[1;37mcheck-update                  \033[0;37m- Check for workspace-repo-tools updates\033[0m"
    echo -e "    \033[1;37mupgrade [--dry-run] [--yes]   \033[0;37m- Upgrade workspace tooling from upstream\033[0m"
    echo -e "    \033[1;37mquit / exit / q               \033[0;37m- Stop active services and exit\033[0m"
    echo ""
}

has_active_pids() {
    local f
    for f in "$SCRIPT_DIR/.pids/"*.pid; do
        if [[ -e "$f" ]]; then
            return 0
        fi
    done
    return 1
}

dispatch_command() {
    local cmd_raw="$1"
    shift
    local cmd
    cmd=$(printf '%s' "$cmd_raw" | tr '[:upper:]' '[:lower:]')

    case "$cmd" in
        -r|--repo|--repo=*)
            sh "$GIT_ALL" "$cmd_raw" "$@"
            ;;
        git)
            if [[ $# -eq 0 ]]; then
                sh "$GIT_ALL" help
            else
                sh "$GIT_ALL" "$@"
            fi
            ;;
        clone|pull|fetch|log|branch|checkout|exec)
            sh "$GIT_ALL" "$cmd" "$@"
            ;;
        repo-status|repos)
            sh "$GIT_ALL" status "$@"
            ;;
        start|stop|restart|force-stop|status|logs)
            bash "$RUN_LOCAL" "$cmd" "$@"
            ;;
        check-update|update-check)
            bash "$UPDATER" check "$@"
            ;;
        upgrade|update)
            bash "$UPDATER" upgrade "$@"
            ;;
        help|-h|--help)
            write_banner
            check_for_updates_banner "--bg"
            show_menu
            ;;
        *)
            echo -e "  \033[1;31mUnknown command: '$cmd_raw'. Use 'help' for available commands.\033[0m" >&2
            return 1
            ;;
    esac
}

# --- Direct CLI Mode ---
if [[ $# -gt 0 ]]; then
    dispatch_command "$@"
    rc=$?
    first_cli=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$first_cli" in
        start|stop|restart|force-stop|status|logs|help|-h|--help|check-update|update-check|upgrade|update)
            ;;
        *)
            check_for_updates_banner "--bg"
            ;;
    esac
    exit "$rc"
fi

# --- Interactive REPL Mode ---
cleanup_repl() {
    echo ""
    if has_active_pids; then
        bash "$RUN_LOCAL" stop
    fi
    echo -e "  \033[1;36mGoodbye!\033[0m"
    exit 0
}
trap cleanup_repl INT TERM

write_banner
check_for_updates_banner "sync"
export WORKSPACE_UPDATE_CHECKED=1
show_menu

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
            bash "$RUN_LOCAL" stop
        fi
        echo -e "  \033[1;36mGoodbye!\033[0m"
        echo ""
        exit 0
    fi

    dispatch_command "$@" || true
done

