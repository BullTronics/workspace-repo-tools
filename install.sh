#!/bin/bash
# =============================================================================
# workspace-repo-tools Bootstrap Installer (macOS / Linux)
#
# One-line usage:
#   curl -fsSL https://raw.githubusercontent.com/BullTronics/workspace-repo-tools/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/BullTronics/workspace-repo-tools/main/install.sh | bash -s -- --dir ./my-workspace
# =============================================================================

set -euo pipefail

UPSTREAM_URL="${TOOLS_UPSTREAM_URL:-https://github.com/BullTronics/workspace-repo-tools.git}"
UPSTREAM_BRANCH="${TOOLS_UPSTREAM_BRANCH:-main}"
TARGET_DIR=""
FORCE_FLAG=0

usage() {
    cat <<EOF
workspace-repo-tools installer

Usage:
  curl -fsSL https://raw.githubusercontent.com/BullTronics/workspace-repo-tools/main/install.sh | bash
  ./install.sh [--dir <path>] [--url <git-url>] [--branch <branch>] [--force]

Options:
  --dir <path>      Target workspace root directory (default: current directory)
  --url <git-url>   Upstream repository URL (default: $UPSTREAM_URL)
  --branch <branch> Upstream branch (default: $UPSTREAM_BRANCH)
  -f, --force       Allow running inside a repo whose origin matches upstream
  -h, --help        Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)
            [[ $# -lt 2 || -z "$2" ]] && { echo "Option '--dir' requires a path." >&2; exit 1; }
            TARGET_DIR="$2"
            shift 2
            ;;
        --url)
            [[ $# -lt 2 || -z "$2" ]] && { echo "Option '--url' requires a URL." >&2; exit 1; }
            UPSTREAM_URL="$2"
            shift 2
            ;;
        --branch)
            [[ $# -lt 2 || -z "$2" ]] && { echo "Option '--branch' requires a branch name." >&2; exit 1; }
            UPSTREAM_BRANCH="$2"
            shift 2
            ;;
        -f|--force)
            FORCE_FLAG=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: Git is required to install workspace-repo-tools." >&2
    exit 1
fi

if [[ -z "$TARGET_DIR" ]]; then
    TARGET_DIR=$(pwd)
else
    mkdir -p "$TARGET_DIR"
    TARGET_DIR=$(cd "$TARGET_DIR" && pwd)
fi

trim_ws() {
    local val="$1"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    printf '%s' "$val"
}

normalize_url() {
    local u="$1"
    u=$(printf '%s' "$u" | tr '[:upper:]' '[:lower:]')
    u="${u%/}"
    u="${u%.git}"
    if [[ "$u" == git@github.com:* ]]; then
        u="https://github.com/${u#git@github.com:}"
    fi
    printf '%s' "$u"
}

if [[ $FORCE_FLAG -eq 0 ]] && git -C "$TARGET_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    origin_url=$(git -C "$TARGET_DIR" config --get remote.origin.url 2>/dev/null || true)
    if [[ -n "$origin_url" && "$(normalize_url "$origin_url")" == "$(normalize_url "$UPSTREAM_URL")" ]]; then
        echo "ERROR: Target directory's origin matches upstream ($UPSTREAM_URL)." >&2
        echo "Choose a different --dir or pass --force." >&2
        exit 1
    fi
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/wrt-install.XXXXXX")
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

echo "Downloading workspace-repo-tools ($UPSTREAM_BRANCH) from $UPSTREAM_URL..."
GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 --branch "$UPSTREAM_BRANCH" "$UPSTREAM_URL" "$TMP_DIR/src"

SRC="$TMP_DIR/src"
REMOTE_SHA=$(git -C "$SRC" rev-parse HEAD)
REMOTE_VER="1.0.0"
if [[ -f "$SRC/VERSION" ]]; then
    REMOTE_VER=$(trim_ws "$(head -n 1 "$SRC/VERSION" | tr -d '\r')")
fi

# Collect managed files & dirs from updater-manifest.txt
MANIFEST_FILES=()
MANIFEST_DIRS=()
MANIFEST_MERGES=()

if [[ -f "$SRC/updater-manifest.txt" ]]; then
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        line=$(printf '%s' "$raw_line" | tr -d '\r')
        line=$(trim_ws "$line")
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" == file:* ]]; then
            MANIFEST_FILES+=("$(trim_ws "${line#file:}")")
        elif [[ "$line" == dir:* ]]; then
            MANIFEST_DIRS+=("$(trim_ws "${line#dir:}")")
        elif [[ "$line" == merge_lines:* ]]; then
            MANIFEST_MERGES+=("$(trim_ws "${line#merge_lines:}")")
        fi
    done < "$SRC/updater-manifest.txt"
fi

if [[ ${#MANIFEST_FILES[@]} -eq 0 ]]; then
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

TS=$(date +"%Y%m%d-%H%M%S")
BACKUP_DIR="$TARGET_DIR/.workspace-tools-backups/$TS"
BACKUP_CREATED=0

backup_if_differs() {
    local rel="$1"
    local dst="$TARGET_DIR/$rel"
    local src_f="$SRC/$rel"
    if [[ -f "$dst" ]] && ! cmp -s "$dst" "$src_f"; then
        if [[ $BACKUP_CREATED -eq 0 ]]; then
            mkdir -p "$BACKUP_DIR"
            BACKUP_CREATED=1
        fi
        mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
        cp -p "$dst" "$BACKUP_DIR/$rel"
    fi
}

echo "Installing tooling into: $TARGET_DIR"

for f in "${MANIFEST_FILES[@]}"; do
    [[ ! -f "$SRC/$f" ]] && continue
    backup_if_differs "$f"
    mkdir -p "$TARGET_DIR/$(dirname "$f")"
    cp "$SRC/$f" "$TARGET_DIR/$f"
    [[ "$f" == *.sh ]] && chmod +x "$TARGET_DIR/$f"
done

for d in "${MANIFEST_DIRS[@]}"; do
    [[ ! -d "$SRC/$d" ]] && continue
    while IFS= read -r abs_f; do
        rel="${abs_f#"$SRC"/}"
        backup_if_differs "$rel"
        mkdir -p "$TARGET_DIR/$(dirname "$rel")"
        cp "$abs_f" "$TARGET_DIR/$rel"
        [[ "$rel" == *.sh ]] && chmod +x "$TARGET_DIR/$rel"
    done < <(find "$SRC/$d" -type f | sort)
done

# Initialize user-owned configuration files ONLY if missing
for cfg in workspace.conf repos.csv services.csv; do
    if [[ -f "$SRC/$cfg" ]]; then
        if [[ ! -f "$TARGET_DIR/$cfg" ]]; then
            cp "$SRC/$cfg" "$TARGET_DIR/$cfg"
            echo "  + Created $cfg (edit this for your project)"
        else
            echo "  = Preserved existing $cfg"
        fi
    fi
done

# Merge or install .gitignore
for mf in "${MANIFEST_MERGES[@]}"; do
    [[ ! -f "$SRC/$mf" ]] && continue
    if [[ ! -f "$TARGET_DIR/$mf" ]]; then
        cp "$SRC/$mf" "$TARGET_DIR/$mf"
        echo "  + Created $mf"
    else
        missing_lines=()
        while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
            line=$(printf '%s' "$raw_line" | tr -d '\r')
            trimmed=$(trim_ws "$line")
            [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
            if ! grep -Fqx "$line" "$TARGET_DIR/$mf" 2>/dev/null; then
                missing_lines+=("$line")
            fi
        done < "$SRC/$mf"
        if [[ ${#missing_lines[@]} -gt 0 ]]; then
            backup_if_differs "$mf"
            {
                printf '\n# Added by workspace-repo-tools installer (%s)\n' "$TS"
                printf '%s\n' "${missing_lines[@]}"
            } >> "$TARGET_DIR/$mf"
            echo "  ~ Appended ${#missing_lines[@]} rule(s) to $mf"
        fi
    fi
done

# Ensure workspace directory placeholder exists
WS_REL_DIR="workspace"
if [[ -f "$TARGET_DIR/workspace.conf" ]]; then
    raw_ws=$(grep -E '^[[:space:]]*WORKSPACE_DIR[[:space:]]*=' "$TARGET_DIR/workspace.conf" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '\r' || true)
    raw_ws=$(trim_ws "$raw_ws")
    raw_ws="${raw_ws#\"}"
    raw_ws="${raw_ws%\"}"
    raw_ws="${raw_ws#\'}"
    raw_ws="${raw_ws%\'}"
    [[ -n "$raw_ws" ]] && WS_REL_DIR="$raw_ws"
fi
mkdir -p "$TARGET_DIR/$WS_REL_DIR"
touch "$TARGET_DIR/$WS_REL_DIR/.gitkeep"

# Record lock & cache
NOW_EPOCH=$(date +%s)
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date)

cat <<EOF > "$TARGET_DIR/.workspace-tools.lock"
INSTALLED_VERSION=$REMOTE_VER
INSTALLED_COMMIT=$REMOTE_SHA
UPSTREAM_URL=$UPSTREAM_URL
UPSTREAM_BRANCH=$UPSTREAM_BRANCH
UPDATED_AT=$NOW_ISO
EOF

cat <<EOF > "$TARGET_DIR/.workspace-tools-cache"
LAST_CHECK_EPOCH=$NOW_EPOCH
LAST_ATTEMPT_EPOCH=$NOW_EPOCH
REMOTE_COMMIT=$REMOTE_SHA
REMOTE_VERSION=$REMOTE_VER
MATCHED_COMMIT=$REMOTE_SHA
UPDATE_AVAILABLE=false
EOF

if [[ $BACKUP_CREATED -eq 1 ]]; then
    echo "Backups of replaced files saved to: .workspace-tools-backups/$TS"
fi

echo ""
echo "✓ workspace-repo-tools ($REMOTE_VER, commit ${REMOTE_SHA:0:7}) installed successfully!"
echo ""
echo "Next steps:"
echo "  1. Edit workspace.conf, repos.csv, and services.csv"
echo "  2. Run ./workspace.sh clone"
echo "  3. Run ./workspace.sh start   (or ./workspace.sh for interactive mode)"
echo ""

