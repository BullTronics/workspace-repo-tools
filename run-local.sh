#!/bin/bash
# =============================================================================
# Generic Local Development Service Runner
# Reads workspace branding from workspace.conf and services from services.csv.
# Supports macOS Terminal / iTerm2, Linux terminal emulators, and background mode.
# =============================================================================

cd "$(dirname "$0")" || exit 1
SCRIPT_DIR=$(pwd)

# Ensure required runtime directories exist
mkdir -p "$SCRIPT_DIR/logs" "$SCRIPT_DIR/.runners" "$SCRIPT_DIR/.pids"

# --- Load workspace.conf ---
WORKSPACE_CONF="$SCRIPT_DIR/workspace.conf"
SERVICES_CSV="$SCRIPT_DIR/services.csv"

WORKSPACE_NAME="Workspace"
WORKSPACE_PROMPT="workspace"
WORKSPACE_REL_DIR="workspace"

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

load_workspace_conf() {
    if [[ ! -f "$WORKSPACE_CONF" ]]; then
        return 0
    fi

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        local line
        line=$(printf '%s' "$raw_line" | tr -d '\r')
        line=$(trim_ws "$line")
        if [[ -z "$line" || "$line" == \#* ]]; then
            continue
        fi
        if [[ "$line" == *=* ]]; then
            local key="${line%%=*}"
            local val="${line#*=}"
            key=$(trim_ws "$key")
            val=$(trim_ws "$val")
            val=$(strip_outer_quotes "$val")
            case "$key" in
                WORKSPACE_NAME)
                    [[ -n "$val" ]] && WORKSPACE_NAME="$val"
                    ;;
                WORKSPACE_PROMPT)
                    [[ -n "$val" ]] && WORKSPACE_PROMPT="$val"
                    ;;
                WORKSPACE_DIR)
                    [[ -n "$val" ]] && WORKSPACE_REL_DIR="$val"
                    ;;
            esac
        fi
    done < "$WORKSPACE_CONF"

    case "$WORKSPACE_REL_DIR" in
        /*|[A-Za-z]:*|..|../*|*/../*|*/..|*\\*)
            echo -e "  \033[1;31mERROR: Invalid WORKSPACE_DIR in workspace.conf: $WORKSPACE_REL_DIR\033[0m" >&2
            exit 1
            ;;
    esac
}

load_workspace_conf
WORKSPACE_ROOT="$SCRIPT_DIR/$WORKSPACE_REL_DIR"

# --- Service Arrays (Bash 3.2 compatible) ---
SVC_NAMES=()
SVC_SLUGS=()
SVC_EMOJIS=()
SVC_PATHS=()
SVC_PORTS=()
SVC_CMD_UNIX=()
SVC_LOAD_ENV=()
SVC_STOP_PATTERNS=()
SVC_HINTS=()

slugify_name() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g'
}

