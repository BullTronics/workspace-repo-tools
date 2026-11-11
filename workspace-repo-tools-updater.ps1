# =============================================================================
# workspace-repo-tools-updater.ps1
# Checks for and applies tooling upgrades from BullTronics/workspace-repo-tools
# while preserving user configuration, repositories, and environment files.
# =============================================================================

$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkspaceConf = Join-Path $ScriptDir "workspace.conf"
$VersionFile = Join-Path $ScriptDir "VERSION"
$LockFile = Join-Path $ScriptDir ".workspace-tools.lock"
$CacheFile = Join-Path $ScriptDir ".workspace-tools-cache"
$BackupsRoot = Join-Path $ScriptDir ".workspace-tools-backups"

$script:UpstreamUrl = "https://github.com/BullTronics/workspace-repo-tools.git"
$script:UpstreamBranch = "main"
$script:RawBaseUrl = ""
$script:DisableAutoCheck = $false
$script:CheckIntervalHours = 24

function Read-KvFile {
    param([string]$FilePath)
    $map = @{}
    if (-not (Test-Path $FilePath)) { return $map }
    foreach ($rawLine in (Get-Content $FilePath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
        if ($line -match '^([^=]+)=(.*)$') {
            $k = $Matches[1].Trim()
            $v = $Matches[2].Trim().Trim('"').Trim("'")
            $map[$k] = $v
        }
    }
    return $map
}

function Load-UpdaterConf {
    $conf = Read-KvFile -FilePath $WorkspaceConf
    if ($conf.ContainsKey("TOOLS_UPSTREAM_URL") -and $conf["TOOLS_UPSTREAM_URL"]) {
        $script:UpstreamUrl = $conf["TOOLS_UPSTREAM_URL"]
    }
    if ($conf.ContainsKey("TOOLS_UPSTREAM_BRANCH") -and $conf["TOOLS_UPSTREAM_BRANCH"]) {
        $script:UpstreamBranch = $conf["TOOLS_UPSTREAM_BRANCH"]
    }
    if ($conf.ContainsKey("TOOLS_RAW_BASE_URL") -and $conf["TOOLS_RAW_BASE_URL"]) {
        $script:RawBaseUrl = $conf["TOOLS_RAW_BASE_URL"].TrimEnd('/')
    }
    if ($conf.ContainsKey("DISABLE_AUTO_UPDATE_CHECK") -and $conf["DISABLE_AUTO_UPDATE_CHECK"]) {
        $val = $conf["DISABLE_AUTO_UPDATE_CHECK"].ToLower()
        if ($val -eq "true") { $script:DisableAutoCheck = $true }
        elseif ($val -eq "false") { $script:DisableAutoCheck = $false }
    }
    if ($conf.ContainsKey("UPDATE_CHECK_INTERVAL_HOURS") -and ($conf["UPDATE_CHECK_INTERVAL_HOURS"] -match '^\d+$')) {
        $script:CheckIntervalHours = [int]$conf["UPDATE_CHECK_INTERVAL_HOURS"]
    }
}

Load-UpdaterConf

function Show-Usage {
@"
workspace-repo-tools-updater.ps1 / .bat - check and upgrade workspace-repo-tools

Usage:

  .\workspace-repo-tools-updater.bat <command> [options]

Commands:

  check               Check if an upstream update is available (default)
  upgrade             Download and apply upstream tooling updates safely
  update              Alias for 'upgrade'
  diff                Show line-by-line diff of local vs upstream tooling files
  status | version    Show installed version, lockfile commit, and cache info
  help                Show this help message

Options:

  --dry-run           Show planned upgrade changes without modifying files
  -y, --yes           Apply upgrade without confirmation prompt
  -f, --force         Apply even if already on the latest commit or inside upstream repo
  --commit            Force commit-SHA check via git ls-remote instead of raw VERSION check
  --url <git-url>     Override upstream repository URL
  --raw-url <url>     Override raw base URL for VERSION checks
  --branch <branch>   Override upstream branch (default: main)
"@ | Write-Host
}

function Get-EpochSeconds {
    return [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
}

function Get-LocalVersion {
    $lock = Read-KvFile -FilePath $LockFile
    if ($lock.ContainsKey("INSTALLED_VERSION") -and $lock["INSTALLED_VERSION"]) {
        return $lock["INSTALLED_VERSION"]
    }
    if (Test-Path $VersionFile) {
        $v = (Get-Content $VersionFile -Encoding UTF8 | Select-Object -First 1).Trim()
        if ($v) { return $v }
    }
    return "unknown"
}

function Get-InstalledCommit {
    $lock = Read-KvFile -FilePath $LockFile
    if ($lock.ContainsKey("INSTALLED_COMMIT")) { return $lock["INSTALLED_COMMIT"] }
    return ""
}

function Invoke-GitWithTimeout {
    param([string[]]$GitArgs, [int]$TimeoutMs = 3000)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "git"
    $psi.Arguments = ($GitArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join " "
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables["GIT_TERMINAL_PROMPT"] = "0"

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $null = $proc.Start()

    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    if (-not $proc.WaitForExit($TimeoutMs)) {
        try { $proc.Kill() } catch {}
        return [pscustomobject]@{ ExitCode = 124; Output = "" }
    }
    $proc.WaitForExit()
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = $outTask.Result }
}

function Get-RemoteHeadSha {
    param([int]$TimeoutMs = 3000)
    $res = Invoke-GitWithTimeout -GitArgs @("ls-remote", $script:UpstreamUrl, "refs/heads/$($script:UpstreamBranch)") -TimeoutMs $TimeoutMs
    if ($res.ExitCode -ne 0 -or -not $res.Output) { return $null }
    $firstLine = ($res.Output -split "`n")[0].Trim()
    if ($firstLine -match '^([0-9a-fA-F]{40})\s+') {
        return $Matches[1]
    }
    return $null
}

function Resolve-RawBaseUrl {
    if ($script:RawBaseUrl) { return $script:RawBaseUrl.TrimEnd('/') }
    $u = $script:UpstreamUrl.Trim().TrimEnd('/')
    if ($u.EndsWith(".git")) { $u = $u.Substring(0, $u.Length - 4) }
    if ($u -like "git@github.com:*") { $u = "https://github.com/" + $u.Substring("git@github.com:".Length) }
    if ($u -match '^https://github\.com/([^/]+/[^/]+)$') {
        return "https://raw.githubusercontent.com/$($Matches[1])/$($script:UpstreamBranch)"
    }
    return $null
}

function Test-ValidSemver {
    param([string]$Ver)
    return ($Ver -match '^[0-9]+(\.[0-9]+)*([-+][A-Za-z0-9._-]+)?$')
}

function Test-VersionNewer {
    param([string]$RemoteVer, [string]$LocalVer)
    if (-not (Test-ValidSemver $RemoteVer)) { return $false }
    if (-not $LocalVer -or $LocalVer -eq "unknown" -or -not (Test-ValidSemver $LocalVer)) { return $true }
    if ($RemoteVer -eq $LocalVer) { return $false }

    $rBase = ($RemoteVer -split '\+')[0]
    $lBase = ($LocalVer -split '\+')[0]
    $rPre = ""; $lPre = ""
    if ($rBase -match '^([^-]+)-(.+)$') { $rBase = $Matches[1]; $rPre = $Matches[2] }
    if ($lBase -match '^([^-]+)-(.+)$') { $lBase = $Matches[1]; $lPre = $Matches[2] }

    $rParts = $rBase -split '\.'
    $lParts = $lBase -split '\.'
    $maxLen = [Math]::Max($rParts.Count, $lParts.Count)

    for ($idx = 0; $idx -lt $maxLen; $idx++) {
        $rv = if ($idx -lt $rParts.Count) { [int]$rParts[$idx] } else { 0 }
        $lv = if ($idx -lt $lParts.Count) { [int]$lParts[$idx] } else { 0 }
        if ($rv -gt $lv) { return $true }
        if ($rv -lt $lv) { return $false }
    }

    if ($lPre -and -not $rPre) { return $true }
    if ($lPre -and $rPre -and ($rPre -gt $lPre)) { return $true }
    return $false
}

function Get-RemoteVersionRaw {
    param([int]$TimeoutSec = 2)
    $rawBase = Resolve-RawBaseUrl
    if (-not $rawBase) { return $null }
    $verUrl = "$rawBase/VERSION"
    try {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch {}
        $resp = Invoke-RestMethod -Uri $verUrl -TimeoutSec $TimeoutSec -ErrorAction Stop
        $first = ("$resp" -split "`n")[0].Trim()
        if (Test-ValidSemver $first) { return $first }
    } catch {}
    return $null
}

function Copy-UpstreamShallow {
    param([string]$DestDir, [int]$TimeoutMs = 20000)
    $res = Invoke-GitWithTimeout -GitArgs @("clone", "--quiet", "--depth", "1", "--branch", $script:UpstreamBranch, $script:UpstreamUrl, $DestDir) -TimeoutMs $TimeoutMs
    return ($res.ExitCode -eq 0)
}

function Get-FileSha256 {
    param([string]$Path)
    if (-not (Test-Path $Path -PathType Leaf)) { return "MISSING" }
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
}

function Normalize-RepoUrl {
    param([string]$Url)
    $u = $Url.Trim().ToLower().TrimEnd('/')
    if ($u.EndsWith(".git")) { $u = $u.Substring(0, $u.Length - 4) }
    if ($u -like "git@github.com:*") { $u = "https://github.com/" + $u.Substring("git@github.com:".Length) }
    return $u
}

function Test-SameUpstreamRepo {
    $res = Invoke-GitWithTimeout -GitArgs @("-C", $ScriptDir, "config", "--get", "remote.origin.url") -TimeoutMs 2000
    if ($res.ExitCode -ne 0 -or -not $res.Output) { return $false }
    $origin = Normalize-RepoUrl -Url $res.Output
    $upstream = Normalize-RepoUrl -Url $script:UpstreamUrl
    return ($origin -eq $upstream)
}

function Write-CacheFile {
    param(
        [int64]$LastCheck,
        [int64]$LastAttempt,
        [string]$RemoteCommit,
        [string]$RemoteVersion,
        [string]$MatchedCommit,
        [string]$UpdateAvailable
    )
    $content = @"
LAST_CHECK_EPOCH=$LastCheck
LAST_ATTEMPT_EPOCH=$LastAttempt
REMOTE_COMMIT=$RemoteCommit
REMOTE_VERSION=$RemoteVersion
MATCHED_COMMIT=$MatchedCommit
UPDATE_AVAILABLE=$UpdateAvailable
"@
    $tmp = "$CacheFile.tmp.$PID"
    Set-Content -Path $tmp -Value $content -Encoding UTF8 -Force
    Move-Item -Path $tmp -Destination $CacheFile -Force
}

function Write-LockFile {
    param([string]$Version, [string]$Commit)
    $nowIso = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $content = @"
INSTALLED_VERSION=$Version
INSTALLED_COMMIT=$Commit
UPSTREAM_URL=$($script:UpstreamUrl)
UPSTREAM_BRANCH=$($script:UpstreamBranch)
UPDATED_AT=$nowIso
"@
    $tmp = "$LockFile.tmp.$PID"
    Set-Content -Path $tmp -Value $content -Encoding UTF8 -Force
    Move-Item -Path $tmp -Destination $LockFile -Force
}

function Test-SafeManifestPath {
    param([string]$RelPath)
    if (-not $RelPath) { return $false }
    if ([System.IO.Path]::IsPathRooted($RelPath) -or $RelPath -match '^[A-Za-z]:' -or $RelPath.Contains("\") -or $RelPath -match '(^|/)\.\.(/|$)') {
        return $false
    }
    return $true
}

function Get-ManifestSpec {
    param([string]$BaseDir)
    $mfile = Join-Path $BaseDir "updater-manifest.txt"
    $files = @()
    $dirs = @()
    $merges = @()

    if (Test-Path $mfile) {
        foreach ($raw in (Get-Content $mfile -Encoding UTF8)) {
            $line = $raw.Trim()
            if (-not $line -or $line.StartsWith("#")) { continue }
            if ($line.StartsWith("file:")) {
                $p = $line.Substring(5).Trim()
                if (Test-SafeManifestPath $p) { $files += $p }
            } elseif ($line.StartsWith("dir:")) {
                $p = $line.Substring(4).Trim()
                if (Test-SafeManifestPath $p) { $dirs += $p }
            } elseif ($line.StartsWith("merge_lines:")) {
                $p = $line.Substring(12).Trim()
                if (Test-SafeManifestPath $p) { $merges += $p }
            }
        }
    }

    if ($files.Count -eq 0 -and $dirs.Count -eq 0) {
        $files = @(
            "workspace.sh", "workspace.ps1", "workspace.bat",
            "git-all.sh", "git-all.ps1", "git-all.bat",
            "run-local.sh", "run-local.ps1", "run-local.bat",
            "workspace-repo-tools-updater.sh", "workspace-repo-tools-updater.ps1", "workspace-repo-tools-updater.bat",
            "updater-manifest.txt", "VERSION", "README.md"
        )
        $dirs = @("templates")
        $merges = @(".gitignore")
    }

    return [pscustomobject]@{ Files = $files; Dirs = $dirs; Merges = $merges }
}

function Get-ManagedFiles {
    param([string]$UpstreamDir)
    $spec = Get-ManifestSpec -BaseDir $UpstreamDir
    $result = @()

    foreach ($f in $spec.Files) {
        $full = Join-Path $UpstreamDir ($f -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (Test-Path $full -PathType Leaf) { $result += $f }
    }

    foreach ($d in $spec.Dirs) {
        $fullDir = Join-Path $UpstreamDir ($d -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (Test-Path $fullDir -PathType Container) {
            $items = Get-ChildItem -Path $fullDir -File -Recurse | Sort-Object FullName
            foreach ($item in $items) {
                $rel = $item.FullName.Substring($UpstreamDir.Length + 1) -replace '\\', '/'
                if (Test-SafeManifestPath $rel) { $result += $rel }
            }
        }
    }

    return [pscustomobject]@{ Files = $result; Merges = $spec.Merges }
}

function Get-MissingMergeLines {
    param([string]$UpstreamFile, [string]$LocalFile)
    if (-not (Test-Path $UpstreamFile)) { return @() }
    $existing = @{}
    if (Test-Path $LocalFile) {
        foreach ($l in (Get-Content $LocalFile -Encoding UTF8)) {
            $existing[$l.TrimEnd("`r")] = $true
        }
    }
    $missing = @()
    foreach ($raw in (Get-Content $UpstreamFile -Encoding UTF8)) {
        $line = $raw.TrimEnd("`r")
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        if (-not $existing.ContainsKey($line)) {
            $missing += $line
        }
    }
    return ,$missing
}

function Test-AllManagedMatch {
    param([string]$UpstreamDir)
    $managed = Get-ManagedFiles -UpstreamDir $UpstreamDir
    foreach ($rel in $managed.Files) {
        $upPath = Join-Path $UpstreamDir ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $locPath = Join-Path $ScriptDir ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if ((Get-FileSha256 $upPath) -ne (Get-FileSha256 $locPath)) { return $false }
    }
    foreach ($mf in $managed.Merges) {
        $upPath = Join-Path $UpstreamDir ($mf -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $locPath = Join-Path $ScriptDir ($mf -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $missing = Get-MissingMergeLines -UpstreamFile $upPath -LocalFile $locPath
        if ($missing.Count -gt 0) { return $false }
    }
    return $true
}

function Show-UpdateNotice {
    param([string]$LocalVer, [string]$RemoteVer, [string]$LocalSha, [string]$RemoteSha)
    $hint = ""
    if ($RemoteVer -and $RemoteVer -ne "unknown") {
        if ($LocalVer -ne $RemoteVer) {
            $hint = "$LocalVer -> $RemoteVer"
        } else {
            $shortR = if ($RemoteSha.Length -ge 7) { $RemoteSha.Substring(0, 7) } else { $RemoteSha }
            if ($LocalSha) {
                $shortL = if ($LocalSha.Length -ge 7) { $LocalSha.Substring(0, 7) } else { $LocalSha }
                $hint = "$LocalVer ($shortL -> $shortR)"
            } else {
                $hint = "$LocalVer (new commit $shortR)"
            }
        }
    } elseif ($RemoteSha) {
        $shortR = if ($RemoteSha.Length -ge 7) { $RemoteSha.Substring(0, 7) } else { $RemoteSha }
        $hint = "commit $shortR"
    }

    Write-Host ""
    Write-Host "  Update available for workspace-repo-tools ($hint)" -ForegroundColor Yellow
    Write-Host "  Run '.\workspace-repo-tools-updater.bat upgrade' or '.\workspace.bat upgrade' to update." -ForegroundColor Cyan
    Write-Host ""
}

function Refresh-UpdateCache {
    param([int]$TimeoutMs = 2500)
    $now = Get-EpochSeconds

    $prev = Read-KvFile -FilePath $CacheFile
    $prevCheck = if ($prev.ContainsKey("LAST_CHECK_EPOCH")) { [int64]$prev["LAST_CHECK_EPOCH"] } else { 0 }
    $prevMatched = if ($prev.ContainsKey("MATCHED_COMMIT")) { $prev["MATCHED_COMMIT"] } else { "" }
    $prevRemote = if ($prev.ContainsKey("REMOTE_COMMIT")) { $prev["REMOTE_COMMIT"] } else { "" }
    $prevRver = if ($prev.ContainsKey("REMOTE_VERSION")) { $prev["REMOTE_VERSION"] } else { "" }
    $prevAvail = if ($prev.ContainsKey("UPDATE_AVAILABLE")) { $prev["UPDATE_AVAILABLE"] } else { "false" }

    $localVer = Get-LocalVersion
    $timeoutSec = [Math]::Max(1, [int][Math]::Ceiling($TimeoutMs / 1000.0))
    $rawVer = Get-RemoteVersionRaw -TimeoutSec $timeoutSec
    if ($rawVer) {
        $isNewer = if (Test-VersionNewer -RemoteVer $rawVer -LocalVer $localVer) { "true" } else { "false" }
        Write-CacheFile -LastCheck $now -LastAttempt $now -RemoteCommit "" -RemoteVersion $rawVer -MatchedCommit $prevMatched -UpdateAvailable $isNewer
        return $true
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-CacheFile -LastCheck $prevCheck -LastAttempt $now -RemoteCommit $prevRemote -RemoteVersion $prevRver -MatchedCommit $prevMatched -UpdateAvailable $prevAvail
        return $false
    }

    $remoteSha = Get-RemoteHeadSha -TimeoutMs $TimeoutMs
    if (-not $remoteSha) {
        Write-CacheFile -LastCheck $prevCheck -LastAttempt $now -RemoteCommit $prevRemote -RemoteVersion $prevRver -MatchedCommit $prevMatched -UpdateAvailable $prevAvail
        return $false
    }

    $installedSha = Get-InstalledCommit
    if ($installedSha) {
        if ($installedSha -eq $remoteSha) {
            Write-CacheFile -LastCheck $now -LastAttempt $now -RemoteCommit $remoteSha -RemoteVersion $localVer -MatchedCommit $remoteSha -UpdateAvailable "false"
            return $true
        }
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "wrt-check-$PID-$(Get-Random)"
        $rVer = ""
        try {
            if (Copy-UpstreamShallow -DestDir $tmp -TimeoutMs 10000) {
                $vf = Join-Path $tmp "VERSION"
                if (Test-Path $vf) { $rVer = (Get-Content $vf -Encoding UTF8 | Select-Object -First 1).Trim() }
            }
        } finally {
            Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-CacheFile -LastCheck $now -LastAttempt $now -RemoteCommit $remoteSha -RemoteVersion $rVer -MatchedCommit $prevMatched -UpdateAvailable "true"
        return $true
    }

    if ($prevMatched -and $prevMatched -eq $remoteSha) {
        $rv = if ($prevRver) { $prevRver } else { $localVer }
        Write-CacheFile -LastCheck $now -LastAttempt $now -RemoteCommit $remoteSha -RemoteVersion $rv -MatchedCommit $prevMatched -UpdateAvailable "false"
        return $true
    }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "wrt-check-$PID-$(Get-Random)"
    $rVer = ""
    $avail = "true"
    $matched = ""
    try {
        if (Copy-UpstreamShallow -DestDir $tmp -TimeoutMs 12000) {
            $vf = Join-Path $tmp "VERSION"
            if (Test-Path $vf) { $rVer = (Get-Content $vf -Encoding UTF8 | Select-Object -First 1).Trim() }
            if (Test-AllManagedMatch -UpstreamDir $tmp) {
                $avail = "false"
                $matched = $remoteSha
            }
        }
    } finally {
        Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-CacheFile -LastCheck $now -LastAttempt $now -RemoteCommit $remoteSha -RemoteVersion $rVer -MatchedCommit $matched -UpdateAvailable $avail
    return $true
}

function Invoke-BannerCheck {
    param([string]$Mode = "sync")
    if ($script:DisableAutoCheck -or $env:WORKSPACE_NO_UPDATE_CHECK -eq "1") { return }

    $now = Get-EpochSeconds
    $intervalSecs = [int64]$script:CheckIntervalHours * 3600
    $cache = Read-KvFile -FilePath $CacheFile
    $lastCheck = if ($cache.ContainsKey("LAST_CHECK_EPOCH") -and $cache["LAST_CHECK_EPOCH"] -match '^\d+$') { [int64]$cache["LAST_CHECK_EPOCH"] } else { 0 }
    $lastAttempt = if ($cache.ContainsKey("LAST_ATTEMPT_EPOCH") -and $cache["LAST_ATTEMPT_EPOCH"] -match '^\d+$') { [int64]$cache["LAST_ATTEMPT_EPOCH"] } else { 0 }

    $needsRefresh = $false
    if ($lastCheck -eq 0 -or ($now - $lastCheck) -ge $intervalSecs) {
        if ($lastAttempt -eq 0 -or ($now - $lastAttempt) -ge 900) {
            $needsRefresh = $true
        }
    }

    if ($needsRefresh) {
        if ($Mode -eq "--bg") {
            $psExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue)
            if (-not $psExe) { $psExe = (Get-Command pwsh -ErrorAction SilentlyContinue) }
            if ($psExe) {
                Start-Process -FilePath $psExe.Source -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $MyInvocation.MyCommand.Path, "--refresh-cache" -WindowStyle Hidden | Out-Null
            }
        } else {
            $null = Refresh-UpdateCache -TimeoutMs 2500
            $cache = Read-KvFile -FilePath $CacheFile
        }
    }

    $remoteSha = if ($cache.ContainsKey("REMOTE_COMMIT")) { $cache["REMOTE_COMMIT"] } else { "" }
    $remoteVer = if ($cache.ContainsKey("REMOTE_VERSION")) { $cache["REMOTE_VERSION"] } else { "" }
    $matchedSha = if ($cache.ContainsKey("MATCHED_COMMIT")) { $cache["MATCHED_COMMIT"] } else { "" }
    $avail = if ($cache.ContainsKey("UPDATE_AVAILABLE")) { $cache["UPDATE_AVAILABLE"] } else { "false" }
    $installedSha = Get-InstalledCommit
    $localVerNow = Get-LocalVersion

    if ($installedSha -and $remoteSha -and $installedSha -eq $remoteSha) { $avail = "false" }
    elseif ($matchedSha -and $remoteSha -and $matchedSha -eq $remoteSha) { $avail = "false" }
    elseif (-not $remoteSha -and $remoteVer -and -not (Test-VersionNewer -RemoteVer $remoteVer -LocalVer $localVerNow)) { $avail = "false" }

    if ($avail -eq "true") {
        Show-UpdateNotice -LocalVer $localVerNow -RemoteVer $remoteVer -LocalSha $installedSha -RemoteSha $remoteSha
    }
}

function Invoke-CheckCommand {
    param([bool]$ForceCommit = $false)
    $localVer = Get-LocalVersion
    $installedSha = Get-InstalledCommit
    $now = Get-EpochSeconds

    if (-not $ForceCommit) {
        $rawBase = Resolve-RawBaseUrl
        if ($rawBase) {
            Write-Host "Checking version via: $rawBase/VERSION..." -ForegroundColor Cyan
            $rawVer = Get-RemoteVersionRaw -TimeoutSec 5
            if ($rawVer) {
                if (-not (Test-VersionNewer -RemoteVer $rawVer -LocalVer $localVer)) {
                    Write-CacheFile -LastCheck $now -LastAttempt $now -RemoteCommit $installedSha -RemoteVersion $rawVer -MatchedCommit $installedSha -UpdateAvailable "false"
                    Write-Host "Up to date (version: $localVer)" -ForegroundColor Green
                    return
                }
                Write-CacheFile -LastCheck $now -LastAttempt $now -RemoteCommit "" -RemoteVersion $rawVer -MatchedCommit "" -UpdateAvailable "true"
                Show-UpdateNotice -LocalVer $localVer -RemoteVer $rawVer -LocalSha $installedSha -RemoteSha ""

                if (Get-Command git -ErrorAction SilentlyContinue) {
                    $tmpPrev = Join-Path ([System.IO.Path]::GetTempPath()) "wrt-preview-$PID-$(Get-Random)"
                    try {
                        if (Copy-UpstreamShallow -DestDir $tmpPrev -TimeoutMs 12000) {
                            $managed = Get-ManagedFiles -UpstreamDir $tmpPrev
                            $preview = @()
                            foreach ($rel in $managed.Files) {
                                $upPath = Join-Path $tmpPrev ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                                $locPath = Join-Path $ScriptDir ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                                $hUp = Get-FileSha256 $upPath
                                $hLoc = Get-FileSha256 $locPath
                                if ($hLoc -eq "MISSING") { $preview += "  + $rel (new)" }
                                elseif ($hUp -ne $hLoc) { $preview += "  ~ $rel (updated)" }
                            }
                            if ($preview.Count -gt 0) {
                                Write-Host "  Changes available:"
                                foreach ($p in $preview) { Write-Host $p }
                                Write-Host ""
                            }
                        }
                    } finally {
                        Remove-Item -Path $tmpPrev -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
                return
            }
        }
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: Git is required to check for updates." -ForegroundColor Red
        exit 1
    }

    Write-Host "Checking upstream: $($script:UpstreamUrl) ($($script:UpstreamBranch))..." -ForegroundColor Cyan

    $remoteSha = Get-RemoteHeadSha -TimeoutMs 8000
    if (-not $remoteSha) {
        Write-Host "ERROR: Could not reach upstream repository: $($script:UpstreamUrl)" -ForegroundColor Red
        Write-Host "Hint: Check network connectivity or git credentials (for private repos)." -ForegroundColor Yellow
        exit 1
    }

    $now = Get-EpochSeconds
    if ($installedSha -and $installedSha -eq $remoteSha) {
        Write-CacheFile -LastCheck $now -LastAttempt $now -RemoteCommit $remoteSha -RemoteVersion $localVer -MatchedCommit $remoteSha -UpdateAvailable "false"
        Write-Host "Up to date (version: $localVer, commit: $($remoteSha.Substring(0, 7)))" -ForegroundColor Green
        return
    }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "wrt-check-$PID-$(Get-Random)"
    try {
        if (-not (Copy-UpstreamShallow -DestDir $tmp -TimeoutMs 20000)) {
            Write-Host "ERROR: Failed to fetch upstream contents from $($script:UpstreamUrl)" -ForegroundColor Red
            exit 1
        }
        $remoteVer = "unknown"
        $vf = Join-Path $tmp "VERSION"
        if (Test-Path $vf) { $remoteVer = (Get-Content $vf -Encoding UTF8 | Select-Object -First 1).Trim() }

        if (-not $installedSha -and (Test-AllManagedMatch -UpstreamDir $tmp)) {
            Write-CacheFile -LastCheck $now -LastAttempt $now -RemoteCommit $remoteSha -RemoteVersion $remoteVer -MatchedCommit $remoteSha -UpdateAvailable "false"
            Write-Host "Up to date (version: $remoteVer, commit: $($remoteSha.Substring(0, 7)) - all managed files match upstream)" -ForegroundColor Green
            return
        }

        Write-CacheFile -LastCheck $now -LastAttempt $now -RemoteCommit $remoteSha -RemoteVersion $remoteVer -MatchedCommit "" -UpdateAvailable "true"
        Show-UpdateNotice -LocalVer $localVer -RemoteVer $remoteVer -LocalSha $installedSha -RemoteSha $remoteSha

        $managed = Get-ManagedFiles -UpstreamDir $tmp
        $changes = @()
        foreach ($rel in $managed.Files) {
            $upPath = Join-Path $tmp ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $locPath = Join-Path $ScriptDir ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $hUp = Get-FileSha256 $upPath
            $hLoc = Get-FileSha256 $locPath
            if ($hLoc -eq "MISSING") { $changes += "  + $rel (new)" }
            elseif ($hUp -ne $hLoc) { $changes += "  ~ $rel (updated)" }
        }
        foreach ($mf in $managed.Merges) {
            $upPath = Join-Path $tmp ($mf -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $locPath = Join-Path $ScriptDir ($mf -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $missing = Get-MissingMergeLines -UpstreamFile $upPath -LocalFile $locPath
            if ($missing.Count -gt 0) { $changes += "  ~ $mf (+$($missing.Count) ignore rule(s))" }
        }
        if ($changes.Count -gt 0) {
            Write-Host ""
            Write-Host "  Changes available:"
            foreach ($c in $changes) { Write-Host $c }
        }
        Write-Host ""
    } finally {
        Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-DiffCommand {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: Git is required." -ForegroundColor Red
        exit 1
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "wrt-diff-$PID-$(Get-Random)"
    try {
        Write-Host "Fetching upstream from $($script:UpstreamUrl) ($($script:UpstreamBranch))..." -ForegroundColor Cyan
        if (-not (Copy-UpstreamShallow -DestDir $tmp -TimeoutMs 20000)) {
            Write-Host "ERROR: Failed to clone upstream repository." -ForegroundColor Red
            exit 1
        }
        $managed = Get-ManagedFiles -UpstreamDir $tmp
        $anyDiff = $false
        foreach ($rel in $managed.Files) {
            $upPath = Join-Path $tmp ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $locPath = Join-Path $ScriptDir ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path $locPath)) {
                Write-Host "[NEW] $rel" -ForegroundColor Green
                $anyDiff = $true
            } elseif ((Get-FileSha256 $upPath) -ne (Get-FileSha256 $locPath)) {
                $anyDiff = $true
                & git --no-pager diff --no-index -- $locPath $upPath
            }
        }
        if (-not $anyDiff) { Write-Host "No differences in managed tooling files." -ForegroundColor Green }
    } finally {
        Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-StatusCommand {
    $localVer = Get-LocalVersion
    $installedSha = Get-InstalledCommit
    $cache = Read-KvFile -FilePath $CacheFile

    Write-Host ""
    Write-Host "workspace-repo-tools Status" -ForegroundColor Cyan
    Write-Host "  Installed Version : $localVer"
    Write-Host "  Installed Commit  : $(if ($installedSha) { $installedSha } else { '<not locked yet>' })"
    Write-Host "  Upstream URL      : $($script:UpstreamUrl)"
    Write-Host "  Upstream Branch   : $($script:UpstreamBranch)"
    Write-Host "  Auto-Check        : $(if ($script:DisableAutoCheck) { 'disabled' } else { "enabled (every $($script:CheckIntervalHours)h)" })"
    if ($cache.ContainsKey("REMOTE_COMMIT") -and $cache["REMOTE_COMMIT"]) {
        $rv = if ($cache.ContainsKey("REMOTE_VERSION") -and $cache["REMOTE_VERSION"]) { $cache["REMOTE_VERSION"] } else { "unknown" }
        $rc = $cache["REMOTE_COMMIT"]
        $shortRc = if ($rc.Length -ge 7) { $rc.Substring(0, 7) } else { $rc }
        Write-Host "  Cached Remote     : $rv ($shortRc)"
    }
    if ($cache.ContainsKey("LAST_CHECK_EPOCH") -and $cache["LAST_CHECK_EPOCH"] -ne "0") {
        Write-Host "  Last Check Epoch  : $($cache['LAST_CHECK_EPOCH'])"
    }
    $avail = if ($cache.ContainsKey("UPDATE_AVAILABLE")) { $cache["UPDATE_AVAILABLE"] } else { "false" }
    if ($avail -eq "true") {
        Write-Host "  Status            : Update available" -ForegroundColor Yellow
    } else {
        Write-Host "  Status            : Up to date (cached)" -ForegroundColor Green
    }
    Write-Host ""
}

function Invoke-UpgradeCommand {
    param([bool]$DryRun, [bool]$AutoYes, [bool]$Force)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: Git is required to upgrade." -ForegroundColor Red
        exit 1
    }

    if (-not $Force -and (Test-SameUpstreamRepo)) {
        Write-Host "This directory's origin matches $($script:UpstreamUrl) (upstream template repo)." -ForegroundColor Yellow
        Write-Host "Use 'git pull' to update the upstream repo itself, or pass '--force' to run updater anyway."
        exit 1
    }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "wrt-upgrade-$PID-$(Get-Random)"
    try {
        Write-Host "Fetching upstream from $($script:UpstreamUrl) ($($script:UpstreamBranch))..." -ForegroundColor Cyan
        if (-not (Copy-UpstreamShallow -DestDir $tmp -TimeoutMs 30000)) {
            Write-Host "ERROR: Failed to fetch upstream repository from $($script:UpstreamUrl)" -ForegroundColor Red
            exit 1
        }

        $remoteSha = (& git -C $tmp rev-parse HEAD).Trim()
        $remoteVer = "unknown"
        $vf = Join-Path $tmp "VERSION"
        if (Test-Path $vf) { $remoteVer = (Get-Content $vf -Encoding UTF8 | Select-Object -First 1).Trim() }
        $localVer = Get-LocalVersion
        $installedSha = Get-InstalledCommit

        $managed = Get-ManagedFiles -UpstreamDir $tmp
        $addFiles = @()
        $updateFiles = @()

        foreach ($rel in $managed.Files) {
            $upPath = Join-Path $tmp ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $locPath = Join-Path $ScriptDir ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $hUp = Get-FileSha256 $upPath
            $hLoc = Get-FileSha256 $locPath
            if ($hLoc -eq "MISSING") { $addFiles += $rel }
            elseif ($hUp -ne $hLoc) { $updateFiles += $rel }
        }

        $mergeTargets = @()
        foreach ($mf in $managed.Merges) {
            $upPath = Join-Path $tmp ($mf -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $locPath = Join-Path $ScriptDir ($mf -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $missing = Get-MissingMergeLines -UpstreamFile $upPath -LocalFile $locPath
            if (-not (Test-Path $locPath)) { $addFiles += $mf }
            elseif ($missing.Count -gt 0) { $mergeTargets += $mf }
        }

        $newConfKeys = @()
        $upConfPath = Join-Path $tmp "workspace.conf"
        if ((Test-Path $upConfPath) -and (Test-Path $WorkspaceConf)) {
            $localConfMap = Read-KvFile -FilePath $WorkspaceConf
            foreach ($raw in (Get-Content $upConfPath -Encoding UTF8)) {
                $line = $raw.Trim()
                if (-not $line -or $line.StartsWith("#") -or -not $line.Contains("=")) { continue }
                $k = ($line -split '=', 2)[0].Trim()
                if (-not $localConfMap.ContainsKey($k)) { $newConfKeys += $line }
            }
        }

        if ($addFiles.Count -eq 0 -and $updateFiles.Count -eq 0 -and $mergeTargets.Count -eq 0 -and -not $Force) {
            $now = Get-EpochSeconds
            Write-CacheFile -LastCheck $now -LastAttempt $now -RemoteCommit $remoteSha -RemoteVersion $remoteVer -MatchedCommit $remoteSha -UpdateAvailable "false"
            if (-not $installedSha -or $installedSha -ne $remoteSha) {
                Write-LockFile -Version $remoteVer -Commit $remoteSha
            }
            Write-Host "Already up to date ($remoteVer, commit $($remoteSha.Substring(0, 7)))." -ForegroundColor Green
            return
        }

        Write-Host ""
        Write-Host "Upgrade Summary: $localVer -> $remoteVer ($($remoteSha.Substring(0, 7)))" -ForegroundColor White
        if ($addFiles.Count -gt 0) {
            Write-Host "  Files to add:" -ForegroundColor Green
            foreach ($f in $addFiles) { Write-Host "    + $f" }
        }
        if ($updateFiles.Count -gt 0) {
            Write-Host "  Files to update (existing modified files backed up):" -ForegroundColor Yellow
            foreach ($f in $updateFiles) { Write-Host "    ~ $f" }
        }
        if ($mergeTargets.Count -gt 0) {
            Write-Host "  Files to append missing rules:" -ForegroundColor Blue
            foreach ($f in $mergeTargets) { Write-Host "    ~ $f" }
        }
        Write-Host "  Preserved (untouched): workspace.conf, repos.csv, services.csv, workspace/, .env*" -ForegroundColor Cyan
        Write-Host ""

        if ($DryRun) {
            Write-Host "Dry run complete. No files were modified." -ForegroundColor Cyan
            return
        }

        if (-not $AutoYes) {
            $ans = Read-Host "Proceed with upgrade? [y/N]"
            if ($ans.Trim().ToLower() -notin @("y", "yes")) {
                Write-Host "Upgrade cancelled."
                return
            }
        }

        $ts = Get-Date -Format "yyyyMMdd-HHmmss"
        $backupDir = Join-Path $BackupsRoot $ts
        $backupCreated = $false

        $ensureBackup = {
            param([string]$Rel)
            $src = Join-Path $ScriptDir ($Rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            if (Test-Path $src -PathType Leaf) {
                if (-not $script:backupCreatedFlag) {
                    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
                    $script:backupCreatedFlag = $true
                }
                $dst = Join-Path $backupDir ($Rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                $dstParent = Split-Path -Parent $dst
                if (-not (Test-Path $dstParent)) { New-Item -ItemType Directory -Path $dstParent -Force | Out-Null }
                Copy-Item -Path $src -Destination $dst -Force
            }
        }
        $script:backupCreatedFlag = $false

        $selfUpdates = @()
        foreach ($rel in ($addFiles + $updateFiles)) {
            if ($rel -in @("workspace-repo-tools-updater.ps1", "workspace-repo-tools-updater.bat")) {
                $selfUpdates += $rel
                continue
            }
            & $ensureBackup $rel
            $upPath = Join-Path $tmp ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $locPath = Join-Path $ScriptDir ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $parent = Split-Path -Parent $locPath
            if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Copy-Item -Path $upPath -Destination $locPath -Force
        }

        foreach ($mf in $mergeTargets) {
            $upPath = Join-Path $tmp ($mf -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $locPath = Join-Path $ScriptDir ($mf -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $missing = Get-MissingMergeLines -UpstreamFile $upPath -LocalFile $locPath
            if ($missing.Count -gt 0) {
                & $ensureBackup $mf
                $appendText = "`r`n# Added by workspace-repo-tools-updater ($ts)`r`n" + ($missing -join "`r`n") + "`r`n"
                Add-Content -Path $locPath -Value $appendText -Encoding UTF8
            }
        }

        $now = Get-EpochSeconds
        Write-LockFile -Version $remoteVer -Commit $remoteSha
        Write-CacheFile -LastCheck $now -LastAttempt $now -RemoteCommit $remoteSha -RemoteVersion $remoteVer -MatchedCommit $remoteSha -UpdateAvailable "false"

        if ($script:backupCreatedFlag) {
            Write-Host "Backups saved to: .workspace-tools-backups\$ts" -ForegroundColor Cyan
        }
        if ($newConfKeys.Count -gt 0) {
            Write-Host ""
            Write-Host "Note: Upstream workspace.conf includes new optional setting(s) not in your workspace.conf:" -ForegroundColor Yellow
            foreach ($nk in $newConfKeys) { Write-Host "  $nk" }
        }

        foreach ($su in $selfUpdates) {
            & $ensureBackup $su
            $upPath = Join-Path $tmp ($su -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $locPath = Join-Path $ScriptDir ($su -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            Copy-Item -Path $upPath -Destination $locPath -Force
        }

        Write-Host "Upgrade complete ($remoteVer, commit $($remoteSha.Substring(0, 7)))." -ForegroundColor Green
    } finally {
        Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Main CLI Parsing ---
$argList = @($args)
if ($argList.Count -gt 0) {
    if ($argList[0] -eq "--banner-check") {
        $mode = if ($argList.Count -gt 1) { $argList[1] } else { "sync" }
        Invoke-BannerCheck -Mode $mode
        exit 0
    }
    if ($argList[0] -eq "--refresh-cache") {
        $null = Refresh-UpdateCache -TimeoutMs 3000
        exit 0
    }
}

$cmd = "check"
$dryRun = $false
$autoYes = $false
$force = $false
$commitCheck = $false

$i = 0
while ($i -lt $argList.Count) {
    $a = $argList[$i]
    switch ($a) {
        { $_ -in @("check", "upgrade", "update", "diff", "status", "version", "help", "-h", "--help") } {
            $cmd = $a
            $i++
        }
        "--dry-run" { $dryRun = $true; $i++ }
        { $_ -in @("-y", "--yes") } { $autoYes = $true; $i++ }
        { $_ -in @("-f", "--force") } { $force = $true; $i++ }
        "--commit" { $commitCheck = $true; $i++ }
        "--url" {
            if ($i + 1 -ge $argList.Count -or -not $argList[$i + 1]) {
                Write-Host "Option '--url' requires a repository URL." -ForegroundColor Red
                exit 1
            }
            $script:UpstreamUrl = $argList[$i + 1]
            $i += 2
        }
        "--raw-url" {
            if ($i + 1 -ge $argList.Count -or -not $argList[$i + 1]) {
                Write-Host "Option '--raw-url' requires a base URL." -ForegroundColor Red
                exit 1
            }
            $script:RawBaseUrl = $argList[$i + 1].TrimEnd('/')
            $i += 2
        }
        "--branch" {
            if ($i + 1 -ge $argList.Count -or -not $argList[$i + 1]) {
                Write-Host "Option '--branch' requires a branch name." -ForegroundColor Red
                exit 1
            }
            $script:UpstreamBranch = $argList[$i + 1]
            $i += 2
        }
        default {
            Write-Host "Unknown option or command: '$a'. Run with 'help' for usage." -ForegroundColor Red
            exit 1
        }
    }
}

switch ($cmd) {
    "check" { Invoke-CheckCommand -ForceCommit $commitCheck }
    { $_ -in @("upgrade", "update") } { Invoke-UpgradeCommand -DryRun $dryRun -AutoYes $autoYes -Force $force }
    "diff" { Invoke-DiffCommand }
    { $_ -in @("status", "version") } { Invoke-StatusCommand }
    default { Show-Usage }
}
