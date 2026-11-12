# =============================================================================
# library-bundle (Windows PowerShell) - Module: 30_services.ps1
# =============================================================================

$script:pidsDir = Join-Path $ScriptDir ".pids"
$script:runnersDir = Join-Path $ScriptDir ".runners"
$script:logsDir = Join-Path $ScriptDir "logs"
$script:runningProcesses = @{}
$script:ServiceExitCode = 0

function Ensure-RuntimeDirs {
    foreach ($d in @($script:pidsDir, $script:runnersDir, $script:logsDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

function Format-ServiceLabel {
    param($svc)
    if ($svc.Emoji) { return "$($svc.Emoji) $($svc.Name)" }
    return $svc.Name
}

function Get-AvailableServicesText {
    Load-ServicesCsv
    if ($script:services.Count -eq 0) { return "(none configured in services.csv)" }
    return (($script:services | ForEach-Object { $_.Name }) -join ", ")
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
        if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
            $conns = Get-NetTCPConnection -LocalPort ([int]$Port) -State Listen -ErrorAction SilentlyContinue
            if ($conns) { return @($conns | Select-Object -ExpandProperty OwningProcess -Unique) }
        }
    } catch {}
    try {
        $lines = & netstat.exe -ano -p TCP 2>$null
        $found = @()
        foreach ($line in $lines) {
            if ($line -match '^\s*TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$') {
                if ([int]$Matches[1] -eq [int]$Port -and [int]$Matches[2] -gt 0) {
                    $found += [int]$Matches[2]
                }
            }
        }
        if ($found.Count -gt 0) { return @($found | Select-Object -Unique) }
    } catch {}
    return @()
}

function Get-RunnerPid {
    param($svc)
    $slug = $svc.Slug
    $pidFile = Join-Path $script:pidsDir "$slug.pid"

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

function Import-DotEnvFile {
    param([string]$EnvPath)
    if (-not (Test-Path $EnvPath)) {
        Write-Host "ERROR: .env file not found: $EnvPath" -ForegroundColor Red
        return $false
    }
    foreach ($rawLine in (Get-Content $EnvPath -Encoding UTF8)) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
        if ($line -match '^export\s+(.+)$') { $line = $Matches[1].Trim() }
        if (-not $line.Contains("=")) { continue }
        $parts = $line.Split("=", 2)
        $k = $parts[0].Trim()
        $v = $parts[1].Trim()
        if (($v.StartsWith('"') -and $v.EndsWith('"') -and $v.Length -ge 2) -or ($v.StartsWith("'") -and $v.EndsWith("'") -and $v.Length -ge 2)) {
            $v = $v.Substring(1, $v.Length - 2)
        }
        if ($k -match '^[A-Za-z_][A-Za-z0-9_]*$') {
            [System.Environment]::SetEnvironmentVariable($k, $v, "Process")
        }
    }
    return $true
}

function Test-ScriptCommand {
    param([string]$Dir, [string]$CmdWin)
    if (-not $CmdWin -or $CmdWin -match '\s') { return $false }
    $candidate = Join-Path $Dir $CmdWin
    return ($CmdWin -match '\.(bat|cmd|ps1)$' -or (Test-Path $candidate -PathType Leaf))
}

function Invoke-ServiceBody {
    param($svc)
    $script:ServiceExitCode = 0
    Set-Location $svc.Dir

    if ($svc.Port) {
        $env:PORT = "$($svc.Port)"
    }

    if ($svc.LoadEnvFile) {
        $ok = Import-DotEnvFile -EnvPath (Join-Path $svc.Dir ".env")
        if (-not $ok) {
            $script:ServiceExitCode = 1
            return
        }
    }

    $global:LASTEXITCODE = 0
    try {
        if ($svc.CmdWin) {
            if (Test-ScriptCommand -Dir $svc.Dir -CmdWin $svc.CmdWin) {
                $target = Join-Path $svc.Dir $svc.CmdWin
                & $target
            } else {
                & cmd.exe /c $svc.CmdWin
            }
        } else {
            switch ($svc.RepoType) {
                "spring-boot" { Invoke-TemplateSpringBoot }
                "flutter-web" { Invoke-TemplateFlutterWeb }
                "go"          { Invoke-TemplateGo }
                "vite"        { Invoke-TemplateVite }
                default {
                    Write-Host "ERROR: No cmd_win or valid repo_type configured for '$($svc.Name)'." -ForegroundColor Red
                    $script:ServiceExitCode = 1
                    return
                }
            }
        }

        if ($script:ServiceExitCode -ne 0) { return }
        if ($null -ne $LASTEXITCODE -and [int]$LASTEXITCODE -ne 0) {
            $script:ServiceExitCode = [int]$LASTEXITCODE
        } elseif (-not $?) {
            $script:ServiceExitCode = 1
        } else {
            $script:ServiceExitCode = 0
        }
    } catch {
        Write-Host "ERROR: Failed to run service '$($svc.Name)': $_" -ForegroundColor Red
        $script:ServiceExitCode = 1
    }
}

function Invoke-ServiceEntrypoint {
    param([string]$Slug)
    $script:ServiceExitCode = 1
    Load-ServicesCsv
    foreach ($svc in $script:services) {
        if ($svc.Slug -eq $Slug) {
            Invoke-ServiceBody -svc $svc
            return
        }
    }
    Write-Host "Service '$Slug' not found." -ForegroundColor Red
}

function Write-ServiceStatus {
    Load-ServicesCsv
    Write-Host ""
    Write-Host "  Service Status:" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
    if ($script:services.Count -eq 0) {
        Write-Host "  No services configured in services.csv" -ForegroundColor Yellow
    } else {
        foreach ($svc in $script:services) {
            $label = Format-ServiceLabel -svc $svc
            $port = Get-ServicePort -svc $svc
            $listenPids = @(Get-PortListenPids -Port $port)
            $runnerPid = Get-RunnerPid -svc $svc
            $typeTag = if ($svc.RepoType -ne "custom") { " [$($svc.RepoType)]" } else { "" }

            if ($port) {
                if ($listenPids.Count -gt 0) {
                    $pidList = $listenPids -join " "
                    Write-Host "  $label " -NoNewline -ForegroundColor White
                    Write-Host "[RUNNING]" -NoNewline -ForegroundColor Green
                    Write-Host "$typeTag (Port: $port, PID: $pidList)" -ForegroundColor DarkGray
                } elseif ($runnerPid) {
                    Write-Host "  $label " -NoNewline -ForegroundColor White
                    Write-Host "[STARTING...]" -NoNewline -ForegroundColor Yellow
                    Write-Host "$typeTag (Port: $port, PID: $runnerPid - booting)" -ForegroundColor DarkGray
                } else {
                    Write-Host "  $label " -NoNewline -ForegroundColor White
                    Write-Host "[STOPPED]" -NoNewline -ForegroundColor Red
                    Write-Host "$typeTag" -ForegroundColor DarkGray
                }
            } else {
                if ($runnerPid) {
                    Write-Host "  $label " -NoNewline -ForegroundColor White
                    Write-Host "[RUNNING]" -NoNewline -ForegroundColor Green
                    Write-Host "$typeTag (PID: $runnerPid)" -ForegroundColor DarkGray
                } else {
                    Write-Host "  $label " -NoNewline -ForegroundColor White
                    Write-Host "[STOPPED]" -NoNewline -ForegroundColor Red
                    Write-Host "$typeTag" -ForegroundColor DarkGray
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
    Load-ServicesCsv
    $targetSlug = ConvertTo-Slug -Text $TargetName.Trim()
    foreach ($svc in $script:services) {
        if ($svc.Slug -eq $targetSlug) { return $svc }
    }
    return $null
}

function Get-PowerShellExe {
    $cmd = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { return $pwsh.Source }
    return "powershell.exe"
}

function New-ThinRunnerScript {
    param($svc, $ResolvedPort, [bool]$BackgroundMode)
    Ensure-RuntimeDirs

    $slug = $svc.Slug
    $runnerFile = Join-Path $script:runnersDir "run_$slug.ps1"
    $pidFile = Join-Path $script:pidsDir "$slug.pid"
    $label = Format-ServiceLabel -svc $svc
    $title = if ($ResolvedPort) { "$($script:WorkspaceName) - $($svc.Name) (Port $ResolvedPort)" } else { "$($script:WorkspaceName) - $($svc.Name)" }
    if ($svc.Emoji) { $title = "$($svc.Emoji) $title" }

    $cmdDisplay = if ($svc.CmdWin) { $svc.CmdWin } else { "template:$($svc.RepoType)" }
    $bundleSelf = $script:BundleSelfPath

    $escTitle = $title.Replace("'", "''")
    $escPidFile = $pidFile.Replace("'", "''")
    $escDir = $svc.Dir.Replace("'", "''")
    $escHints = $svc.Hints.Replace("'", "''")
    $escLabel = $label.Replace("'", "''")
    $escCmdDisp = $cmdDisplay.Replace("'", "''")
    $escBundle = $bundleSelf.Replace("'", "''")
    $escRoot = $ScriptDir.Replace("'", "''")
    $escName = $svc.Name.Replace("'", "''")
    $escSlug = $slug.Replace("'", "''")
    $portVal = if ($ResolvedPort) { "$ResolvedPort" } else { "" }
    $bgStr = if ($BackgroundMode) { "`$true" } else { "`$false" }

    $content = @"
`$ErrorActionPreference = "Continue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { `$Host.UI.RawUI.WindowTitle = '$escTitle' } catch {}

`$pidFile = '$escPidFile'
`$isBg = $bgStr
if (-not (Test-Path `$pidFile)) {
    try { Set-Content -Path `$pidFile -Value `$PID -Force } catch {}
}

if (-not `$isBg) {
    Write-Host "=============================================================================" -ForegroundColor Cyan
    Write-Host "  $escLabel" -ForegroundColor Green
    Write-Host "  Directory : $escDir" -ForegroundColor White
    if ('$portVal') { Write-Host "  Port      : $portVal" -ForegroundColor White }
    Write-Host "  Runner    : $escCmdDisp" -ForegroundColor White
    if ('$escHints') { Write-Host "  Controls  : $escHints" -ForegroundColor Yellow }
    Write-Host "=============================================================================" -ForegroundColor Cyan
    Write-Host ""
}

`$exitCode = 0
try {
    `$env:WORKSPACE_ROOT_DIR = '$escRoot'
    & '$escBundle' "__run-service" '$escSlug'
    `$exitCode = if (`$null -ne `$LASTEXITCODE) { [int]`$LASTEXITCODE } else { 0 }
} finally {
    Remove-Item -Path `$pidFile -Force -ErrorAction SilentlyContinue
}

if (-not `$isBg -and `$exitCode -ne 0) {
    Write-Host ""
    Write-Host "$escName exited with code `$exitCode." -ForegroundColor Red
    Read-Host "Press [Enter] to close this window..."
}
exit `$exitCode
"@

    Set-Content -Path $runnerFile -Value $content -Encoding UTF8 -Force
    return $runnerFile
}

function Start-ServiceEntry {
    param($svc, [bool]$BackgroundMode = $false)
    Ensure-RuntimeDirs

    $label = Format-ServiceLabel -svc $svc
    $slug = $svc.Slug
    $pidFile = Join-Path $script:pidsDir "$slug.pid"

    if (-not (Test-Path $svc.Dir -PathType Container)) {
        Write-Host "  ERROR: Service directory not found: $($svc.Dir)" -ForegroundColor Red
        Write-Host "  Hint: Run '.\workspace.bat clone' first." -ForegroundColor Yellow
        return $false
    }

    if ($svc.CmdWin) {
        if ((Test-ScriptCommand -Dir $svc.Dir -CmdWin $svc.CmdWin) -and -not (Test-Path (Join-Path $svc.Dir $svc.CmdWin) -PathType Leaf)) {
            Write-Host "  ERROR: Runner script not found: $(Join-Path $svc.Dir $svc.CmdWin)" -ForegroundColor Red
            return $false
        }
    } elseif ($svc.RepoType -eq "custom") {
        Write-Host "  ERROR: Service '$($svc.Name)' has repo_type='custom' and no cmd_win specified." -ForegroundColor Red
        return $false
    }

    if ($svc.LoadEnvFile) {
        $envFile = Join-Path $svc.Dir ".env"
        if (-not (Test-Path $envFile -PathType Leaf)) {
            Write-Host "  ERROR: .env file not found for '$($svc.Name)' at: $envFile (load_env_file=true)" -ForegroundColor Red
            if (Test-Path (Join-Path $svc.Dir ".env.example") -PathType Leaf) {
                Write-Host "  Hint: Found .env.example -- copy it to .env and configure it before starting." -ForegroundColor Yellow
            }
            return $false
        }
    }

    $port = Get-ServicePort -svc $svc
    $listenPids = @(Get-PortListenPids -Port $port)
    $runnerPid = Get-RunnerPid -svc $svc
    if ($listenPids.Count -gt 0 -or $runnerPid) {
        $activePid = if ($listenPids.Count -gt 0) { $listenPids[0] } else { $runnerPid }
        Write-Host "  $label is already running (PID: $activePid)" -ForegroundColor Yellow
        return $true
    }

    Remove-Item -Path $pidFile -Force -ErrorAction SilentlyContinue
    $runnerFile = New-ThinRunnerScript -svc $svc -ResolvedPort $port -BackgroundMode $BackgroundMode
    $psExe = Get-PowerShellExe

    if ($BackgroundMode) {
        Write-Host "  Starting $label in background..." -ForegroundColor Cyan
        $logFile = Join-Path $script:logsDir "${slug}_run.log"
        $errLogFile = Join-Path $script:logsDir "${slug}_run.err.log"
        $proc = Start-Process -FilePath $psExe `
            -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$runnerFile`"" `
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
            -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$runnerFile`"" `
            -PassThru -WindowStyle Normal
        $script:runningProcesses[$slug] = $proc
        Set-Content -Path $pidFile -Value $proc.Id -Force
        Write-Host "  $label launched (PID: $($proc.Id))" -ForegroundColor Green
    }
    return $true
}

function Stop-ServiceEntry {
    param($svc)
    Ensure-RuntimeDirs
    $label = Format-ServiceLabel -svc $svc
    $slug = $svc.Slug
    $port = Get-ServicePort -svc $svc
    $pidFile = Join-Path $script:pidsDir "$slug.pid"
    $stoppedAny = $false

    $runnerPid = Get-RunnerPid -svc $svc
    if ($runnerPid) {
        try {
            Write-Host "  Stopping $label (PID: $runnerPid)..." -ForegroundColor Yellow
            & taskkill /T /F /PID $runnerPid 2>&1 | Out-Null
            $stoppedAny = $true
        } catch {}
    }

    foreach ($p in (Get-PortListenPids -Port $port)) {
        try {
            Write-Host "  Stopping $label port $port listener (PID: $p)..." -ForegroundColor Yellow
            & taskkill /T /F /PID $p 2>&1 | Out-Null
            $stoppedAny = $true
        } catch {}
    }

    $script:runningProcesses.Remove($slug)
    Remove-Item -Path $pidFile -Force -ErrorAction SilentlyContinue
    if ($stoppedAny) { Write-Host "  $label stopped" -ForegroundColor Green }
    else { Write-Host "  $label is not running" -ForegroundColor Yellow }
}

function Restart-ServiceEntry {
    param($svc, [bool]$BackgroundMode = $false)
    Stop-ServiceEntry -svc $svc
    Start-Sleep -Seconds 1
    return (Start-ServiceEntry -svc $svc -BackgroundMode $BackgroundMode)
}

function Start-AllServices {
    param([bool]$BackgroundMode = $false)
    Load-ServicesCsv
    $failures = 0
    Write-Host ""
    Write-Host "  Starting all services..." -ForegroundColor Cyan
    Write-Host ""
    foreach ($svc in $script:services) {
        if (-not (Start-ServiceEntry -svc $svc -BackgroundMode $BackgroundMode)) { $failures++ }
    }
    Write-Host ""
    return ($failures -eq 0)
}

function Stop-AllServices {
    Load-ServicesCsv
    Write-Host ""
    Write-Host "  Stopping all services..." -ForegroundColor Yellow
    Write-Host ""
    foreach ($svc in $script:services) { Stop-ServiceEntry -svc $svc }
    Write-Host ""
}

function Force-KillByPort {
    param([int]$Port, [string]$Label)
    $pids = @(Get-PortListenPids -Port $Port)
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
    Load-ServicesCsv
    Ensure-RuntimeDirs
    Write-Host ""
    Write-Host "  Force stopping all $($script:WorkspaceName) services..." -ForegroundColor Red
    Write-Host ""

    foreach ($svc in $script:services) { Stop-ServiceEntry -svc $svc }
    Write-Host "  Scanning for orphaned processes..." -ForegroundColor Yellow
    Write-Host ""

    foreach ($svc in $script:services) {
        $port = Get-ServicePort -svc $svc
        if (-not $port -and $svc.StopPatterns.Count -eq 0) { continue }
        $label = Format-ServiceLabel -svc $svc
        if ($port) {
            Write-Host "  ${label} (port $port):" -ForegroundColor White
            Force-KillByPort -Port $port -Label $svc.Name
        } else {
            Write-Host "  ${label}:" -ForegroundColor White
        }
        foreach ($pat in $svc.StopPatterns) { Force-KillByCommandLine -Pattern $pat -Label $svc.Name }
        Write-Host ""
    }

    Get-ChildItem -Path $script:pidsDir -Filter "*.pid" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    $script:runningProcesses = @{}
    Write-Host "  Force stop complete." -ForegroundColor Green
    Write-Host ""
}

function Show-ServiceLogs {
    param([string]$TargetName, [int]$Lines = 20)
    if (-not $TargetName) {
        Write-Host "  Please specify a service. Available: $(Get-AvailableServicesText)" -ForegroundColor Red
        $script:CommandSucceeded = $false
        return
    }
    $svc = Find-ServiceByName -TargetName $TargetName
    if (-not $svc) {
        Write-Host "  Service '$TargetName' not found. Available: $(Get-AvailableServicesText)" -ForegroundColor Red
        $script:CommandSucceeded = $false
        return
    }
    $logFile = Join-Path $script:logsDir "$($svc.Slug)_run.log"
    $errLogFile = Join-Path $script:logsDir "$($svc.Slug)_run.err.log"
    $hasOut = Test-Path $logFile
    $hasErr = (Test-Path $errLogFile) -and ((Get-Item $errLogFile).Length -gt 0)
    if ($hasOut -or $hasErr) {
        if ($hasOut) {
            Write-Host "  === Last $Lines lines of $logFile ===" -ForegroundColor Cyan
            Get-Content -Path $logFile -Tail $Lines
            Write-Host ""
        }
        if ($hasErr) {
            Write-Host "  === Last $Lines lines of $errLogFile ===" -ForegroundColor Yellow
            Get-Content -Path $errLogFile -Tail $Lines
            Write-Host ""
        }
    } else {
        Write-Host "  No log file found at $logFile" -ForegroundColor Yellow
        Write-Host ""
    }
    $script:CommandSucceeded = $true
}

function Resolve-TargetAndBg {
    param([string]$Arg1, [string]$Arg2)
    $bg = $false; $target = ""
    foreach ($a in @($Arg1, $Arg2)) {
        if (-not $a) { continue }
        $al = "$a".Trim().ToLower()
        if ($al -in @("--bg", "bg", "-bg")) { $bg = $true }
        elseif ($al -ne "all" -and -not $target) { $target = $a.Trim() }
    }
    return [pscustomobject]@{ Target = $target; Bg = $bg }
}