load_services_csv() {
    if [[ ! -f "$SERVICES_CSV" ]]; then
        echo -e "  \033[1;31mERROR: services.csv not found at $SERVICES_CSV\033[0m" >&2
        exit 1
    fi

    local us
    us=$(printf '\037')

    local parsed
    parsed=$(awk -v US="$us" '
        function trim(s) {
            gsub(/^[ \t]+|[ \t]+$/, "", s)
            return s
        }
        function parse_csv(line, arr,    i, len, ch, in_q, field, n) {
            n = 1
            field = ""
            in_q = 0
            len = length(line)
            for (i = 1; i <= len; i++) {
                ch = substr(line, i, 1)
                if (in_q) {
                    if (ch == "\"") {
                        if (i < len && substr(line, i + 1, 1) == "\"") {
                            field = field "\""
                            i++
                        } else {
                            in_q = 0
                        }
                    } else {
                        field = field ch
                    }
                } else {
                    if (ch == "\"") {
                        in_q = 1
                    } else if (ch == ",") {
                        arr[n++] = field
                        field = ""
                    } else {
                        field = field ch
                    }
                }
            }
            if (in_q) {
                return -1
            }
            arr[n++] = field
            return n - 1
        }
        BEGIN {
            header_seen = 0
        }
        {
            sub(/\r$/, "", $0)
            trimmed = trim($0)
            if (trimmed == "" || substr(trimmed, 1, 1) == "#") {
                next
            }
            cols = parse_csv($0, f)
            if (cols < 0) {
                printf "ERROR: Unclosed quote in services.csv on line %d\n", NR > "/dev/stderr"
                exit 2
            }
            if (!header_seen) {
                header_seen = 1
                expected = "name,emoji,path,port,cmd_unix,cmd_win,load_env_file,stop_pattern,hints"
                got = ""
                for (i = 1; i <= cols; i++) {
                    got = got (i > 1 ? "," : "") trim(f[i])
                }
                if (got != expected) {
                    printf "ERROR: Invalid services.csv header.\nExpected: %s\nFound:    %s\n", expected, got > "/dev/stderr"
                    exit 2
                }
                next
            }
            if (cols != 9) {
                printf "ERROR: services.csv line %d expected 9 columns, found %d\n", NR, cols > "/dev/stderr"
                exit 2
            }
            printf "%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%sEND\n",
                trim(f[1]), US,
                trim(f[2]), US,
                trim(f[3]), US,
                trim(f[4]), US,
                trim(f[5]), US,
                trim(f[6]), US,
                trim(f[7]), US,
                trim(f[8]), US,
                trim(f[9]), US
        }
        END {
            if (!header_seen) {
                printf "ERROR: services.csv is empty or missing header.\n" > "/dev/stderr"
                exit 2
            }
        }
    ' "$SERVICES_CSV") || exit 1

    if [[ -z "$parsed" ]]; then
        return 0
    fi

    local row_idx=0
    while IFS="$us" read -r s_name s_emoji s_path s_port s_cmd_unix _s_cmd_win s_load_env s_stop_pat s_hints _end; do
        row_idx=$((row_idx + 1))

        if [[ -z "$s_name" ]]; then
            echo -e "  \033[1;31mERROR: services.csv row $row_idx is missing 'name'.\033[0m" >&2
            exit 1
        fi

        local s_slug
        s_slug=$(slugify_name "$s_name")
        local existing
        for existing in "${SVC_SLUGS[@]+"${SVC_SLUGS[@]}"}"; do
            if [[ "$existing" == "$s_slug" ]]; then
                echo -e "  \033[1;31mERROR: Duplicate service name '$s_name' in services.csv.\033[0m" >&2
                exit 1
            fi
        done

        if [[ -z "$s_path" ]]; then
            echo -e "  \033[1;31mERROR: Service '$s_name' is missing 'path' in services.csv.\033[0m" >&2
            exit 1
        fi

        case "$s_path" in
            /*|[A-Za-z]:*|..|../*|*/../*|*/..|*\\*)
                echo -e "  \033[1;31mERROR: Invalid relative path '$s_path' for service '$s_name'.\033[0m" >&2
                exit 1
                ;;
        esac

        [[ "$s_emoji" == "-" ]] && s_emoji=""
        [[ "$s_port" == "-" ]] && s_port=""

        if [[ -n "$s_port" ]]; then
            if ! [[ "$s_port" =~ ^[0-9]+$ ]] || [[ "$s_port" -lt 1 || "$s_port" -gt 65535 ]]; then
                echo -e "  \033[1;31mERROR: Invalid port '$s_port' for service '$s_name' in services.csv.\033[0m" >&2
                exit 1
            fi
        fi

        [[ -z "$s_cmd_unix" ]] && s_cmd_unix="run-local.sh"

        local load_norm
        load_norm=$(printf '%s' "$s_load_env" | tr '[:upper:]' '[:lower:]')
        case "$load_norm" in
            ""|false)
                load_norm="false"
                ;;
            true)
                load_norm="true"
                ;;
            *)
                echo -e "  \033[1;31mERROR: Invalid load_env_file '$s_load_env' for service '$s_name' (expected true/false).\033[0m" >&2
                exit 1
                ;;
        esac

        SVC_NAMES+=("$s_name")
        SVC_SLUGS+=("$s_slug")
        SVC_EMOJIS+=("$s_emoji")
        SVC_PATHS+=("$s_path")
        SVC_PORTS+=("$s_port")
        SVC_CMD_UNIX+=("$s_cmd_unix")
        SVC_LOAD_ENV+=("$load_norm")
        SVC_STOP_PATTERNS+=("$s_stop_pat")
        SVC_HINTS+=("$s_hints")
    done <<EOF
