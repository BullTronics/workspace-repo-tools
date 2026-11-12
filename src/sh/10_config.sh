# =============================================================================
# library-bundle (Unix / macOS / Linux) - Module: 10_config.sh
# =============================================================================

WORKSPACE_CONF="$SCRIPT_DIR/workspace.conf"
REPOS_CSV="$SCRIPT_DIR/repos.csv"
SERVICES_CSV="$SCRIPT_DIR/services.csv"

WORKSPACE_NAME="Workspace"
WORKSPACE_PROMPT="workspace"
WORKSPACE_REL_DIR="workspace"
TOOLS_VERSION="$BUNDLE_VERSION"
CONFIG_SCHEMA_VERSION="$BUNDLE_SCHEMA_VERSION"
TOOLS_REPO_URL="https://github.com/BullTronics/workspace-repo-tools"
TOOLS_RELEASE_BASE_URL=""
DISABLE_AUTO_UPDATE_CHECK="false"
UPDATE_CHECK_INTERVAL_HOURS="24"

load_workspace_conf() {
    if [[ -f "$WORKSPACE_CONF" ]]; then
        local raw_line line k v
        while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
            line="${raw_line//$'\r'/}"
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
            k="${line%%=*}"
            k="${k#"${k%%[![:space:]]*}"}"
            k="${k%"${k##*[![:space:]]}"}"
            v="${line#*=}"
            v="${v#"${v%%[![:space:]]*}"}"
            v="${v%"${v##*[![:space:]]}"}"
            if [[ "$v" == \"*\" && "$v" == *\" && ${#v} -ge 2 ]]; then
                v="${v#\"}"; v="${v%\"}"
            elif [[ "$v" == \'*\' && "$v" == *\' && ${#v} -ge 2 ]]; then
                v="${v#\'}"; v="${v%\'}"
            fi
            [[ -z "$v" ]] && continue
            case "$k" in
                WORKSPACE_NAME)             WORKSPACE_NAME="$v" ;;
                WORKSPACE_PROMPT)           WORKSPACE_PROMPT="$v" ;;
                WORKSPACE_DIR)              WORKSPACE_REL_DIR="$v" ;;
                TOOLS_VERSION)              TOOLS_VERSION="$v" ;;
                CONFIG_SCHEMA_VERSION)      CONFIG_SCHEMA_VERSION="$v" ;;
                TOOLS_REPO_URL)             TOOLS_REPO_URL="${v%/}" ;;
                TOOLS_RELEASE_BASE_URL)     TOOLS_RELEASE_BASE_URL="${v%/}" ;;
                DISABLE_AUTO_UPDATE_CHECK)
                    case "$v" in
                        true|TRUE|True)   DISABLE_AUTO_UPDATE_CHECK="true" ;;
                        false|FALSE|False) DISABLE_AUTO_UPDATE_CHECK="false" ;;
                    esac
                    ;;
                UPDATE_CHECK_INTERVAL_HOURS)
                    [[ "$v" =~ ^[0-9]+$ ]] && UPDATE_CHECK_INTERVAL_HOURS="$v"
                    ;;
            esac
        done < "$WORKSPACE_CONF"
    fi

    case "$WORKSPACE_REL_DIR" in
        /*|[A-Za-z]:*|..|../*|*/../*|*/..|*\\*)
            error "Invalid WORKSPACE_DIR in workspace.conf: $WORKSPACE_REL_DIR"
            exit 1
            ;;
    esac

    WORKSPACE_DIR="$SCRIPT_DIR/$WORKSPACE_REL_DIR"
    WORKSPACE_ROOT="$WORKSPACE_DIR"

    if [[ -n "${WORKSPACE_RELEASE_URL:-}" ]]; then
        RELEASES_BASE_URL="${WORKSPACE_RELEASE_URL%/}"
    elif [[ -n "$TOOLS_RELEASE_BASE_URL" ]]; then
        RELEASES_BASE_URL="$TOOLS_RELEASE_BASE_URL"
    else
        RELEASES_BASE_URL="${TOOLS_REPO_URL%/}/releases"
    fi
}

load_workspace_conf

