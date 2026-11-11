# =============================================================================
# library-bundle (Windows PowerShell) - Module: 20_git.ps1
# =============================================================================

function Assert-GitInstalled {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "Git was not found. Please install Git and make sure it is in PATH." -ForegroundColor Red
        exit 1
    }
}

function Invoke-GitRepositories {
    param([string]$RepoFilter, [string]$CommandName, [string[]]$GitArgs)
    Assert-GitInstalled

    $entries = Get-RepoEntries
    $total = 0; $matched = 0; $successful = 0; $skipped = 0; $failed = 0

    foreach ($entry in $entries) {
        $total++
        $url = $entry.Url
        $relPath = $entry.Path
        $branch = $entry.Branch

        if (-not $url) {
            Write-Host "Row ${total}: missing URL." -ForegroundColor Red
            $failed++; continue
        }
        if (-not (Test-RelativePath -RelPath $relPath -RowNum $total)) {
            $failed++; continue
        }
        if (-not (Test-RepoMatchesFilter -RelPath $relPath -Filter $RepoFilter)) { continue }

        $matched++
        $repoPath = Join-Path $script:WorkspaceDir ($relPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)

        Write-Host ""
        Write-Host "============================================================"
        Write-Host "Repository : $relPath"
        Write-Host "URL        : $url"
        if ($branch -and $CommandName -eq "clone") { Write-Host "Branch     : $branch" }
        Write-Host "============================================================"

        if ($CommandName -eq "clone") {
            if (Test-Path $repoPath) {
                $null = & git -C $repoPath rev-parse --git-dir 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "Already cloned. Skipping." -ForegroundColor Yellow
                    $skipped++; continue
                }
                Write-Host "Path exists but is not a Git repository: $repoPath" -ForegroundColor Red
                $failed++; continue
            }

            $parentDir = Split-Path -Parent $repoPath
            if (-not (Test-Path $parentDir)) {
                New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
            }

            Write-Host "Cloning..." -ForegroundColor Cyan
            if ($branch) { & git clone -b $branch $url $repoPath }
            else { & git clone $url $repoPath }

            if ($LASTEXITCODE -eq 0) {
                Write-Host "Clone successful" -ForegroundColor Green
                $successful++
            } else {
                Write-Host "Clone failed" -ForegroundColor Red
                $failed++
            }
            continue
        }

        $null = & git -C $repoPath rev-parse --git-dir 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Repository not found: $repoPath" -ForegroundColor Yellow
            Write-Host "Run '.\workspace.bat clone' first." -ForegroundColor Yellow
            $skipped++; continue
        }

        $argDisplay = if ($GitArgs -and $GitArgs.Count -gt 0) { " $($GitArgs -join ' ')" } else { "" }
        Write-Host "Running: git $CommandName$argDisplay" -ForegroundColor Cyan
        & git -C $repoPath $CommandName @GitArgs
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Success" -ForegroundColor Green
            $successful++
        } else {
            Write-Host "Failed" -ForegroundColor Red
            $failed++
        }
    }

    if ($RepoFilter -and $matched -eq 0) {
        Write-Host "No repository matching '$RepoFilter' found in repos.csv." -ForegroundColor Red
        return $false
    }

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "Summary"
    Write-Host "============================================================"
    Write-Host "Matched    : $matched"
    Write-Host "Successful : $successful"
    Write-Host "Skipped    : $skipped"
    Write-Host "Failed     : $failed"

    return ($failed -eq 0)
}

function Get-GitRepositoriesStatus {
    param([string]$RepoFilter, [string[]]$StatusArgs)
    Assert-GitInstalled

    $targetRepo = $RepoFilter
    $showAll = $false
    if ($StatusArgs -and $StatusArgs.Count -gt 0) {
        if ($StatusArgs[0] -in @("-all", "--all")) { $showAll = $true }
        else { $targetRepo = $StatusArgs[0] }
    }

    $entries = Get-RepoEntries
    $repoFound = 0; $rowNum = 0

    foreach ($entry in $entries) {
        $rowNum++
        $url = $entry.Url
        $relPath = $entry.Path
        if (-not (Test-RelativePath -RelPath $relPath -RowNum $rowNum)) { continue }

        $repoPath = Join-Path $script:WorkspaceDir ($relPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)

        if ($targetRepo) {
            if (-not (Test-RepoMatchesFilter -RelPath $relPath -Filter $targetRepo)) { continue }
            $repoFound++

            Write-Host ""
            Write-Host "============================================================"
            Write-Host "Repository : $relPath"
            Write-Host "URL        : $url"
            Write-Host "============================================================"

            $null = & git -C $repoPath rev-parse --git-dir 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Repository not found: $repoPath" -ForegroundColor Yellow
                Write-Host "Run '.\workspace.bat clone' first." -ForegroundColor Yellow
                continue
            }
            Write-Host "Running: git status" -ForegroundColor Cyan
            & git -C $repoPath status
            continue
        }

        $null = & git -C $repoPath rev-parse --git-dir 2>$null
        if ($LASTEXITCODE -ne 0) {
            if ($showAll) { Write-Host "$relPath - not cloned" }
            continue
        }

        $lines = & git -C $repoPath status -sb --porcelain 2>$null
        $branch = "unknown"; $ahead = 0; $behind = 0
        $updated = 0; $newFiles = 0; $untracked = 0; $deleted = 0; $renamed = 0

        foreach ($line in $lines) {
            if ($line -match '^##\s+([^\.\s]+)') {
                $branch = $Matches[1]
                if ($line -match 'ahead\s+(\d+)') { $ahead = [int]$Matches[1] }
                if ($line -match 'behind\s+(\d+)') { $behind = [int]$Matches[1] }
                continue
            }
            if ($line -match '^( M|M )') { $updated++ }
            if ($line -match '^( A|A )') { $newFiles++ }
            if ($line -match '^\?\?') { $untracked++ }
            if ($line -match '^( D|D )') { $deleted++ }
            if ($line -match '^( R|R )') { $renamed++ }
        }

        $hasChanges = ($updated -gt 0 -or $newFiles -gt 0 -or $untracked -gt 0 -or $deleted -gt 0 -or $renamed -gt 0 -or $ahead -gt 0 -or $behind -gt 0)
        if (-not $hasChanges -and -not $showAll) { continue }

        $out = "$relPath - $branch"
        if (-not $hasChanges) {
            $out += " - uptodate"
        } else {
            if ($ahead -gt 0) { $out += " - ahead $ahead" }
            if ($behind -gt 0) { $out += " - behind $behind" }
            if ($updated -gt 0) { $out += " - $updated updated files" }
            if ($newFiles -gt 0) { $out += " - $newFiles new files" }
            if ($untracked -gt 0) { $out += " - $untracked untracked files" }
            if ($deleted -gt 0) { $out += " - $deleted deleted files" }
            if ($renamed -gt 0) { $out += " - $renamed renamed files" }
        }
        Write-Host $out
    }

    if ($targetRepo -and $repoFound -eq 0) {
        Write-Host "No repository matching '$targetRepo' found." -ForegroundColor Red
        return $false
    }
    return $true
}

