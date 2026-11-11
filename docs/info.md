# Workspace Repo Tools — Technical Documentation

> Looking for everyday setup and command usage? See the **[User Guide (README)](../README.md)**.

This `docs/` directory documents the internal design, architecture, cross-platform execution model, update protocol, and release pipeline of **`workspace-repo-tools`**.

---

## Documentation Index

| Document | Focus |
| --- | --- |
| [`info.md`](info.md) | **Entry point** — design goals, two-world repository model, source layout, and end-to-end execution flow |
| [`architecture.md`](architecture.md) | Thin wrappers, Gradle-Wrapper-style bundle loading, modular `src/` composition, internal hooks, and cross-platform portability |
| [`install-and-update.md`](install-and-update.md) | Ephemeral bootstrap installers, 3-point Git preflight checks, HTTP CDN polling, SHA-256 verification, and schema migration notices |
| [`service-runner.md`](service-runner.md) | `services.csv` parsing, built-in `repo_type` templates, port precedence, `.env` isolation, terminal vs `--bg` runners, and orphan cleanup |
| [`git-operations.md`](git-operations.md) | `repos.csv` path safety validation, `--repo` filtering, and multi-repository Git execution & status parsing |
| [`release-pipeline.md`](release-pipeline.md) | Role of `VERSION` & `CONFIG_SCHEMA_VERSION`, `scripts/build-release.sh`, `dist/` release artifacts, and GitHub Actions publishing |

---

## Core Design Philosophy

`workspace-repo-tools` separates **contributor maintainability** from **downstream workspace simplicity** using a two-world distribution model (similar to the Gradle Wrapper):

1. **In this source repository (`BullTronics/workspace-repo-tools`):**
   - Shell and PowerShell code is split into small single-purpose modules (`src/sh/`, `src/ps1/`), wrapper templates (`src/wrapper/`), and per-framework service runners (`templates/`).
   - Nothing requires contributors to manually sync giant monolithic scripts.
2. **In a downstream user repository:**
   - Only **3 thin wrapper scripts** (`workspace.sh`, `workspace.ps1`, `workspace.bat`) and user configuration files (`workspace.conf`, `repos.csv`, `services.csv`, `.gitignore`) are committed.
   - No `templates/`, no legacy standalone `git-all.*` / `run-local.*` / `workspace-repo-tools-updater.*`, and no installer scripts remain in the user's repo.
   - All runtime implementation lives inside version-pinned `library-bundle-<version>.{sh,ps1,bat}` files downloaded automatically into the gitignored `.workspace-tools/` directory.

---

## Source Repository Layout

```text
.
├── VERSION                              # Default release version for builds & manual CI dispatch
├── CONFIG_SCHEMA_VERSION                # Integer schema version for config migration warnings
├── README.md                            # User guide
├── docs/                                # Architecture & contributor documentation (entry: info.md)
│   ├── info.md
│   ├── architecture.md
│   ├── install-and-update.md
│   ├── service-runner.md
│   ├── git-operations.md
│   └── release-pipeline.md
├── src/
│   ├── sh/                              # Modular Bash source modules (Bash 3.2+ compatible)
│   │   ├── 00_common.sh                 # Constants, colors, path root, semver/KV/SHA-256, Git preflight
│   │   ├── 10_config.sh                 # workspace.conf, repos.csv, services.csv & repo_type defaults
│   │   ├── 20_git.sh                    # Multi-repo clone/pull/fetch/repo-status/exec
│   │   ├── 30_services.sh               # Service runners, .env isolation, --bg, status, force-stop
│   │   ├── 40_updater.sh                # HTTP release polling, update cache, self-update & schema diff
│   │   └── 99_main.sh                   # Internal hooks, CLI router, interactive REPL
│   ├── ps1/                             # Modular PowerShell equivalents (00_common..99_main.ps1)
│   └── wrapper/                         # Thin wrapper templates shipped to downstream repos
│       ├── workspace.sh.tmpl
│       ├── workspace.ps1.tmpl
│       └── workspace.bat
├── templates/                           # Built-in repo_type service runners (compiled into bundles)
│   ├── spring-boot/                     # runner.sh, runner.ps1, .env.example
│   ├── flutter-web/                     # runner.sh, runner.ps1, .env.example
│   ├── go/                              # runner.sh, runner.ps1, .env.example
│   └── vite/                            # runner.sh, runner.ps1, .env.example
├── scripts/
│   └── build-release.sh                 # Assembles src/ + templates/ + wrappers into dist/
├── .github/workflows/
│   └── release.yml                      # CI syntax checks, smoke test & GitHub Release publisher
├── install.sh / install.ps1             # Ephemeral one-line bootstrap installers
├── workspace.sh / workspace.ps1 / workspace.bat   # Pre-built thin wrappers matching VERSION
├── workspace.conf / repos.csv / services.csv      # Default downstream templates
└── .gitignore                           # Downstream base rules (+ source repo dist/)
```

---

## High-Level Execution Lifecycle

```text
  User / Teammate runs:
    ./workspace.sh <command>   (or workspace.bat <command> on Windows)
          │
          ▼
  1. Thin Wrapper (workspace.sh / workspace.ps1)
     ├─ Reads TOOLS_VERSION, TOOLS_REPO_URL, TOOLS_RELEASE_BASE_URL from workspace.conf
     ├─ Checks for .workspace-tools/library-bundle-<TOOLS_VERSION>.{sh,ps1}
     └─ If missing (e.g. fresh git clone):
          Downloads release bundle + SHA256SUMS.txt over HTTPS,
          verifies checksum, removes older cached bundles, saves bundle.
          │
          ▼
  2. Unified Bundle Execution (.workspace-tools/library-bundle-<ver>.{sh,ps1})
     ├─ Sets WORKSPACE_ROOT_DIR so SCRIPT_DIR resolves to repo root (not .workspace-tools/)
     ├─ Loads workspace.conf into runtime config (10_config)
     ├─ Handles internal child hooks if invoked as __run-service / __refresh-cache
     └─ Dispatches CLI command or launches interactive REPL (99_main):
          ├─ Git commands      -> 20_git
          ├─ Service commands  -> 30_services (+ embedded templates/*/runner.*)
          └─ Update commands   -> 40_updater
```

