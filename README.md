# Workspace Repo Tools

A modular, unified multi-repository workspace toolset for cloning, syncing, and running local development services across **macOS**, **Linux**, and **Windows**.

User repositories commit only **3 thin wrapper scripts** (`workspace.sh`, `workspace.ps1`, `workspace.bat`) alongside their workspace configuration (`workspace.conf`, `repos.csv`, `services.csv`, `.gitignore`). At runtime, the wrappers automatically fetch and verify the version-pinned `library-bundle-<version>.*` release artifact into the gitignored `.workspace-tools/` directory (like the Gradle Wrapper).

> **Contributors & Maintainers:** See [`docs/info.md`](docs/info.md) for the internal architecture, module layout, update protocol, and release pipeline design.

---

## Quick Start

### First-Time Installation

Before running the installer in a project repository, ensure:
1. `git` is installed.
2. You are at the **root of an initialized Git repository**.
3. Your working tree has **no uncommitted or untracked changes** (stage or commit pending work first).

Then run the ephemeral one-line installer (no installer file is left behind in your repository):

- **macOS / Linux:**
  ```bash
  curl -fsSL https://github.com/BullTronics/workspace-repo-tools/releases/latest/download/install.sh | bash
  # Install a specific release or target directory:
  curl -fsSL https://github.com/BullTronics/workspace-repo-tools/releases/latest/download/install.sh | bash -s -- --dir ./my-workspace --version v1.0.0
  ```
- **Windows (PowerShell):**
  ```powershell
  irm https://github.com/BullTronics/workspace-repo-tools/releases/latest/download/install.ps1 | iex
  ```

After installation:
1. Customize `workspace.conf`, `repos.csv`, and `services.csv`.
2. Verify everything works (`./workspace.sh repo-status`, `./workspace.sh status`, etc.).
3. Commit the integration changes:
   ```bash
   git add workspace.sh workspace.ps1 workspace.bat workspace.conf repos.csv services.csv .gitignore
   git commit -m "added integration of https://github.com/BullTronics/workspace-repo-tools"
   ```

When teammates clone your repository later and run `./workspace.sh` (or `workspace.bat`), the wrapper reads `TOOLS_VERSION` from `workspace.conf`, downloads `.workspace-tools/library-bundle-<version>.*` over HTTPS, verifies its SHA-256 checksum, and runs seamlessly.

---

### Configure & Run

1. **Customize workspace settings & pinned tooling version** in [`workspace.conf`](workspace.conf):
   ```ini
   WORKSPACE_NAME=My Project
   WORKSPACE_PROMPT=myproj
   WORKSPACE_DIR=workspace
   TOOLS_VERSION=1.0.0
   CONFIG_SCHEMA_VERSION=1
   ```
2. **Configure Git repositories** in [`repos.csv`](repos.csv):
   ```csv
   url,path,branch
   git@github.com:my-org/api.git,api,main
   git@github.com:my-org/web.git,web,
   ```
3. **Configure runnable services** in [`services.csv`](services.csv):
   ```csv
   name,emoji,path,repo_type,port,cmd_unix,cmd_win,load_env_file,stop_pattern,hints
   backend,📡,api,spring-boot,8080,,,true,,
   frontend,💻,web,flutter-web,3000,,,true,,
   worker,🤖,worker,go,-,,,false,,
   portal,🌐,portal,vite,5173,,,false,,
   custom,⚙️,tools,,9000,npm run dev,npm run dev,false,tools,
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

## Workspace Directory Layout

```text
.
├── workspace.sh / workspace.ps1 / workspace.bat   # Only 3 committed script wrappers
├── workspace.conf                                 # Branding, repo dir & pinned TOOLS_VERSION
├── repos.csv                                      # Git repositories managed via workspace CLI
├── services.csv                                   # Local services & repo_type runner definitions
├── .gitignore                                     # Ignores workspace/, .workspace-tools/, logs/, .pids/, .runners/, .env*
├── .workspace-tools/                              # Gitignored auto-downloaded library-bundle-<version>.*
└── workspace/                                     # Gitignored directory where repositories are cloned
```

---

## Configuration Reference

### 1. `workspace.conf`
| Key | Default | Description |
| --- | --- | --- |
| `WORKSPACE_NAME` | `My Workspace` | Display title shown in banners and terminal window titles |
| `WORKSPACE_PROMPT` | `workspace` | Interactive REPL prompt prefix |
| `WORKSPACE_DIR` | `workspace` | Relative directory where repositories are cloned (must not escape root) |
| `TOOLS_VERSION` | `1.0.0` | Pinned release version (`library-bundle-<version>.*`) used by the wrappers |
| `CONFIG_SCHEMA_VERSION` | `1` | Tracks config file structure across upgrades for migration notices |
| `TOOLS_REPO_URL` | `https://github.com/BullTronics/workspace-repo-tools` | Upstream GitHub repository hosting releases |
| `TOOLS_RELEASE_BASE_URL` | *(optional)* | Custom release base URL override (replaces `<TOOLS_REPO_URL>/releases`) |
| `DISABLE_AUTO_UPDATE_CHECK` | `false` | Set to `true` to disable throttled HTTP update checks & banners |
| `UPDATE_CHECK_INTERVAL_HOURS` | `24` | Minimum hours between automatic background release checks |

