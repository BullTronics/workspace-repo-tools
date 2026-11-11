# Architecture & Bundle Model

This document explains how the thin wrappers, compiled versioned bundles, source modules, and cross-platform helpers work together at build time and runtime.

---

## 1. Two-World File Separation

| Location | Tracked in Git? | Contents | Purpose |
| --- | --- | --- | --- |
| User repo root | **Yes** | `workspace.sh`, `workspace.ps1`, `workspace.bat`, `workspace.conf`, `repos.csv`, `services.csv`, `.gitignore` | Version-controlled entrypoints and project configuration |
| User repo `.workspace-tools/` | **No** (gitignored) | `library-bundle-<version>.{sh,ps1,bat}`, `update-cache` | Executable implementation pinned to `TOOLS_VERSION` + local update check timestamp |
| User repo runtime dirs | **No** (gitignored) | `workspace/`, `.pids/`, `.runners/`, `logs/`, `.env*` | Cloned child repos, background PIDs, generated window launch scripts, service logs, secrets |

By pinning `TOOLS_VERSION` in [`workspace.conf`](../workspace.conf) rather than hardcoding the implementation into committed scripts:
- Downstream repos avoid noisy multi-thousand-line diffs on tool upgrades.
- Every developer on a project automatically runs the exact same tooling version committed in `workspace.conf`.
- Checking out an older commit in the user repo automatically runs the older matching `library-bundle-<version>` (downloading it if needed).

---

## 2. Thin Wrapper Resolution Flow

Both [`workspace.sh.tmpl`](../src/wrapper/workspace.sh.tmpl) and [`workspace.ps1.tmpl`](../src/wrapper/workspace.ps1.tmpl) (with [`workspace.bat`](../src/wrapper/workspace.bat) forwarding via `powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0workspace.ps1" %*`) perform the exact same bootstrap sequence before delegating:

1. **Resolve `SCRIPT_DIR`**: Anchors all lookups relative to the wrapper script location.
2. **Parse `workspace.conf`**:
   - Reads `TOOLS_VERSION` (falls back to `@DEFAULT_VERSION@` baked at build time if missing).
   - Reads `TOOLS_REPO_URL` (falls back to `@REPO_URL@`, trailing slash stripped).
   - Determines `RELEASES_BASE` in priority order:
     1. Environment override `WORKSPACE_RELEASE_URL` (used for testing / `file://` mirrors)
     2. `TOOLS_RELEASE_BASE_URL` in `workspace.conf`
     3. `<TOOLS_REPO_URL>/releases`
3. **Locate bundle by filename (zero file inspection needed)**:
   - Unix: `.workspace-tools/library-bundle-<TOOLS_VERSION>.sh`
   - Windows: `.workspace-tools/library-bundle-<TOOLS_VERSION>.ps1` (plus optional `.bat`)
4. **Auto-download & SHA-256 verification on cache miss**:
   - Downloads from `<RELEASES_BASE>/download/v<TOOLS_VERSION>/<bundle>` and `SHA256SUMS.txt` into a temporary directory using `curl` / `wget` (Unix, 20s timeout) or `Invoke-WebRequest` with TLS 1.2 enabled / `file://` copy (PowerShell, 20s timeout).
   - Verifies SHA-256 (`shasum -a 256` / `sha256sum` on Unix; `Get-FileHash -Algorithm SHA256` on Windows). Aborts immediately on mismatch before touching `.workspace-tools/`.
   - Cleans older `library-bundle-*.{sh,ps1,bat}` files from `.workspace-tools/` and promotes the verified bundle.
5. **Delegate execution**:
   - Sets `WORKSPACE_ROOT_DIR="$SCRIPT_DIR"` (env var `$env:WORKSPACE_ROOT_DIR` on Windows).
   - Executes `library-bundle-<TOOLS_VERSION>.sh "$@"` (or `& $bundlePs1Path @args` on PowerShell).

---

## 3. Modular Assembly Order (`scripts/build-release.sh`)

To keep modules maintainable while shipping a single executable bundle per platform, [`scripts/build-release.sh`](../scripts/build-release.sh) concatenates files in a strict dependency order:

