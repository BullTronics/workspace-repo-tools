# =============================================================================
# library-bundle (Windows PowerShell) - Module: 99_main.ps1
# =============================================================================

$script:BundleSelfPath = $MyInvocation.MyCommand.Path

function Write-UnifiedBanner {
@"

  ====================================================
    $($script:WorkspaceName) - Workspace Control (v$($script:ToolsVersion))
  ====================================================

"@ | Write-Host -ForegroundColor Cyan
}

function Show-UnifiedMenu {
    $avail = Get-AvailableServicesText
    Write-Host "  Repository Commands:" -ForegroundColor Magenta
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
    Write-Host "    --repo <name> <git-cmd>     " -NoNewline -ForegroundColor White
    Write-Host "- Filter repository Git command to <name>" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Service Commands:" -ForegroundColor Magenta
    Write-Host "    start [svc] [--bg]          " -NoNewline -ForegroundColor White
    Write-Host "- Start all or single service ($avail)" -ForegroundColor Gray
    Write-Host "    stop [svc]                  " -NoNewline -ForegroundColor White
    Write-Host "- Stop all or single service" -ForegroundColor Gray
    Write-Host "    restart [svc] [--bg]        " -NoNewline -ForegroundColor White
    Write-Host "- Restart all or single service" -ForegroundColor Gray
    Write-Host "    force-stop                  " -NoNewline -ForegroundColor Red
    Write-Host "- Kill all services & orphaned processes" -ForegroundColor Gray
    Write-Host "    status                      " -NoNewline -ForegroundColor White
    Write-Host "- Show service status" -ForegroundColor Gray
    Write-Host "    logs <svc> [lines]          " -NoNewline -ForegroundColor White
    Write-Host "- Show background log output" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Workspace Tools:" -ForegroundColor Magenta
    Write-Host "    check-update                " -NoNewline -ForegroundColor White
    Write-Host "- Check for new workspace-repo-tools release" -ForegroundColor Gray
    Write-Host "    update [--dry-run] [--yes]  " -NoNewline -ForegroundColor White
    Write-Host "- Update workspace integration from release" -ForegroundColor Gray
    Write-Host "    version                     " -NoNewline -ForegroundColor White
    Write-Host "- Show configured tools & schema version" -ForegroundColor Gray
    Write-Host "    quit / exit / q             " -NoNewline -ForegroundColor White
    Write-Host "- Stop active services and exit" -ForegroundColor Gray
    Write-Host ""
}

function Test-ActivePids {
    if (-not (Test-Path $script:pidsDir)) { return $false }
    $items = Get-ChildItem -Path $script:pidsDir -Filter "*.pid" -ErrorAction SilentlyContinue
    return ($items -and $items.Count -gt 0)
}

function Invoke-GitDispatch {
    param([string[]]$GitCmdArgs)
    $repoFilter = ""; $i = 0
    while ($i -lt $GitCmdArgs.Count) {
        $cur = $GitCmdArgs[$i]
        if ($cur -in @("-r", "--repo", "-Repo")) {
            if ($i + 1 -ge $GitCmdArgs.Count -or -not $GitCmdArgs[$i + 1]) {
                Write-Host "Option '$cur' requires a repository name." -ForegroundColor Red
                return $false
            }
            $repoFilter = $GitCmdArgs[$i + 1]; $i += 2; continue
        }
        if ($cur -like "--repo=*") {
            $repoFilter = $cur.Substring(7)
            if (-not $repoFilter) { Write-Host "Option '--repo=' requires a repository name." -ForegroundColor Red; return $false }
            $i++; continue
        }
        break
    }

    $rem = if ($i -lt $GitCmdArgs.Count) { $GitCmdArgs[$i..($GitCmdArgs.Count - 1)] } else { @() }
    if ($rem.Count -eq 0) { Show-UnifiedMenu; return $true }
    $gcmd = $rem[0].ToLower()
    $gargs = if ($rem.Count -gt 1) { $rem[1..($rem.Count - 1)] } else { @() }

    switch ($gcmd) {
        "clone" {
            if ($gargs.Count -ne 0) { Write-Host "Usage: .\workspace.bat [--repo <name>] clone" -ForegroundColor Red; return $false }
            return (Invoke-GitRepositories -RepoFilter $repoFilter -CommandName "clone" -GitArgs @())
        }
        { $_ -in @("pull", "fetch") } {
            return (Invoke-GitRepositories -RepoFilter $repoFilter -CommandName $gcmd -GitArgs $gargs)
        }
        { $_ -in @("repo-status", "repos", "status") } {
            return (Get-GitRepositoriesStatus -RepoFilter $repoFilter -StatusArgs $gargs)
        }
        "log" {
            return (Invoke-GitRepositories -RepoFilter $repoFilter -CommandName "log" -GitArgs (@("--oneline", "-1") + $gargs))
        }
        "branch" {
            return (Invoke-GitRepositories -RepoFilter $repoFilter -CommandName "branch" -GitArgs (@("--show-current") + $gargs))
        }
        "checkout" {
            if ($gargs.Count -ne 1) { Write-Host "Usage: .\workspace.bat [--repo <name>] checkout <branch>" -ForegroundColor Red; return $false }
            return (Invoke-GitRepositories -RepoFilter $repoFilter -CommandName "checkout" -GitArgs $gargs)
        }
        "exec" {
            if ($gargs.Count -eq 0) { Write-Host "Usage: .\workspace.bat [--repo <name>] exec <git-command> [args...]" -ForegroundColor Red; return $false }
            $subArgs = if ($gargs.Count -gt 1) { $gargs[1..($gargs.Count - 1)] } else { @() }
            return (Invoke-GitRepositories -RepoFilter $repoFilter -CommandName $gargs[0] -GitArgs $subArgs)
        }
        default {
            Write-Host "Unknown git subcommand: '$gcmd'" -ForegroundColor Red
            return $false
        }
    }
}

