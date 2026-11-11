# =============================================================================
# library-bundle (Unix / macOS / Linux) - Module: 30_services.sh
# =============================================================================

ensure_runtime_dirs() {
    mkdir -p "$SCRIPT_DIR/logs" "$SCRIPT_DIR/.runners" "$SCRIPT_DIR/.pids"
}

format_service_label() {
    local emoji="$1"
    local name="$2"
    if [[ -n "$emoji" ]]; then
        printf '%s %s' "$emoji" "$name"
    else
        printf '%s' "$name"
    fi
}

available_services_csv() {
    load_services_csv
    if [[ ${#SVC_NAMES[@]} -eq 0 ]]; then
        printf '(none configured in services.csv)'
        return 0
    fi
    local list="" i
    for ((i = 0; i < ${#SVC_NAMES[@]}; i++)); do
        if [[ -n "$list" ]]; then
            list="$list, ${SVC_NAMES[$i]}"
        else
            list="${SVC_NAMES[$i]}"
        fi
    done
    printf '%s' "$list"
}

get_service_full_path() {
    printf '%s/%s' "$WORKSPACE_ROOT" "$1"
}

get_service_port() {
    local full_path="$1"
    local default_port="$2"
    local env_file="$full_path/.env"
    if [[ -f "$env_file" ]]; then
        local env_port
        env_port=$(grep -E '^[[:space:]]*(export[[:space:]]+)?PORT[[:space:]]*=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2 | tr -d '[:space:]"'\''')
        if [[ -n "$env_port" && "$env_port" =~ ^[0-9]+$ ]]; then
            echo "$env_port"
            return 0
        fi
    fi
    echo "$default_port"
}

get_port_listen_pids() {
    local port="$1"
    [[ -z "$port" ]] && return 0
    if command -v lsof >/dev/null 2>&1; then
        lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null
    elif command -v ss >/dev/null 2>&1; then
        ss -tlnp "sport = :$port" 2>/dev/null | awk 'match($0, /pid=[0-9]+/) { print substr($0, RSTART + 4, RLENGTH - 4) }' | sort -u
    fi
}

get_service_pids() {
    local slug="$1"
    local port="$2"
    local pid_file="$SCRIPT_DIR/.pids/${slug}.pid"
    local pids=()

    if [[ -n "$port" ]]; then
        local port_pids p
        port_pids=$(get_port_listen_pids "$port")
        for p in $port_pids; do
            pids+=("$p")
        done
    fi

    if [[ -f "$pid_file" ]]; then
        local saved_pid
        saved_pid=$(tr -d '[:space:]' < "$pid_file" 2>/dev/null)
        if [[ -n "$saved_pid" ]] && kill -0 "$saved_pid" 2>/dev/null; then
            pids+=("$saved_pid")
        fi
    fi

    if [[ ${#pids[@]} -gt 0 ]]; then
        printf "%s\n" "${pids[@]}" | sort -u | tr '\n' ' '
        return 0
    fi
    return 1
}

load_dotenv_file() {
    local env_file="$1"
    if [[ ! -f "$env_file" ]]; then
        error "ERROR: .env file not found: $env_file"
        return 1
    fi

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        local line
        line=$(printf '%s' "$raw_line" | tr -d '\r')
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" == export[[:space:]]* ]]; then
            line="${line#export}"
            line="${line#"${line%%[![:space:]]*}"}"
        fi
        [[ "$line" != *=* ]] && continue

        local key="${line%%=*}"
        local val="${line#*=}"
        key=$(trim_ws "$key")
        val=$(trim_ws "$val")
        val=$(strip_outer_quotes "$val")

        if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            export "$key=$val"
        fi
    done < "$env_file"
    return 0
}

is_script_file_command() {
    local full_path="$1"
    local cmd_spec="$2"
    [[ -z "$cmd_spec" || "$cmd_spec" == *[[:space:]]* ]] && return 1
    [[ "$cmd_spec" == *.sh || -f "$full_path/$cmd_spec" ]]
}

execute_service_body() {
    local idx="$1"
    load_services_csv
    local rel_path="${SVC_PATHS[$idx]}"
    local repo_type="${SVC_TYPES[$idx]}"
    local default_port="${SVC_PORTS[$idx]}"
    local cmd_spec="${SVC_CMD_UNIX[$idx]}"
    local load_env="${SVC_LOAD_ENV[$idx]}"
    local full_path
    full_path=$(get_service_full_path "$rel_path")

    cd "$full_path" || return 1

    if [[ -n "$default_port" ]]; then
        export PORT="$default_port"
    fi

    if [[ "$load_env" == "true" ]]; then
        load_dotenv_file "$full_path/.env" || return 1
    fi

    if [[ -n "$cmd_spec" ]]; then
        if is_script_file_command "$full_path" "$cmd_spec"; then
            if [[ "$cmd_spec" == *.sh ]]; then
                bash "$cmd_spec"
            elif [[ -x "$cmd_spec" ]]; then
                "./$cmd_spec"
            else
                bash "$cmd_spec"
            fi
        else
            bash -c "$cmd_spec"
        fi
        return $?
    fi

    case "$repo_type" in
        spring-boot) run_template_spring_boot ;;
        flutter-web) run_template_flutter_web ;;
        go)          run_template_go ;;
        vite)        run_template_vite ;;
        *)
            error "No command or valid repo_type configured for '${SVC_NAMES[$idx]}'."
            return 1
            ;;
    esac
}

run_service_entrypoint() {
    local target_slug="$1"
    load_services_csv
    local i
    for ((i = 0; i < ${#SVC_SLUGS[@]}; i++)); do
        if [[ "${SVC_SLUGS[$i]}" == "$target_slug" ]]; then
            execute_service_body "$i"
            return $?
        fi
    done
    error "Service '$target_slug' not found."
    return 1
}

write_service_status() {
    load_services_csv
    echo ""
    echo -e "  \033[1;33mService Status:\033[0m"
    echo -e "  \033[1;30m----------------------------------------\033[0m"
    if [[ ${#SVC_NAMES[@]} -eq 0 ]]; then
        echo -e "  \033[1;33mNo services configured in services.csv\033[0m"
    else
        local i
        for ((i = 0; i < ${#SVC_NAMES[@]}; i++)); do
            local name="${SVC_NAMES[$i]}"
            local slug="${SVC_SLUGS[$i]}"
            local emoji="${SVC_EMOJIS[$i]}"
            local rel_path="${SVC_PATHS[$i]}"
            local repo_type="${SVC_TYPES[$i]}"
            local default_port="${SVC_PORTS[$i]}"
            local full_path
            full_path=$(get_service_full_path "$rel_path")
            local port
            port=$(get_service_port "$full_path" "$default_port")
            local pid_file="$SCRIPT_DIR/.pids/${slug}.pid"
            local label
            label=$(format_service_label "$emoji" "$name")

            local listen_pid=""
            if [[ -n "$port" ]]; then
                listen_pid=$(get_port_listen_pids "$port" | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')
            fi

            local runner_pid=""
            if [[ -f "$pid_file" ]]; then
                local sp
                sp=$(tr -d '[:space:]' < "$pid_file" 2>/dev/null)
                if [[ -n "$sp" ]] && kill -0 "$sp" 2>/dev/null; then
                    runner_pid="$sp"
                fi
            fi

            local type_tag=""
            [[ "$repo_type" != "custom" ]] && type_tag=" [$repo_type]"

            if [[ -n "$port" ]]; then
                if [[ -n "$listen_pid" ]]; then
                    echo -e "  $label \033[1;32m[RUNNING]\033[0m${type_tag} (Port: $port, PID: $listen_pid)"
                elif [[ -n "$runner_pid" ]]; then
                    echo -e "  $label \033[1;33m[STARTING...]\033[0m${type_tag} (Port: $port, PID: $runner_pid - booting)"
                else
                    echo -e "  $label \033[1;31m[STOPPED]\033[0m${type_tag}"
                fi
            else
                if [[ -n "$runner_pid" ]]; then
                    echo -e "  $label \033[1;32m[RUNNING]\033[0m${type_tag} (PID: $runner_pid)"
                else
                    echo -e "  $label \033[1;31m[STOPPED]\033[0m${type_tag}"
                fi
            fi
        done
    fi
    echo -e "  \033[1;30m----------------------------------------\033[0m"
    echo ""
}

generate_runner_script() {
    local idx="$1"
    local resolved_port="$2"

    ensure_runtime_dirs
    local name="${SVC_NAMES[$idx]}"
    local slug="${SVC_SLUGS[$idx]}"
    local emoji="${SVC_EMOJIS[$idx]}"
    local rel_path="${SVC_PATHS[$idx]}"
    local repo_type="${SVC_TYPES[$idx]}"
    local cmd_spec="${SVC_CMD_UNIX[$idx]}"
    local hints="${SVC_HINTS[$idx]}"

    local full_path
    full_path=$(get_service_full_path "$rel_path")
    local runner_file="$SCRIPT_DIR/.runners/run_${slug}.command"
    local pid_file="$SCRIPT_DIR/.pids/${slug}.pid"
    local label
    label=$(format_service_label "$emoji" "$name")

    local title="$WORKSPACE_NAME - $name"
    [[ -n "$emoji" ]] && title="$emoji $title"
    [[ -n "$resolved_port" ]] && title="$title (Port $resolved_port)"

    local cmd_display
    if [[ -n "$cmd_spec" ]]; then
        cmd_display="$cmd_spec"
    else
        cmd_display="template:$repo_type"
    fi

    local self_bundle
    self_bundle=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

    local q_pid_file q_full_path q_hints q_title q_label q_port q_cmd_disp q_bundle q_root q_slug
    q_pid_file=$(printf '%q' "$pid_file")
    q_full_path=$(printf '%q' "$full_path")
    q_hints=$(printf '%q' "$hints")
    q_title=$(printf '%q' "$title")
    q_label=$(printf '%q' "$label")
    q_port=$(printf '%q' "$resolved_port")
    q_cmd_disp=$(printf '%q' "$cmd_display")
    q_bundle=$(printf '%q' "$self_bundle")
    q_root=$(printf '%q' "$SCRIPT_DIR")
    q_slug=$(printf '%q' "$slug")

    cat <<EOF > "$runner_file"
#!/bin/bash
TITLE=$q_title
PID_FILE=$q_pid_file
FULL_PATH=$q_full_path
HINTS=$q_hints
LABEL=$q_label
PORT_NUM=$q_port
CMD_DISP=$q_cmd_disp
BUNDLE_SCRIPT=$q_bundle
ROOT_DIR=$q_root
SVC_SLUG=$q_slug

printf '\033]0;%s\007' "\$TITLE"
echo \$\$ > "\$PID_FILE"

cleanup_runner() {
    rm -f "\$PID_FILE"
}
trap cleanup_runner EXIT INT TERM

echo -e "\033[1;36m=============================================================================\033[0m"
echo -e "  \033[1;32m\$LABEL\033[0m"
echo -e "  \033[1;37mDirectory :\033[0m \$FULL_PATH"
if [[ -n "\$PORT_NUM" ]]; then
echo -e "  \033[1;37mPort      :\033[0m \$PORT_NUM"
fi
echo -e "  \033[1;37mRunner    :\033[0m \$CMD_DISP"
if [[ -n "\$HINTS" ]]; then
echo -e "  \033[1;33mControls  :\033[0m \$HINTS"
fi
echo -e "\033[1;36m=============================================================================\033[0m"
echo ""

export WORKSPACE_ROOT_DIR="\$ROOT_DIR"
bash "\$BUNDLE_SCRIPT" __run-service "\$SVC_SLUG"
EXIT_CODE=\$?

cleanup_runner

if [[ \$EXIT_CODE -ne 0 && \$EXIT_CODE -ne 130 && \$EXIT_CODE -ne 143 && \$EXIT_CODE -ne 137 ]]; then
    echo ""
    echo -e "\033[1;31m⚠️  $name exited with code \$EXIT_CODE.\033[0m"
    echo "Press [Enter] to close this window..."
    read -r
fi
EOF

    chmod +x "$runner_file"
    echo "$runner_file"
}

launch_terminal() {
    local slug="$1"
    local runner_file="$2"

    if [[ "$OSTYPE" == darwin* ]] && [[ "$TERM_PROGRAM" == "iTerm.app" ]] && command -v osascript >/dev/null 2>&1; then
        osascript -e "tell application \"iTerm2\" to tell current window to create tab with default profile command \"$runner_file\"" 2>/dev/null && return 0
        osascript -e "tell application \"iTerm\" to tell current window to create tab with default profile command \"$runner_file\"" 2>/dev/null && return 0
    fi

    if [[ "$OSTYPE" == darwin* ]] && [[ "$TERM_PROGRAM" == "Apple_Terminal" ]] && command -v osascript >/dev/null 2>&1; then
        osascript -e "tell application \"Terminal\" to do script \"$runner_file\"" 2>/dev/null && return 0
    fi

    if [[ "$OSTYPE" == darwin* ]]; then
        open -a Terminal "$runner_file" 2>/dev/null && return 0
        open "$runner_file" 2>/dev/null && return 0
    fi

    local term
    for term in x-terminal-emulator gnome-terminal konsole xfce4-terminal alacritty kitty terminator xterm; do
        if command -v "$term" >/dev/null 2>&1; then
            case "$term" in
                gnome-terminal) gnome-terminal -- "$runner_file" & return 0 ;;
                *)              "$term" -e "$runner_file" & return 0 ;;
            esac
        fi
    done

    warning "⚠️ No graphical terminal emulator detected. Running in background..."
    local log_file="$SCRIPT_DIR/logs/${slug}_run.log"
    bash "$runner_file" > "$log_file" 2>&1 &
    local pid=$!
    disown "$pid" 2>/dev/null || true
    return 0
}

start_service_idx() {
    local idx="$1"
    local mode="${2:-}"
    load_services_csv
    ensure_runtime_dirs

    local name="${SVC_NAMES[$idx]}"
    local slug="${SVC_SLUGS[$idx]}"
    local emoji="${SVC_EMOJIS[$idx]}"
    local rel_path="${SVC_PATHS[$idx]}"
    local repo_type="${SVC_TYPES[$idx]}"
    local default_port="${SVC_PORTS[$idx]}"
    local cmd_spec="${SVC_CMD_UNIX[$idx]}"
    local load_env="${SVC_LOAD_ENV[$idx]}"
    local label
    label=$(format_service_label "$emoji" "$name")

    local full_path
    full_path=$(get_service_full_path "$rel_path")

    if [[ ! -d "$full_path" ]]; then
        error "ERROR: Service directory not found: $full_path"
        warning "Hint: Run './workspace.sh clone' first."
        return 1
    fi

    if [[ -n "$cmd_spec" ]]; then
        if is_script_file_command "$full_path" "$cmd_spec" && [[ ! -f "$full_path/$cmd_spec" ]]; then
            error "ERROR: Runner script not found: $full_path/$cmd_spec"
            return 1
        fi
    elif [[ "$repo_type" == "custom" ]]; then
        error "ERROR: Service '$name' has repo_type='custom' (or empty) and no cmd_unix specified."
        return 1
    fi

    if [[ "$load_env" == "true" && ! -f "$full_path/.env" ]]; then
        error "ERROR: .env file not found for '$name' at: $full_path/.env (load_env_file=true)"
        if [[ -f "$full_path/.env.example" ]]; then
            warning "Hint: Found .env.example — copy it to .env and configure it before starting."
        fi
        return 1
    fi

    local port
    port=$(get_service_port "$full_path" "$default_port")

    local current_pids
    current_pids=$(get_service_pids "$slug" "$port")
    if [[ -n "$current_pids" ]]; then
        warning "$label is already running (PID: $current_pids)"
        return 0
    fi

    if [[ "$mode" == "--bg" || "$mode" == "bg" ]]; then
        echo -e "  \033[1;36mStarting $label in background...\033[0m"
        local log_file="$SCRIPT_DIR/logs/${slug}_run.log"
        (
            execute_service_body "$idx"
        ) > "$log_file" 2>&1 &
        local pid=$!
        echo "$pid" > "$SCRIPT_DIR/.pids/${slug}.pid"
        disown "$pid" 2>/dev/null || true
        echo -e "  \033[1;32m$label started in background (PID: $pid). Logs: $log_file\033[0m"
    else
        echo -e "  \033[1;36mStarting $label in new terminal window/tab...\033[0m"
        rm -f "$SCRIPT_DIR/.pids/${slug}.pid"
        local runner_file
        runner_file=$(generate_runner_script "$idx" "$port")
        launch_terminal "$slug" "$runner_file"

        local waited=0
        while [[ ! -s "$SCRIPT_DIR/.pids/${slug}.pid" && $waited -lt 15 ]]; do
            sleep 0.1
            waited=$((waited + 1))
        done
        echo -e "  \033[1;32m$label launched.\033[0m"
    fi
    return 0
}

get_descendants() {
    local parent="$1"
    local children=""
    if command -v pgrep >/dev/null 2>&1; then
        children=$(pgrep -P "$parent" 2>/dev/null || true)
    else
        children=$(ps -eo pid=,ppid= 2>/dev/null | awk -v p="$parent" '$2 == p { print $1 }' || true)
    fi

    local child
    for child in $children; do
        child=$(trim_ws "$child")
        [[ -z "$child" ]] && continue
        get_descendants "$child"
        echo "$child"
    done
}

kill_pid_tree() {
    local target_pid="$1"
    local descendants p
    descendants=$(get_descendants "$target_pid")

    for p in $descendants "$target_pid"; do
        kill -15 "$p" 2>/dev/null || true
    done

    local wait_i=0
    while [[ $wait_i -lt 10 ]] && kill -0 "$target_pid" 2>/dev/null; do
        sleep 0.1
        wait_i=$((wait_i + 1))
    done

    for p in $descendants "$target_pid"; do
        if kill -0 "$p" 2>/dev/null; then
            kill -9 "$p" 2>/dev/null || true
        fi
    done
}

stop_service_idx() {
    local idx="$1"
    load_services_csv
    ensure_runtime_dirs

    local name="${SVC_NAMES[$idx]}"
    local slug="${SVC_SLUGS[$idx]}"
    local emoji="${SVC_EMOJIS[$idx]}"
    local rel_path="${SVC_PATHS[$idx]}"
    local default_port="${SVC_PORTS[$idx]}"
    local label
    label=$(format_service_label "$emoji" "$name")

    local full_path
    full_path=$(get_service_full_path "$rel_path")
    local port
    port=$(get_service_port "$full_path" "$default_port")
    local pid_file="$SCRIPT_DIR/.pids/${slug}.pid"

    local pids
    pids=$(get_service_pids "$slug" "$port")

    if [[ -z "$pids" ]]; then
        echo -e "  \033[1;33m$label is not running\033[0m"
        rm -f "$pid_file"
        return 0
    fi

    echo -e "  \033[1;33mStopping $label (PID: $pids)...\033[0m"

    if [[ -f "$pid_file" ]]; then
        local saved_pid
        saved_pid=$(tr -d '[:space:]' < "$pid_file" 2>/dev/null)
        if [[ -n "$saved_pid" ]] && kill -0 "$saved_pid" 2>/dev/null; then
            kill_pid_tree "$saved_pid"
        fi
        rm -f "$pid_file"
    fi

    if [[ -n "$port" ]]; then
        local port_pids p
        port_pids=$(get_port_listen_pids "$port")
        for p in $port_pids; do
            kill_pid_tree "$p"
        done
    fi

    echo -e "  \033[1;32m$label stopped\033[0m"
    return 0
}

find_service_index() {
    load_services_csv
    local target_slug
    target_slug=$(slugify_name "$1")
    local i
    for ((i = 0; i < ${#SVC_SLUGS[@]}; i++)); do
        if [[ "${SVC_SLUGS[$i]}" == "$target_slug" ]]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

start_service_by_name() {
    local target="$1"
    local mode="${2:-}"
    load_services_csv
    local idx
    idx=$(find_service_index "$target")
    if [[ -z "$idx" ]]; then
        error "Service '$target' not found. Available: $(available_services_csv)"
        return 1
    fi
    start_service_idx "$idx" "$mode"
}

stop_service_by_name() {
    local target="$1"
    load_services_csv
    local idx
    idx=$(find_service_index "$target")
    if [[ -z "$idx" ]]; then
        error "Service '$target' not found. Available: $(available_services_csv)"
        return 1
    fi
    stop_service_idx "$idx"
}

restart_service_by_name() {
    local target="$1"
    local mode="${2:-}"
    load_services_csv
    local idx
    idx=$(find_service_index "$target")
    if [[ -z "$idx" ]]; then
        error "Service '$target' not found. Available: $(available_services_csv)"
        return 1
    fi
    stop_service_idx "$idx"
    sleep 1
    start_service_idx "$idx" "$mode"
}

start_all_services() {
    local mode="${1:-}"
    load_services_csv
    local failures=0 i
    echo ""
    echo -e "  \033[1;36mStarting all services...\033[0m"
    echo ""
    for ((i = 0; i < ${#SVC_NAMES[@]}; i++)); do
        if ! start_service_idx "$i" "$mode"; then
            failures=$((failures + 1))
        fi
    done
    echo ""
    [[ $failures -eq 0 ]]
}

stop_all_services() {
    load_services_csv
    echo ""
    echo -e "  \033[1;33mStopping all services...\033[0m"
    echo ""
    local i
    for ((i = 0; i < ${#SVC_NAMES[@]}; i++)); do
        stop_service_idx "$i"
    done
    echo ""
}

force_kill_port() {
    local port="$1"
    local label="$2"
    local pids p
    pids=$(get_port_listen_pids "$port")
    if [[ -n "$pids" ]]; then
        for p in $pids; do
            echo -e "    \033[1;33mKilling $label process on port $port (PID: $p)\033[0m"
            kill_pid_tree "$p"
        done
    else
        echo -e "    \033[1;30mNo process found on port $port\033[0m"
    fi
}

force_kill_cmd() {
    local pattern="$1"
    local label="$2"
    local pids="" p
    if command -v pgrep >/dev/null 2>&1; then
        pids=$(pgrep -f "$pattern" 2>/dev/null || true)
    else
        pids=$(ps aux 2>/dev/null | grep -F "$pattern" | grep -v grep | awk '{print $2}' || true)
    fi
    if [[ -n "$pids" ]]; then
        for p in $pids; do
            if [[ "$p" != "$$" ]]; then
                echo -e "    \033[1;33mKilling $label process matching '$pattern' (PID: $p)\033[0m"
                kill_pid_tree "$p"
            fi
        done
    else
        echo -e "    \033[1;30mNo process found matching '$pattern'\033[0m"
    fi
}

force_stop_all_services() {
    load_services_csv
    ensure_runtime_dirs
    echo ""
    echo -e "  \033[1;31mForce stopping all $WORKSPACE_NAME services...\033[0m"
    echo ""

    local i
    for ((i = 0; i < ${#SVC_NAMES[@]}; i++)); do
        stop_service_idx "$i"
    done

    echo -e "  \033[1;33mScanning for orphaned processes...\033[0m"
    echo ""

    for ((i = 0; i < ${#SVC_NAMES[@]}; i++)); do
        local name="${SVC_NAMES[$i]}"
        local emoji="${SVC_EMOJIS[$i]}"
        local rel_path="${SVC_PATHS[$i]}"
        local default_port="${SVC_PORTS[$i]}"
        local stop_patterns="${SVC_STOP_PATTERNS[$i]}"
        local full_path port label
        full_path=$(get_service_full_path "$rel_path")
        port=$(get_service_port "$full_path" "$default_port")
        label=$(format_service_label "$emoji" "$name")

        [[ -z "$port" && -z "$stop_patterns" ]] && continue
        if [[ -n "$port" ]]; then
            echo -e "  \033[1;37m$label (port $port):\033[0m"
            force_kill_port "$port" "$name"
        else
            echo -e "  \033[1;37m$label:\033[0m"
        fi
        if [[ -n "$stop_patterns" ]]; then
            local IFS=';' pat
            for pat in $stop_patterns; do
                pat=$(trim_ws "$pat")
                [[ -z "$pat" ]] && continue
                force_kill_cmd "$pat" "$name"
            done
        fi
        echo ""
    done

    rm -f "$SCRIPT_DIR/.pids/"*.pid 2>/dev/null
    echo -e "  \033[1;32mForce stop complete.\033[0m"
    echo ""
}

show_service_logs() {
    local target="$1"
    local lines="${2:-20}"
    if [[ -z "$target" ]]; then
        error "Please specify a service. Available: $(available_services_csv)"
        return 1
    fi
    load_services_csv
    local idx
    idx=$(find_service_index "$target")
    if [[ -z "$idx" ]]; then
        error "Service '$target' not found. Available: $(available_services_csv)"
        return 1
    fi
    local slug="${SVC_SLUGS[$idx]}"
    local log_file="$SCRIPT_DIR/logs/${slug}_run.log"
    if [[ -f "$log_file" ]]; then
        echo -e "  \033[1;36m=== Last $lines lines of $log_file ===\033[0m"
        tail -n "$lines" "$log_file"
        echo ""
    else
        warning "No log file found at $log_file"
        echo "  (Services started in interactive terminal windows output directly to their window)"
        echo ""
    fi
}

parse_target_and_mode() {
    local arg1="${1:-}"
    local arg2="${2:-}"
    PARSED_TARGET=""
    PARSED_MODE=""
    if [[ "$arg1" == "--bg" || "$arg1" == "bg" ]]; then
        PARSED_MODE="--bg"
        [[ -n "$arg2" && "$arg2" != "all" ]] && PARSED_TARGET="$arg2"
    elif [[ "$arg2" == "--bg" || "$arg2" == "bg" ]]; then
        PARSED_MODE="--bg"
        [[ -n "$arg1" && "$arg1" != "all" ]] && PARSED_TARGET="$arg1"
    else
        [[ -n "$arg1" && "$arg1" != "all" ]] && PARSED_TARGET="$arg1"
    fi
}

