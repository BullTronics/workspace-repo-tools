# =============================================================================
# library-bundle (Windows PowerShell) - Module: 40_updater.ps1
# =============================================================================

$script:UpdateCacheFile = Join-Path $ToolsStateDir "update-cache"

function Get-EpochSeconds {
    return [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
}

function Write-UpdateCache {
    param([int64]$LastCheck, [int64]$LastAttempt, [string]$RemoteVer, [string]$UpdateAvail)
    if (-not (Test-Path $ToolsStateDir)) { New-Item -ItemType Directory -Path $ToolsStateDir -Force | Out-Null }
    $content = @"
LAST_CHECK_EPOCH=$LastCheck
LAST_ATTEMPT_EPOCH=$LastAttempt
REMOTE_VERSION=$RemoteVer
UPDATE_AVAILABLE=$UpdateAvail
"@
    $tmp = "$($script:UpdateCacheFile).tmp.$PID"
    Set-Content -Path $tmp -Value $content -Encoding UTF8 -Force
    Move-Item -Path $tmp -Destination $script:UpdateCacheFile -Force
}

function Fetch-ReleaseMeta {
    param([string]$TagOverride = "", [string]$DestFile, [int]$TimeoutSec = 3)
    $metaUrl = if ($TagOverride) {
        "$($script:ReleasesBaseUrl)/download/$TagOverride/release-meta.env"
    } else {
        "$($script:ReleasesBaseUrl)/latest/download/release-meta.env"
    }
    return (Get-HttpFile -Url $metaUrl -OutFile $DestFile -TimeoutSec $TimeoutSec)
}

function Refresh-UpdateCache {
    param([int]$TimeoutSec = 2)
    $now = Get-EpochSeconds
    $prev = Read-KvFile -FilePath $script:UpdateCacheFile
    $prevCheck = if ($prev.ContainsKey("LAST_CHECK_EPOCH") -and $prev["LAST_CHECK_EPOCH"] -match '^\d+$') { [int64]$prev["LAST_CHECK_EPOCH"] } else { 0 }
    $prevVer = if ($prev.ContainsKey("REMOTE_VERSION")) { $prev["REMOTE_VERSION"] } else { "" }
    $prevAvail = if ($prev.ContainsKey("UPDATE_AVAILABLE")) { $prev["UPDATE_AVAILABLE"] } else { "false" }

    $tmpMeta = Join-Path ([System.IO.Path]::GetTempPath()) "wrt-meta-$PID-$(Get-Random).env"
    try {
        if (-not (Fetch-ReleaseMeta -DestFile $tmpMeta -TimeoutSec $TimeoutSec)) {
            Write-UpdateCache -LastCheck $prevCheck -LastAttempt $now -RemoteVer $prevVer -UpdateAvail $prevAvail
            return $false
        }
        $meta = Read-KvFile -FilePath $tmpMeta
        $remoteVer = if ($meta.ContainsKey("VERSION")) { $meta["VERSION"] } else { "" }
        if (-not (Test-ValidSemver $remoteVer)) {
            Write-UpdateCache -LastCheck $prevCheck -LastAttempt $now -RemoteVer $prevVer -UpdateAvail $prevAvail
            return $false
        }
        $avail = if (Test-VersionNewer -RemoteVer $remoteVer -LocalVer $script:ToolsVersion) { "true" } else { "false" }
        Write-UpdateCache -LastCheck $now -LastAttempt $now -RemoteVer $remoteVer -UpdateAvail $avail
        return $true
    } finally {
        Remove-Item -Path $tmpMeta -Force -ErrorAction SilentlyContinue
    }
}

function Show-UpdateBannerNotice {
    param([string]$RemoteVer)
    Write-Host ""
    Write-Host "  Update available for workspace-repo-tools ($($script:ToolsVersion) -> $RemoteVer)" -ForegroundColor Yellow
    Write-Host "  Run '.\workspace.bat update' to upgrade." -ForegroundColor Cyan
    Write-Host ""
}

function Invoke-UpdateBannerCheck {
    param([string]$Mode = "--bg")
    if ($script:DisableAutoCheck -or $env:WORKSPACE_NO_UPDATE_CHECK -eq "1" -or $env:WORKSPACE_UPDATE_CHECKED -eq "1") { return }

    $now = Get-EpochSeconds
    $intervalSecs = [int64]$script:CheckIntervalHours * 3600
    $cache = Read-KvFile -FilePath $script:UpdateCacheFile
    $lastCheck = if ($cache.ContainsKey("LAST_CHECK_EPOCH") -and $cache["LAST_CHECK_EPOCH"] -match '^\d+$') { [int64]$cache["LAST_CHECK_EPOCH"] } else { 0 }
    $lastAttempt = if ($cache.ContainsKey("LAST_ATTEMPT_EPOCH") -and $cache["LAST_ATTEMPT_EPOCH"] -match '^\d+$') { [int64]$cache["LAST_ATTEMPT_EPOCH"] } else { 0 }

    $needsRefresh = $false
    if ($lastCheck -eq 0 -or ($now - $lastCheck) -ge $intervalSecs) {
        if ($lastAttempt -eq 0 -or ($now - $lastAttempt) -ge 900) { $needsRefresh = $true }
    }

    if ($needsRefresh) {
        if ($Mode -eq "--bg") {
            $psExe = Get-PowerShellExe
            Start-Process -FilePath $psExe -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$($script:BundleSelfPath)`"", "__refresh-cache" -WindowStyle Hidden | Out-Null
        } else {
            $null = Refresh-UpdateCache -TimeoutSec 2
            $cache = Read-KvFile -FilePath $script:UpdateCacheFile
        }
    }

    $remoteVer = if ($cache.ContainsKey("REMOTE_VERSION")) { $cache["REMOTE_VERSION"] } else { "" }
    $avail = if ($cache.ContainsKey("UPDATE_AVAILABLE")) { $cache["UPDATE_AVAILABLE"] } else { "false" }
    if ($avail -eq "true" -and $remoteVer -and (Test-VersionNewer -RemoteVer $remoteVer -LocalVer $script:ToolsVersion)) {
        Show-UpdateBannerNotice -RemoteVer $remoteVer
    }
}

function Invoke-CheckUpdateCommand {
    Write-Host "Checking latest release at: $($script:ReleasesBaseUrl)/latest/download/release-meta.env..." -ForegroundColor Cyan
    $tmpMeta = Join-Path ([System.IO.Path]::GetTempPath()) "wrt-meta-$PID-$(Get-Random).env"
    try {
        if (-not (Fetch-ReleaseMeta -DestFile $tmpMeta -TimeoutSec 8)) {
            Write-Host "ERROR: Could not fetch release metadata from $($script:ReleasesBaseUrl)" -ForegroundColor Red
            return $false
        }
        $meta = Read-KvFile -FilePath $tmpMeta
        $remoteVer = if ($meta.ContainsKey("VERSION")) { $meta["VERSION"] } else { "" }
        $remoteSchema = if ($meta.ContainsKey("CONFIG_SCHEMA_VERSION")) { $meta["CONFIG_SCHEMA_VERSION"] } else { "" }
        $notes = if ($meta.ContainsKey("SCHEMA_NOTES")) { $meta["SCHEMA_NOTES"] } else { "" }

        if (-not (Test-ValidSemver $remoteVer)) {
            Write-Host "ERROR: Invalid release metadata received." -ForegroundColor Red
            return $false
        }

        $now = Get-EpochSeconds
        if (Test-VersionNewer -RemoteVer $remoteVer -LocalVer $script:ToolsVersion) {
            Write-UpdateCache -LastCheck $now -LastAttempt $now -RemoteVer $remoteVer -UpdateAvail "true"
            Show-UpdateBannerNotice -RemoteVer $remoteVer
            if ($remoteSchema -and $remoteSchema -ne $script:ConfigSchemaVersion) {
                Write-Host "  Config schema update included: $($script:ConfigSchemaVersion) -> $remoteSchema" -ForegroundColor Yellow
            }
            if ($notes) {
                Write-Host "  Notes: $notes"
                Write-Host ""
            }
        } else {
            Write-UpdateCache -LastCheck $now -LastAttempt $now -RemoteVer $remoteVer -UpdateAvail "false"
            Write-Host "Up to date (version: $($script:ToolsVersion))" -ForegroundColor Green
        }
        return $true
    } finally {
        Remove-Item -Path $tmpMeta -Force -ErrorAction SilentlyContinue
    }
}

function Merge-GitignoreFromFile {
    param([string]$SrcGitignore)
    if (-not (Test-Path $SrcGitignore)) { return }
    $dstGitignore = Join-Path $ScriptDir ".gitignore"
    if (-not (Test-Path $dstGitignore)) {
        Copy-Item -Path $SrcGitignore -Destination $dstGitignore -Force
        Write-Host "  + Created .gitignore" -ForegroundColor Green
        return
    }
    $existing = @{}
    foreach ($l in (Get-Content $dstGitignore -Encoding UTF8)) { $existing[$l.TrimEnd("`r")] = $true }
    $missing = @()
    foreach ($raw in (Get-Content $SrcGitignore -Encoding UTF8)) {
        $line = $raw.TrimEnd("`r")
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        if (-not $existing.ContainsKey($line)) { $missing += $line }
    }
    if ($missing.Count -gt 0) {
        $append = "`r`n# Added by workspace-repo-tools update`r`n" + ($missing -join "`r`n") + "`r`n"
        Add-Content -Path $dstGitignore -Value $append -Encoding UTF8
        Write-Host "  ~ Updated .gitignore (+$($missing.Count) rule(s))" -ForegroundColor Blue
    } else {
        Write-Host "  = .gitignore already up to date" -ForegroundColor Gray
    }
}

function Show-ConfigSchemaWarnings {
    param([string]$StageDir, [string]$RemoteSchema, [string]$SchemaNotes)
    $warnings = @()
    if ($RemoteSchema -and $RemoteSchema -ne $script:ConfigSchemaVersion) {
        $warnings += "CONFIG_SCHEMA_VERSION changed ($($script:ConfigSchemaVersion) -> $RemoteSchema)."
    }
    if ($SchemaNotes) { $warnings += "Release schema notes: $SchemaNotes" }

    $defConf = Join-Path $StageDir "workspace.conf.default"
    if ((Test-Path $defConf) -and (Test-Path $WorkspaceConf)) {
        $curMap = Read-KvFile -FilePath $WorkspaceConf
        foreach ($raw in (Get-Content $defConf -Encoding UTF8)) {
            $t = $raw.Trim()
            if (-not $t -or $t.StartsWith("#") -or -not $t.Contains("=")) { continue }
            $k = ($t -split '=', 2)[0].Trim()
            if (-not $curMap.ContainsKey($k)) { $warnings += "workspace.conf is missing new key: $t" }
        }
    }

    $defSvc = Join-Path $StageDir "services.csv.default"
    if ((Test-Path $defSvc) -and (Test-Path $ServicesCsvPath)) {
        $expH = ((Get-Content $defSvc -Encoding UTF8 | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith("#") } | Select-Object -First 1) -replace '\s+', '')
        $curH = ((Get-Content $ServicesCsvPath -Encoding UTF8 | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith("#") } | Select-Object -First 1) -replace '\s+', '')
        if ($expH -and $expH -ne $curH) { $warnings += "services.csv header differs from latest schema. Expected: $expH" }
    }

    $defRep = Join-Path $StageDir "repos.csv.default"
    if ((Test-Path $defRep) -and (Test-Path $ReposCsvPath)) {
        $expH = ((Get-Content $defRep -Encoding UTF8 | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith("#") } | Select-Object -First 1) -replace '\s+', '')
        $curH = ((Get-Content $ReposCsvPath -Encoding UTF8 | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith("#") } | Select-Object -First 1) -replace '\s+', '')
        if ($expH -and $expH -ne $curH -and $curH -ne "url,path") { $warnings += "repos.csv header differs from latest schema. Expected: $expH" }
    }

    if ($warnings.Count -gt 0) {
        Write-Host ""
        Write-Host "  Config structure updates detected -- please review your config files:" -ForegroundColor Yellow
        foreach ($w in $warnings) { Write-Host "   - $w" }
    }
}