function Invoke-WorkspaceCommand {
    param([string[]]$CmdArgs)
    if (-not $CmdArgs -or $CmdArgs.Count -eq 0) { return $true }

    $rawFirst = $CmdArgs[0]
    $first = $rawFirst.ToLower()
    $rest = if ($CmdArgs.Count -gt 1) { $CmdArgs[1..($CmdArgs.Count - 1)] } else { @() }

    if ($first -in @("-r", "--repo", "-repo") -or $first -like "--repo=*") {
        return (Invoke-GitDispatch -GitCmdArgs $CmdArgs)
    }

    switch ($first) {
        "git" {
            if ($rest.Count -eq 0) { Show-UnifiedMenu; return $true }
            return (Invoke-GitDispatch -GitCmdArgs $rest)
        }
        { $_ -in @("clone", "pull", "fetch", "repo-status", "repos", "log", "branch", "checkout", "exec") } {
            return (Invoke-GitDispatch -GitCmdArgs $CmdArgs)
        }
        "start" {
            $a1 = if ($rest.Count -gt 0) { $rest[0] } else { "" }
            $a2 = if ($rest.Count -gt 1) { $rest[1] } else { "" }
            $parsed = Resolve-TargetAndBg -Arg1 $a1 -Arg2 $a2
            $ok = $true
            if (-not $parsed.Target) {
                $ok = Start-AllServices -BackgroundMode $parsed.Bg
            } else {
                $svc = Find-ServiceByName -TargetName $parsed.Target
                if ($svc) { $ok = Start-ServiceEntry -svc $svc -BackgroundMode $parsed.Bg }
                else { Write-Host "  Service '$($parsed.Target)' not found. Available: $(Get-AvailableServicesText)" -ForegroundColor Red; $ok = $false }
            }
            Write-ServiceStatus
            return $ok
        }
        "stop" {
            $a1 = if ($rest.Count -gt 0) { $rest[0] } else { "" }
            $ok = $true
            if (-not $a1 -or $a1.ToLower() -eq "all") {
                Stop-AllServices
            } else {
                $svc = Find-ServiceByName -TargetName $a1
                if ($svc) { Stop-ServiceEntry -svc $svc }
                else { Write-Host "  Service '$a1' not found. Available: $(Get-AvailableServicesText)" -ForegroundColor Red; $ok = $false }
            }
            Write-ServiceStatus
            return $ok
        }
        "restart" {
            $a1 = if ($rest.Count -gt 0) { $rest[0] } else { "" }
            $a2 = if ($rest.Count -gt 1) { $rest[1] } else { "" }
            $parsed = Resolve-TargetAndBg -Arg1 $a1 -Arg2 $a2
            $ok = $true
            if (-not $parsed.Target) {
                Stop-AllServices
                Start-Sleep -Seconds 1
                $ok = Start-AllServices -BackgroundMode $parsed.Bg
            } else {
                $svc = Find-ServiceByName -TargetName $parsed.Target
                if ($svc) { $ok = Restart-ServiceEntry -svc $svc -BackgroundMode $parsed.Bg }
                else { Write-Host "  Service '$($parsed.Target)' not found. Available: $(Get-AvailableServicesText)" -ForegroundColor Red; $ok = $false }
            }
            Write-ServiceStatus
            return $ok
        }
        "force-stop" {
            Force-StopAllServices
            return $true
        }
        "status" {
            Write-ServiceStatus
            return $true
        }
        "logs" {
            $a1 = if ($rest.Count -gt 0) { $rest[0] } else { "" }
            $lines = if ($rest.Count -gt 1 -and $rest[1] -match '^\d+$') { [int]$rest[1] } else { 20 }
            return (Show-ServiceLogs -TargetName $a1 -Lines $lines)
        }
        { $_ -in @("check-update", "update-check") } {
            return (Invoke-CheckUpdateCommand)
        }
        { $_ -in @("update", "upgrade") } {
            return (Invoke-UpdateCommand -UpdateArgs $rest)
        }
        "version" {
            Write-Host "workspace-repo-tools v$($script:ToolsVersion) (schema: $($script:ConfigSchemaVersion), bundle: $($script:BundleVersion))"
            return $true
        }
        { $_ -in @("help", "-h", "--help") } {
            Write-UnifiedBanner
            Invoke-UpdateBannerCheck -Mode "--bg"
            Show-UnifiedMenu
            return $true
        }
        default {
            Write-Host "Unknown command: '$rawFirst'. Run '.\workspace.bat help' for usage." -ForegroundColor Red
            return $false
        }
    }
}

