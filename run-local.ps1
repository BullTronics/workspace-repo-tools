# =============================================================================
# Generic Local Development Service Runner (Windows PowerShell)
# Reads workspace branding from workspace.conf and services from services.csv.
# Supports interactive REPL mode, terminal windows, background mode (--bg), and CLI args.
# =============================================================================

$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidsDir = Join-Path $scriptDir ".pids"
$runnersDir = Join-Path $scriptDir ".runners"
$logsDir = Join-Path $scriptDir "logs"

foreach ($d in @($pidsDir, $runnersDir, $logsDir)) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}

$workspaceConf = Join-Path $scriptDir "workspace.conf"
$servicesCsv = Join-Path $scriptDir "services.csv"

$script:WorkspaceName = "Workspace"
$script:WorkspacePrompt = "workspace"
$script:WorkspaceRelDir = "workspace"

function Load-WorkspaceConf {
    if (-not (Test-Path $workspaceConf)) { return }
    foreach ($rawLine in (Get-Content $workspaceConf -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
        if ($line -match '^([^=]+)=(.*)$') {
            $k = $Matches[1].Trim()
            $v = $Matches[2].Trim().Trim('"').Trim("'")
            switch ($k) {
                "WORKSPACE_NAME"   { if ($v) { $script:WorkspaceName = $v } }
                "WORKSPACE_PROMPT" { if ($v) { $script:WorkspacePrompt = $v } }
                "WORKSPACE_DIR"    { if ($v) { $script:WorkspaceRelDir = $v } }
            }
        }
    }

    if ([System.IO.Path]::IsPathRooted($script:WorkspaceRelDir) -or $script:WorkspaceRelDir -match '^[A-Za-z]:' -or $script:WorkspaceRelDir -match '(^|[\\/])\.\.([\\/]|$)') {
        Write-Host "  ERROR: Invalid WORKSPACE_DIR in workspace.conf: $($script:WorkspaceRelDir)" -ForegroundColor Red
        exit 1
    }
}

Load-WorkspaceConf
$workspaceRoot = Join-Path $scriptDir ($script:WorkspaceRelDir -replace '/', [System.IO.Path]::DirectorySeparatorChar)

function ConvertTo-Slug {
    param([string]$Text)
    return ($Text.ToLower() -replace '[^a-z0-9._-]', '-')
}

function Load-ServicesCsv {
    if (-not (Test-Path $servicesCsv)) {
        Write-Host "  ERROR: services.csv not found at $servicesCsv" -ForegroundColor Red
        exit 1
    }

    $lines = @()
    foreach ($raw in (Get-Content $servicesCsv -Encoding UTF8)) {
        $trimmed = $raw.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        $lines += $raw
    }

    if ($lines.Count -eq 0) {
        Write-Host "  ERROR: services.csv is empty or missing header." -ForegroundColor Red
        exit 1
    }

    $expectedHeader = "name,emoji,path,port,cmd_unix,cmd_win,load_env_file,stop_pattern,hints"
    $actualHeader = (($lines[0] -split ',') | ForEach-Object { $_.Trim() }) -join ','
    if ($actualHeader -ne $expectedHeader) {
        Write-Host "  ERROR: Invalid services.csv header." -ForegroundColor Red
        Write-Host "  Expected: $expectedHeader" -ForegroundColor Red
        Write-Host "  Found:    $actualHeader" -ForegroundColor Red
        exit 1
    }

    $loaded = @()
    if ($lines.Count -le 1) { return ,$loaded }

    $rows = $lines | ConvertFrom-Csv
    $seenSlugs = @{}
    $rowNum = 0

    foreach ($row in $rows) {
        $rowNum++
        $name = if ($row.name) { $row.name.Trim() } else { "" }
        if (-not $name) {
            Write-Host "  ERROR: services.csv row $rowNum is missing 'name'." -ForegroundColor Red
            exit 1
        }

        $slug = ConvertTo-Slug -Text $name
        if ($seenSlugs.ContainsKey($slug)) {
            Write-Host "  ERROR: Duplicate service name '$name' in services.csv." -ForegroundColor Red
            exit 1
        }
        $seenSlugs[$slug] = $true

        $relPath = if ($row.path) { $row.path.Trim() } else { "" }
        if (-not $relPath -or $relPath.StartsWith("/") -or $relPath.StartsWith("\") -or $relPath -match '^[A-Za-z]:' -or $relPath -match '(^|[\\/])\.\.([\\/]|$)') {
            Write-Host "  ERROR: Invalid relative path '$relPath' for service '$name'." -ForegroundColor Red
            exit 1
        }

        $emoji = if ($row.emoji -and $row.emoji.Trim() -ne "-") { $row.emoji.Trim() } else { "" }
        $portRaw = if ($row.port) { $row.port.Trim() } else { "" }
        $portNum = $null
        if ($portRaw -and $portRaw -ne "-") {
            $parsedPort = 0
            if (-not [int]::TryParse($portRaw, [ref]$parsedPort) -or $parsedPort -lt 1 -or $parsedPort -gt 65535) {
                Write-Host "  ERROR: Invalid port '$portRaw' for service '$name' in services.csv." -ForegroundColor Red
                exit 1
            }
            $portNum = $parsedPort
        }

        $cmdWin = if ($row.cmd_win -and $row.cmd_win.Trim()) { $row.cmd_win.Trim() } else { "run-local.bat" }

        $loadRaw = if ($row.load_env_file) { $row.load_env_file.Trim().ToLower() } else { "" }
        $loadEnv = $false
        if ($loadRaw -eq "true") {
            $loadEnv = $true
        } elseif ($loadRaw -and $loadRaw -ne "false") {
            Write-Host "  ERROR: Invalid load_env_file '$($row.load_env_file)' for service '$name' (expected true/false)." -ForegroundColor Red
            exit 1
        }

        $stopPatterns = @()
        if ($row.stop_pattern) {
            foreach ($p in ($row.stop_pattern -split ';')) {
                $tp = $p.Trim()
                if ($tp) { $stopPatterns += $tp }
            }
        }

        $hints = if ($row.hints) { $row.hints.Trim() } else { "" }

        $loaded += [pscustomobject]@{
            Name         = $name
            Slug         = $slug
            Emoji        = $emoji
            RelPath      = $relPath
            Dir          = (Join-Path $workspaceRoot ($relPath -replace '/', [System.IO.Path]::DirectorySeparatorChar))
            Port         = $portNum
            CmdWin       = $cmdWin
            LoadEnvFile  = $loadEnv
            StopPatterns = $stopPatterns
            Hints        = $hints
        }
    }

    return ,$loaded
}

$script:services = Load-ServicesCsv
$script:runningProcesses = @{}

function Format-ServiceLabel {
    param($svc)
    if ($svc.Emoji) { return "$($svc.Emoji) $($svc.Name)" }
    return $svc.Name
}

function Get-AvailableServicesText {
    if ($script:services.Count -eq 0) { return "(none configured in services.csv)" }
    return (($script:services | ForEach-Object { $_.Name }) -join ", ")
}

function Write-Banner {
    $banner = @"

  ====================================================
    $($script:WorkspaceName) - Local Development Runner
  ====================================================

"@
    Write-Host $banner -ForegroundColor Cyan
}

function Invoke-UpdateBannerCheck {
    param([string]$Mode = "--bg")
    if ($env:WORKSPACE_UPDATE_CHECKED -eq "1") { return }
    $updater = Join-Path $scriptDir "workspace-repo-tools-updater.ps1"
    if (Test-Path $updater) {
        try { & $updater "--banner-check" $Mode } catch {}
    }
}

function Get-ServicePort {
    param($svc)
    $defaultPort = $svc.Port
    $envFile = Join-Path $svc.Dir ".env"
    if (Test-Path $envFile) {
        try {
            foreach ($line in (Get-Content $envFile -ErrorAction SilentlyContinue)) {
                $trimmed = $line.Trim()
                if ($trimmed -and -not $trimmed.StartsWith("#") -and $trimmed -match '^(?:export\s+)?PORT\s*=\s*"?''?(\d+)"?''?') {
                    return [int]$Matches[1]
                }
            }
        } catch {}
    }
    return $defaultPort
}

function Get-PortListenPids {
    param($Port)
    if (-not $Port) { return @() }
    try {
        $conns = Get-NetTCPConnection -LocalPort ([int]$Port) -State Listen -ErrorAction SilentlyContinue
        if ($conns) {
            return @($conns | Select-Object -ExpandProperty OwningProcess -Unique)
        }
    } catch {}
    return @()
}

function Get-RunnerPid {
    param($svc)
    $slug = $svc.Slug
    $pidFile = Join-Path $pidsDir "$slug.pid"

    if ($script:runningProcesses.ContainsKey($slug)) {
        try {
            $p = Get-Process -Id $script:runningProcesses[$slug].Id -ErrorAction SilentlyContinue
            if ($p -and -not $p.HasExited) { return $p.Id }
        } catch {}
        $script:runningProcesses.Remove($slug)
    }

    if (Test-Path $pidFile) {
        $savedPid = Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($savedPid) {
            try {
                $p = Get-Process -Id ([int]$savedPid.Trim()) -ErrorAction SilentlyContinue
                if ($p -and -not $p.HasExited) { return $p.Id }
            } catch {}
        }
        Remove-Item -Path $pidFile -Force -ErrorAction SilentlyContinue
    }
    return $null
}

function Write-Status {
    Write-Host ""
    Write-Host "  Service Status:" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
    if ($script:services.Count -eq 0) {
        Write-Host "  No services configured in services.csv" -ForegroundColor Yellow
    } else {
        foreach ($svc in $script:services) {
            $label = Format-ServiceLabel -svc $svc
            $port = Get-ServicePort -svc $svc
            $listenPids = Get-PortListenPids -Port $port
            $runnerPid = Get-RunnerPid -svc $svc

            if ($port) {
                if ($listenPids.Count -gt 0) {
                    $pidList = $listenPids -join " "
                    Write-Host "  $label " -NoNewline -ForegroundColor White
                    Write-Host "[RUNNING]" -NoNewline -ForegroundColor Green
                    Write-Host " (Port: $port, PID: $pidList)" -ForegroundColor DarkGray
                } elseif ($runnerPid) {
                    Write-Host "  $label " -NoNewline -ForegroundColor White
                    Write-Host "[STARTING...]" -NoNewline -ForegroundColor Yellow
                    Write-Host " (Port: $port, PID: $runnerPid - booting)" -ForegroundColor DarkGray
                } else {
                    Write-Host "  $label " -NoNewline -ForegroundColor White
                    Write-Host "[STOPPED]" -ForegroundColor Red
                }
            } else {
                if ($runnerPid) {
                    Write-Host "  $label " -NoNewline -ForegroundColor White
                    Write-Host "[RUNNING]" -NoNewline -ForegroundColor Green
                    Write-Host " (PID: $runnerPid)" -ForegroundColor DarkGray
                } else {
                    Write-Host "  $label " -NoNewline -ForegroundColor White
                    Write-Host "[STOPPED]" -ForegroundColor Red
                }
            }
        }
    }
    Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
}

function Find-ServiceByName {
    param([string]$TargetName)
    if (-not $TargetName) { return $null }
    $targetSlug = ConvertTo-Slug -Text $TargetName.Trim()
    foreach ($svc in $script:services) {
        if ($svc.Slug -eq $targetSlug) { return $svc }
    }
    return $null
}

function Test-ScriptCommand {
    param([string]$Dir, [string]$CmdWin)
    if ($CmdWin -match '\s') { return $false }
    $candidate = Join-Path $Dir $CmdWin
    return ($CmdWin -match '\.(bat|cmd|ps1)$' -or (Test-Path $candidate -PathType Leaf))
}

function New-IsolatedRunnerScript {
    param($svc, $ResolvedPort, [bool]$BackgroundMode)

    $slug = $svc.Slug
    $runnerFile = Join-Path $runnersDir "run_$slug.ps1"
    $pidFile = Join-Path $pidsDir "$slug.pid"
    $label = Format-ServiceLabel -svc $svc
    $title = if ($ResolvedPort) { "$($script:WorkspaceName) - $($svc.Name) (Port $ResolvedPort)" } else { "$($script:WorkspaceName) - $($svc.Name)" }
    if ($svc.Emoji) { $title = "$($svc.Emoji) $title" }

    $isScript = Test-ScriptCommand -Dir $svc.Dir -CmdWin $svc.CmdWin

    $escapedDir = $svc.Dir.Replace("'", "''")
    $escapedPidFile = $pidFile.Replace("'", "''")
    $escapedCmd = $svc.CmdWin.Replace("'", "''")
    $escapedTitle = $title.Replace("'", "''")
    $escapedLabel = $label.Replace("'", "''")
    $escapedHints = $svc.Hints.Replace("'", "''")
    $escapedName = $svc.Name.Replace("'", "''")
    $portVal = if ($ResolvedPort) { "$ResolvedPort" } else { "" }
    $loadEnvStr = if ($svc.LoadEnvFile) { "`$true" } else { "`$false" }
    $isScriptStr = if ($isScript) { "`$true" } else { "`$false" }
    $bgStr = if ($BackgroundMode) { "`$true" } else { "`$false" }

    $content = @"
`$ErrorActionPreference = "Continue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { `$Host.UI.RawUI.WindowTitle = '$escapedTitle' } catch {}

`$pidFile = '$escapedPidFile'
`$serviceDir = '$escapedDir'
`$cmdSpec = '$escapedCmd'
`$loadEnv = $loadEnvStr
`$isScript = $isScriptStr
`$isBg = $bgStr
`$portNum = '$portVal'
`$hints = '$escapedHints'

Set-Content -Path `$pidFile -Value `$PID -Force

function Import-DotEnv {
    param([string]`$EnvPath)
    if (-not (Test-Path `$EnvPath)) {
        Write-Host "ERROR: .env file not found: `$EnvPath" -ForegroundColor Red
        return `$false
    }
    foreach (`$rawLine in (Get-Content `$EnvPath -Encoding UTF8)) {
        `$line = `$rawLine.Trim()
        if (-not `$line -or `$line.StartsWith("#")) { continue }
        if (`$line -match '^export\s+(.+)$') { `$line = `$Matches[1].Trim() }
        if (-not `$line.Contains("=")) { continue }
        `$parts = `$line.Split("=", 2)
        `$k = `$parts[0].Trim()
        `$v = `$parts[1].Trim()
        if ((`$v.StartsWith('"') -and `$v.EndsWith('"') -and `$v.Length -ge 2) -or (`$v.StartsWith("'") -and `$v.EndsWith("'") -and `$v.Length -ge 2)) {
            `$v = `$v.Substring(1, `$v.Length - 2)
        }
        if (`$k -match '^[A-Za-z_][A-Za-z0-9_]*$') {
            [System.Environment]::SetEnvironmentVariable(`$k, `$v, "Process")
        }
    }
    return `$true
}

if (-not `$isBg) {
    Write-Host "=============================================================================" -ForegroundColor Cyan
    Write-Host "  $escapedLabel" -ForegroundColor Green
    Write-Host "  Directory : `$serviceDir" -ForegroundColor White
    if (`$portNum) { Write-Host "  Port      : `$portNum" -ForegroundColor White }
    Write-Host "  Command   : `$cmdSpec" -ForegroundColor White
    if (`$hints) { Write-Host "  Controls  : `$hints" -ForegroundColor Yellow }
    Write-Host "=============================================================================" -ForegroundColor Cyan
    Write-Host ""
}

Set-Location `$serviceDir

if (`$loadEnv) {
    `$ok = Import-DotEnv -EnvPath (Join-Path `$serviceDir ".env")
    if (-not `$ok) { exit 1 }
}

`$exitCode = 0
if (`$isScript) {
    `$target = Join-Path `$serviceDir `$cmdSpec
    if (`$cmdSpec -match '\.ps1$') {
        & `$target
        `$exitCode = `$LASTEXITCODE
    } else {
        & cmd.exe /c "`"`$target`""
        `$exitCode = `$LASTEXITCODE
    }
} else {
    & cmd.exe /c `$cmdSpec
    `$exitCode = `$LASTEXITCODE
}

Remove-Item -Path `$pidFile -Force -ErrorAction SilentlyContinue

if (-not `$isBg -and `$exitCode -ne 0) {
    Write-Host ""
    Write-Host "$escapedName exited with code `$exitCode." -ForegroundColor Red
    Read-Host "Press [Enter] to close this window..."
}
exit `$exitCode
"@

    Set-Content -Path $runnerFile -Value $content -Encoding UTF8 -Force
    return $runnerFile
}

function Get-PowerShellExe {
    $cmd = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { return $pwsh.Source }
    return "powershell.exe"
}

function Start-ServiceEntry {
    param($svc, [bool]$BackgroundMode = $false)

    $label = Format-ServiceLabel -svc $svc
    $slug = $svc.Slug
    $pidFile = Join-Path $pidsDir "$slug.pid"

    if (-not (Test-Path $svc.Dir -PathType Container)) {
        Write-Host "  ERROR: Service directory not found: $($svc.Dir)" -ForegroundColor Red
        Write-Host "  Hint: Run '.\git-all.bat clone' first." -ForegroundColor Yellow
        return $false
    }

    if ((Test-ScriptCommand -Dir $svc.Dir -CmdWin $svc.CmdWin) -and -not (Test-Path (Join-Path $svc.Dir $svc.CmdWin) -PathType Leaf)) {
        Write-Host "  ERROR: Runner script not found: $(Join-Path $svc.Dir $svc.CmdWin)" -ForegroundColor Red
        return $false
    }

    if ($svc.LoadEnvFile) {
        $envFile = Join-Path $svc.Dir ".env"
        if (-not (Test-Path $envFile -PathType Leaf)) {
            Write-Host "  ERROR: .env file not found for '$($svc.Name)' at: $envFile (load_env_file=true)" -ForegroundColor Red
            if (Test-Path (Join-Path $svc.Dir ".env.example") -PathType Leaf) {
                Write-Host "  Hint: Found .env.example — copy it to .env and configure it before starting." -ForegroundColor Yellow
            }
            return $false
        }
    }

    $port = Get-ServicePort -svc $svc
    $listenPids = Get-PortListenPids -Port $port
    $runnerPid = Get-RunnerPid -svc $svc
    if ($listenPids.Count -gt 0 -or $runnerPid) {
        $activePid = if ($listenPids.Count -gt 0) { $listenPids[0] } else { $runnerPid }
        Write-Host "  $label is already running (PID: $activePid)" -ForegroundColor Yellow
        return $true
    }

    Remove-Item -Path $pidFile -Force -ErrorAction SilentlyContinue
    $runnerFile = New-IsolatedRunnerScript -svc $svc -ResolvedPort $port -BackgroundMode $BackgroundMode
    $psExe = Get-PowerShellExe

    if ($BackgroundMode) {
        Write-Host "  Starting $label in background..." -ForegroundColor Cyan
        $logFile = Join-Path $logsDir "${slug}_run.log"
        $errLogFile = Join-Path $logsDir "${slug}_run.err.log"
        $proc = Start-Process -FilePath $psExe `
            -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $runnerFile `
            -WindowStyle Hidden `
            -RedirectStandardOutput $logFile `
            -RedirectStandardError $errLogFile `
            -PassThru
        $script:runningProcesses[$slug] = $proc
        Set-Content -Path $pidFile -Value $proc.Id -Force
        Write-Host "  $label started in background (PID: $($proc.Id)). Logs: $logFile" -ForegroundColor Green
    } else {
        Write-Host "  Starting $label in new terminal window..." -ForegroundColor Cyan
        $proc = Start-Process -FilePath $psExe `
            -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $runnerFile `
            -PassThru `
            -WindowStyle Normal
        $script:runningProcesses[$slug] = $proc
        if (-not (Test-Path $pidFile)) {
            Set-Content -Path $pidFile -Value $proc.Id -Force
        }
        Write-Host "  $label launched (PID: $($proc.Id))" -ForegroundColor Green
    }
    return $true
}

function Stop-ServiceEntry {
    param($svc)

    $label = Format-ServiceLabel -svc $svc
    $slug = $svc.Slug
    $port = Get-ServicePort -svc $svc
    $pidFile = Join-Path $pidsDir "$slug.pid"
    $stoppedAny = $false

    $runnerPid = Get-RunnerPid -svc $svc
    if ($runnerPid) {
        try {
            Write-Host "  Stopping $label (PID: $runnerPid)..." -ForegroundColor Yellow
            & taskkill /T /F /PID $runnerPid 2>&1 | Out-Null
            $stoppedAny = $true
        } catch {}
    }

    $listenPids = Get-PortListenPids -Port $port
    foreach ($p in $listenPids) {
        try {
            Write-Host "  Stopping $label port $port listener (PID: $p)..." -ForegroundColor Yellow
            & taskkill /T /F /PID $p 2>&1 | Out-Null
            $stoppedAny = $true
        } catch {}
    }

    $script:runningProcesses.Remove($slug)
    Remove-Item -Path $pidFile -Force -ErrorAction SilentlyContinue

    if ($stoppedAny) {
        Write-Host "  $label stopped" -ForegroundColor Green
    } else {
        Write-Host "  $label is not running" -ForegroundColor Yellow
    }
}

function Restart-ServiceEntry {
    param($svc, [bool]$BackgroundMode = $false)
    Stop-ServiceEntry -svc $svc
    Start-Sleep -Seconds 1
    return (Start-ServiceEntry -svc $svc -BackgroundMode $BackgroundMode)
}

function Start-AllServices {
    param([bool]$BackgroundMode = $false)
    $failures = 0
    Write-Host ""
    Write-Host "  Starting all services..." -ForegroundColor Cyan
    Write-Host ""
    foreach ($svc in $script:services) {
        $ok = Start-ServiceEntry -svc $svc -BackgroundMode $BackgroundMode
        if (-not $ok) { $failures++ }
    }
    Write-Host ""
    return ($failures -eq 0)
}

function Stop-AllServices {
    Write-Host ""
    Write-Host "  Stopping all services..." -ForegroundColor Yellow
    Write-Host ""
    foreach ($svc in $script:services) {
        Stop-ServiceEntry -svc $svc
    }
    Write-Host ""
}

function Force-KillByPort {
    param([int]$Port, [string]$Label)
    $pids = Get-PortListenPids -Port $Port
    if ($pids.Count -gt 0) {
        foreach ($procId in $pids) {
            try {
                Write-Host "    Killing $Label process on port $Port (PID: $procId)" -ForegroundColor Yellow
                & taskkill /T /F /PID $procId 2>&1 | Out-Null
            } catch {}
        }
    } else {
        Write-Host "    No process found on port $Port" -ForegroundColor DarkGray
    }
}

function Force-KillByCommandLine {
    param([string]$Pattern, [string]$Label)
    $currentPid = $PID
    $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine -match $Pattern -and $_.ProcessId -ne $currentPid
    }
    if ($procs) {
        foreach ($proc in $procs) {
            try {
                Write-Host "    Killing $Label process matching '$Pattern': $($proc.Name) (PID: $($proc.ProcessId))" -ForegroundColor Yellow
                & taskkill /T /F /PID $proc.ProcessId 2>&1 | Out-Null
            } catch {}
        }
    } else {
        Write-Host "    No process found matching '$Pattern'" -ForegroundColor DarkGray
    }
}

function Force-StopAllServices {
    Write-Host ""
    Write-Host "  Force stopping all $($script:WorkspaceName) services..." -ForegroundColor Red
    Write-Host ""

    foreach ($svc in $script:services) {
        Stop-ServiceEntry -svc $svc
    }

    Write-Host "  Scanning for orphaned processes..." -ForegroundColor Yellow
    Write-Host ""

    foreach ($svc in $script:services) {
        $port = Get-ServicePort -svc $svc
        if (-not $port -and $svc.StopPatterns.Count -eq 0) { continue }
        $label = Format-ServiceLabel -svc $svc
        if ($port) {
            Write-Host "  $label (port $port):" -ForegroundColor White
            Force-KillByPort -Port $port -Label $svc.Name
        } else {
            Write-Host "  $label:" -ForegroundColor White
        }
        foreach ($pat in $svc.StopPatterns) {
            Force-KillByCommandLine -Pattern $pat -Label $svc.Name
        }
        Write-Host ""
    }

    Get-ChildItem -Path $pidsDir -Filter "*.pid" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    $script:runningProcesses = @{}

    Write-Host "  Force stop complete." -ForegroundColor Green
    Write-Host ""
}

function Show-Logs {
    param([string]$TargetName, [int]$Lines = 20)
    if (-not $TargetName) {
        Write-Host "  Please specify a service. Available: $(Get-AvailableServicesText)" -ForegroundColor Red
        return $false
    }
    $svc = Find-ServiceByName -TargetName $TargetName
    if (-not $svc) {
        Write-Host "  Service '$TargetName' not found. Available: $(Get-AvailableServicesText)" -ForegroundColor Red
        return $false
    }
    $logFile = Join-Path $logsDir "$($svc.Slug)_run.log"
    if (Test-Path $logFile) {
        Write-Host "  === Last $Lines lines of $logFile ===" -ForegroundColor Cyan
        Get-Content -Path $logFile -Tail $Lines
        Write-Host ""
    } else {
        Write-Host "  No log file found at $logFile" -ForegroundColor Yellow
        Write-Host "  (Services started in interactive windows output directly to their window)" -ForegroundColor Gray
        Write-Host ""
    }
    return $true
}

function Show-Menu {
    $avail = Get-AvailableServicesText
    Write-Host "  Commands:" -ForegroundColor Magenta
    Write-Host "    start [svc] [--bg]  " -NoNewline -ForegroundColor White
    Write-Host "- Start all or single service ($avail)" -ForegroundColor Gray
    Write-Host "    stop [svc]          " -NoNewline -ForegroundColor White
    Write-Host "- Stop all or single service" -ForegroundColor Gray
    Write-Host "    restart [svc] [--bg]" -NoNewline -ForegroundColor White
    Write-Host "- Restart all or single service" -ForegroundColor Gray
    Write-Host "    force-stop          " -NoNewline -ForegroundColor Red
    Write-Host "- Kill all services (including orphaned processes)" -ForegroundColor Gray
    Write-Host "    status              " -NoNewline -ForegroundColor White
    Write-Host "- Show service status" -ForegroundColor Gray
    Write-Host "    logs <svc> [lines]  " -NoNewline -ForegroundColor White
    Write-Host "- View background log file for a service" -ForegroundColor Gray
    Write-Host "    quit / exit / q     " -NoNewline -ForegroundColor White
    Write-Host "- Stop all and exit" -ForegroundColor Gray
    Write-Host ""
}

function Resolve-TargetAndBg {
    param([string]$Arg1, [string]$Arg2)
    $bg = $false
    $target = ""
    foreach ($a in @($Arg1, $Arg2)) {
        if (-not $a) { continue }
        $al = $a.Trim().ToLower()
        if ($al -in @("--bg", "bg", "-bg")) {
            $bg = $true
        } elseif ($al -ne "all" -and -not $target) {
            $target = $a.Trim()
        }
    }
    return [pscustomobject]@{ Target = $target; Bg = $bg }
}

function Invoke-Action {
    param([string]$Cmd, [string]$Arg1 = "", [string]$Arg2 = "")
    $cmdLower = $Cmd.Trim().ToLower()
    $ok = $true

    switch ($cmdLower) {
        "start" {
            $parsed = Resolve-TargetAndBg -Arg1 $Arg1 -Arg2 $Arg2
            if (-not $parsed.Target) {
                $ok = Start-AllServices -BackgroundMode $parsed.Bg
            } else {
                $svc = Find-ServiceByName -TargetName $parsed.Target
                if ($svc) {
                    $ok = Start-ServiceEntry -svc $svc -BackgroundMode $parsed.Bg
                } else {
                    Write-Host "  Service '$($parsed.Target)' not found. Available: $(Get-AvailableServicesText)" -ForegroundColor Red
                    $ok = $false
                }
            }
            Write-Status
        }
        "stop" {
            if (-not $Arg1 -or $Arg1.Trim().ToLower() -eq "all") {
                Stop-AllServices
            } else {
                $svc = Find-ServiceByName -TargetName $Arg1
                if ($svc) {
                    Stop-ServiceEntry -svc $svc
                } else {
                    Write-Host "  Service '$Arg1' not found. Available: $(Get-AvailableServicesText)" -ForegroundColor Red
                    $ok = $false
                }
            }
            Write-Status
        }
        "restart" {
            $parsed = Resolve-TargetAndBg -Arg1 $Arg1 -Arg2 $Arg2
            if (-not $parsed.Target) {
                Stop-AllServices
                Start-Sleep -Seconds 1
                $ok = Start-AllServices -BackgroundMode $parsed.Bg
            } else {
                $svc = Find-ServiceByName -TargetName $parsed.Target
                if ($svc) {
                    $ok = Restart-ServiceEntry -svc $svc -BackgroundMode $parsed.Bg
                } else {
                    Write-Host "  Service '$($parsed.Target)' not found. Available: $(Get-AvailableServicesText)" -ForegroundColor Red
                    $ok = $false
                }
            }
            Write-Status
        }
        "force-stop" {
            Force-StopAllServices
        }
        "status" {
            Write-Status
        }
        "logs" {
            $lineCount = 20
            if ($Arg2 -and ($Arg2 -match '^\d+$')) { $lineCount = [int]$Arg2 }
            $ok = Show-Logs -TargetName $Arg1 -Lines $lineCount
        }
        { $_ -in @("help", "-h", "--help") } {
            Write-Banner
            Invoke-UpdateBannerCheck -Mode "--bg"
            Show-Menu
        }
        default {
            Write-Host "  Unknown command: '$Cmd'. Type 'help' for available commands." -ForegroundColor Red
            Write-Host ""
            $ok = $false
        }
    }
    return $ok
}

# --- Direct CLI Mode (does NOT register exit cleanup so launched services stay alive) ---
if ($args.Count -gt 0) {
    $c = $args[0]
    $a1 = if ($args.Count -gt 1) { $args[1] } else { "" }
    $a2 = if ($args.Count -gt 2) { $args[2] } else { "" }
    $success = Invoke-Action -Cmd $c -Arg1 $a1 -Arg2 $a2
    if ($c.ToLower() -notin @("help", "-h", "--help")) {
        Invoke-UpdateBannerCheck -Mode "--bg"
    }
    if (-not $success) { exit 1 }
    exit 0
}

# --- Interactive REPL Mode (register cleanup only in interactive mode) ---
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
        Stop-AllServices
        Write-Host "  Goodbye!" -ForegroundColor Cyan
        exit 0
    } -ErrorAction SilentlyContinue | Out-Null
} catch {}

Write-Banner
Invoke-UpdateBannerCheck -Mode "sync"
$env:WORKSPACE_UPDATE_CHECKED = "1"
Show-Menu

while ($true) {
    Write-Host "  $($script:WorkspacePrompt)> " -NoNewline -ForegroundColor Cyan
    $inputCmd = Read-Host

    if ($null -eq $inputCmd) { break }
    $inputTrimmed = $inputCmd.Trim()
    if (-not $inputTrimmed) { continue }

    $parts = $inputTrimmed -split '\s+'
    $cmd = $parts[0]
    $arg1 = if ($parts.Length -gt 1) { $parts[1] } else { "" }
    $arg2 = if ($parts.Length -gt 2) { $parts[2] } else { "" }

    if ($cmd.ToLower() -in @("quit", "exit", "q")) {
        Stop-AllServices
        Write-Host "  Goodbye!" -ForegroundColor Cyan
        Write-Host ""
        exit 0
    }

    $null = Invoke-Action -Cmd $cmd -Arg1 $arg1 -Arg2 $arg2
}
