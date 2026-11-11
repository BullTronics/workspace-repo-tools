# =============================================================================
# workspace-repo-tools Bootstrap Installer (Windows PowerShell)
#
# One-line usage:
#   irm https://raw.githubusercontent.com/BullTronics/workspace-repo-tools/main/install.ps1 | iex
#
# Local / parameterized usage:
#   .\install.ps1 -Dir C:\Projects\my-workspace
# =============================================================================

param(
    [string]$Dir = "",
    [string]$Url = $(if ($env:TOOLS_UPSTREAM_URL) { $env:TOOLS_UPSTREAM_URL } else { "https://github.com/BullTronics/workspace-repo-tools.git" }),
    [string]$Branch = $(if ($env:TOOLS_UPSTREAM_BRANCH) { $env:TOOLS_UPSTREAM_BRANCH } else { "main" }),
    [switch]$Force
)

$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Git is required to install workspace-repo-tools." -ForegroundColor Red
    exit 1
}

if (-not $Dir) {
    $TargetDir = (Get-Location).Path
} else {
    if (-not (Test-Path $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    $TargetDir = (Resolve-Path $Dir).Path
}

function Normalize-RepoUrl {
    param([string]$RepoUrl)
    $u = $RepoUrl.Trim().ToLower().TrimEnd('/')
    if ($u.EndsWith(".git")) { $u = $u.Substring(0, $u.Length - 4) }
    if ($u -like "git@github.com:*") { $u = "https://github.com/" + $u.Substring("git@github.com:".Length) }
    return $u
}

if (-not $Force) {
    try {
        $originOut = & git -C $TargetDir config --get remote.origin.url 2>$null
        if ($LASTEXITCODE -eq 0 -and $originOut) {
            if ((Normalize-RepoUrl $originOut) -eq (Normalize-RepoUrl $Url)) {
                Write-Host "ERROR: Target directory's origin matches upstream ($Url)." -ForegroundColor Red
                Write-Host "Choose a different -Dir or pass -Force." -ForegroundColor Yellow
                exit 1
            }
        }
    } catch {}
}

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) "wrt-install-$PID-$(Get-Random)"
try {
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
    $srcDir = Join-Path $tmpRoot "src"

    Write-Host "Downloading workspace-repo-tools ($Branch) from $Url..." -ForegroundColor Cyan
    $prevPrompt = $env:GIT_TERMINAL_PROMPT
    $env:GIT_TERMINAL_PROMPT = "0"
    try {
        & git clone --quiet --depth 1 --branch $Branch $Url $srcDir
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: Failed to clone upstream repository." -ForegroundColor Red
            exit 1
        }
    } finally {
        $env:GIT_TERMINAL_PROMPT = $prevPrompt
    }

    $remoteSha = (& git -C $srcDir rev-parse HEAD).Trim()
    $remoteVer = "1.0.0"
    $verPath = Join-Path $srcDir "VERSION"
    if (Test-Path $verPath) {
        $remoteVer = (Get-Content $verPath -Encoding UTF8 | Select-Object -First 1).Trim()
    }

    $manifestFiles = @()
    $manifestDirs = @()
    $manifestMerges = @()
    $mfile = Join-Path $srcDir "updater-manifest.txt"
    if (Test-Path $mfile) {
        foreach ($raw in (Get-Content $mfile -Encoding UTF8)) {
            $line = $raw.Trim()
            if (-not $line -or $line.StartsWith("#")) { continue }
            if ($line.StartsWith("file:")) { $manifestFiles += $line.Substring(5).Trim() }
            elseif ($line.StartsWith("dir:")) { $manifestDirs += $line.Substring(4).Trim() }
            elseif ($line.StartsWith("merge_lines:")) { $manifestMerges += $line.Substring(12).Trim() }
        }
    }
    if ($manifestFiles.Count -eq 0) {
        $manifestFiles = @(
            "workspace.sh", "workspace.ps1", "workspace.bat",
            "git-all.sh", "git-all.ps1", "git-all.bat",
            "run-local.sh", "run-local.ps1", "run-local.bat",
            "workspace-repo-tools-updater.sh", "workspace-repo-tools-updater.ps1", "workspace-repo-tools-updater.bat",
            "updater-manifest.txt", "VERSION", "README.md"
        )
        $manifestDirs = @("templates")
        $manifestMerges = @(".gitignore")
    }

    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupDir = Join-Path $TargetDir ".workspace-tools-backups\$ts"
    $backupCreated = $false

    function Backup-IfDiffers {
        param([string]$RelPath)
        $dst = Join-Path $TargetDir ($RelPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $src = Join-Path $srcDir ($RelPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if ((Test-Path $dst -PathType Leaf) -and (Test-Path $src -PathType Leaf)) {
            $hDst = (Get-FileHash -Path $dst -Algorithm SHA256).Hash
            $hSrc = (Get-FileHash -Path $src -Algorithm SHA256).Hash
            if ($hDst -ne $hSrc) {
                if (-not $script:backupCreated) {
                    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
                    $script:backupCreated = $true
                }
                $bDst = Join-Path $backupDir ($RelPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                $bParent = Split-Path -Parent $bDst
                if (-not (Test-Path $bParent)) { New-Item -ItemType Directory -Path $bParent -Force | Out-Null }
                Copy-Item -Path $dst -Destination $bDst -Force
            }
        }
    }

    Write-Host "Installing tooling into: $TargetDir" -ForegroundColor Cyan

    foreach ($f in $manifestFiles) {
        $srcFile = Join-Path $srcDir ($f -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path $srcFile -PathType Leaf)) { continue }
        Backup-IfDiffers -RelPath $f
        $dstFile = Join-Path $TargetDir ($f -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $dstParent = Split-Path -Parent $dstFile
        if (-not (Test-Path $dstParent)) { New-Item -ItemType Directory -Path $dstParent -Force | Out-Null }
        Copy-Item -Path $srcFile -Destination $dstFile -Force
    }

    foreach ($d in $manifestDirs) {
        $srcSub = Join-Path $srcDir ($d -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path $srcSub -PathType Container)) { continue }
        foreach ($item in (Get-ChildItem -Path $srcSub -File -Recurse)) {
            $rel = $item.FullName.Substring($srcDir.Length + 1) -replace '\\', '/'
            Backup-IfDiffers -RelPath $rel
            $dstFile = Join-Path $TargetDir ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $dstParent = Split-Path -Parent $dstFile
            if (-not (Test-Path $dstParent)) { New-Item -ItemType Directory -Path $dstParent -Force | Out-Null }
            Copy-Item -Path $item.FullName -Destination $dstFile -Force
        }
    }

    foreach ($cfg in @("workspace.conf", "repos.csv", "services.csv")) {
        $srcCfg = Join-Path $srcDir $cfg
        $dstCfg = Join-Path $TargetDir $cfg
        if (Test-Path $srcCfg -PathType Leaf) {
            if (-not (Test-Path $dstCfg -PathType Leaf)) {
                Copy-Item -Path $srcCfg -Destination $dstCfg -Force
                Write-Host "  + Created $cfg (edit this for your project)" -ForegroundColor Green
            } else {
                Write-Host "  = Preserved existing $cfg" -ForegroundColor Gray
            }
        }
    }

    foreach ($mf in $manifestMerges) {
        $srcMf = Join-Path $srcDir ($mf -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $dstMf = Join-Path $TargetDir ($mf -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path $srcMf -PathType Leaf)) { continue }
        if (-not (Test-Path $dstMf -PathType Leaf)) {
            Copy-Item -Path $srcMf -Destination $dstMf -Force
            Write-Host "  + Created $mf" -ForegroundColor Green
        } else {
            $existing = @{}
            foreach ($l in (Get-Content $dstMf -Encoding UTF8)) { $existing[$l.TrimEnd("`r")] = $true }
            $missing = @()
            foreach ($raw in (Get-Content $srcMf -Encoding UTF8)) {
                $line = $raw.TrimEnd("`r")
                $trimmed = $line.Trim()
                if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
                if (-not $existing.ContainsKey($line)) { $missing += $line }
            }
            if ($missing.Count -gt 0) {
                Backup-IfDiffers -RelPath $mf
                $append = "`r`n# Added by workspace-repo-tools installer ($ts)`r`n" + ($missing -join "`r`n") + "`r`n"
                Add-Content -Path $dstMf -Value $append -Encoding UTF8
                Write-Host "  ~ Appended $($missing.Count) rule(s) to $mf" -ForegroundColor Blue
            }
        }
    }

    $wsRelDir = "workspace"
    $targetConf = Join-Path $TargetDir "workspace.conf"
    if (Test-Path $targetConf) {
        foreach ($raw in (Get-Content $targetConf -Encoding UTF8)) {
            $t = $raw.Trim()
            if ($t -and -not $t.StartsWith("#") -and $t -match '^WORKSPACE_DIR\s*=\s*(.+)$') {
                $v = $Matches[1].Trim().Trim('"').Trim("'")
                if ($v) { $wsRelDir = $v }
            }
        }
    }
    $wsFull = Join-Path $TargetDir ($wsRelDir -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path $wsFull)) { New-Item -ItemType Directory -Path $wsFull -Force | Out-Null }
    $gitkeep = Join-Path $wsFull ".gitkeep"
    if (-not (Test-Path $gitkeep)) { New-Item -ItemType File -Path $gitkeep -Force | Out-Null }

    $nowEpoch = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $nowIso = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")

@"
INSTALLED_VERSION=$remoteVer
INSTALLED_COMMIT=$remoteSha
UPSTREAM_URL=$Url
UPSTREAM_BRANCH=$Branch
UPDATED_AT=$nowIso
"@ | Set-Content -Path (Join-Path $TargetDir ".workspace-tools.lock") -Encoding UTF8 -Force

@"
LAST_CHECK_EPOCH=$nowEpoch
LAST_ATTEMPT_EPOCH=$nowEpoch
REMOTE_COMMIT=$remoteSha
REMOTE_VERSION=$remoteVer
MATCHED_COMMIT=$remoteSha
UPDATE_AVAILABLE=false
"@ | Set-Content -Path (Join-Path $TargetDir ".workspace-tools-cache") -Encoding UTF8 -Force

    if ($backupCreated) {
        Write-Host "Backups of replaced files saved to: .workspace-tools-backups\$ts" -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host "workspace-repo-tools ($remoteVer, commit $($remoteSha.Substring(0, 7))) installed successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "  1. Edit workspace.conf, repos.csv, and services.csv"
    Write-Host "  2. Run .\workspace.bat clone"
    Write-Host "  3. Run .\workspace.bat start   (or .\workspace.bat for interactive mode)"
    Write-Host ""
} finally {
    Remove-Item -Path $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

