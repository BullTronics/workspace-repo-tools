#!/bin/bash
# =============================================================================
# scripts/build-release.sh
# Compiles modular src/sh, src/ps1, templates/, and src/wrapper/ into
# standalone release artifacts under dist/.
# =============================================================================

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

VERSION_ARG="${1:-}"
if [[ -z "$VERSION_ARG" ]]; then
    if [[ -f "$ROOT_DIR/VERSION" ]]; then
        VERSION_ARG=$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")
    else
        VERSION_ARG="1.0.0"
    fi
fi
VERSION="${VERSION_ARG#v}"

SCHEMA_VERSION="${2:-}"
if [[ -z "$SCHEMA_VERSION" ]]; then
    if [[ -f "$ROOT_DIR/CONFIG_SCHEMA_VERSION" ]]; then
        SCHEMA_VERSION=$(tr -d '[:space:]' < "$ROOT_DIR/CONFIG_SCHEMA_VERSION")
    else
        SCHEMA_VERSION="1"
    fi
fi

REPO_URL="${TOOLS_REPO_URL:-https://github.com/BullTronics/workspace-repo-tools}"
DIST_DIR="${DIST_OUTPUT_DIR:-$ROOT_DIR/dist}"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

BUNDLE_SH="$DIST_DIR/library-bundle-${VERSION}.sh"
BUNDLE_PS1="$DIST_DIR/library-bundle-${VERSION}.ps1"
BUNDLE_BAT="$DIST_DIR/library-bundle-${VERSION}.bat"

# -----------------------------------------------------------------------------
# 1. Build library-bundle-<version>.sh (header -> templates -> src/sh)
# -----------------------------------------------------------------------------
{
    cat "$ROOT_DIR/src/sh/00_common.sh"
    echo ""
    for runner in "$ROOT_DIR"/templates/*/runner.sh; do
        [[ -f "$runner" ]] || continue
        echo "# --- Embedded Template: $(basename "$(dirname "$runner")") ---"
        cat "$runner"
        echo ""
    done
    for mod in "$ROOT_DIR"/src/sh/[0-9][0-9]_*.sh; do
        [[ "$(basename "$mod")" == "00_common.sh" ]] && continue
        echo "# --- Module: $(basename "$mod") ---"
        cat "$mod"
        echo ""
    done
} | sed \
    -e "s|@VERSION@|${VERSION}|g" \
    -e "s|@CONFIG_SCHEMA_VERSION@|${SCHEMA_VERSION}|g" \
    -e "s|@REPO_URL@|${REPO_URL}|g" > "$BUNDLE_SH"
chmod +x "$BUNDLE_SH"

# -----------------------------------------------------------------------------
# 2. Build library-bundle-<version>.ps1 + .bat
# -----------------------------------------------------------------------------
{
    cat "$ROOT_DIR/src/ps1/00_common.ps1"
    echo ""
    for runner in "$ROOT_DIR"/templates/*/runner.ps1; do
        [[ -f "$runner" ]] || continue
        echo "# --- Embedded Template: $(basename "$(dirname "$runner")") ---"
        cat "$runner"
        echo ""
    done
    for mod in "$ROOT_DIR"/src/ps1/[0-9][0-9]_*.ps1; do
        [[ "$(basename "$mod")" == "00_common.ps1" ]] && continue
        echo "# --- Module: $(basename "$mod") ---"
        cat "$mod"
        echo ""
    done
} | sed \
    -e "s|@VERSION@|${VERSION}|g" \
    -e "s|@CONFIG_SCHEMA_VERSION@|${SCHEMA_VERSION}|g" \
    -e "s|@REPO_URL@|${REPO_URL}|g" > "$BUNDLE_PS1"

cat <<EOF > "$BUNDLE_BAT"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0library-bundle-${VERSION}.ps1" %*
EOF

# -----------------------------------------------------------------------------
# 3. Build thin workspace.{sh,ps1,bat} wrappers
# -----------------------------------------------------------------------------
sed \
    -e "s|@DEFAULT_VERSION@|${VERSION}|g" \
    -e "s|@DEFAULT_SCHEMA_VERSION@|${SCHEMA_VERSION}|g" \
    -e "s|@REPO_URL@|${REPO_URL}|g" \
    "$ROOT_DIR/src/wrapper/workspace.sh.tmpl" > "$DIST_DIR/workspace.sh"
