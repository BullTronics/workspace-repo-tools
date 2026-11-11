# Multi-Repository Git Operations (`repos.csv`)

This document describes how [`src/sh/20_git.sh`](../src/sh/20_git.sh) and [`src/ps1/20_git.ps1`](../src/ps1/20_git.ps1) validate [`repos.csv`](../repos.csv) and execute Git workflows across child repositories inside `WORKSPACE_DIR`.

---

## 1. Configuration & Containment Rules

### `WORKSPACE_DIR` Validation (`10_config`)
In [`workspace.conf`](../workspace.conf), `WORKSPACE_DIR` defaults to `workspace`. Both [`10_config.sh`](../src/sh/10_config.sh#L44-L53) and [`10_config.ps1`](../src/ps1/10_config.ps1) reject values that start with `/`, contain a Windows drive prefix (`C:`), use `\`, or contain `..` path traversal. All managed repositories reside inside `$SCRIPT_DIR/$WORKSPACE_REL_DIR`.

### `repos.csv` Format & Path Safety
[`repos.csv`](../repos.csv) supports `#` comment lines, blank lines, and either `url,path` or `url,path,branch` headers:
- Each row's relative `path` is checked by `validate_rel_path`:
  - Rejects empty path
  - Rejects leading `/` and `[A-Za-z]:` drive paths
  - Rejects `\` backslashes (requires `/` separators)
  - Rejects `..`, `../`, `/../`, `/..` traversal components
- Nested monorepo/grouped target paths such as `services/api` are permitted and parent directories are created automatically during `clone`.

---

## 2. Repository Filtering (`--repo`)

Git commands invoked through [`99_main.sh`](../src/sh/99_main.sh#L49-L101) / [`99_main.ps1`](../src/ps1/99_main.ps1#L67-L110) accept `-r <name>`, `--repo <name>`, or `--repo=<name>` either before the Git verb (`./workspace.sh --repo backend pull`) or after `git` (`./workspace.sh git --repo backend status`):
- `matches_repo_filter` matches either an exact `path` (`services/api`) or a trailing path segment (`*/api`).
- If a filter matches zero rows in `repos.csv`, execution fails with an explicit error (`No repository matching '<filter>' found in repos.csv.`).

---

## 3. Command Behavior

| CLI Command | Underlying Git Invocation | Notes |
| --- | --- | --- |
| `clone` | `git clone [-b <branch>] <url> <repo_path>` | Skips already-cloned Git repos; fails cleanly if target exists as a non-Git directory |
| `pull [args...]` | `git -C <repo_path> pull [args...]` | Supports flags such as `--rebase` |
| `fetch [args...]` | `git -C <repo_path> fetch [args...]` | Accepts any `git fetch` arguments |
| `log [args...]` | `git -C <repo_path> log --oneline -1 [args...]` | Compact one-line HEAD summary per repo |
| `branch [args...]` | `git -C <repo_path> branch --show-current [args...]` | Displays active branch per repo |
| `checkout <branch>` | `git -C <repo_path> checkout <branch>` | Requires `<branch>` argument |
| `exec <cmd> [args...]` | `git -C <repo_path> <cmd> [args...]` | Runs any arbitrary `git` subcommand across matched repos |
| `repo-status [-all \| <repo>]` | `git -C <repo_path> status -sb --porcelain` (or `git status`) | Summarizes workspace repo state (details below) |

Note on `status` vs `repo-status`: at the top level (`./workspace.sh status`), `status` displays **service** running status, while `./workspace.sh repo-status` (or `./workspace.sh git status` / `./workspace.sh repos`) inspects **Git repositories**.

### `repo-status` Modes (`status_git_repositories`)
1. **Default (`./workspace.sh repo-status`)**: Prints only repositories that have local modifications, untracked/new/deleted/renamed files, or ahead/behind divergence relative to their upstream tracking branch (`<path> - <branch> - ahead N - M updated files ...`). Clean repositories are omitted.
2. **Show all (`./workspace.sh repo-status -all` / `--all`)**: Prints every configured repository, including `<path> - <branch> - uptodate` and `<path> - not cloned`.
3. **Single repository (`./workspace.sh repo-status <repo>` or `--repo <name> repo-status`)**: Runs full verbose `git status` on the matching repository.

