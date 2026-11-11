#!/bin/bash
# =============================================================================
# workspace-repo-tools Bootstrap Installer (macOS / Linux)
#
# One-line usage:
#   curl -fsSL https://github.com/BullTronics/workspace-repo-tools/releases/latest/download/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/BullTronics/workspace-repo-tools/main/install.sh | bash
# =============================================================================

set -euo pipefail

REPO_URL="${TOOLS_REPO_URL:-https://github.com/BullTronics/workspace-repo-tools}"
RELEASE_BASE_OVERRIDE="${WORKSPACE_RELEASE_URL:-}"
TARGET_TAG=""
TARGET_DIR=""

usage() {
    cat <<EOF
workspace-repo-tools installer

Usage:
  curl -fsSL https://github.com/BullTronics/workspace-repo-tools/releases/latest/download/install.sh | bash
  ./install.sh [--dir <path>] [--version <vX.Y.Z>] [--repo-url <url>] [--release-url <url>]

Options:
  --dir <path>          Target Git repository root (default: current directory)
  --version <ver>       Specific release tag or version (default: latest)
  --repo-url <url>      Upstream repository URL (default: $REPO_URL)
  --release-url <url>   Custom releases base URL (default: <repo-url>/releases)
  -h, --help            Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)
            [[ $# -lt 2 || -z "$2" ]] && { echo "Option '--dir' requires a path." >&2; exit 1; }
            TARGET_DIR="$2"; shift 2 ;;
        --version)
            [[ $# -lt 2 || -z "$2" ]] && { echo "Option '--version' requires a version." >&2; exit 1; }
            TARGET_TAG="$2"
            [[ "$TARGET_TAG" != v* ]] && TARGET_TAG="v$TARGET_TAG"
            shift 2 ;;
        --repo-url)
            [[ $# -lt 2 || -z "$2" ]] && { echo "Option '--repo-url' requires a URL." >&2; exit 1; }
            REPO_URL="${2%/}"; shift 2 ;;
        --release-url)
            [[ $# -lt 2 || -z "$2" ]] && { echo "Option '--release-url' requires a URL." >&2; exit 1; }
            RELEASE_BASE_OVERRIDE="${2%/}"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1 ;;
    esac
done

trim_ws() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

read_kv() {
    local file="$1" key="$2"
    [[ ! -f "$file" ]] && return 0
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        local line
        line=$(printf '%s' "$raw" | tr -d '\r')
        line=$(trim_ws "$line")
        [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
        local k="${line%%=*}"
        k=$(trim_ws "$k")
        if [[ "$k" == "$key" ]]; then
            local v="${line#*=}"
            v=$(trim_ws "$v")
            v="${v#\"}"; v="${v%\"}"
            v="${v#\'}"; v="${v%\'}"
            printf '%s' "$v"
            return 0
        fi
    done < "$file"
}

set_kv() {
    local file="$1" key="$2" val="$3"
    local tmp="${file}.tmp.$$"
    local found=0
    : > "$tmp"
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        local line trimmed
        line=$(printf '%s' "$raw" | tr -d '\r')
        trimmed=$(trim_ws "$line")
        if [[ -n "$trimmed" && "$trimmed" != \#* && "$trimmed" == *=* ]]; then
            local k
            k=$(trim_ws "${trimmed%%=*}")
            if [[ "$k" == "$key" ]]; then
                if [[ $found -eq 0 ]]; then
                    printf '%s=%s\n' "$key" "$val" >> "$tmp"
                    found=1
                fi
                continue
            fi
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$file"
    [[ $found -eq 0 ]] && printf '%s=%s\n' "$key" "$val" >> "$tmp"
    mv -f "$tmp" "$file"
}

http_get() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 20 "$url" -o "$dest" 2>/dev/null
        return $?
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 20 -O "$dest" "$url" 2>/dev/null
        return $?
    fi
    return 1
}

verify_sha() {
    local sums="$1" file="$2" asset="$3"
    [[ ! -f "$sums" ]] && return 0
    local expected actual=""
    expected=$(awk -v n="$asset" '{ f=$2; sub(/^\.\//,"",f); sub(/^\*/,"",f); if (f==n) { print tolower($1); exit } }' "$sums")
    [[ -z "$expected" ]] && return 0
    if command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$file" | awk '{print tolower($1)}')
    elif command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$file" | awk '{print tolower($1)}')
    fi
    if [[ -n "$actual" && "$actual" != "$expected" ]]; then
        echo "ERROR: Checksum verification failed for $asset." >&2
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# 1. Preflight Checks: Git installed, Git repo root, clean working tree
# -----------------------------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: Git is not installed. Please install Git and try again." >&2
    exit 1
fi

if [[ -z "$TARGET_DIR" ]]; then
    TARGET_DIR=$(pwd)
else
    if [[ ! -d "$TARGET_DIR" ]]; then
        echo "ERROR: Target directory does not exist: $TARGET_DIR" >&2
        exit 1
    fi
    TARGET_DIR=$(cd "$TARGET_DIR" && pwd)
fi

if ! git -C "$TARGET_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: Current directory is not a Git repository: $TARGET_DIR" >&2
    echo "Please initialize a Git repository first ('git init') and commit initial files." >&2
    exit 1
fi

TOP_LEVEL=$(git -C "$TARGET_DIR" rev-parse --show-toplevel)
PHYS_TOP=$(cd "$TOP_LEVEL" && pwd -P)
PHYS_DIR=$(cd "$TARGET_DIR" && pwd -P)
if [[ "$PHYS_TOP" != "$PHYS_DIR" ]]; then
    echo "ERROR: Please run install from the root of your Git repository:" >&2
    echo "  Repo root:   $PHYS_TOP" >&2
    echo "  Current dir: $PHYS_DIR" >&2
    exit 1
fi

PENDING=$(git -C "$TARGET_DIR" status --porcelain 2>/dev/null)
if [[ -n "$PENDING" ]]; then
    echo "ERROR: Current Git repository has pending uncommitted or untracked changes:" >&2
    printf '%s\n' "$PENDING" >&2
    echo "" >&2
    echo "Please stage and commit (or stash) pending changes before installing workspace-repo-tools." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# 2. Fetch release metadata and assets
# -----------------------------------------------------------------------------
if [[ -n "$RELEASE_BASE_OVERRIDE" ]]; then
    RELEASES_BASE="$RELEASE_BASE_OVERRIDE"
else
    RELEASES_BASE="$REPO_URL/releases"
fi

STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/wrt-install.XXXXXX")
trap 'rm -rf "$STAGE_DIR"' EXIT INT TERM

if [[ -n "$TARGET_TAG" ]]; then
    META_URL="$RELEASES_BASE/download/$TARGET_TAG/release-meta.env"
else
    META_URL="$RELEASES_BASE/latest/download/release-meta.env"
fi

echo "Fetching release metadata from $META_URL..."
if ! http_get "$META_URL" "$STAGE_DIR/release-meta.env"; then
    echo "ERROR: Failed to fetch release metadata from $META_URL" >&2
    exit 1
fi

REL_VER=$(read_kv "$STAGE_DIR/release-meta.env" "VERSION")
REL_TAG=$(read_kv "$STAGE_DIR/release-meta.env" "TAG")
REL_SCHEMA=$(read_kv "$STAGE_DIR/release-meta.env" "CONFIG_SCHEMA_VERSION")
[[ -z "$REL_TAG" ]] && REL_TAG="v$REL_VER"
[[ -z "$REL_SCHEMA" ]] && REL_SCHEMA="1"

if [[ -z "$REL_VER" ]]; then
    echo "ERROR: Invalid release-meta.env (missing VERSION)." >&2
    exit 1
fi

DL_BASE="$RELEASES_BASE/download/$REL_TAG"
echo "Downloading workspace-repo-tools $REL_TAG into $TARGET_DIR..."

http_get "$DL_BASE/SHA256SUMS.txt" "$STAGE_DIR/SHA256SUMS.txt" || true

BUNDLE_SH="library-bundle-${REL_VER}.sh"
BUNDLE_PS1="library-bundle-${REL_VER}.ps1"
BUNDLE_BAT="library-bundle-${REL_VER}.bat"

for f in workspace.sh workspace.ps1 workspace.bat "$BUNDLE_SH" "$BUNDLE_PS1" "$BUNDLE_BAT" workspace.conf.default repos.csv.default services.csv.default gitignore.default; do
    if ! http_get "$DL_BASE/$f" "$STAGE_DIR/$f"; then
        echo "ERROR: Failed to download release asset: $DL_BASE/$f" >&2
        exit 1
    fi
    verify_sha "$STAGE_DIR/SHA256SUMS.txt" "$STAGE_DIR/$f" "$f"
done

# -----------------------------------------------------------------------------
# 3. Install 3 unified scripts + configs + gitignored .workspace-tools/ bundle
# -----------------------------------------------------------------------------
cp "$STAGE_DIR/workspace.sh" "$TARGET_DIR/workspace.sh"
chmod +x "$TARGET_DIR/workspace.sh"
cp "$STAGE_DIR/workspace.ps1" "$TARGET_DIR/workspace.ps1"
cp "$STAGE_DIR/workspace.bat" "$TARGET_DIR/workspace.bat"

STATE_DIR="$TARGET_DIR/.workspace-tools"
mkdir -p "$STATE_DIR"
find "$STATE_DIR" -maxdepth 1 -name 'library-bundle-*' -exec rm -f {} + 2>/dev/null || true
cp "$STAGE_DIR/$BUNDLE_SH" "$STATE_DIR/$BUNDLE_SH"
cp "$STAGE_DIR/$BUNDLE_PS1" "$STATE_DIR/$BUNDLE_PS1"
cp "$STAGE_DIR/$BUNDLE_BAT" "$STATE_DIR/$BUNDLE_BAT"
chmod +x "$STATE_DIR/$BUNDLE_SH"

NOW_EPOCH=$(date +%s)
cat <<EOF > "$STATE_DIR/update-cache"
LAST_CHECK_EPOCH=$NOW_EPOCH
LAST_ATTEMPT_EPOCH=$NOW_EPOCH
REMOTE_VERSION=$REL_VER
UPDATE_AVAILABLE=false
EOF

if [[ ! -f "$TARGET_DIR/workspace.conf" ]]; then
    cp "$STAGE_DIR/workspace.conf.default" "$TARGET_DIR/workspace.conf"
    echo "  + Created workspace.conf"
else
    echo "  = Preserved existing workspace.conf (updated TOOLS_VERSION=$REL_VER)"
fi
set_kv "$TARGET_DIR/workspace.conf" "TOOLS_VERSION" "$REL_VER"
set_kv "$TARGET_DIR/workspace.conf" "CONFIG_SCHEMA_VERSION" "$REL_SCHEMA"
set_kv "$TARGET_DIR/workspace.conf" "TOOLS_REPO_URL" "$REPO_URL"

if [[ ! -f "$TARGET_DIR/repos.csv" ]]; then
    cp "$STAGE_DIR/repos.csv.default" "$TARGET_DIR/repos.csv"
    echo "  + Created repos.csv"
else
    echo "  = Preserved existing repos.csv"
fi

if [[ ! -f "$TARGET_DIR/services.csv" ]]; then
    cp "$STAGE_DIR/services.csv.default" "$TARGET_DIR/services.csv"
    echo "  + Created services.csv"
else
    echo "  = Preserved existing services.csv"
fi

if [[ ! -f "$TARGET_DIR/.gitignore" ]]; then
    cp "$STAGE_DIR/gitignore.default" "$TARGET_DIR/.gitignore"
    echo "  + Created .gitignore"
else
    missing_rules=()
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        line=$(printf '%s' "$raw" | tr -d '\r')
        trimmed=$(trim_ws "$line")
        [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
        if ! grep -Fqx "$line" "$TARGET_DIR/.gitignore" 2>/dev/null; then
            missing_rules+=("$line")
        fi
    done < "$STAGE_DIR/gitignore.default"
    if [[ ${#missing_rules[@]} -gt 0 ]]; then
        {
            printf '\n# Added by workspace-repo-tools installer\n'
            printf '%s\n' "${missing_rules[@]}"
        } >> "$TARGET_DIR/.gitignore"
        echo "  ~ Updated .gitignore (+${#missing_rules[@]} rule(s))"
    else
        echo "  = .gitignore already up to date"
    fi
fi

rm -rf "$STAGE_DIR"
trap - EXIT INT TERM

echo ""
echo "✓ workspace-repo-tools $REL_TAG installed successfully!"
echo ""
echo "Installed files:"
echo "  Scripts (committed): workspace.sh, workspace.ps1, workspace.bat"
echo "  Configs (committed): workspace.conf, repos.csv, services.csv, .gitignore"
echo "  Bundle (gitignored): .workspace-tools/$BUNDLE_SH (and .ps1/.bat)"
echo ""
echo "Next steps:"
echo "  1. Update workspace.conf, repos.csv, and services.csv for your project"
echo "  2. Verify the setup (e.g. run './workspace.sh status' and './workspace.sh clone')"
echo "  3. Commit the integration changes with:"
echo "     git add workspace.sh workspace.ps1 workspace.bat workspace.conf repos.csv services.csv .gitignore"
echo "     git commit -m \"added integration of $REPO_URL\""
echo ""
