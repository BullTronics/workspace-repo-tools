# =============================================================================
# workspace.ps1 - Thin Workspace Wrapper (Windows PowerShell)
# Reads TOOLS_VERSION from workspace.conf, ensures the matching library-bundle
# exists in .workspace-tools\, downloads it from GitHub Releases if missing,
# and delegates execution.
# =============================================================================

$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkspaceConf = Join-Path $ScriptDir "workspace.conf"

$DefaultToolsVersion = "1.0.1"
$DefaultRepoUrl = "https://github.com/BullTronics/workspace-repo-tools"

function Read-WrapperConfValue {
    param([string]$TargetKey)
    if (-not (Test-Path $WorkspaceConf)) { return "" }
    foreach ($raw in (Get-Content $WorkspaceConf -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith("#") -or -not $line.Contains("=")) { continue }
        $parts = $line.Split("=", 2)
        if ($parts[0].Trim() -eq $TargetKey) {
            return $parts[1].Trim().Trim('"').Trim("'")
        }
    }
    return ""
}

$toolsVersion = Read-WrapperConfValue "TOOLS_VERSION"
if (-not $toolsVersion) { $toolsVersion = $DefaultToolsVersion }

$repoUrl = Read-WrapperConfValue "TOOLS_REPO_URL"
if (-not $repoUrl) { $repoUrl = $DefaultRepoUrl }
$repoUrl = $repoUrl.TrimEnd('/')

$relOverride = Read-WrapperConfValue "TOOLS_RELEASE_BASE_URL"
if ($env:WORKSPACE_RELEASE_URL) {
    $releasesBase = $env:WORKSPACE_RELEASE_URL.TrimEnd('/')
} elseif ($relOverride) {
    $releasesBase = $relOverride.TrimEnd('/')
} else {
    $releasesBase = "$repoUrl/releases"
}

$stateDir = Join-Path $ScriptDir ".workspace-tools"
$bundlePs1Name = "library-bundle-$toolsVersion.ps1"
$bundleBatName = "library-bundle-$toolsVersion.bat"
$bundlePs1Path = Join-Path $stateDir $bundlePs1Name
$bundleBatPath = Join-Path $stateDir $bundleBatName

function Get-WrapperHttpFile {
    param([string]$Url, [string]$OutFile)
    try {
        if ($Url -match '^file://') {
            $localSrc = ([System.Uri]$Url).LocalPath
            if (Test-Path $localSrc -PathType Leaf) {
                Copy-Item -Path $localSrc -Destination $OutFile -Force
                return $true
            }
            return $false
        }
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch {}
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
        return (Test-Path $OutFile -PathType Leaf)
    } catch {
        return $false
    }
}

function Verify-WrapperSha {
    param([string]$SumsFile, [string]$LocalFile, [string]$AssetName)
    if (-not (Test-Path $SumsFile)) { return $true }
    $expected = ""
    foreach ($line in (Get-Content $SumsFile -Encoding UTF8)) {
        if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?\.?/?(.+?)\s*$') {
            if ($Matches[2] -eq $AssetName) { $expected = $Matches[1].ToLower(); break }
        }
    }
    if (-not $expected) { return $true }
    $actual = (Get-FileHash -Path $LocalFile -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) {
        Write-Host "ERROR: SHA-256 verification failed for $AssetName." -ForegroundColor Red
        return $false
    }
    return $true
}

if (-not (Test-Path $bundlePs1Path -PathType Leaf)) {
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    $dlDir = "$releasesBase/download/v$toolsVersion"
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "wrt-dl-$PID-$(Get-Random)"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    try {
        Write-Host "Downloading workspace-repo-tools bundle (v$toolsVersion)..." -ForegroundColor Cyan
        $tmpPs1 = Join-Path $tmpDir $bundlePs1Name
        if (-not (Get-WrapperHttpFile -Url "$dlDir/$bundlePs1Name" -OutFile $tmpPs1)) {
            Write-Host "ERROR: Failed to download $dlDir/$bundlePs1Name" -ForegroundColor Red
            exit 1
        }
        $sumsFile = Join-Path $tmpDir "SHA256SUMS.txt"
        $null = Get-WrapperHttpFile -Url "$dlDir/SHA256SUMS.txt" -OutFile $sumsFile
        if (-not (Verify-WrapperSha -SumsFile $sumsFile -LocalFile $tmpPs1 -AssetName $bundlePs1Name)) { exit 1 }

        $tmpBat = Join-Path $tmpDir $bundleBatName
        $hasBat = Get-WrapperHttpFile -Url "$dlDir/$bundleBatName" -OutFile $tmpBat
        if ($hasBat) {
            if (-not (Verify-WrapperSha -SumsFile $sumsFile -LocalFile $tmpBat -AssetName $bundleBatName)) { exit 1 }
        }

        Get-ChildItem -Path $stateDir -Filter "library-bundle-*.ps1" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem -Path $stateDir -Filter "library-bundle-*.bat" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

        Copy-Item -Path $tmpPs1 -Destination $bundlePs1Path -Force
        if ($hasBat) { Copy-Item -Path $tmpBat -Destination $bundleBatPath -Force }
    } finally {
        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$env:WORKSPACE_ROOT_DIR = $ScriptDir
& $bundlePs1Path @args
exit $LASTEXITCODE

