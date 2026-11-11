# Service Runner Architecture (`services.csv` & Templates)

This document explains how services defined in [`services.csv`](../services.csv) are parsed, resolved, launched interactively or in background (`--bg`), monitored, and stopped by [`src/sh/10_config.sh`](../src/sh/10_config.sh), [`src/sh/30_services.sh`](../src/sh/30_services.sh), [`src/ps1/10_config.ps1`](../src/ps1/10_config.ps1), [`src/ps1/30_services.ps1`](../src/ps1/30_services.ps1), and [`templates/`](../templates/).

---

## 1. CSV Parsing & Validation (`10_config`)

[`services.csv`](../services.csv) requires an exact 10-column header:
```csv
name,emoji,path,repo_type,port,cmd_unix,cmd_win,load_env_file,stop_pattern,hints
```

- **CSV parsing**:
  - Bash (`load_services_csv` in `10_config.sh`): Uses an `awk` state-machine parser supporting RFC-style double quotes and escaped quotes (`""`), outputting Unit-Separator (`\037`) delimited records for Bash 3.2 compatibility.
  - PowerShell (`Load-ServicesCsv` in `10_config.ps1`): Uses `Import-Csv` / CSV parsing and validates column count and values.
- **Slugification & deduplication**:
  - `slugify_name` (`tr` + `sed 's/[^a-z0-9._-]/-/g'`) produces `<slug>` used for `.pids/<slug>.pid`, `.runners/run_<slug>.{command,ps1}`, and `logs/<slug>_run.log`.
  - Duplicate service slugs fail immediately with a descriptive error.