# --- repos.csv helpers ---
validate_rel_path() {
    local p="$1"
    local row_num="$2"
    if [[ -z "$p" ]]; then
        error "Row $row_num: missing path."
        return 1
    fi
    case "$p" in
        /*)           error "Row $row_num: absolute paths are not allowed: $p"; return 1 ;;
        [A-Za-z]:*)   error "Row $row_num: absolute Windows paths are not allowed: $p"; return 1 ;;
        *\\*)         error "Row $row_num: use '/' instead of '\\' in path: $p"; return 1 ;;
        ..|../*|*/../*|*/..) error "Row $row_num: path escapes workspace: $p"; return 1 ;;
    esac
    return 0
}

matches_repo_filter() {
    local repo_rel="$1"
    local filter="$2"
    [[ -z "$filter" ]] && return 0
    [[ "$repo_rel" == "$filter" ]] && return 0
    case "$repo_rel" in
        */"$filter") return 0 ;;
    esac
    return 1
}

prepare_repos_rows() {
    local out_file="$1"
    if [[ ! -f "$REPOS_CSV" ]]; then
        error "repos.csv not found: $REPOS_CSV"
        exit 1
    fi

    local header_found=0
    : > "$out_file"

    local raw_line line trimmed
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        line="${raw_line//$'\r'/}"
        trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        case "$trimmed" in
            ""|\#*) continue ;;
        esac

        if [[ "$header_found" -eq 0 ]]; then
            header_found=1
            local norm_h="${trimmed//[[:space:]]/}"
            if [[ "$norm_h" != "url,path" && "$norm_h" != "url,path,branch" ]]; then
                error "Invalid repos.csv header. Expected 'url,path' or 'url,path,branch', found: $trimmed"
                exit 1
            fi
            continue
        fi
        printf '%s\n' "$line" >> "$out_file"
    done < "$REPOS_CSV"

    if [[ "$header_found" -eq 0 ]]; then
        error "repos.csv is empty or missing header (url,path[,branch])."
        exit 1
    fi
}

# --- services.csv loader ---
SVC_NAMES=()
SVC_SLUGS=()
SVC_EMOJIS=()
SVC_PATHS=()
SVC_TYPES=()
SVC_PORTS=()
SVC_CMD_UNIX=()
SVC_CMD_WIN=()
SVC_LOAD_ENV=()
SVC_STOP_PATTERNS=()
SVC_HINTS=()
SERVICES_LOADED=0

normalize_repo_type() {
    local raw
    raw=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$raw" in
        ""|custom)                  printf 'custom' ;;
        spring-boot|spring-boot-maven) printf 'spring-boot' ;;
        flutter-web)                printf 'flutter-web' ;;
        go|go-service)              printf 'go' ;;
        vite|node-vite)             printf 'vite' ;;
        *)                          printf 'INVALID' ;;
    esac
}