### Bash Bundle (`library-bundle-<ver>.sh`)
1. `src/sh/00_common.sh` — header (`#!/bin/bash`), `BUNDLE_VERSION`, `BUNDLE_SCHEMA_VERSION`, `SCRIPT_DIR` root resolution, shared helpers
2. `templates/*/runner.sh` — embedded service runner functions (`run_template_spring_boot`, `run_template_flutter_web`, `run_template_go`, `run_template_vite`)
3. `src/sh/[0-9][0-9]_*.sh` (excluding `00_common.sh`, sorted numerically):
   - `10_config.sh` (runs `load_workspace_conf` on load)
   - `20_git.sh`
   - `30_services.sh`
   - `40_updater.sh`
   - `99_main.sh` (entrypoint dispatcher & REPL at the bottom so all functions are defined first)

### PowerShell Bundle (`library-bundle-<ver>.ps1` + `.bat`)
1. `src/ps1/00_common.ps1`
2. `templates/*/runner.ps1` (`Invoke-TemplateSpringBoot`, `Invoke-TemplateFlutterWeb`, `Invoke-TemplateGo`, `Invoke-TemplateVite`)
3. `src/ps1/[0-9][0-9]_*.ps1` (`10_config.ps1` .. `99_main.ps1`)
4. Sibling `.bat` shim invoking `library-bundle-<ver>.ps1 %*`

After concatenation, `sed` replaces build tokens:
- `@VERSION@`, `@CONFIG_SCHEMA_VERSION@`, `@REPO_URL@` inside bundles
- `@DEFAULT_VERSION@`, `@DEFAULT_SCHEMA_VERSION@`, `@REPO_URL@` inside wrappers and installers

---

## 4. Path Resolution & Internal Runtime Hooks

### Resolving Root When Living in `.workspace-tools/`
Because the bundle file physically resides inside `<repo>/.workspace-tools/library-bundle-<ver>.sh`, naive `dirname "$0"` would point to `.workspace-tools/`. Both [`00_common.sh`](../src/sh/00_common.sh#L9-L15) and [`00_common.ps1`](../src/ps1/00_common.ps1#L1-L10) handle this in two ways:
1. Prefer `WORKSPACE_ROOT_DIR` set by the wrapper.
2. Otherwise check whether `basename(dirname($0)) == ".workspace-tools"` and walk up one level (`..`).

### Internal Bundle Hooks (`99_main`)
Before CLI dispatch or REPL initialization, [`99_main.sh`](../src/sh/99_main.sh#L187-L199) and [`99_main.ps1`](../src/ps1/99_main.ps1#L190-L202) intercept two internal subcommands:
- **`__run-service <slug>`**: Used by generated terminal window scripts (`.runners/run_<slug>.{command,ps1}`) to execute a single service inside the bundle environment (`.env` loading, `PORT` export, template runner execution) without reprinting the workspace banner or running update checks.
- **`__refresh-cache`**: Spawned asynchronously in the background by `check_for_updates_banner --bg` (Bash) or `Start-Process` hidden PowerShell (Windows) so network checks never block interactive CLI commands.

---

## 5. Cross-Platform Portability & Parity Constraints

- **macOS Bash 3.2 compatibility (`src/sh/*.sh`)**: All Unix modules avoid Bash 4+ constructs (`declare -A` associative arrays, `mapfile`/`readarray`, `${var,,}` lowercasing). Case folding uses `tr '[:upper:]' '[:lower:]'`, CSV structured storage uses parallel indexed arrays (`SVC_NAMES`, `SVC_SLUGS`, etc.), and CSV splitting uses `awk` + ASCII Unit Separator (`\037`).
- **Physical directory resolution (`pwd -P`)**: On macOS where `/tmp` and `/var` symlink into `/private/...`, `check_git_clean_repo` compares physical paths (`pwd -P`) of `git rev-parse --show-toplevel` vs current directory so legitimate repo roots never falsely fail root checks.
- **Self-updating running scripts safely**:
  - In `40_updater.sh`, `workspace.sh` is staged via `workspace.sh.new.$$` then atomically `mv -f` replaced, and `cmd_update` finishes with `exit 0` immediately so Bash does not keep reading modified offsets.
  - Because `library-bundle-<new_ver>` uses a new versioned filename, upgrading never overwrites the currently executing bundle file on disk.
- **Windows TLS & Flutter Chrome wrapper**:
  - `workspace.ps1`, `install.ps1`, and `00_common.ps1` explicitly enable `[Net.SecurityProtocolType]::Tls12` before calling `Invoke-WebRequest` for compatibility with older Windows PowerShell 5.1 hosts.
  - [`templates/flutter-web/runner.ps1`](../templates/flutter-web/runner.ps1) compiles a small C# helper (`chrome-launcher.exe` via `Add-Type`) so Flutter's `--user-data-dir` flag works reliably with Windows Chrome without arg-splitting issues.

