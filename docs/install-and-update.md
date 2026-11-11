# Install & Self-Update Mechanics

This document covers [`install.sh`](../install.sh), [`install.ps1`](../install.ps1), HTTP update polling, cache throttling, and `./workspace.sh update` / `workspace.bat update` ([`src/sh/40_updater.sh`](../src/sh/40_updater.sh) / [`src/ps1/40_updater.ps1`](../src/ps1/40_updater.ps1)).

---

## 1. Strict 3-Point Git Preflight Checks

Both **first-time installation** and **every update** enforce identical Git safety preconditions (`check_git_clean_repo` in Bash, `Test-GitCleanRepo` in PowerShell, and inline preflight in installers):

1. **Git is installed**: Checks `git` is available on `PATH`.
2. **Current directory is the Git repository root**: Runs `git -C <dir> rev-parse --is-inside-work-tree`, then compares `pwd -P` (Unix) / `GetFullPath` (Windows) of `git rev-parse --show-toplevel` against `<dir>`. Installing or updating from a subdirectory or non-Git folder aborts cleanly.
3. **Working tree is completely clean**: Runs `git -C <dir> status --porcelain`. If any modified, staged, or untracked files exist, execution aborts and asks the user to stage/commit or stash pending changes first.

This ensures tool integration changes can always be reviewed and committed cleanly in isolation from feature work.

---

## 2. Ephemeral One-Line Installation Flow

`install.sh` and `install.ps1` are piped directly to `bash` or `iex` (or run with flags `--dir <path>`, `--version <ver>`, `--repo-url <url>`, `--release-url <url>` / `-TargetDir`, `-Version`, `-RepoUrl`, `-ReleaseUrl`) and clean up their temporary staging directories automatically without leaving any installer file behind in the user's repo.

### Step-by-Step Install Sequence
1. Run the 3 Git preflight checks against the target directory.
2. Fetch `release-meta.env` from:
   - Specified tag: `<RELEASES_BASE>/download/<tag>/release-meta.env`
   - Default (latest): `<RELEASES_BASE>/latest/download/release-meta.env`
3. Parse `VERSION`, `TAG`, and `CONFIG_SCHEMA_VERSION` from `release-meta.env`.
4. Download `SHA256SUMS.txt` plus all required release assets from `<RELEASES_BASE>/download/<TAG>/`:
   - `workspace.sh`, `workspace.ps1`, `workspace.bat`
   - `library-bundle-<ver>.sh`, `library-bundle-<ver>.ps1`, `library-bundle-<ver>.bat`
   - `workspace.conf.default`, `repos.csv.default`, `services.csv.default`, `gitignore.default`
5. Verify SHA-256 of every downloaded asset against `SHA256SUMS.txt` before touching the target repo.
6. Write the 3 wrappers (`workspace.{sh,ps1,bat}`) and cache the bundles inside `.workspace-tools/`.
7. Write an initial `.workspace-tools/update-cache` seeded with current timestamp and `UPDATE_AVAILABLE=false`.
8. Preserve any existing `workspace.conf`, `repos.csv`, `services.csv` (or create them from `.default`), then update `TOOLS_VERSION`, `CONFIG_SCHEMA_VERSION`, and `TOOLS_REPO_URL` in `workspace.conf`.
9. Create `.gitignore` from `gitignore.default`, or append any missing non-comment lines if `.gitignore` already exists.
10. Print user guidance with the exact integration commit message:
    ```text
    added integration of <TOOLS_REPO_URL>
    ```

---

## 3. HTTP Release Polling & Cache Throttling

### Why `release-meta.env` Over GitHub Releases CDN
Instead of querying `api.github.com` (which rate-limits unauthenticated IPs at 60 requests/hour) or spawning `git ls-remote`, release checking fetches a tiny static key-value file:

```text
<RELEASES_BASE_URL>/latest/download/release-meta.env
```

On GitHub (`https://github.com/<owner>/<repo>/releases/latest/download/release-meta.env`), GitHub's web server redirects cleanly to the latest release asset on the static CDN with no API token or quota. `release-meta.env` contains:
```ini
VERSION=1.0.0
TAG=v1.0.0
CONFIG_SCHEMA_VERSION=1
SCHEMA_NOTES=
```

