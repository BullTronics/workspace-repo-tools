# Workspace Repo Tools

A generic, zero-dependency multi-repository workspace template for cloning, syncing, and running local development services across **macOS**, **Linux**, and **Windows**.

---

## Quick Start

### First-Time Setup

Choose whichever fits your workflow:

#### Option A: One-Line Bootstrap Installer (Empty Folder or Existing Workspace)
Safely installs tooling scripts and `templates/` into the current directory while preserving any existing `workspace.conf`, `repos.csv`, `services.csv`, and `workspace/` contents:

- **macOS / Linux:**
  ```bash
  curl -fsSL https://raw.githubusercontent.com/BullTronics/workspace-repo-tools/main/install.sh | bash
  # Or target a specific directory:
  curl -fsSL https://raw.githubusercontent.com/BullTronics/workspace-repo-tools/main/install.sh | bash -s -- --dir ./my-workspace
  ```
- **Windows (PowerShell):**
  ```powershell
  irm https://raw.githubusercontent.com/BullTronics/workspace-repo-tools/main/install.ps1 | iex
  ```

#### Option B: GitHub Template Repository
1. On `https://github.com/BullTronics/workspace-repo-tools`, click **Use this template** to create your project's own repository.
2. Clone your new repository locally.

---

### Configure & Run

1. **Customize project branding** in [`workspace.conf`](workspace.conf):
   ```ini
   WORKSPACE_NAME=My Project
   WORKSPACE_PROMPT=myproj
   WORKSPACE_DIR=workspace
   ```
2. **Configure Git repositories** in [`repos.csv`](repos.csv):
   ```csv
   url,path,branch
   git@github.com:my-org/api.git,api,main
   git@github.com:my-org/web.git,web,
   ```
3. **Configure runnable services** in [`services.csv`](services.csv):
   ```csv
   name,emoji,path,port,cmd_unix,cmd_win,load_env_file,stop_pattern,hints
   api,📡,api,8080,run-local.sh,run-local.bat,true,spring-boot:run,
   web,🌐,web,5173,npm run dev,npm run dev,false,vite,
   ```
4. **Clone repositories & start services**:
   - **macOS / Linux:**
     ```bash
     ./workspace.sh clone
     ./workspace.sh start
     ```
   - **Windows (CMD / PowerShell):**
     ```bat
     workspace.bat clone
     workspace.bat start
     ```
   Or launch the interactive shell with no arguments: `./workspace.sh` (or `workspace.bat`).

---

## Directory Structure

```text
.
├── workspace.conf          # Workspace display name, REPL prompt, and repos directory
├── repos.csv               # Git repositories managed by git-all
├── services.csv            # Local services managed by run-local
├── workspace.sh/.ps1/.bat                # Unified CLI & interactive REPL (delegates to git-all, run-local, updater)
├── git-all.sh/.ps1/.bat                  # Multi-repo Git manager
├── run-local.sh/.ps1/.bat                # Multi-service local runner
├── workspace-repo-tools-updater.*        # Upstream template checker & safe upgrader
├── VERSION                               # Upstream tooling version
├── updater-manifest.txt                  # Managed tooling file list for upgrades
├── templates/              # Starter runner scripts to copy into service repos
│   ├── spring-boot-maven/
│   ├── flutter-web/
│   ├── go-service/
│   └── node-vite/
└── workspace/              # Gitignored directory where repositories are cloned
```

---

## Configuration Reference

### 1. `workspace.conf`
| Key | Default | Description |
| --- | --- | --- |
| `WORKSPACE_NAME` | `Workspace` | Display title shown in banners and terminal window titles |
| `WORKSPACE_PROMPT` | `workspace` | Interactive REPL prompt prefix |
| `WORKSPACE_DIR` | `workspace` | Relative directory where repositories are cloned (must not escape root) |
| `TOOLS_UPSTREAM_URL` | `https://github.com/BullTronics/workspace-repo-tools.git` | Upstream repository checked by `workspace-repo-tools-updater` |
| `TOOLS_UPSTREAM_BRANCH` | `main` | Upstream branch to track |
| `TOOLS_RAW_BASE_URL` | *(auto-derived for GitHub)* | Optional raw base URL override for fetching `VERSION` |
| `DISABLE_AUTO_UPDATE_CHECK` | `false` | Set to `true` to disable automatic throttled update checks & notices |
| `UPDATE_CHECK_INTERVAL_HOURS` | `24` | Minimum hours between automatic background update checks |

### 2. `repos.csv`
Supports `#` comment lines, blank lines, and either `url,path` or `url,path,branch` headers:
- `url`: Git clone URL (SSH or HTTPS).
- `path`: Relative target directory inside `WORKSPACE_DIR` (absolute paths and `..` traversal are rejected). Supports monorepos or nested paths like `services/api`.
- `branch` *(optional)*: Branch passed to `git clone -b <branch>` when cloning.

### 3. `services.csv`
Decouples runnable services from `repos.csv` so you can:
- Omit non-runnable repositories (shared libraries, docs, infra).
- Declare multiple services from a single monorepo (e.g., `my-monorepo/api`, `my-monorepo/ui`).
- Run either a script inside the service directory (`run-local.sh` / `run-local.bat`) **or** an inline command (`npm run dev`).