$parsed
EOF
}

load_services_csv

# --- Helper Functions ---
format_label() {
    local emoji="$1"
    local name="$2"
    if [[ -n "$emoji" ]]; then
        printf '%s %s' "$emoji" "$name"
    else
        printf '%s' "$name"
    fi
}

available_services_csv() {
    if [[ ${#SVC_NAMES[@]} -eq 0 ]]; then
        printf '(none configured in services.csv)'
        return 0
    fi
    local list=""
    local i
    for ((i = 0; i < ${#SVC_NAMES[@]}; i++)); do
        if [[ -n "$list" ]]; then
            list="$list, ${SVC_NAMES[$i]}"
        else
            list="${SVC_NAMES[$i]}"
        fi
    done
    printf '%s' "$list"
}

write_banner() {
    echo -e "\033[1;36m"
    echo "  ===================================================="
    echo "    $WORKSPACE_NAME - Local Development Runner"
    echo "  ===================================================="
    echo -e "\033[0m"
}

check_for_updates_banner() {
    local mode="${1:---bg}"
    if [[ "${WORKSPACE_UPDATE_CHECKED:-0}" == "1" ]]; then
        return 0
    fi
    local updater="$SCRIPT_DIR/workspace-repo-tools-updater.sh"
    if [[ -f "$updater" ]]; then
        bash "$updater" --banner-check "$mode" || true
    fi
}

get_service_full_path() {
    local rel_path="$1"
    printf '%s/%s' "$WORKSPACE_ROOT" "$rel_path"
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
    if [[ -z "$port" ]]; then
        return 0
    fi
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
        local port_pids
        port_pids=$(get_port_listen_pids "$port")
        if [[ -n "$port_pids" ]]; then
            local p
            for p in $port_pids; do
                pids+=("$p")
            done
        fi
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

# Loads KEY=VALUE entries from a .env file into the CURRENT (isolated) shell.
load_dotenv_file() {
    local env_file="$1"
    if [[ ! -f "$env_file" ]]; then
        echo "ERROR: .env file not found: $env_file" >&2
        return 1
    fi

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        local line
        line=$(printf '%s' "$raw_line" | tr -d '\r')
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        if [[ -z "$line" || "$line" == \#* ]]; then
            continue
        fi

        if [[ "$line" == export[[:space:]]* ]]; then
            line="${line#export}"
            line="${line#"${line%%[![:space:]]*}"}"
        fi

        if [[ "$line" != *=* ]]; then
            continue
        fi

        local key="${line%%=*}"
        local val="${line#*=}"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"

        if [[ "$val" == \"*\" && "$val" == *\" && ${#val} -ge 2 ]]; then
            val="${val#\"}"
            val="${val%\"}"
        elif [[ "$val" == \'*\' && "$val" == *\' && ${#val} -ge 2 ]]; then
            val="${val#\'}"
            val="${val%\'}"
        fi

        if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            export "$key=$val"
        fi
    done < "$env_file"
    return 0
}

write_status() {
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
            local default_port="${SVC_PORTS[$i]}"
            local full_path
            full_path=$(get_service_full_path "$rel_path")
            local port
            port=$(get_service_port "$full_path" "$default_port")
            local pid_file="$SCRIPT_DIR/.pids/${slug}.pid"
            local label
            label=$(format_label "$emoji" "$name")

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

            if [[ -n "$port" ]]; then
                if [[ -n "$listen_pid" ]]; then
                    echo -e "  $label \033[1;32m[RUNNING]\033[0m (Port: $port, PID: $listen_pid)"
                elif [[ -n "$runner_pid" ]]; then
                    echo -e "  $label \033[1;33m[STARTING...]\033[0m (Port: $port, PID: $runner_pid - booting)"
                else
                    echo -e "  $label \033[1;31m[STOPPED]\033[0m"
                fi
            else
                if [[ -n "$runner_pid" ]]; then
                    echo -e "  $label \033[1;32m[RUNNING]\033[0m (PID: $runner_pid)"
                else
                    echo -e "  $label \033[1;31m[STOPPED]\033[0m"
                fi
            fi
        done
    fi
    echo -e "  \033[1;30m----------------------------------------\033[0m"
    echo ""
}

is_script_file_command() {
    local full_path="$1"
    local cmd_spec="$2"
    if [[ "$cmd_spec" == *[[:space:]]* ]]; then
        return 1
    fi
    if [[ "$cmd_spec" == *.sh || -f "$full_path/$cmd_spec" ]]; then
        return 0
    fi
    return 1
}

generate_runner_script() {
    local idx="$1"
    local resolved_port="$2"

    local name="${SVC_NAMES[$idx]}"
    local slug="${SVC_SLUGS[$idx]}"
    local emoji="${SVC_EMOJIS[$idx]}"
    local rel_path="${SVC_PATHS[$idx]}"
    local cmd_spec="${SVC_CMD_UNIX[$idx]}"
    local load_env="${SVC_LOAD_ENV[$idx]}"
    local hints="${SVC_HINTS[$idx]}"

    local full_path
    full_path=$(get_service_full_path "$rel_path")
    local runner_file="$SCRIPT_DIR/.runners/run_${slug}.command"
    local pid_file="$SCRIPT_DIR/.pids/${slug}.pid"
    local label
    label=$(format_label "$emoji" "$name")

    local title="$WORKSPACE_NAME - $name"
    [[ -n "$emoji" ]] && title="$emoji $title"
    [[ -n "$resolved_port" ]] && title="$title (Port $resolved_port)"

    local cmd_display="$cmd_spec"
    local is_script=0
    if is_script_file_command "$full_path" "$cmd_spec"; then
        is_script=1
        if [[ "$cmd_spec" == *.sh ]]; then
            cmd_display="bash $cmd_spec"
        fi
    fi

    local q_pid_file q_full_path q_cmd_spec q_hints q_title q_label q_ws_name q_port q_load_env
    q_pid_file=$(printf '%q' "$pid_file")
    q_full_path=$(printf '%q' "$full_path")
    q_cmd_spec=$(printf '%q' "$cmd_spec")
    q_hints=$(printf '%q' "$hints")
    q_title=$(printf '%q' "$title")
    q_label=$(printf '%q' "$label")
    q_ws_name=$(printf '%q' "$WORKSPACE_NAME")
    q_port=$(printf '%q' "$resolved_port")
    q_load_env=$(printf '%q' "$load_env")

    cat <<EOF > "$runner_file"
#!/bin/bash
# Generated runner script for $name

TITLE=$q_title
PID_FILE=$q_pid_file
FULL_PATH=$q_full_path
CMD_SPEC=$q_cmd_spec
HINTS=$q_hints
LABEL=$q_label
PORT_NUM=$q_port
LOAD_ENV=$q_load_env
IS_SCRIPT=$is_script

printf '\033]0;%s\007' "\$TITLE"
echo \$\$ > "\$PID_FILE"

cleanup_runner() {
    rm -f "\$PID_FILE"
}
trap cleanup_runner EXIT INT TERM

load_dotenv() {
    local env_file="\$1"
    if [[ ! -f "\$env_file" ]]; then
        echo -e "\033[1;31mERROR: .env file not found: \$env_file\033[0m" >&2
        return 1
    fi
    while IFS= read -r raw_line || [[ -n "\$raw_line" ]]; do
        local line
        line=\$(printf '%s' "\$raw_line" | tr -d '\r')
        line="\${line#"\${line%%[![:space:]]*}"}"
        line="\${line%"\${line##*[![:space:]]}"}"
        if [[ -z "\$line" || "\$line" == \\#* ]]; then
            continue
        fi
        if [[ "\$line" == export[[:space:]]* ]]; then
            line="\${line#export}"
            line="\${line#"\${line%%[![:space:]]*}"}"
        fi
        [[ "\$line" != *=* ]] && continue
        local key="\${line%%=*}"
        local val="\${line#*=}"
        key="\${key#"\${key%%[![:space:]]*}"}"
        key="\${key%"\${key##*[![:space:]]}"}"
        val="\${val#"\${val%%[![:space:]]*}"}"
        val="\${val%"\${val##*[![:space:]]}"}"
        if [[ "\$val" == \\"*\\" && "\$val" == *\\" && \${#val} -ge 2 ]]; then
            val="\${val#\\"}"
            val="\${val%\\"}"
        elif [[ "\$val" == \\'*\\' && "\$val" == *\\' && \${#val} -ge 2 ]]; then
            val="\${val#\\'}"
            val="\${val%\\'}"
        fi
        if [[ "\$key" =~ ^[A-Za-z_][A-Za-z0-9_]*\$ ]]; then
            export "\$key=\$val"
        fi
    done < "\$env_file"
}

echo -e "\033[1;36m=============================================================================\033[0m"
echo -e "  \033[1;32m\$LABEL\033[0m"
echo -e "  \033[1;37mDirectory :\033[0m \$FULL_PATH"
if [[ -n "\$PORT_NUM" ]]; then
echo -e "  \033[1;37mPort      :\033[0m \$PORT_NUM"
fi
echo -e "  \033[1;37mCommand   :\033[0m $cmd_display"
if [[ -n "\$HINTS" ]]; then
echo -e "  \033[1;33mControls  :\033[0m \$HINTS"
fi
echo -e "\033[1;36m=============================================================================\033[0m"
echo ""

cd "\$FULL_PATH" || exit 1

if [[ "\$LOAD_ENV" == "true" ]]; then
    load_dotenv "\$FULL_PATH/.env" || exit 1
fi

if [[ "\$IS_SCRIPT" -eq 1 ]]; then
    if [[ "\$CMD_SPEC" == *.sh ]]; then
        bash "\$CMD_SPEC"
    elif [[ -x "\$CMD_SPEC" ]]; then
        "./\$CMD_SPEC"
    else
        bash "\$CMD_SPEC"
    fi
else
    bash -c "\$CMD_SPEC"
fi
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

    # 1. macOS with iTerm2
    if [[ "$OSTYPE" == darwin* ]] && [[ "$TERM_PROGRAM" == "iTerm.app" ]] && command -v osascript >/dev/null 2>&1; then
        if osascript -e "tell application \"iTerm2\" to tell current window to create tab with default profile command \"$runner_file\"" 2>/dev/null; then
            return 0
        fi
        if osascript -e "tell application \"iTerm\" to tell current window to create tab with default profile command \"$runner_file\"" 2>/dev/null; then
            return 0
        fi
    fi

    # 2. macOS with Terminal.app via AppleScript
    if [[ "$OSTYPE" == darwin* ]] && [[ "$TERM_PROGRAM" == "Apple_Terminal" ]] && command -v osascript >/dev/null 2>&1; then
        if osascript -e "tell application \"Terminal\" to do script \"$runner_file\"" 2>/dev/null; then
            return 0
        fi
    fi

    # 3. macOS standard LaunchServices
    if [[ "$OSTYPE" == darwin* ]]; then
        if open -a Terminal "$runner_file" 2>/dev/null; then
            return 0
        fi
        if open "$runner_file" 2>/dev/null; then
            return 0
        fi
    fi

    # 4. Linux / BSD terminal emulators
    local term
    for term in x-terminal-emulator gnome-terminal konsole xfce4-terminal alacritty kitty terminator xterm; do
        if command -v "$term" >/dev/null 2>&1; then
            case "$term" in
                gnome-terminal)
                    gnome-terminal -- "$runner_file" &
                    return 0
                    ;;
                konsole|xfce4-terminal|*)
                    "$term" -e "$runner_file" &
                    return 0
                    ;;
            esac
        fi
    done

    # 5. Fallback: background execution
    echo -e "  \033[1;33m⚠️ No graphical terminal emulator detected. Running in background...\033[0m"
    local log_file="$SCRIPT_DIR/logs/${slug}_run.log"
    bash "$runner_file" > "$log_file" 2>&1 &
    local pid=$!
    disown "$pid" 2>/dev/null
    return 0
}

start_service_idx() {
    local idx="$1"
    local mode="${2:-}"

    local name="${SVC_NAMES[$idx]}"
    local slug="${SVC_SLUGS[$idx]}"
    local emoji="${SVC_EMOJIS[$idx]}"
    local rel_path="${SVC_PATHS[$idx]}"
    local default_port="${SVC_PORTS[$idx]}"
    local cmd_spec="${SVC_CMD_UNIX[$idx]}"
    local load_env="${SVC_LOAD_ENV[$idx]}"
    local label
    label=$(format_label "$emoji" "$name")

    local full_path
    full_path=$(get_service_full_path "$rel_path")

    if [[ ! -d "$full_path" ]]; then
        echo -e "  \033[1;31mERROR: Service directory not found: $full_path\033[0m" >&2
        echo -e "  \033[1;33mHint: Run './git-all.sh clone' first.\033[0m" >&2
        return 1
    fi

    if is_script_file_command "$full_path" "$cmd_spec" && [[ ! -f "$full_path/$cmd_spec" ]]; then
        echo -e "  \033[1;31mERROR: Runner script not found: $full_path/$cmd_spec\033[0m" >&2
        return 1
    fi

    if [[ "$load_env" == "true" && ! -f "$full_path/.env" ]]; then
        echo -e "  \033[1;31mERROR: .env file not found for '$name' at: $full_path/.env (load_env_file=true)\033[0m" >&2
        if [[ -f "$full_path/.env.example" ]]; then
            echo -e "  \033[1;33mHint: Found .env.example — copy it to .env and configure it before starting.\033[0m" >&2
        fi
        return 1
    fi

    local port
    port=$(get_service_port "$full_path" "$default_port")

    local current_pids
    current_pids=$(get_service_pids "$slug" "$port")
    if [[ -n "$current_pids" ]]; then
        echo -e "  \033[1;33m$label is already running (PID: $current_pids)\033[0m"
        return 0
    fi

    if [[ "$mode" == "--bg" || "$mode" == "bg" ]]; then
        echo -e "  \033[1;36mStarting $label in background...\033[0m"
        local log_file="$SCRIPT_DIR/logs/${slug}_run.log"
        local is_script=0
        if is_script_file_command "$full_path" "$cmd_spec"; then
            is_script=1
        fi

        (
            cd "$full_path" || exit 1
            if [[ "$load_env" == "true" ]]; then
                load_dotenv_file "$full_path/.env" || exit 1
            fi
            if [[ "$is_script" -eq 1 ]]; then
                if [[ "$cmd_spec" == *.sh ]]; then
                    exec bash "$cmd_spec"
                elif [[ -x "$cmd_spec" ]]; then
                    exec "./$cmd_spec"
                else
                    exec bash "$cmd_spec"
                fi
            else
                exec bash -c "$cmd_spec"
            fi
        ) > "$log_file" 2>&1 &
        local pid=$!
        echo "$pid" > "$SCRIPT_DIR/.pids/${slug}.pid"
        disown "$pid" 2>/dev/null
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

# Portable recursive descendant lookup (macOS + Linux)
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
        child=$(printf '%s' "$child" | tr -d '[:space:]')
        [[ -z "$child" ]] && continue
        get_descendants "$child"
        echo "$child"
    done
}

kill_pid_tree() {
    local target_pid="$1"
    local descendants
    descendants=$(get_descendants "$target_pid")

    local p
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

    local name="${SVC_NAMES[$idx]}"
    local slug="${SVC_SLUGS[$idx]}"
    local emoji="${SVC_EMOJIS[$idx]}"
    local rel_path="${SVC_PATHS[$idx]}"
    local default_port="${SVC_PORTS[$idx]}"
    local label
    label=$(format_label "$emoji" "$name")

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
        local port_pids
        port_pids=$(get_port_listen_pids "$port")
        if [[ -n "$port_pids" ]]; then
            local p
            for p in $port_pids; do
                kill_pid_tree "$p"
            done
        fi
    fi

    echo -e "  \033[1;32m$label stopped\033[0m"
    return 0
}

find_service_index() {
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
    local idx
    idx=$(find_service_index "$target")
    if [[ -z "$idx" ]]; then
        echo -e "  \033[1;31mService '$target' not found. Available: $(available_services_csv)\033[0m" >&2
        return 1
    fi
    start_service_idx "$idx" "$mode"
}

stop_service_by_name() {
    local target="$1"
    local idx
    idx=$(find_service_index "$target")
    if [[ -z "$idx" ]]; then
        echo -e "  \033[1;31mService '$target' not found. Available: $(available_services_csv)\033[0m" >&2
        return 1
    fi
    stop_service_idx "$idx"
}

restart_service_by_name() {
    local target="$1"
    local mode="${2:-}"
    local idx
    idx=$(find_service_index "$target")
    if [[ -z "$idx" ]]; then
        echo -e "  \033[1;31mService '$target' not found. Available: $(available_services_csv)\033[0m" >&2
        return 1
    fi
    stop_service_idx "$idx"
    sleep 1
    start_service_idx "$idx" "$mode"
}

start_all() {
    local mode="${1:-}"
    local failures=0
    echo ""
    echo -e "  \033[1;36mStarting all services...\033[0m"
    echo ""
    local i
    for ((i = 0; i < ${#SVC_NAMES[@]}; i++)); do
        if ! start_service_idx "$i" "$mode"; then
            failures=$((failures + 1))
        fi
    done
    echo ""
    [[ $failures -eq 0 ]]
}

stop_all() {
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

    local pids
    pids=$(get_port_listen_pids "$port")
    if [[ -n "$pids" ]]; then
        local p
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

    local pids=""
    if command -v pgrep >/dev/null 2>&1; then
        pids=$(pgrep -f "$pattern" 2>/dev/null || true)
    else
        pids=$(ps aux 2>/dev/null | grep -F "$pattern" | grep -v grep | awk '{print $2}' || true)
    fi

    if [[ -n "$pids" ]]; then
        local p
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

force_stop_all() {
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
        local full_path
        full_path=$(get_service_full_path "$rel_path")
        local port
        port=$(get_service_port "$full_path" "$default_port")
        local label
        label=$(format_label "$emoji" "$name")

        if [[ -z "$port" && -z "$stop_patterns" ]]; then
            continue
        fi

        if [[ -n "$port" ]]; then
            echo -e "  \033[1;37m$label (port $port):\033[0m"
            force_kill_port "$port" "$name"
        else
            echo -e "  \033[1;37m$label:\033[0m"
        fi

        if [[ -n "$stop_patterns" ]]; then
            local IFS=';'
            local pat
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

show_logs() {
    local target="$1"
    local lines="${2:-20}"
    if [[ -z "$target" ]]; then
        echo -e "  \033[1;31mPlease specify a service. Available: $(available_services_csv)\033[0m" >&2
        return 1
    fi

    local idx
    idx=$(find_service_index "$target")
    if [[ -z "$idx" ]]; then
        echo -e "  \033[1;31mService '$target' not found. Available: $(available_services_csv)\033[0m" >&2
        return 1
    fi

    local slug="${SVC_SLUGS[$idx]}"
    local log_file="$SCRIPT_DIR/logs/${slug}_run.log"

    if [[ -f "$log_file" ]]; then
        echo -e "  \033[1;36m=== Last $lines lines of $log_file ===\033[0m"
        tail -n "$lines" "$log_file"
        echo ""
    else
        echo -e "  \033[1;33mNo log file found at $log_file\033[0m"
        echo -e "  \033[0;37m(Services started in interactive terminal windows output directly to their window)\033[0m"
        echo ""
    fi
}

show_menu() {
    local avail
    avail=$(available_services_csv)
    echo -e "  \033[1;35mCommands:\033[0m"
    echo -e "    \033[1;37mstart [svc] [--bg] \033[0;37m- Start all or single service ($avail)\033[0m"
    echo -e "    \033[1;37mstop [svc]          \033[0;37m- Stop all or single service\033[0m"
    echo -e "    \033[1;37mrestart [svc] [--bg]\033[0;37m- Restart all or single service\033[0m"
    echo -e "    \033[1;31mforce-stop          \033[0;37m- Kill all services (including orphaned processes)\033[0m"
    echo -e "    \033[1;37mstatus              \033[0;37m- Show service status\033[0m"
    echo -e "    \033[1;37mlogs <svc> [lines]  \033[0;37m- View background log file for a service\033[0m"
    echo -e "    \033[1;37mquit / exit / q     \033[0;37m- Stop all and exit\033[0m"
    echo ""
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

# --- Direct CLI arguments handling ---
if [[ $# -gt 0 ]]; then
    cli_cmd=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    cli_arg="${2:-}"
    cli_opt="${3:-}"
    cli_rc=0

    case "$cli_cmd" in
        start)
            parse_target_and_mode "$cli_arg" "$cli_opt"
            if [[ -z "$PARSED_TARGET" ]]; then
                start_all "$PARSED_MODE" || cli_rc=1
            else
                start_service_by_name "$PARSED_TARGET" "$PARSED_MODE" || cli_rc=1
            fi
            write_status
            check_for_updates_banner "--bg"
            exit "$cli_rc"
            ;;
        stop)
            if [[ -z "$cli_arg" || "$cli_arg" == "all" ]]; then
                stop_all
            else
                stop_service_by_name "$cli_arg" || cli_rc=1
            fi
            write_status
            check_for_updates_banner "--bg"
            exit "$cli_rc"
            ;;
        restart)
            parse_target_and_mode "$cli_arg" "$cli_opt"
            if [[ -z "$PARSED_TARGET" ]]; then
                stop_all
                sleep 1
                start_all "$PARSED_MODE" || cli_rc=1
            else
                restart_service_by_name "$PARSED_TARGET" "$PARSED_MODE" || cli_rc=1
            fi
            write_status
            check_for_updates_banner "--bg"
            exit "$cli_rc"
            ;;
        force-stop)
            force_stop_all
            check_for_updates_banner "--bg"
            ;;
        status)
            write_status
            check_for_updates_banner "--bg"
            ;;
        logs)
            show_logs "$cli_arg" "${cli_opt:-20}" || exit 1
            check_for_updates_banner "--bg"
            ;;
        help|-h|--help)
            write_banner
            check_for_updates_banner "--bg"
            show_menu
            ;;
        *)
            echo "Unknown command: '$1'. Run without arguments for interactive mode or use 'help'." >&2
            exit 1
            ;;
    esac
    exit 0
fi

# --- Interactive REPL Mode (trap registered only in interactive mode) ---
cleanup_repl() {
    echo -e "\n  \033[1;33mInterrupt detected. Cleaning up...\033[0m"
    stop_all
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

    read -r cmd arg opt <<< "$input_line"
    cmd=$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')
    arg=$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]')
    opt=$(printf '%s' "$opt" | tr '[:upper:]' '[:lower:]')

    case "$cmd" in
        start)
            parse_target_and_mode "$arg" "$opt"
            if [[ -z "$PARSED_TARGET" ]]; then
                start_all "$PARSED_MODE" || true
            else
                start_service_by_name "$PARSED_TARGET" "$PARSED_MODE" || true
            fi
            write_status
            ;;
        stop)
            if [[ -z "$arg" || "$arg" == "all" ]]; then
                stop_all
            else
                stop_service_by_name "$arg" || true
            fi
            write_status
            ;;
        restart)
            parse_target_and_mode "$arg" "$opt"
            if [[ -z "$PARSED_TARGET" ]]; then
                stop_all
                sleep 1
                start_all "$PARSED_MODE" || true
            else
                restart_service_by_name "$PARSED_TARGET" "$PARSED_MODE" || true
            fi
            write_status
            ;;
        force-stop)
            force_stop_all
            ;;
        status)
            write_status
            ;;
        logs)
            show_logs "$arg" "${opt:-20}" || true
            ;;
        quit|exit|q)
            stop_all
            echo -e "  \033[1;36mGoodbye!\033[0m"
            echo ""
            exit 0
            ;;
        help)
            show_menu
            ;;
        *)
            echo -e "  \033[1;31mUnknown command: '$input_line'. Type 'help' for available commands.\033[0m"
            echo ""
            ;;
    esac
done