- **Path containment**:
  - `validate_rel_path` rejects missing paths, leading `/`, Windows drive letters (`C:...`), backslashes `\`, and `..` traversal so every service stays inside `WORKSPACE_DIR`.

---

## 2. `repo_type` Normalization & Built-in Defaults

`normalize_repo_type` (Bash) / `Resolve-RepoType` (PowerShell) maps optional aliases into canonical template keys:

| Input values (case-insensitive) | Canonical `repo_type` | Default Port | Default `stop_pattern` | Default `hints` |
| --- | --- | --- | --- | --- |
| `spring-boot`, `spring-boot-maven` | `spring-boot` | `8080` | `spring-boot:run` | *(empty)* |
| `flutter-web` | `flutter-web` | `3000` | *(empty)* | `[r] Hot reload  [R] Hot restart  [h] Help  [d] DevTools  [q] Quit` |
| `go`, `go-service` | `go` | *(portless)* | *(empty)* | *(empty)* |
| `vite`, `node-vite` | `vite` | `5173` | `vite` | *(empty)* |
| *(empty)* or `custom` | `custom` | *(portless)* | *(empty)* | *(empty)* |

- Passing `-` in the `port` column explicitly forces a service to be **portless** even when `repo_type` has a default port.
- Any unknown `repo_type` or invalid port (`< 1` or `> 65535`) fails validation on load.

### Built-In Template Implementations
During [`build-release.sh`](../scripts/build-release.sh), each `templates/<type>/runner.{sh,ps1}` is embedded directly inside `library-bundle-<version>.{sh,ps1}`:
- **`spring-boot`**: Runs `$JAR_FILE` with `java $JVM_ARGS -jar "$JAR_FILE"` if `$JAR_FILE` points to an existing file; otherwise runs `./mvnw spring-boot:run` (`.\mvnw.cmd` on Windows) if present, falling back to `mvn spring-boot:run`. Defaults `JVM_ARGS` to `-Duser.timezone=UTC`.
- **`flutter-web`**: Cleans `.dart_tool/chrome-device`, constructs a per-app Chrome profile dir (`$CHROME_USER_DATA_DIR` or `/tmp/<app_slug>-chrome-data`), appends `--dart-define-from-file=.env` when `.env` exists, appends `$FLUTTER_EXTRA_ARGS`, and invokes `flutter run -d chrome --web-port <PORT> ...`. On Windows (`templates/flutter-web/runner.ps1`), compiles and injects `chrome-launcher.exe` via `CHROME_EXECUTABLE` so user-data-dir flags pass cleanly.
- **`go`**: Runs `go run ${GO_ENTRYPOINT:-.}`.
- **`vite`**: Exports `PORT="${PORT:-5173}"` and invokes `${DEV_CMD:-npm run dev}` via `bash -c` (Unix) or `cmd.exe /c` (Windows).

---

## 3. Port & Environment Precedence

When `start` runs for a service:
1. **Static port lookup (`get_service_port` / `Get-ServicePort`)** for status checks and window titles:
   - Reads `<service_dir>/.env` for `PORT=<digits>` if present.
   - Falls back to the resolved `services.csv` / `repo_type` port.
2. **Runtime environment inside `execute_service_body` / `Invoke-ServiceBody`**:
   - Exports `PORT` from the `services.csv` / `repo_type` port if non-empty.
   - Then, if `load_env_file=true`, loads `<service_dir>/.env` via `load_dotenv_file` / `Import-DotEnvFile` strictly inside that service's subshell / child process. Any `PORT=` in `.env` therefore overrides the `services.csv` port without leaking variables to sibling services or the parent shell.
3. **Fail-fast `.env` guard**:
   - Before checking ports or spawning background jobs, `start_service_idx` / `Start-ServiceEntry` checks whether `load_env_file=true` and `<service_dir>/.env` is missing. If missing, startup fails synchronously immediately (and hints if `.env.example` exists).

---

## 4. Command Dispatch: Explicit vs Template

Inside `execute_service_body` / `Invoke-ServiceBody`:
1. If `cmd_unix` (or `cmd_win`) is non-empty:
   - If single token without whitespace referencing a script (`.sh` on Unix; `.bat`/`.cmd`/`.ps1` on Windows; or existing file in service dir), executes that script directly (`bash <script>`, `& <script.ps1>`, or `cmd.exe /c`).
   - Otherwise executes the value as an inline shell command (`bash -c "$cmd_spec"` or `cmd.exe /c $cmd_win`).
2. If `cmd_unix` / `cmd_win` is empty:
   - Dispatches directly to the embedded `repo_type` template function (`run_template_*` / `Invoke-Template*`).
   - Fails cleanly if `repo_type` is `custom`.

Note for single-service Bash commands (`start <svc>`, `stop <svc>`, `restart <svc>`, `logs <svc>`): `load_services_csv` is always invoked in the current shell before `idx=$(find_service_index ...)` so `SVC_*` arrays remain populated outside subshells.

---

## 5. Launch Modes, Status & Termination

### Launch Modes (`start` / `restart`)
- **Default (interactive terminal window/tab):**
  - Generates `.runners/run_<slug>.command` (Unix) or `.runners/run_<slug>.ps1` (Windows) containing window title formatting, `.pids/<slug>.pid` registration, service hints display, `WORKSPACE_ROOT_DIR` export, and `<bundle> __run-service <slug>`.
  - Opens a new tab/window via AppleScript (`iTerm2` / `Terminal.app`), macOS `open -a Terminal`, common Linux terminal emulators (`gnome-terminal`, `konsole`, `alacritty`, etc. with headless fallback to background logging), or `Start-Process` PowerShell window on Windows.
- **Background (`--bg`):**
  - Redirects stdout/stderr into `logs/<slug>_run.log` (plus `<slug>_run.err.log` on Windows), records the runner PID in `.pids/<slug>.pid`, and detaches (`disown` on Unix, `-WindowStyle Hidden` on Windows).

### Status Detection (`write_service_status` / `Write-ServiceStatus`)
- Checks TCP listeners via `lsof -tiTCP:<port> -sTCP:LISTEN` -> `ss -tlnp` fallback (Unix) or `Get-NetTCPConnection -State Listen` -> `netstat -ano` fallback (Windows), plus `.pids/<slug>.pid` liveness:
  - **Ported service**: `[RUNNING]` if TCP port is listening; `[STARTING...]` if runner PID is alive but port is not listening yet; `[STOPPED]` otherwise.
  - **Portless service**: `[RUNNING]` if runner PID is alive; `[STOPPED]` otherwise.

### Graceful `stop` vs `force-stop`
- **`stop [svc]`**: Walks process descendants recursively (`pgrep -P` / `ps` on Unix via `kill_pid_tree` -> `SIGTERM` then `SIGKILL` after 1s; `taskkill /T /F` on Windows via `Stop-PidTree`), then terminates any listener PID on the configured port and removes `.pids/<slug>.pid`.
- **`force-stop`**: Runs `stop` across all configured services, then performs an orphan sweep across every configured TCP port (`force_kill_port` / `Force-KillByPort`) and every `;`-separated pattern in `stop_pattern` (`pgrep -f` / `ps aux` or `Win32_Process` `CommandLine` match), clearing remaining `.pids/*.pid`.

