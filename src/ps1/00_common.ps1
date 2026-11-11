# =============================================================================
# library-bundle (Windows PowerShell) - Module: 00_common.ps1
# =============================================================================

$ErrorActionPreference = "Continue"

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$script:BundleVersion = "@VERSION@"
$script:BundleSchemaVersion = "@CONFIG_SCHEMA_VERSION@"

if ($env:WORKSPACE_ROOT_DIR) {
    $ScriptDir = (Resolve-Path $env:WORKSPACE_ROOT_DIR).Path
} elseif ((Split-Path -Leaf (Split-Path -Parent $MyInvocation.MyCommand.Path)) -eq ".workspace-tools") {
    $ScriptDir = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..")).Path
} else {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$ToolsStateDir = Join-Path $ScriptDir ".workspace-tools"
if (-not (Test-Path $ToolsStateDir)) {
    New-Item -ItemType Directory -Path $ToolsStateDir -Force | Out-Null
}

function ConvertTo-Slug {
    param([string]$Text)
    return ($Text.ToLower() -replace '[^a-z0-9._-]', '-')
}

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

function Set-KvValue {
    param([string]$FilePath, [string]$Key, [string]$Value)
    if (-not (Test-Path $FilePath)) {
        Set-Content -Path $FilePath -Value "$Key=$Value" -Encoding UTF8 -Force
        return
    }
    $lines = Get-Content $FilePath -Encoding UTF8
    $out = @()
    $found = $false
    foreach ($raw in $lines) {
        $trimmed = $raw.Trim()
        if ($trimmed -and -not $trimmed.StartsWith("#") -and $trimmed -match '^([^=]+)=') {
            if ($Matches[1].Trim() -eq $Key) {
                if (-not $found) {
                    $out += "$Key=$Value"
                    $found = $true
                }
                continue
            }
        }
        $out += $raw
    }
    if (-not $found) { $out += "$Key=$Value" }
    Set-Content -Path $FilePath -Value ($out -join "`r`n") -Encoding UTF8 -Force
}

function Get-HttpFile {
    param([string]$Url, [string]$OutFile, [int]$TimeoutSec = 10)
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
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        return (Test-Path $OutFile -PathType Leaf)
    } catch {
        return $false
    }
}

function Verify-Sha256Manifest {
    param([string]$SumsFile, [string]$LocalFile, [string]$AssetName)
    if (-not (Test-Path $SumsFile)) { return $true }
    $expected = ""
    foreach ($line in (Get-Content $SumsFile -Encoding UTF8)) {
        if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?\.?/?(.+?)\s*$') {
            if ($Matches[2] -eq $AssetName) {
                $expected = $Matches[1].ToLower()
                break
            }
        }
    }
    if (-not $expected) { return $true }
    $actual = (Get-FileHash -Path $LocalFile -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) {
        Write-Host "Checksum mismatch for $AssetName!" -ForegroundColor Red
        Write-Host "  Expected: $expected" -ForegroundColor Red
        Write-Host "  Actual:   $actual" -ForegroundColor Red
        return $false
    }
    return $true
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

function Test-GitCleanRepo {
    param([string]$Dir)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "Git was not found. Please install Git and make sure it is in PATH." -ForegroundColor Red
        return $false
    }

    $inside = & git -C $Dir rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0 -or "$inside".Trim() -ne "true") {
        Write-Host "Current directory is not a Git repository: $Dir" -ForegroundColor Red
        Write-Host "Please run 'git init' (or run inside your workspace Git repository root)." -ForegroundColor Yellow
        return $false
    }

    $top = (& git -C $Dir rev-parse --show-toplevel 2>$null).Trim()
    $physTop = (Resolve-Path $top).Path.TrimEnd('\', '/')
    $physDir = (Resolve-Path $Dir).Path.TrimEnd('\', '/')
    if ($physTop -ne $physDir) {
        Write-Host "Please run from the root of your Git repository:" -ForegroundColor Red
        Write-Host "  Repo root:   $physTop" -ForegroundColor Red
        Write-Host "  Current dir: $physDir" -ForegroundColor Red
        return $false
    }

    $pending = & git -C $Dir status --porcelain 2>$null
    if ($pending) {
        Write-Host "Current Git repository has pending uncommitted or untracked changes:" -ForegroundColor Red
        foreach ($line in $pending) { Write-Host "  $line" -ForegroundColor Yellow }
        Write-Host "Please stage and commit (or stash) pending changes before proceeding." -ForegroundColor Red
        return $false
    }

    return $true
}

