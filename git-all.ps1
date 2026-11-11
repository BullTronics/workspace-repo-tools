# =============================================================================
# git-all.ps1
#
# Manage multiple independent Git repositories configured in repos.csv.
# Native Windows PowerShell counterpart to git-all.sh.
# =============================================================================

$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir "repos.csv"
$WorkspaceConf = Join-Path $ScriptDir "workspace.conf"

function Get-WorkspaceDir {
    $relDir = "workspace"
    if (Test-Path $WorkspaceConf) {
        foreach ($rawLine in (Get-Content $WorkspaceConf -ErrorAction SilentlyContinue)) {
            $line = $rawLine.Trim()
            if (-not $line -or $line.StartsWith("#")) { continue }
            if ($line -match '^WORKSPACE_DIR\s*=\s*(.+)$') {
                $val = $Matches[1].Trim().Trim('"').Trim("'")
                if ($val) { $relDir = $val }
            }
        }
    }

    if ([System.IO.Path]::IsPathRooted($relDir) -or $relDir -match '^[A-Za-z]:' -or $relDir -match '(^|[\\/])\.\.([\\/]|$)') {
        Write-Host "Invalid WORKSPACE_DIR in workspace.conf: $relDir" -ForegroundColor Red
        exit 1
    }

    return Join-Path $ScriptDir ($relDir -replace '/', [System.IO.Path]::DirectorySeparatorChar)
}

$WorkspaceDir = Get-WorkspaceDir

function Show-Usage {
@"
git-all.ps1 / git-all.bat - manage multiple Git repositories

Usage:

  .\git-all.bat [--repo <name>] <command> [args...]

Commands:

  clone                         Clone all repositories from repos.csv
  pull [git-args...]            Run 'git pull' in every repository
  fetch [git-args...]           Run 'git fetch' in every repository
  status [-all | <repository>]  Show concise dirty summary, '-all', or detailed status
  log [git-args...]             Show latest commit from every repository
  branch [git-args...]          Show current branch for every repository
  checkout <branch>             Checkout a branch in every repository
  exec <git-command> [args...]  Run an arbitrary Git command in every repository

Options:

  -r, --repo <name>             Limit command to repositories matching exact path or suffix

Examples:

  .\git-all.bat clone
  .\git-all.bat pull --rebase
  .\git-all.bat fetch --prune
  .\git-all.bat status
  .\git-all.bat status -all
  .\git-all.bat status backend-repo
  .\git-all.bat --repo backend-repo pull
  .\git-all.bat checkout main
  .\git-all.bat exec remote -v
"@ | Write-Host
}

function Test-GitInstalled {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "Git was not found. Please install Git and make sure it is in PATH." -ForegroundColor Red
        exit 1
    }
}

