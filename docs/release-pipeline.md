# Release Pipeline & Build Guide

This document explains how [`scripts/build-release.sh`](../scripts/build-release.sh) packages release assets and how [`.github/workflows/release.yml`](../.github/workflows/release.yml) validates and publishes GitHub Releases.

---

## 1. Version Tracking Files in Source Control

| File | Role | Copied to User Repos? |
| --- | --- | --- |
| [`VERSION`](../VERSION) | Default release semver (`X.Y.Z`) read by `scripts/build-release.sh` and manual CI runs when no explicit version/tag is passed | **No** |
| [`CONFIG_SCHEMA_VERSION`](../CONFIG_SCHEMA_VERSION) | Integer schema version incremented whenever config structure/keys change in `workspace.conf`, `repos.csv`, or `services.csv` | Written as `CONFIG_SCHEMA_VERSION` key inside downstream `workspace.conf` |

Maintainers can optionally pass `SCHEMA_NOTES="..."` into [`scripts/build-release.sh`](../scripts/build-release.sh) to emit human-readable migration guidance inside `release-meta.env` (surfaced by `check-update` and `update --dry-run` / `update`).

---

## 2. Build Script (`scripts/build-release.sh`)

Usage:
```bash
./scripts/build-release.sh [version] [schema_version]
```
Environment overrides:
- `TOOLS_REPO_URL` (defaults to `https://github.com/BullTronics/workspace-repo-tools`)
- `DIST_OUTPUT_DIR` (defaults to `dist/`)
- `SCHEMA_NOTES` (defaults to empty string)

### Generated `dist/` Artifacts
Running the build populates `dist/` with **14 files** (the 13 release assets + `SHA256SUMS.txt` generated across all files in `dist/`):

| Artifact | Purpose |
| --- | --- |
| `library-bundle-<ver>.sh` | Unified Bash bundle (`00_common.sh` + `templates/*/runner.sh` + `[0-9][0-9]_*.sh`) |
| `library-bundle-<ver>.ps1` | Unified PowerShell bundle (`00_common.ps1` + `templates/*/runner.ps1` + `[0-9][0-9]_*.ps1`) |
| `library-bundle-<ver>.bat` | Batch shim invoking `library-bundle-<ver>.ps1 %*` |
| `workspace.sh`, `workspace.ps1`, `workspace.bat` | Thin wrappers with `@DEFAULT_VERSION@` & `@REPO_URL@` substituted |
| `install.sh`, `install.ps1` | Standalone one-line bootstrap installers attached directly to GitHub Releases |
| `workspace.conf.default` | Default `workspace.conf` with `TOOLS_VERSION=<ver>` and `CONFIG_SCHEMA_VERSION=<schema>` stamped |
| `repos.csv.default` | Default `repos.csv` template |
| `services.csv.default` | Default 10-column `services.csv` template |
| `gitignore.default` | Downstream `.gitignore` (same as repo `.gitignore` with `# Release build output` and `dist/` stripped via `sed`) |
| `release-meta.env` | Lightweight `VERSION`, `TAG`, `CONFIG_SCHEMA_VERSION`, `SCHEMA_NOTES` file polled over HTTP |
| `SHA256SUMS.txt` | SHA-256 digests (`shasum -a 256` / `sha256sum`) verified by wrappers, installers, and `update` |

Before finishing, `build-release.sh` runs `bash -n` on `library-bundle-<ver>.sh`, `workspace.sh`, and `install.sh`.

---

## 3. GitHub Actions Workflow (`.github/workflows/release.yml`)

### Triggers
- `push` to tags matching `v*` (e.g., `v1.0.0`)
- `workflow_dispatch` with optional `version` input

### Workflow Steps (`build-and-release` on `ubuntu-latest`)
1. **Determine release version**:
   - Uses manual input `version` if provided,
   - Else strips leading `v` from `${GITHUB_REF_NAME}` for `v*` tag pushes,
   - Else falls back to [`VERSION`](../VERSION).
2. **Build release artifacts**: Executes `./scripts/build-release.sh <version>`.
3. **Validate bash bundle syntax & local release smoke test**:
   - Runs `bash -n` on `dist/workspace.sh`, `dist/library-bundle-<ver>.sh`, and `dist/install.sh`.
   - Creates a temporary `file://` mock release folder and an initialized empty Git repo, runs `dist/install.sh --version v<ver>`, and executes `./workspace.sh version` and `./workspace.sh status` against the installed workspace.
4. **Create GitHub Release**:
   - Publishes `tag_name: v<ver>` with all `dist/*` files using `softprops/action-gh-release@v2` (`generate_release_notes: true`).

---

## 4. Maintainer Release Checklist

1. If `workspace.conf`, `repos.csv`, or `services.csv` structure changed, increment [`CONFIG_SCHEMA_VERSION`](../CONFIG_SCHEMA_VERSION).
2. Update [`VERSION`](../VERSION) to the new semantic version (e.g. `1.1.0`).
3. Build locally and copy updated root wrappers if wrapper templates changed:
   ```bash
   ./scripts/build-release.sh
   cp dist/workspace.sh dist/workspace.ps1 dist/workspace.bat .
   chmod +x workspace.sh
   rm -rf dist
   ```
4. Validate shell syntax across `src/sh/*.sh`, `templates/*/runner.sh`, `install.sh`, `scripts/build-release.sh`, and `workspace.sh`.
5. Commit changes on `main`, then create and push the release tag:
   ```bash
   git tag v1.1.0
   git push origin main v1.1.0
   ```
   GitHub Actions builds cleanly from the tagged commit and attaches all assets under `releases/download/v1.1.0/` and `releases/latest/download/`.