chmod +x "$DIST_DIR/workspace.sh"

sed \
    -e "s|@DEFAULT_VERSION@|${VERSION}|g" \
    -e "s|@DEFAULT_SCHEMA_VERSION@|${SCHEMA_VERSION}|g" \
    -e "s|@REPO_URL@|${REPO_URL}|g" \
    "$ROOT_DIR/src/wrapper/workspace.ps1.tmpl" > "$DIST_DIR/workspace.ps1"

cp "$ROOT_DIR/src/wrapper/workspace.bat" "$DIST_DIR/workspace.bat"

# -----------------------------------------------------------------------------
# 4. Package installers, defaults, and release-meta.env
# -----------------------------------------------------------------------------
sed \
    -e "s|@DEFAULT_VERSION@|${VERSION}|g" \
    -e "s|@DEFAULT_SCHEMA_VERSION@|${SCHEMA_VERSION}|g" \
    -e "s|@REPO_URL@|${REPO_URL}|g" \
    "$ROOT_DIR/install.sh" > "$DIST_DIR/install.sh"
chmod +x "$DIST_DIR/install.sh"

sed \
    -e "s|@DEFAULT_VERSION@|${VERSION}|g" \
    -e "s|@DEFAULT_SCHEMA_VERSION@|${SCHEMA_VERSION}|g" \
    -e "s|@REPO_URL@|${REPO_URL}|g" \
    "$ROOT_DIR/install.ps1" > "$DIST_DIR/install.ps1"

# Ensure workspace.conf.default has the built VERSION and CONFIG_SCHEMA_VERSION
cp "$ROOT_DIR/workspace.conf" "$DIST_DIR/workspace.conf.default"
if grep -q '^TOOLS_VERSION=' "$DIST_DIR/workspace.conf.default"; then
    sed "s|^TOOLS_VERSION=.*|TOOLS_VERSION=${VERSION}|" "$DIST_DIR/workspace.conf.default" > "$DIST_DIR/workspace.conf.default.tmp"
    mv "$DIST_DIR/workspace.conf.default.tmp" "$DIST_DIR/workspace.conf.default"
fi
if grep -q '^CONFIG_SCHEMA_VERSION=' "$DIST_DIR/workspace.conf.default"; then
    sed "s|^CONFIG_SCHEMA_VERSION=.*|CONFIG_SCHEMA_VERSION=${SCHEMA_VERSION}|" "$DIST_DIR/workspace.conf.default" > "$DIST_DIR/workspace.conf.default.tmp"
    mv "$DIST_DIR/workspace.conf.default.tmp" "$DIST_DIR/workspace.conf.default"
fi

cp "$ROOT_DIR/repos.csv" "$DIST_DIR/repos.csv.default"
cp "$ROOT_DIR/services.csv" "$DIST_DIR/services.csv.default"
sed -e '/^# Release build output/d' -e '/^dist\/$/d' "$ROOT_DIR/.gitignore" > "$DIST_DIR/gitignore.default"

SCHEMA_NOTES="${SCHEMA_NOTES:-}"
cat <<EOF > "$DIST_DIR/release-meta.env"
VERSION=${VERSION}
TAG=v${VERSION}
CONFIG_SCHEMA_VERSION=${SCHEMA_VERSION}
SCHEMA_NOTES=${SCHEMA_NOTES}
EOF

# -----------------------------------------------------------------------------
# 5. Validate bash syntax & generate SHA256SUMS.txt
# -----------------------------------------------------------------------------
bash -n "$BUNDLE_SH"
bash -n "$DIST_DIR/workspace.sh"
bash -n "$DIST_DIR/install.sh"

(
    cd "$DIST_DIR"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -- * > SHA256SUMS.txt
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- * > SHA256SUMS.txt
    fi
)

echo "✓ Built release v${VERSION} (schema ${SCHEMA_VERSION}) into: $DIST_DIR"
ls -1 "$DIST_DIR"