function Test-RelativeRepoPath {
    param([string]$RelPath, [int]$RowNum)

    if (-not $RelPath) {
        Write-Host "Row ${RowNum}: missing path." -ForegroundColor Red
        return $false
    }
    if ($RelPath.StartsWith("/") -or $RelPath.StartsWith("\") -or $RelPath -match '^[A-Za-z]:') {
        Write-Host "Row ${RowNum}: absolute paths are not allowed: $RelPath" -ForegroundColor Red
        return $false
    }
    if ($RelPath.Contains("\")) {
        Write-Host "Row ${RowNum}: use '/' instead of '\' in path: $RelPath" -ForegroundColor Red
        return $false
    }
    if ($RelPath -eq ".." -or $RelPath -match '(^|/)\.\.(/|$)') {
        Write-Host "Row ${RowNum}: path escapes workspace: $RelPath" -ForegroundColor Red
        return $false
    }
    return $true
}

function Test-RepoMatchesFilter {
    param([string]$RelPath, [string]$Filter)
    if (-not $Filter) { return $true }
    $normFilter = ($Filter -replace '\\', '/').Trim('/')
    if ($RelPath -eq $normFilter) { return $true }
    if ($RelPath.EndsWith("/$normFilter")) { return $true }
    return $false
}

function Get-RepoEntries {
    if (-not (Test-Path $ConfigFile)) {
        Write-Host "repos.csv not found: $ConfigFile" -ForegroundColor Red
        exit 1
    }

    $lines = @()
    foreach ($raw in (Get-Content $ConfigFile -Encoding UTF8)) {
        $trimmed = $raw.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        $lines += $raw
    }

    if ($lines.Count -eq 0) {
        Write-Host "repos.csv is empty or missing header (url,path[,branch])." -ForegroundColor Red
        exit 1
    }

    $normHeader = ($lines[0] -replace '\s+', '')
    if ($normHeader -ne "url,path" -and $normHeader -ne "url,path,branch") {
        Write-Host "Invalid repos.csv header." -ForegroundColor Red
        Write-Host "Expected: url,path  or  url,path,branch" -ForegroundColor Red
        Write-Host "Found: $($lines[0].Trim())" -ForegroundColor Red
        exit 1
    }

    $entries = @()
    if ($lines.Count -gt 1) {
        $parsed = $lines | ConvertFrom-Csv
        foreach ($row in $parsed) {
            $u = if ($row.url) { $row.url.Trim() } else { "" }
            $p = if ($row.path) { $row.path.Trim() } else { "" }
            $b = if ($row.PSObject.Properties['branch'] -and $row.branch) { $row.branch.Trim() } else { "" }
            if (-not $u -and -not $p) { continue }
            $entries += [pscustomobject]@{
                Url    = $u
                Path   = $p
                Branch = $b
            }
        }
    }
    return ,$entries
}

function Invoke-GitRepositories {
    param(
        [string]$RepoFilter,
        [string]$CommandName,
        [string[]]$GitArgs
    )

    $entries = Get-RepoEntries
    $total = 0
    $matched = 0
    $successful = 0
    $skipped = 0
    $failed = 0

    foreach ($entry in $entries) {
        $total++
        $url = $entry.Url
        $relPath = $entry.Path
        $branch = $entry.Branch

        if (-not $url) {
            Write-Host "Row ${total}: missing URL." -ForegroundColor Red
            $failed++
            continue
        }

        if (-not (Test-RelativeRepoPath -RelPath $relPath -RowNum $total)) {
            $failed++
            continue
        }

        if (-not (Test-RepoMatchesFilter -RelPath $relPath -Filter $RepoFilter)) {
            continue
        }

        $matched++
        $repoPath = Join-Path $WorkspaceDir ($relPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)

        Write-Host ""
        Write-Host "============================================================"
        Write-Host "Repository : $relPath"
        Write-Host "URL        : $url"
        if ($branch -and $CommandName -eq "clone") {
            Write-Host "Branch     : $branch"
        }
        Write-Host "============================================================"

        if ($CommandName -eq "clone") {
            if (Test-Path $repoPath) {
                $null = & git -C $repoPath rev-parse --git-dir 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "Already cloned. Skipping." -ForegroundColor Yellow
                    $skipped++
                    continue
                }
                Write-Host "Path exists but is not a Git repository: $repoPath" -ForegroundColor Red
                $failed++
                continue
            }

            $parentDir = Split-Path -Parent $repoPath
            if (-not (Test-Path $parentDir)) {
                try {
                    New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
                } catch {
                    Write-Host "Could not create parent directory: $parentDir" -ForegroundColor Red
                    $failed++
                    continue
                }
            }

            Write-Host "Cloning..." -ForegroundColor Cyan
            if ($branch) {
                & git clone -b $branch $url $repoPath
            } else {
                & git clone $url $repoPath
            }
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Clone successful" -ForegroundColor Green
                $successful++
            } else {
                Write-Host "Clone failed" -ForegroundColor Red
                $failed++
            }
            continue
        }

        $null = & git -C $repoPath rev-parse --git-dir 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Repository not found: $repoPath" -ForegroundColor Yellow
            Write-Host "Run '.\git-all.bat clone' first." -ForegroundColor Yellow
            $skipped++
            continue
        }

        $argDisplay = if ($GitArgs -and $GitArgs.Count -gt 0) { " $($GitArgs -join ' ')" } else { "" }
        Write-Host "Running:" -ForegroundColor Cyan
        Write-Host "  git $CommandName$argDisplay" -ForegroundColor Cyan

        & git -C $repoPath $CommandName @GitArgs
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Success" -ForegroundColor Green
            $successful++
        } else {
            Write-Host "Failed" -ForegroundColor Red
            $failed++
        }
    }

    if ($RepoFilter -and $matched -eq 0) {
        Write-Host "No repository matching '$RepoFilter' found in repos.csv." -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "Summary"
    Write-Host "============================================================"
    Write-Host "Matched    : $matched"
    Write-Host "Successful : $successful"
    Write-Host "Skipped    : $skipped"
    Write-Host "Failed     : $failed"

    if ($failed -gt 0) {
        exit 1
    }
}

