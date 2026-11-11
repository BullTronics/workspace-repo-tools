# =============================================================================
# workspace-repo-tools Bootstrap Installer (Windows PowerShell)
#
# One-line usage:
#   irm https://github.com/BullTronics/workspace-repo-tools/releases/latest/download/install.ps1 | iex
#   irm https://raw.githubusercontent.com/BullTronics/workspace-repo-tools/main/install.ps1 | iex
# =============================================================================

param(
    [string]$Dir = "",
    [string]$Version = "",
    [string]$RepoUrl = $(if ($env:TOOLS_REPO_URL) { $env:TOOLS_REPO_URL } else { "https://github.com/BullTronics/workspace-repo-tools" }),
    [string]$ReleaseUrl = $(if ($env:WORKSPACE_RELEASE_URL) { $env:WORKSPACE_RELEASE_URL } else { "" })
)

$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$RepoUrl = $RepoUrl.TrimEnd('/')

function Read-Kv {
    param([string]$FilePath)
    $map = @{}
    if (-not (Test-Path $FilePath)) { return $map }
    foreach ($raw in (Get-Content $FilePath -Encoding UTF8)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith("#") -or -not $line.Contains("=")) { continue }
        $parts = $line.Split("=", 2)
        $map[$parts[0].Trim()] = $parts[1].Trim().Trim('"').Trim("'")
    }
    return $map
}

function Set-Kv {
    param([string]$FilePath, [string]$Key, [string]$Value)
    $lines = Get-Content $FilePath -Encoding UTF8
    $out = @(); $found = $false
    foreach ($raw in $lines) {
        $t = $raw.Trim()
        if ($t -and -not $t.StartsWith("#") -and $t -match '^([^=]+)=') {
            if ($Matches[1].Trim() -eq $Key) {
                if (-not $found) { $out += "$Key=$Value"; $found = $true }
                continue
            }
        }
        $out += $raw
    }
    if (-not $found) { $out += "$Key=$Value" }
    Set-Content -Path $FilePath -Value ($out -join "`r`n") -Encoding UTF8 -Force
}

function Get-HttpFile {
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

function Verify-Sha {
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
        Write-Host "ERROR: Checksum verification failed for $AssetName." -ForegroundColor Red
        return $false
    }
    return $true
}

# 1. Preflight checks: Git installed, Git repo root, clean working tree
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Git is not installed. Please install Git and try again." -ForegroundColor Red
    exit 1
}

if (-not $Dir) {
    $TargetDir = (Get-Location).Path
} else {
    if (-not (Test-Path $Dir -PathType Container)) {
        Write-Host "ERROR: Target directory does not exist: $Dir" -ForegroundColor Red
        exit 1
    }
    $TargetDir = (Resolve-Path $Dir).Path
}

$prevErrPref = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    $inside = & git -C $TargetDir rev-parse --is-inside-work-tree 2>$null
    $insideRc = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevErrPref
}
if ($insideRc -ne 0 -or "$inside".Trim() -ne "true") {
    Write-Host "ERROR: Current directory is not a Git repository: $TargetDir" -ForegroundColor Red
    Write-Host "Please initialize a Git repository first ('git init') and commit initial files." -ForegroundColor Yellow
    exit 1
}