load_services_csv() {
    [[ $SERVICES_LOADED -eq 1 ]] && return 0
    SERVICES_LOADED=1

    SVC_NAMES=()
    SVC_SLUGS=()
    SVC_EMOJIS=()
    SVC_PATHS=()
    SVC_TYPES=()
    SVC_PORTS=()
    SVC_CMD_UNIX=()
    SVC_CMD_WIN=()
    SVC_LOAD_ENV=()
    SVC_STOP_PATTERNS=()
    SVC_HINTS=()

    if [[ ! -f "$SERVICES_CSV" ]]; then
        error "services.csv not found at $SERVICES_CSV"
        exit 1
    fi

    local us parsed
    us=$(printf '\037')
    parsed=$(awk -v US="$us" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        function parse_csv(line, arr,    i, len, ch, in_q, field, n) {
            n = 1; field = ""; in_q = 0; len = length(line)
            for (i = 1; i <= len; i++) {
                ch = substr(line, i, 1)
                if (in_q) {
                    if (ch == "\"") {
                        if (i < len && substr(line, i + 1, 1) == "\"") { field = field "\""; i++ }
                        else { in_q = 0 }
                    } else { field = field ch }
                } else {
                    if (ch == "\"") { in_q = 1 }
                    else if (ch == ",") { arr[n++] = field; field = "" }
                    else { field = field ch }
                }
            }
            if (in_q) return -1
            arr[n++] = field
            return n - 1
        }
        BEGIN { header_seen = 0 }
        {
            sub(/\r$/, "", $0)
            trimmed = trim($0)
            if (trimmed == "" || substr(trimmed, 1, 1) == "#") next
            cols = parse_csv($0, f)
            if (cols < 0) { printf "ERROR: Unclosed quote in services.csv line %d\n", NR > "/dev/stderr"; exit 2 }
            if (!header_seen) {
                header_seen = 1
                expected = "name,emoji,path,repo_type,port,cmd_unix,cmd_win,load_env_file,stop_pattern,hints"
                got = ""
                for (i = 1; i <= cols; i++) got = got (i > 1 ? "," : "") trim(f[i])
                if (got != expected) {
                    printf "ERROR: Invalid services.csv header.\nExpected: %s\nFound:    %s\n", expected, got > "/dev/stderr"
                    exit 2
                }
                next
            }
            if (cols != 10) {
                printf "ERROR: services.csv line %d expected 10 columns, found %d\n", NR, cols > "/dev/stderr"
                exit 2
            }
            printf "%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%sEND\n",
                trim(f[1]), US, trim(f[2]), US, trim(f[3]), US, trim(f[4]), US,
                trim(f[5]), US, trim(f[6]), US, trim(f[7]), US, trim(f[8]), US,
                trim(f[9]), US, trim(f[10]), US
        }
        END {
            if (!header_seen) { printf "ERROR: services.csv is empty or missing header.\n" > "/dev/stderr"; exit 2 }
        }
    ' "$SERVICES_CSV") || exit 1

    [[ -z "$parsed" ]] && return 0

    local row_idx=0
    while IFS="$us" read -r s_name s_emoji s_path s_type s_port s_cmd_unix s_cmd_win s_load_env s_stop_pat s_hints _end; do
        row_idx=$((row_idx + 1))
        if [[ -z "$s_name" ]]; then
            error "services.csv row $row_idx is missing 'name'."
            exit 1
        fi

        local s_slug
        s_slug=$(slugify_name "$s_name")
        local existing
        for existing in "${SVC_SLUGS[@]+"${SVC_SLUGS[@]}"}"; do
            if [[ "$existing" == "$s_slug" ]]; then
                error "Duplicate service name '$s_name' in services.csv."
                exit 1
            fi
        done

        if ! validate_rel_path "$s_path" "$row_idx"; then
            exit 1
        fi

        local norm_type
        norm_type=$(normalize_repo_type "$s_type")
        if [[ "$norm_type" == "INVALID" ]]; then
            error "Invalid repo_type '$s_type' for service '$s_name' (expected: spring-boot, flutter-web, go, vite, custom)."
            exit 1
        fi

        [[ "$s_emoji" == "-" ]] && s_emoji=""

        # Apply template defaults for empty fields (explicit '-' forces portless)
        if [[ "$s_port" == "-" ]]; then
            s_port=""
        elif [[ -z "$s_port" ]]; then
            case "$norm_type" in
                spring-boot) s_port="8080" ;;
                flutter-web) s_port="3000" ;;
                vite)        s_port="5173" ;;
                go|custom)   s_port="" ;;
            esac
        fi

        if [[ -n "$s_port" ]]; then
            if ! [[ "$s_port" =~ ^[0-9]+$ ]] || [[ "$s_port" -lt 1 || "$s_port" -gt 65535 ]]; then
                error "Invalid port '$s_port' for service '$s_name' in services.csv."
                exit 1
            fi
        fi

        if [[ -z "$s_stop_pat" ]]; then
            case "$norm_type" in
                spring-boot) s_stop_pat="spring-boot:run" ;;
                vite)        s_stop_pat="vite" ;;
            esac
        fi

        if [[ -z "$s_hints" && "$norm_type" == "flutter-web" ]]; then
            s_hints="[r] Hot reload  [R] Hot restart  [h] Help  [d] DevTools  [q] Quit"
        fi

        local load_norm
        load_norm=$(printf '%s' "$s_load_env" | tr '[:upper:]' '[:lower:]')
        case "$load_norm" in
            ""|false) load_norm="false" ;;
            true)     load_norm="true" ;;
            *)        error "Invalid load_env_file '$s_load_env' for service '$s_name' (expected true/false)."; exit 1 ;;
        esac

        SVC_NAMES+=("$s_name")
        SVC_SLUGS+=("$s_slug")
        SVC_EMOJIS+=("$s_emoji")
        SVC_PATHS+=("$s_path")
        SVC_TYPES+=("$norm_type")
        SVC_PORTS+=("$s_port")
        SVC_CMD_UNIX+=("$s_cmd_unix")
        SVC_CMD_WIN+=("$s_cmd_win")
        SVC_LOAD_ENV+=("$load_norm")
        SVC_STOP_PATTERNS+=("$s_stop_pat")
        SVC_HINTS+=("$s_hints")
    done <<EOF
$parsed
EOF
}