function Get-GitRepositoriesStatus {
    param(
        [string]$RepoFilter,
        [string[]]$StatusArgs
    )

    $targetRepo = $RepoFilter
    $showAll = $false

    if ($StatusArgs -and $StatusArgs.Count -gt 0) {
        if ($StatusArgs[0] -eq "-all" -or $StatusArgs[0] -eq "--all") {
            $showAll = $true
        } else {
            $targetRepo = $StatusArgs[0]
        }
    }

    $entries = Get-RepoEntries
    $repoFound = 0
    $rowNum = 0

    foreach ($entry in $entries) {
        $rowNum++
        $url = $entry.Url
        $relPath = $entry.Path
        if (-not (Test-RelativeRepoPath -RelPath $relPath -RowNum $rowNum)) { continue }

        $repoPath = Join-Path $WorkspaceDir ($relPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)

        if ($targetRepo) {
            if (-not (Test-RepoMatchesFilter -RelPath $relPath -Filter $targetRepo)) { continue }
            $repoFound++

            Write-Host ""
            Write-Host "============================================================"
            Write-Host "Repository : $relPath"
            Write-Host "URL        : $url"
            Write-Host "============================================================"

            $null = & git -C $repoPath rev-parse --git-dir 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Repository not found: $repoPath" -ForegroundColor Yellow
                Write-Host "Run '.\git-all.bat clone' first." -ForegroundColor Yellow
                continue
            }

            Write-Host "Running:" -ForegroundColor Cyan
            Write-Host "  git status" -ForegroundColor Cyan
            & git -C $repoPath status
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Failed" -ForegroundColor Red
            }
            continue
        }

        $null = & git -C $repoPath rev-parse --git-dir 2>$null
        if ($LASTEXITCODE -ne 0) {
            if ($showAll) {
                Write-Host "$relPath - not cloned"
            }
            continue
        }

        $lines = & git -C $repoPath status -sb --porcelain 2>$null
        $branch = "unknown"
        $ahead = 0
        $behind = 0
        $updated = 0
        $newFiles = 0
        $untracked = 0
        $deleted = 0
        $renamed = 0

        foreach ($line in $lines) {
            if ($line -match '^##\s+([^\.\s]+)') {
                $branch = $Matches[1]
                if ($line -match 'ahead\s+(\d+)') { $ahead = [int]$Matches[1] }
                if ($line -match 'behind\s+(\d+)') { $behind = [int]$Matches[1] }
                continue
            }
            if ($line -match '^( M|M )') { $updated++ }
            if ($line -match '^( A|A )') { $newFiles++ }
            if ($line -match '^\?\?') { $untracked++ }
            if ($line -match '^( D|D )') { $deleted++ }
            if ($line -match '^( R|R )') { $renamed++ }
        }

        $hasChanges = ($updated -gt 0 -or $newFiles -gt 0 -or $untracked -gt 0 -or $deleted -gt 0 -or $renamed -gt 0 -or $ahead -gt 0 -or $behind -gt 0)
        if (-not $hasChanges -and -not $showAll) {
            continue
        }

        $out = "$relPath - $branch"
        if (-not $hasChanges) {
            $out += " - uptodate"
        } else {
            if ($ahead -gt 0) { $out += " - ahead $ahead" }
            if ($behind -gt 0) { $out += " - behind $behind" }
            if ($updated -gt 0) { $out += " - $updated updated files" }
            if ($newFiles -gt 0) { $out += " - $newFiles new files" }
            if ($untracked -gt 0) { $out += " - $untracked untracked files" }
            if ($deleted -gt 0) { $out += " - $deleted deleted files" }
            if ($renamed -gt 0) { $out += " - $renamed renamed files" }
        }
        Write-Host $out
    }

    if ($targetRepo -and $repoFound -eq 0) {
        Write-Host "No repository matching '$targetRepo' found." -ForegroundColor Red
        exit 1
    }
}