function Invoke-UpdateCommand {
    param([string[]]$UpdateArgs)
    $dryRun = $false; $autoYes = $false; $force = $false; $targetTag = ""
    $i = 0
    while ($i -lt $UpdateArgs.Count) {
        $a = $UpdateArgs[$i]
        switch ($a) {
            "--dry-run" { $dryRun = $true; $i++ }
            { $_ -in @("-y", "--yes") } { $autoYes = $true; $i++ }
            { $_ -in @("-f", "--force") } { $force = $true; $i++ }
            "--version" {
                if ($i + 1 -ge $UpdateArgs.Count -or -not $UpdateArgs[$i + 1]) {
                    Write-Host "Option '--version' requires a version or tag." -ForegroundColor Red
                    return $false
                }
                $targetTag = $UpdateArgs[$i + 1]
                if (-not $targetTag.StartsWith("v")) { $targetTag = "v$targetTag" }
                $i += 2
            }
            default {
                Write-Host "Unknown update option: $a" -ForegroundColor Red
                return $false
            }
        }
    }

    if (-not (Test-GitCleanRepo -Dir $ScriptDir)) { return $false }

    $stageDir = Join-Path ([System.IO.Path]::GetTempPath()) "wrt-update-$PID-$(Get-Random)"
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
    try {
        Write-Host "Checking release metadata..." -ForegroundColor Cyan
        $metaFile = Join-Path $stageDir "release-meta.env"
        if (-not (Fetch-ReleaseMeta -TagOverride $targetTag -DestFile $metaFile -TimeoutSec 10)) {
            Write-Host "ERROR: Failed to fetch release metadata from $($script:ReleasesBaseUrl)" -ForegroundColor Red
            return $false
        }
        $meta = Read-KvFile -FilePath $metaFile
        $remoteVer = if ($meta.ContainsKey("VERSION")) { $meta["VERSION"] } else { "" }
        $remoteTag = if ($meta.ContainsKey("TAG") -and $meta["TAG"]) { $meta["TAG"] } else { "v$remoteVer" }
        $remoteSchema = if ($meta.ContainsKey("CONFIG_SCHEMA_VERSION")) { $meta["CONFIG_SCHEMA_VERSION"] } else { "" }
        $schemaNotes = if ($meta.ContainsKey("SCHEMA_NOTES")) { $meta["SCHEMA_NOTES"] } else { "" }

        if (-not (Test-ValidSemver $remoteVer)) {
            Write-Host "ERROR: Invalid VERSION in release-meta.env: '$remoteVer'" -ForegroundColor Red
            return $false
        }

        if (-not $force -and -not $targetTag -and -not (Test-VersionNewer -RemoteVer $remoteVer -LocalVer $script:ToolsVersion)) {
            $now = Get-EpochSeconds
            Write-UpdateCache -LastCheck $now -LastAttempt $now -RemoteVer $remoteVer -UpdateAvail "false"
            Write-Host "Already up to date (version: $($script:ToolsVersion))." -ForegroundColor Green
            return $true
        }

        $dlBase = "$($script:ReleasesBaseUrl)/download/$remoteTag"
        Write-Host "Downloading release $remoteTag ($dlBase)..." -ForegroundColor Cyan
        $sumsFile = Join-Path $stageDir "SHA256SUMS.txt"
        $null = Get-HttpFile -Url "$dlBase/SHA256SUMS.txt" -OutFile $sumsFile -TimeoutSec 10

        $bundleSh = "library-bundle-$remoteVer.sh"
        $bundlePs1 = "library-bundle-$remoteVer.ps1"
        $bundleBat = "library-bundle-$remoteVer.bat"

        foreach ($f in @("workspace.sh", "workspace.ps1", "workspace.bat", $bundleSh, $bundlePs1, $bundleBat)) {
            $dst = Join-Path $stageDir $f
            if (-not (Get-HttpFile -Url "$dlBase/$f" -OutFile $dst -TimeoutSec 20)) {
                Write-Host "ERROR: Failed to download release asset: $dlBase/$f" -ForegroundColor Red
                return $false
            }
            if (-not (Verify-Sha256Manifest -SumsFile $sumsFile -LocalFile $dst -AssetName $f)) { return $false }
        }

        foreach ($f in @("gitignore.default", "workspace.conf.default", "repos.csv.default", "services.csv.default")) {
            $dst = Join-Path $stageDir $f
            if (Get-HttpFile -Url "$dlBase/$f" -OutFile $dst -TimeoutSec 10) {
                if (-not (Verify-Sha256Manifest -SumsFile $sumsFile -LocalFile $dst -AssetName $f)) { return $false }
            }
        }

        $nextSchema = if ($remoteSchema) { $remoteSchema } else { $script:ConfigSchemaVersion }
        Write-Host ""
        Write-Host "Update Plan: $($script:ToolsVersion) -> $remoteVer" -ForegroundColor White
        Write-Host "  ~ workspace.sh, workspace.ps1, workspace.bat"
        Write-Host "  ~ .workspace-tools\$bundleSh, $bundlePs1, $bundleBat"
        Write-Host "  ~ workspace.conf (TOOLS_VERSION=$remoteVer, CONFIG_SCHEMA_VERSION=$nextSchema)"
        Write-Host "  ~ .gitignore (merged from latest release)"
        Write-Host "  = Preserved user files: repos.csv, services.csv, custom workspace.conf settings, $($script:WorkspaceRelDir)\"
        Write-Host ""

        if ($dryRun) {
            Show-ConfigSchemaWarnings -StageDir $stageDir -RemoteSchema $remoteSchema -SchemaNotes $schemaNotes
            Write-Host "Dry run complete. No files were modified." -ForegroundColor Cyan
            return $true
        }

        if (-not $autoYes) {
            $ans = Read-Host "Proceed with update? [y/N]"
            if ($ans.Trim().ToLower() -notin @("y", "yes")) {
                Write-Host "Update cancelled."
                return $true
            }
        }

        if (-not (Test-Path $ToolsStateDir)) { New-Item -ItemType Directory -Path $ToolsStateDir -Force | Out-Null }
        Get-ChildItem -Path $ToolsStateDir -Filter "library-bundle-*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

        foreach ($bf in @($bundleSh, $bundlePs1, $bundleBat)) {
            Copy-Item -Path (Join-Path $stageDir $bf) -Destination (Join-Path $ToolsStateDir $bf) -Force
        }

        Merge-GitignoreFromFile -SrcGitignore (Join-Path $stageDir "gitignore.default")
        Show-ConfigSchemaWarnings -StageDir $stageDir -RemoteSchema $remoteSchema -SchemaNotes $schemaNotes

        Set-KvValue -FilePath $WorkspaceConf -Key "TOOLS_VERSION" -Value $remoteVer
        if ($remoteSchema) { Set-KvValue -FilePath $WorkspaceConf -Key "CONFIG_SCHEMA_VERSION" -Value $remoteSchema }

        foreach ($wf in @("workspace.sh", "workspace.ps1", "workspace.bat")) {
            Copy-Item -Path (Join-Path $stageDir $wf) -Destination (Join-Path $ScriptDir $wf) -Force
        }

        $now = Get-EpochSeconds
        Write-UpdateCache -LastCheck $now -LastAttempt $now -RemoteVer $remoteVer -UpdateAvail "false"

        Write-Host ""
        Write-Host "Updated workspace-repo-tools integration to version $remoteVer!" -ForegroundColor Green
        Write-Host ""
        Write-Host "Next steps:"
        Write-Host "  1. Verify your workspace (e.g., run '.\workspace.bat status' and '.\workspace.bat repo-status')"
        Write-Host "  2. Update workspace.conf / repos.csv / services.csv if any schema notices appeared above"
        Write-Host "  3. Commit the integration update with:"
        Write-Host "     git add workspace.sh workspace.ps1 workspace.bat workspace.conf .gitignore"
        Write-Host "     git commit -m `"update integration of $($script:ToolsRepoUrl) to version : $remoteVer`""
        Write-Host ""
        return $true
    } finally {
        Remove-Item -Path $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