### 2. `repos.csv`
Supports `#` comment lines, blank lines, and either `url,path` or `url,path,branch` headers:
- `url`: Git clone URL (SSH or HTTPS).
- `path`: Relative target directory inside `WORKSPACE_DIR` (absolute paths and `..` traversal are rejected). Supports nested paths like `services/api`.
- `branch` *(optional)*: Branch passed to `git clone -b <branch>` when cloning.

### 3. `services.csv`
Decouples runnable services from `repos.csv` and supports built-in `repo_type` runners so individual service repositories do not need duplicated boilerplate scripts.

| Column | Required | Description |
| --- | --- | --- |
| `name` | Yes | Unique service identifier (case-insensitive CLI target) |
| `emoji` | No | Optional icon shown in status and window titles (`-` or empty for none) |
| `path` | Yes | Relative path inside `WORKSPACE_DIR` |
| `repo_type` | No | Built-in runner: `spring-boot`, `flutter-web`, `go`, `vite`, or `custom` / empty |
| `port` | No | Default TCP listening port (empty uses `repo_type` default; `-` forces portless; overridden at runtime by `PORT=` in `<service_dir>/.env`) |
| `cmd_unix` | No | Script filename inside service dir or inline shell command (when empty, uses built-in `repo_type` runner) |
| `cmd_win` | No | Script filename inside service dir (`.bat`, `.cmd`, `.ps1`) or inline command (when empty, uses built-in `repo_type` runner) |
| `load_env_file` | No | `true` or `false` (default `false`). When `true`, `<service_dir>/.env` **must exist** before startup — missing `.env` fails immediately instead of starting; valid `.env` variables are loaded strictly into that service's isolated environment |
| `stop_pattern` | No | Optional `;`-separated command-line patterns used by `force-stop` to clean up orphaned child processes (defaults by `repo_type` when omitted) |
| `hints` | No | Optional keyboard-shortcut or usage note printed in interactive terminal windows (defaults by `repo_type` when omitted) |

**Built-in `repo_type` defaults:**
- `spring-boot`: port `8080`, stop pattern `spring-boot:run` — runs `$JAR_FILE` if set, otherwise `./mvnw spring-boot:run` (`.\mvnw.cmd` on Windows) or `mvn spring-boot:run`.
- `flutter-web`: port `3000`, Flutter keyboard hints — runs `flutter run -d chrome --web-port <PORT>` with an isolated Chrome profile (`$CHROME_USER_DATA_DIR`) and `--dart-define-from-file=.env` if `.env` exists.
- `go`: portless by default — runs `go run ${GO_ENTRYPOINT:-.}`.
- `vite`: port `5173`, stop pattern `vite` — exports `PORT` and executes `${DEV_CMD:-npm run dev}`.
- `custom` (or empty): executes `cmd_unix` / `cmd_win` directly.

---

## Command Reference (`./workspace.sh` / `workspace.bat`)

Run without arguments for interactive REPL mode, or pass commands directly:

### Repository Commands
```bash
./workspace.sh clone                         # Clone all repositories from repos.csv
./workspace.sh repo-status [-all | <repo>]   # Concise status across dirty/all/matching repos
./workspace.sh pull [--rebase]               # Pull updates across repositories
./workspace.sh fetch                         # Fetch remotes across repositories
./workspace.sh log                           # Show latest commit across repositories
./workspace.sh branch                        # Show current branch across repositories
./workspace.sh checkout <branch>             # Switch branch across repositories
./workspace.sh exec <git-cmd> [args...]      # Run an arbitrary Git command across repos
./workspace.sh --repo <name> <git-cmd>       # Restrict Git command to a single repository
```

### Service Commands
```bash
./workspace.sh start [service] [--bg]        # Start all or one service (new terminal tab or --bg)
./workspace.sh stop [service]                # Gracefully stop all or one service
./workspace.sh restart [service] [--bg]      # Restart all or one service
./workspace.sh force-stop                    # Kill tracked services + port/stop_pattern orphans
./workspace.sh status                        # Show running / starting / stopped status & ports
./workspace.sh logs <service> [lines]        # Tail background service log output
```

### Update & Version Commands
```bash
./workspace.sh version                       # Show pinned TOOLS_VERSION, schema, and bundle version
./workspace.sh check-update                  # Query latest release via HTTP release-meta.env
./workspace.sh update [--dry-run] [--yes]    # Update wrappers, bundle, .gitignore, and workspace.conf
```

---

## Documentation & Internals

For design details, source module structure, HTTP release checking, and the CI release pipeline, see:
- **[`docs/info.md`](docs/info.md)** — Documentation entry point & overview
- **[`docs/architecture.md`](docs/architecture.md)** — Wrapper-to-bundle execution model & modular `src/` layout
- **[`docs/install-and-update.md`](docs/install-and-update.md)** — Installer preflight, HTTP polling & schema migration notices
- **[`docs/service-runner.md`](docs/service-runner.md)** — `services.csv`, `repo_type` runners & lifecycle cleanup
- **[`docs/git-operations.md`](docs/git-operations.md)** — `repos.csv` validation & multi-repo Git execution
- **[`docs/release-pipeline.md`](docs/release-pipeline.md)** — `build-release.sh`, `VERSION` & GitHub Actions publishing
