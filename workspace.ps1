# =============================================================================
# Unified Workspace Entrypoint (Windows PowerShell)
# Delegates Git multi-repo actions to git-all.ps1 and service actions to run-local.ps1.
# =============================================================================

$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkspaceConf = Join-Path $ScriptDir "workspace.conf"
$GitAllPs1 = Join-Path $ScriptDir "git-all.ps1"
$RunLocalPs1 = Join-Path $ScriptDir "run-local.ps1"
$UpdaterPs1 = Join-Path $ScriptDir "workspace-repo-tools-updater.ps1"
$PidsDir = Join-Path $ScriptDir ".pids"

$script:WorkspaceName = "Workspace"
$script:WorkspacePrompt = "workspace"

if (Test-Path $WorkspaceConf) {
    foreach ($rawLine in (Get-Content $WorkspaceConf -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
        if ($line -match '^([^=]+)=(.*)$') {
            $k = $Matches[1].Trim()
            $v = $Matches[2].Trim().Trim('"').Trim("'")
            if ($k -eq "WORKSPACE_NAME" -and $v) { $script:WorkspaceName = $v }
            if ($k -eq "WORKSPACE_PROMPT" -and $v) { $script:WorkspacePrompt = $v }
        }
    }
}

function Write-Banner {
@"

  ====================================================
    $($script:WorkspaceName) - Workspace Control
  ====================================================

"@ | Write-Host -ForegroundColor Cyan
}

function Invoke-UpdateBannerCheck {
    param([string]$Mode = "--bg")
    if ($env:WORKSPACE_UPDATE_CHECKED -eq "1") { return }
    if (Test-Path $UpdaterPs1) {
        try { & $UpdaterPs1 "--banner-check" $Mode } catch {}
    }
}

function Show-Menu {
    Write-Host "  Repository Commands (git-all.ps1):" -ForegroundColor Magenta
    Write-Host "    clone                       " -NoNewline -ForegroundColor White
    Write-Host "- Clone repositories from repos.csv" -ForegroundColor Gray
    Write-Host "    pull [args...]              " -NoNewline -ForegroundColor White
    Write-Host "- Pull updates across repositories" -ForegroundColor Gray
    Write-Host "    fetch [args...]             " -NoNewline -ForegroundColor White
    Write-Host "- Fetch remotes across repositories" -ForegroundColor Gray
    Write-Host "    repo-status [-all | <repo>] " -NoNewline -ForegroundColor White
    Write-Host "- Show Git status across repositories" -ForegroundColor Gray
    Write-Host "    log / branch / checkout     " -NoNewline -ForegroundColor White
    Write-Host "- Inspect or switch branches across repos" -ForegroundColor Gray
    Write-Host "    exec <git-cmd> [args...]    " -NoNewline -ForegroundColor White
    Write-Host "- Run an arbitrary Git command across repos" -ForegroundColor Gray
    Write-Host "    git <git-all-args...>       " -NoNewline -ForegroundColor White
    Write-Host "- Pass any flags/command directly to git-all.ps1" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Service Commands (run-local.ps1):" -ForegroundColor Magenta
    Write-Host "    start [svc] [--bg]          " -NoNewline -ForegroundColor White
    Write-Host "- Start all or a single service" -ForegroundColor Gray
    Write-Host "    stop [svc]                  " -NoNewline -ForegroundColor White
    Write-Host "- Stop all or a single service" -ForegroundColor Gray
    Write-Host "    restart [svc] [--bg]        " -NoNewline -ForegroundColor White
    Write-Host "- Restart all or a single service" -ForegroundColor Gray
    Write-Host "    force-stop                  " -NoNewline -ForegroundColor Red
    Write-Host "- Force stop all services & orphaned processes" -ForegroundColor Gray
    Write-Host "    status                      " -NoNewline -ForegroundColor White
    Write-Host "- Show running service status" -ForegroundColor Gray
    Write-Host "    logs <svc> [lines]          " -NoNewline -ForegroundColor White
    Write-Host "- Show background log output" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Workspace Tooling:" -ForegroundColor Magenta
    Write-Host "    check-update                " -NoNewline -ForegroundColor White
    Write-Host "- Check for workspace-repo-tools updates" -ForegroundColor Gray
    Write-Host "    upgrade [--dry-run] [--yes] " -NoNewline -ForegroundColor White
    Write-Host "- Upgrade workspace tooling from upstream" -ForegroundColor Gray
    Write-Host "    quit / exit / q             " -NoNewline -ForegroundColor White
    Write-Host "- Stop active services and exit" -ForegroundColor Gray
    Write-Host ""
}

function Test-ActivePids {
    if (-not (Test-Path $PidsDir)) { return $false }
    $items = Get-ChildItem -Path $PidsDir -Filter "*.pid" -ErrorAction SilentlyContinue
    return ($items -and $items.Count -gt 0)
}

function Invoke-WorkspaceCommand {
    param([string[]]$CmdArgs)
    if (-not $CmdArgs -or $CmdArgs.Count -eq 0) { return 0 }

    $first = $CmdArgs[0]
    $firstLower = $first.ToLower()
    $rest = if ($CmdArgs.Count -gt 1) { $CmdArgs[1..($CmdArgs.Count - 1)] } else { @() }

    if ($firstLower -in @("-r", "--repo", "-repo") -or $firstLower -like "--repo=*") {
        & $GitAllPs1 @CmdArgs
        return $LASTEXITCODE
    }

    switch ($firstLower) {
        "git" {
            if ($rest.Count -eq 0) {
                & $GitAllPs1 "help"
            } else {
                & $GitAllPs1 @rest
            }
            return $LASTEXITCODE
        }
        { $_ -in @("clone", "pull", "fetch", "log", "branch", "checkout", "exec") } {
            & $GitAllPs1 @CmdArgs
            return $LASTEXITCODE
        }
        { $_ -in @("repo-status", "repos") } {
            & $GitAllPs1 "status" @rest
            return $LASTEXITCODE
        }
        { $_ -in @("start", "stop", "restart", "force-stop", "status", "logs") } {
            & $RunLocalPs1 @CmdArgs
            return $LASTEXITCODE
        }
        { $_ -in @("check-update", "update-check") } {
            & $UpdaterPs1 "check" @rest
            return $LASTEXITCODE
        }
        { $_ -in @("upgrade", "update") } {
            & $UpdaterPs1 "upgrade" @rest
            return $LASTEXITCODE
        }
        { $_ -in @("help", "-h", "--help") } {
            Write-Banner
            Invoke-UpdateBannerCheck -Mode "--bg"
            Show-Menu
            return 0
        }
        default {
            Write-Host "  Unknown command: '$first'. Use 'help' for available commands." -ForegroundColor Red
            return 1
        }
    }
}

# --- Direct CLI Mode ---
if ($args.Count -gt 0) {
    $rc = Invoke-WorkspaceCommand -CmdArgs $args
    $firstCli = $args[0].ToLower()
    if ($firstCli -notin @("start", "stop", "restart", "force-stop", "status", "logs", "help", "-h", "--help", "check-update", "update-check", "upgrade", "update")) {
        Invoke-UpdateBannerCheck -Mode "--bg"
    }
    exit $rc
}

# --- Interactive REPL Mode ---
Write-Banner
Invoke-UpdateBannerCheck -Mode "sync"
$env:WORKSPACE_UPDATE_CHECKED = "1"
Show-Menu

while ($true) {
    Write-Host "  $($script:WorkspacePrompt)> " -NoNewline -ForegroundColor Cyan
    $line = Read-Host
    if ($null -eq $line) { break }
    $trimmed = $line.Trim()
    if (-not $trimmed) { continue }

    $parts = $trimmed -split '\s+'
    if ($parts[0].ToLower() -in @("quit", "exit", "q")) {
        if (Test-ActivePids) {
            & $RunLocalPs1 "stop"
        }
        Write-Host "  Goodbye!" -ForegroundColor Cyan
        Write-Host ""
        exit 0
    }

    $null = Invoke-WorkspaceCommand -CmdArgs $parts
}