$ErrorActionPreference = "Continue"
try {
    $topLevel = (& git -C $TargetDir rev-parse --show-toplevel 2>$null | Out-String).Trim()
} finally {
    $ErrorActionPreference = $prevErrPref
}
$physTop = (Resolve-Path $topLevel).Path.TrimEnd('\', '/')
$physDir = (Resolve-Path $TargetDir).Path.TrimEnd('\', '/')
if ($physTop -ne $physDir) {
    Write-Host "ERROR: Please run install from the root of your Git repository ($physTop)." -ForegroundColor Red
    exit 1
}

$ErrorActionPreference = "Continue"
try {
    $pending = & git -C $TargetDir status --porcelain 2>$null
} finally {
    $ErrorActionPreference = $prevErrPref
}
if ($pending) {
    Write-Host "ERROR: Current Git repository has pending uncommitted or untracked changes:" -ForegroundColor Red
    foreach ($p in $pending) { Write-Host "  $p" -ForegroundColor Yellow }
    Write-Host "Please stage and commit (or stash) pending changes before installing workspace-repo-tools." -ForegroundColor Red
    exit 1
}

# 2. Fetch release metadata and assets
$releasesBase = if ($ReleaseUrl) { $ReleaseUrl.TrimEnd('/') } else { "$RepoUrl/releases" }
$targetTag = ""
if ($Version) {
    $targetTag = if ($Version.StartsWith("v")) { $Version } else { "v$Version" }
}

$stageDir = Join-Path ([System.IO.Path]::GetTempPath()) "wrt-install-$PID-$(Get-Random)"
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

try {
    $metaUrl = if ($targetTag) { "$releasesBase/download/$targetTag/release-meta.env" } else { "$releasesBase/latest/download/release-meta.env" }
    Write-Host "Fetching release metadata from $metaUrl..." -ForegroundColor Cyan
    $metaFile = Join-Path $stageDir "release-meta.env"
    if (-not (Get-HttpFile -Url $metaUrl -OutFile $metaFile)) {
        Write-Host "ERROR: Failed to fetch release metadata from $metaUrl" -ForegroundColor Red
        exit 1
    }

    $meta = Read-Kv -FilePath $metaFile
    $relVer = if ($meta.ContainsKey("VERSION")) { $meta["VERSION"] } else { "" }
    $relTag = if ($meta.ContainsKey("TAG") -and $meta["TAG"]) { $meta["TAG"] } else { "v$relVer" }
    $relSchema = if ($meta.ContainsKey("CONFIG_SCHEMA_VERSION") -and $meta["CONFIG_SCHEMA_VERSION"]) { $meta["CONFIG_SCHEMA_VERSION"] } else { "1" }

    if (-not $relVer) {
        Write-Host "ERROR: Invalid release-meta.env (missing VERSION)." -ForegroundColor Red
        exit 1
    }

    $dlBase = "$releasesBase/download/$relTag"
    Write-Host "Downloading workspace-repo-tools $relTag into $TargetDir..." -ForegroundColor Cyan
    $sumsFile = Join-Path $stageDir "SHA256SUMS.txt"
    $null = Get-HttpFile -Url "$dlBase/SHA256SUMS.txt" -OutFile $sumsFile

    $bundleSh = "library-bundle-$relVer.sh"
    $bundlePs1 = "library-bundle-$relVer.ps1"
    $bundleBat = "library-bundle-$relVer.bat"

    $assets = @("workspace.sh", "workspace.ps1", "workspace.bat", $bundleSh, $bundlePs1, $bundleBat, "workspace.conf.default", "repos.csv.default", "services.csv.default", "gitignore.default")
    foreach ($a in $assets) {
        $dst = Join-Path $stageDir $a
        if (-not (Get-HttpFile -Url "$dlBase/$a" -OutFile $dst)) {
            Write-Host "ERROR: Failed to download release asset: $dlBase/$a" -ForegroundColor Red
            exit 1
        }
        if (-not (Verify-Sha -SumsFile $sumsFile -LocalFile $dst -AssetName $a)) { exit 1 }
    }

    # 3. Install unified scripts + configs + gitignored .workspace-tools bundle
    foreach ($wf in @("workspace.sh", "workspace.ps1", "workspace.bat")) {
        Copy-Item -Path (Join-Path $stageDir $wf) -Destination (Join-Path $TargetDir $wf) -Force
    }

    $stateDir = Join-Path $TargetDir ".workspace-tools"
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    Get-ChildItem -Path $stateDir -Filter "library-bundle-*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    foreach ($bf in @($bundleSh, $bundlePs1, $bundleBat)) {
        Copy-Item -Path (Join-Path $stageDir $bf) -Destination (Join-Path $stateDir $bf) -Force
    }

    $nowEpoch = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
@"
LAST_CHECK_EPOCH=$nowEpoch
LAST_ATTEMPT_EPOCH=$nowEpoch
REMOTE_VERSION=$relVer
UPDATE_AVAILABLE=false
"@ | Set-Content -Path (Join-Path $stateDir "update-cache") -Encoding UTF8 -Force

    $confDst = Join-Path $TargetDir "workspace.conf"
    if (-not (Test-Path $confDst)) {
        Copy-Item -Path (Join-Path $stageDir "workspace.conf.default") -Destination $confDst -Force
        Write-Host "  + Created workspace.conf" -ForegroundColor Green
    } else {
        Write-Host "  = Preserved existing workspace.conf (updated TOOLS_VERSION=$relVer)" -ForegroundColor Gray
    }
    Set-Kv -FilePath $confDst -Key "TOOLS_VERSION" -Value $relVer
    Set-Kv -FilePath $confDst -Key "CONFIG_SCHEMA_VERSION" -Value $relSchema
    Set-Kv -FilePath $confDst -Key "TOOLS_REPO_URL" -Value $RepoUrl

    foreach ($cfg in @("repos.csv", "services.csv")) {
        $dst = Join-Path $TargetDir $cfg
        if (-not (Test-Path $dst)) {
            Copy-Item -Path (Join-Path $stageDir "$cfg.default") -Destination $dst -Force
            Write-Host "  + Created $cfg" -ForegroundColor Green
        } else {
            Write-Host "  = Preserved existing $cfg" -ForegroundColor Gray
        }
    }

    $giSrc = Join-Path $stageDir "gitignore.default"
    $giDst = Join-Path $TargetDir ".gitignore"
    if (-not (Test-Path $giDst)) {
        Copy-Item -Path $giSrc -Destination $giDst -Force
        Write-Host "  + Created .gitignore" -ForegroundColor Green
    } else {
        $existing = @{}
        foreach ($l in (Get-Content $giDst -Encoding UTF8)) { $existing[$l.TrimEnd("`r")] = $true }
        $missing = @()
        foreach ($raw in (Get-Content $giSrc -Encoding UTF8)) {
            $line = $raw.TrimEnd("`r")
            $trimmed = $line.Trim()
            if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
            if (-not $existing.ContainsKey($line)) { $missing += $line }
        }
        if ($missing.Count -gt 0) {
            $append = "`r`n# Added by workspace-repo-tools installer`r`n" + ($missing -join "`r`n") + "`r`n"
            Add-Content -Path $giDst -Value $append -Encoding UTF8
            Write-Host "  ~ Updated .gitignore (+$($missing.Count) rule(s))" -ForegroundColor Blue
        } else {
            Write-Host "  = .gitignore already up to date" -ForegroundColor Gray
        }
    }

    Write-Host ""
    Write-Host "workspace-repo-tools $relTag installed successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Installed files:"
    Write-Host "  Scripts (committed): workspace.sh, workspace.ps1, workspace.bat"
    Write-Host "  Configs (committed): workspace.conf, repos.csv, services.csv, .gitignore"
    Write-Host "  Bundle (gitignored): .workspace-tools\$bundlePs1 (and .sh/.bat)"
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "  1. Update workspace.conf, repos.csv, and services.csv for your project"
    Write-Host "  2. Verify the setup (e.g. run '.\workspace.bat status' and '.\workspace.bat clone')"
    Write-Host "  3. Commit the integration changes with:"
    Write-Host "     git add workspace.sh workspace.ps1 workspace.bat workspace.conf repos.csv services.csv .gitignore"
    Write-Host "     git commit -m `"added integration of $RepoUrl`""
    Write-Host ""
} finally {
    Remove-Item -Path $stageDir -Recurse -Force -ErrorAction SilentlyContinue
}