This same layout (`latest/download/` and `download/v<ver>/`) also works transparently with `file://` local directories for offline E2E tests or custom artifact mirrors via `TOOLS_RELEASE_BASE_URL` / `WORKSPACE_RELEASE_URL`.

### Cache & Throttle Logic (`.workspace-tools/update-cache`)
To keep everyday `./workspace.sh` commands fast and silent offline:
- **File location**: `.workspace-tools/update-cache` (gitignored).
- **Stored keys**: `LAST_CHECK_EPOCH`, `LAST_ATTEMPT_EPOCH`, `REMOTE_VERSION`, `UPDATE_AVAILABLE`.
- **Disabled conditions**: If `DISABLE_AUTO_UPDATE_CHECK=true` in `workspace.conf` or `WORKSPACE_NO_UPDATE_CHECK=1` in environment, no check runs and no banner is shown.
- **Throttle intervals**:
  - Successful check cooldown: `UPDATE_CHECK_INTERVAL_HOURS * 3600` seconds (default 24 hours).
  - Failed/offline retry backoff: `900` seconds (15 minutes via `LAST_ATTEMPT_EPOCH`) so offline environments do not retry on every invocation.
- **CLI vs REPL timing**:
  - **Direct CLI commands** (`start`, `status`, `clone`, etc.) run `check_for_updates_banner --bg`, printing any cached banner synchronously and refreshing stale caches asynchronously via a detached `__refresh-cache` subprocess.
  - **Interactive REPL startup** runs a short synchronous check (`2s` timeout).
- **Version comparison (`is_version_newer`)**: Compares numeric dot-separated segments (`10#$rv` vs `10#$lv`) and pre-release suffixes (a stable release `1.0.0` is newer than pre-release `1.0.0-rc1`).

---

## 4. Self-Update Workflow (`update` / `check-update`)

- **`./workspace.sh check-update`**: Fetches `<RELEASES_BASE_URL>/latest/download/release-meta.env` synchronously (8s timeout), updates `.workspace-tools/update-cache`, and displays version/schema delta and `SCHEMA_NOTES` if newer.
- **`./workspace.sh update [--dry-run] [-y|--yes] [-f|--force] [--version <ver>]`**:
  1. Runs the 3-point Git preflight check (`check_git_clean_repo`).
  2. Fetches target/latest `release-meta.env` (10s timeout) and skips if already at or above remote version (unless `--force` or `--version` is passed).
  3. Downloads new wrappers, `library-bundle-<remote_ver>.{sh,ps1,bat}`, `SHA256SUMS.txt`, and `.default` config templates into an isolated staging directory and verifies every SHA-256 checksum.
  4. Prints an update plan and stops cleanly if `--dry-run` is active.
  5. Prompts confirmation unless `--yes` / `-y` is passed.
  6. Replaces `.workspace-tools/library-bundle-*` with the new versioned bundle files.
  7. Merges missing ignore rules from `gitignore.default` into `.gitignore`.
  8. Inspects config schema differences before mutating `workspace.conf` (`inspect_config_schema_changes` / `Test-ConfigSchemaChanges`):
     - `CONFIG_SCHEMA_VERSION` changed (`old -> new`)
     - Non-empty `SCHEMA_NOTES` from `release-meta.env`
     - New non-comment keys present in `workspace.conf.default` missing from local `workspace.conf`
     - `services.csv` or `repos.csv` header format mismatch against `.default`
  9. Updates `TOOLS_VERSION` and `CONFIG_SCHEMA_VERSION` in `workspace.conf` while keeping all `WORKSPACE_*` settings, `repos.csv`, and `services.csv` intact.
  10. Atomically installs updated `workspace.sh`, `workspace.ps1`, and `workspace.bat`, refreshes `update-cache`, cleans the staging directory, and prints commit instructions:
      ```text
      update integration of <TOOLS_REPO_URL> to version : <new_version>
      ```