# --- Main ---
Test-GitInstalled

$argList = @($args)
$repoFilter = ""
$idx = 0

while ($idx -lt $argList.Count) {
    $cur = $argList[$idx]
    if ($cur -eq "-r" -or $cur -eq "--repo" -or $cur -eq "-Repo") {
        if ($idx + 1 -ge $argList.Count -or -not $argList[$idx + 1]) {
            Write-Host "Option '$cur' requires a repository name or path." -ForegroundColor Red
            exit 1
        }
        $repoFilter = $argList[$idx + 1]
        $idx += 2
        continue
    }
    if ($cur -like "--repo=*") {
        $repoFilter = $cur.Substring(7)
        if (-not $repoFilter) {
            Write-Host "Option '--repo=' requires a repository name or path." -ForegroundColor Red
            exit 1
        }
        $idx++
        continue
    }
    break
}

$remaining = if ($idx -lt $argList.Count) { $argList[$idx..($argList.Count - 1)] } else { @() }

if ($remaining.Count -eq 0) {
    Show-Usage
    exit 0
}

$command = $remaining[0].ToLower()
$cmdArgs = if ($remaining.Count -gt 1) { $remaining[1..($remaining.Count - 1)] } else { @() }

switch ($command) {
    "clone" {
        if ($cmdArgs.Count -ne 0) {
            Write-Host "Usage: .\git-all.bat [--repo <name>] clone" -ForegroundColor Red
            exit 1
        }
        Invoke-GitRepositories -RepoFilter $repoFilter -CommandName "clone" -GitArgs @()
    }
    "pull" {
        Invoke-GitRepositories -RepoFilter $repoFilter -CommandName "pull" -GitArgs $cmdArgs
    }
    "fetch" {
        Invoke-GitRepositories -RepoFilter $repoFilter -CommandName "fetch" -GitArgs $cmdArgs
    }
    "status" {
        Get-GitRepositoriesStatus -RepoFilter $repoFilter -StatusArgs $cmdArgs
    }
    "log" {
        Invoke-GitRepositories -RepoFilter $repoFilter -CommandName "log" -GitArgs (@("--oneline", "-1") + $cmdArgs)
    }
    "branch" {
        Invoke-GitRepositories -RepoFilter $repoFilter -CommandName "branch" -GitArgs (@("--show-current") + $cmdArgs)
    }
    "checkout" {
        if ($cmdArgs.Count -ne 1) {
            Write-Host "Usage: .\git-all.bat [--repo <name>] checkout <branch>" -ForegroundColor Red
            exit 1
        }
        Invoke-GitRepositories -RepoFilter $repoFilter -CommandName "checkout" -GitArgs $cmdArgs
    }
    "exec" {
        if ($cmdArgs.Count -eq 0) {
            Write-Host "Usage: .\git-all.bat [--repo <name>] exec <git-command> [args...]" -ForegroundColor Red
            exit 1
        }
        Invoke-GitRepositories -RepoFilter $repoFilter -CommandName $cmdArgs[0] -GitArgs $(if ($cmdArgs.Count -gt 1) { $cmdArgs[1..($cmdArgs.Count - 1)] } else { @() })
    }
    { $_ -in @("help", "-h", "--help") } {
        Show-Usage
    }
    default {
        Write-Host "Unknown command: $($remaining[0])" -ForegroundColor Red
        Write-Host ""
        Show-Usage
        exit 1
    }
}