| Column | Required | Description |
| --- | --- | --- |
| `name` | Yes | Unique service identifier (case-insensitive CLI target) |
| `emoji` | No | Optional icon shown in status and window titles (`-` or empty for none) |
| `path` | Yes | Relative path inside `WORKSPACE_DIR` |
| `port` | No | Default TCP listening port (`-` or empty for portless workers). Overridden at runtime by `PORT=` in `<service_dir>/.env` if present |
| `cmd_unix` | No | Script filename inside service dir or inline shell command (defaults to `run-local.sh`) |
| `cmd_win` | No | Script filename inside service dir (`.bat`, `.cmd`, `.ps1`) or inline command (defaults to `run-local.bat`) |
| `load_env_file` | No | `true` or `false` (default `false`). When `true`, `<service_dir>/.env` **must exist** before startup — missing `.env` fails immediately instead of starting; valid `.env` variables are loaded strictly into that service's isolated environment |
| `stop_pattern` | No | Optional `;`-separated command-line patterns used by `force-stop` to clean up orphaned child processes |
| `hints` | No | Optional keyboard-shortcut or usage note printed in interactive terminal windows |

---

## Command Reference

### Unified Launcher (`./workspace.sh` or `workspace.bat`)
Run without arguments for interactive REPL mode, or pass commands directly:
- **Repository commands**: `clone`, `pull [args...]`, `fetch [args...]`, `repo-status [-all | <repo>]`, `log`, `branch`, `checkout <branch>`, `exec <git-cmd> [args...]`, `git <git-all-args...>`, `--repo <name> <git-cmd>`
- **Service commands**: `start [svc] [--bg]`, `stop [svc]`, `restart [svc] [--bg]`, `force-stop`, `status`, `logs <svc> [lines]`
- **Tooling updater commands**: `check-update`, `upgrade [--dry-run] [--yes]`

### Git Tools (`./git-all.sh` or `git-all.bat`)
```bash
./git-all.sh clone
./git-all.sh status                  # Concise summary of dirty/ahead/behind repos
./git-all.sh status -all             # Summary across all configured repos
./git-all.sh status backend-repo     # Full git status for matching repo
./git-all.sh pull --rebase
./git-all.sh --repo backend-repo pull
./git-all.sh exec remote -v
```

### Service Runner (`./run-local.sh` or `run-local.bat`)
```bash
./run-local.sh                       # Interactive REPL mode (Ctrl+C / quit stops services)
./run-local.sh start                 # Launch all services in terminal windows/tabs
./run-local.sh start backend --bg    # Launch a single service in background
./run-local.sh logs backend 50       # Tail background log file
./run-local.sh status                # Show running / starting / stopped status
./run-local.sh stop [service]        # Stop all or one service
./run-local.sh force-stop            # Kill tracked services + port/stop_pattern orphans
```

---

## Upgrading Tooling (`workspace-repo-tools-updater`)

Projects bootstrapped from `https://github.com/BullTronics/workspace-repo-tools` maintain their own Git history and configuration. When `DISABLE_AUTO_UPDATE_CHECK=false` (the default), `workspace` and `run-local` perform a throttled check (once every `UPDATE_CHECK_INTERVAL_HOURS`, 2s timeout, silent if offline) by comparing local `VERSION` against `https://raw.githubusercontent.com/BullTronics/workspace-repo-tools/<branch>/VERSION` (automatically falling back to `git ls-remote` for private or non-GitHub remotes) and display a notice whenever an update is available.

```bash
# Check if updates are available
./workspace-repo-tools-updater.sh check       # or: ./workspace.sh check-update

# Preview upgrade changes without modifying files
./workspace-repo-tools-updater.sh upgrade --dry-run

# Show line-by-line diff of local vs upstream tooling scripts
./workspace-repo-tools-updater.sh diff

# Apply upgrade (backs up modified tooling files to .workspace-tools-backups/)
./workspace-repo-tools-updater.sh upgrade     # or: ./workspace.sh upgrade
```

On Windows, run `workspace-repo-tools-updater.bat check` / `workspace-repo-tools-updater.bat upgrade` (or `workspace.bat check-update` / `workspace.bat upgrade`).

### What Gets Upgraded vs Preserved
- **Upgraded**: Root runner scripts (`workspace.*`, `git-all.*`, `run-local.*`, `workspace-repo-tools-updater.*`), `VERSION`, `updater-manifest.txt`, `templates/`, and `README.md`.
- **Merged**: Missing rules from upstream `.gitignore` are appended cleanly without removing your custom ignore rules.
- **Always Preserved**: `workspace.conf`, `repos.csv`, `services.csv`, `workspace/` (your cloned repositories), `.env*`, `.pids/`, `.runners/`, and `logs/`.

---

## Starter Templates (`templates/`)
Copy the matching folder's files into a service repository (and customize `.env.example` → `.env`) if your service prefers repo-local runner scripts instead of inline `services.csv` commands:
- `templates/spring-boot-maven/` — Spring Boot + Maven (`run-local.*`, `start-server.ps1`, `.env.example`)
- `templates/flutter-web/` — Flutter Web with isolated Chrome user-data directory (`run-local.*`, `.env.example`)
- `templates/go-service/` — Go HTTP service or background worker (`run-local.*`, `.env.example`)
- `templates/node-vite/` — Node / Vite / React / Vue dev server (`run-local.*`, `.env.example`)