# --- Internal Hooks ---
if ($args.Count -gt 0) {
    if ($args[0] -eq "__run-service") {
        $slugArg = if ($args.Count -gt 1) { $args[1] } else { "" }
        $rc = Invoke-ServiceEntrypoint -Slug $slugArg
        exit $rc
    }
    if ($args[0] -eq "__refresh-cache") {
        $null = Refresh-UpdateCache -TimeoutSec 3
        exit 0
    }
}

# --- Direct CLI Mode ---
if ($args.Count -gt 0) {
    $ok = Invoke-WorkspaceCommand -CmdArgs $args
    $firstLc = $args[0].ToLower()
    if ($firstLc -notin @("help", "-h", "--help", "check-update", "update-check", "update", "upgrade", "version")) {
        Invoke-UpdateBannerCheck -Mode "--bg"
    }
    if (-not $ok) { exit 1 }
    exit 0
}

# --- Interactive REPL Mode ---
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    foreach ($slug in @($script:runningProcesses.Keys)) {
        $proc = $script:runningProcesses[$slug]
        try { & taskkill /T /F /PID $proc.Id 2>&1 | Out-Null } catch {}
    }
}

try {
    [Console]::TreatControlCAsInput = $false
    Register-ObjectEvent -InputObject ([Console]) -EventName CancelKeyPress -Action {
        $event.Cancel = $true
        Write-Host "`n  Ctrl+C detected. Cleaning up..." -ForegroundColor Yellow
        if (Test-ActivePids) { Stop-AllServices }
        Write-Host "  Goodbye!" -ForegroundColor Cyan
        exit 0
    } -ErrorAction SilentlyContinue | Out-Null
} catch {}

Write-UnifiedBanner
Invoke-UpdateBannerCheck -Mode "sync"
$env:WORKSPACE_UPDATE_CHECKED = "1"
Show-UnifiedMenu

while ($true) {
    Write-Host "  $($script:WorkspacePrompt)> " -NoNewline -ForegroundColor Cyan
    $line = Read-Host
    if ($null -eq $line) { break }
    $trimmed = $line.Trim()
    if (-not $trimmed) { continue }

    $parts = $trimmed -split '\s+'
    if ($parts[0].ToLower() -in @("quit", "exit", "q")) {
        if (Test-ActivePids) { Stop-AllServices }
        Write-Host "  Goodbye!" -ForegroundColor Cyan
        Write-Host ""
        exit 0
    }

    $null = Invoke-WorkspaceCommand -CmdArgs $parts
}

