# =============================================================================
# library-bundle (Windows PowerShell) - Module: 10_config.ps1
# =============================================================================

$WorkspaceConf = Join-Path $ScriptDir "workspace.conf"
$ReposCsvPath = Join-Path $ScriptDir "repos.csv"
$ServicesCsvPath = Join-Path $ScriptDir "services.csv"

$script:WorkspaceName = "Workspace"
$script:WorkspacePrompt = "workspace"
$script:WorkspaceRelDir = "workspace"
$script:ToolsVersion = $script:BundleVersion
$script:ConfigSchemaVersion = $script:BundleSchemaVersion
$script:ToolsRepoUrl = "https://github.com/BullTronics/workspace-repo-tools"
$script:ToolsReleaseBaseUrl = ""
$script:DisableAutoCheck = $false
$script:CheckIntervalHours = 24

function Load-WorkspaceConf {
    $conf = Read-KvFile -FilePath $WorkspaceConf
    if ($conf.ContainsKey("WORKSPACE_NAME") -and $conf["WORKSPACE_NAME"]) { $script:WorkspaceName = $conf["WORKSPACE_NAME"] }
    if ($conf.ContainsKey("WORKSPACE_PROMPT") -and $conf["WORKSPACE_PROMPT"]) { $script:WorkspacePrompt = $conf["WORKSPACE_PROMPT"] }
    if ($conf.ContainsKey("WORKSPACE_DIR") -and $conf["WORKSPACE_DIR"]) { $script:WorkspaceRelDir = $conf["WORKSPACE_DIR"] }
    if ($conf.ContainsKey("TOOLS_VERSION") -and $conf["TOOLS_VERSION"]) { $script:ToolsVersion = $conf["TOOLS_VERSION"] }
    if ($conf.ContainsKey("CONFIG_SCHEMA_VERSION") -and $conf["CONFIG_SCHEMA_VERSION"]) { $script:ConfigSchemaVersion = $conf["CONFIG_SCHEMA_VERSION"] }
    if ($conf.ContainsKey("TOOLS_REPO_URL") -and $conf["TOOLS_REPO_URL"]) { $script:ToolsRepoUrl = $conf["TOOLS_REPO_URL"].TrimEnd('/') }
    if ($conf.ContainsKey("TOOLS_RELEASE_BASE_URL") -and $conf["TOOLS_RELEASE_BASE_URL"]) { $script:ToolsReleaseBaseUrl = $conf["TOOLS_RELEASE_BASE_URL"].TrimEnd('/') }
    if ($conf.ContainsKey("DISABLE_AUTO_UPDATE_CHECK") -and $conf["DISABLE_AUTO_UPDATE_CHECK"]) {
        $v = $conf["DISABLE_AUTO_UPDATE_CHECK"].ToLower()
        if ($v -eq "true") { $script:DisableAutoCheck = $true }
        elseif ($v -eq "false") { $script:DisableAutoCheck = $false }
    }
    if ($conf.ContainsKey("UPDATE_CHECK_INTERVAL_HOURS") -and ($conf["UPDATE_CHECK_INTERVAL_HOURS"] -match '^\d+$')) {
        $script:CheckIntervalHours = [int]$conf["UPDATE_CHECK_INTERVAL_HOURS"]
    }

    if ([System.IO.Path]::IsPathRooted($script:WorkspaceRelDir) -or $script:WorkspaceRelDir -match '^[A-Za-z]:' -or $script:WorkspaceRelDir -match '(^|[\\/])\.\.([\\/]|$)') {
        Write-Host "ERROR: Invalid WORKSPACE_DIR in workspace.conf: $($script:WorkspaceRelDir)" -ForegroundColor Red
        exit 1
    }

    $script:WorkspaceDir = Join-Path $ScriptDir ($script:WorkspaceRelDir -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if ($env:WORKSPACE_RELEASE_URL) {
        $script:ReleasesBaseUrl = $env:WORKSPACE_RELEASE_URL.TrimEnd('/')
    } elseif ($script:ToolsReleaseBaseUrl) {
        $script:ReleasesBaseUrl = $script:ToolsReleaseBaseUrl
    } else {
        $script:ReleasesBaseUrl = "$($script:ToolsRepoUrl)/releases"
    }
}

Load-WorkspaceConf

function Test-RelativePath {
    param([string]$RelPath, [int]$RowNum)
    if (-not $RelPath) {
        Write-Host "Row ${RowNum}: missing path." -ForegroundColor Red
        return $false
    }
    if ($RelPath.StartsWith("/") -or $RelPath.StartsWith("\") -or $RelPath -match '^[A-Za-z]:') {
        Write-Host "Row ${RowNum}: absolute paths are not allowed: $RelPath" -ForegroundColor Red
        return $false
    }
    if ($RelPath.Contains("\")) {
        Write-Host "Row ${RowNum}: use '/' instead of '\' in path: $RelPath" -ForegroundColor Red
        return $false
    }
    if ($RelPath -eq ".." -or $RelPath -match '(^|/)\.\.(/|$)') {
        Write-Host "Row ${RowNum}: path escapes workspace: $RelPath" -ForegroundColor Red
        return $false
    }
    return $true
}

function Test-RepoMatchesFilter {
    param([string]$RelPath, [string]$Filter)
    if (-not $Filter) { return $true }
    $normFilter = ($Filter -replace '\\', '/').Trim('/')
    return ($RelPath -eq $normFilter -or $RelPath.EndsWith("/$normFilter"))
}

function Get-RepoEntries {
    if (-not (Test-Path $ReposCsvPath)) {
        Write-Host "repos.csv not found: $ReposCsvPath" -ForegroundColor Red
        exit 1
    }

    $lines = @()
    foreach ($raw in (Get-Content $ReposCsvPath -Encoding UTF8)) {
        $trimmed = $raw.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        $lines += $raw
    }

    if ($lines.Count -eq 0) {
        Write-Host "repos.csv is empty or missing header (url,path[,branch])." -ForegroundColor Red
        exit 1
    }

    $normHeader = ($lines[0] -replace '\s+', '')
    if ($normHeader -ne "url,path" -and $normHeader -ne "url,path,branch") {
        Write-Host "Invalid repos.csv header. Expected 'url,path' or 'url,path,branch', found: $($lines[0].Trim())" -ForegroundColor Red
        exit 1
    }

    $entries = @()
    if ($lines.Count -gt 1) {
        foreach ($row in ($lines | ConvertFrom-Csv)) {
            $u = if ($row.url) { $row.url.Trim() } else { "" }
            $p = if ($row.path) { $row.path.Trim() } else { "" }
            $b = if ($row.PSObject.Properties['branch'] -and $row.branch) { $row.branch.Trim() } else { "" }
            if (-not $u -and -not $p) { continue }
            $entries += [pscustomobject]@{ Url = $u; Path = $p; Branch = $b }
        }
    }
    return ,$entries
}

function Normalize-RepoType {
    param([string]$Raw)
    switch ($Raw.Trim().ToLower()) {
        "" { return "custom" }
        "custom" { return "custom" }
        { $_ -in @("spring-boot", "spring-boot-maven") } { return "spring-boot" }
        "flutter-web" { return "flutter-web" }
        { $_ -in @("go", "go-service") } { return "go" }
        { $_ -in @("vite", "node-vite") } { return "vite" }
        default { return "INVALID" }
    }
}

$script:services = @()
$script:servicesLoaded = $false

function Load-ServicesCsv {
    if ($script:servicesLoaded) { return }
    $script:servicesLoaded = $true

    if (-not (Test-Path $ServicesCsvPath)) {
        Write-Host "ERROR: services.csv not found at $ServicesCsvPath" -ForegroundColor Red
        exit 1
    }

    $lines = @()
    foreach ($raw in (Get-Content $ServicesCsvPath -Encoding UTF8)) {
        $trimmed = $raw.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        $lines += $raw
    }

    if ($lines.Count -eq 0) {
        Write-Host "ERROR: services.csv is empty or missing header." -ForegroundColor Red
        exit 1
    }

    $expectedHeader = "name,emoji,path,repo_type,port,cmd_unix,cmd_win,load_env_file,stop_pattern,hints"
    $actualHeader = (($lines[0] -split ',') | ForEach-Object { $_.Trim() }) -join ','
    if ($actualHeader -ne $expectedHeader) {
        Write-Host "ERROR: Invalid services.csv header." -ForegroundColor Red
        Write-Host "Expected: $expectedHeader" -ForegroundColor Red
        Write-Host "Found:    $actualHeader" -ForegroundColor Red
        exit 1
    }

    $loaded = @()
    if ($lines.Count -le 1) {
        $script:services = $loaded
        return
    }

    $rows = $lines | ConvertFrom-Csv
    $seenSlugs = @{}
    $rowNum = 0

    foreach ($row in $rows) {
        $rowNum++
        $name = if ($row.name) { $row.name.Trim() } else { "" }
        if (-not $name) {
            Write-Host "ERROR: services.csv row $rowNum is missing 'name'." -ForegroundColor Red
            exit 1
        }
        $slug = ConvertTo-Slug -Text $name
        if ($seenSlugs.ContainsKey($slug)) {
            Write-Host "ERROR: Duplicate service name '$name' in services.csv." -ForegroundColor Red
            exit 1
        }
        $seenSlugs[$slug] = $true

        $relPath = if ($row.path) { $row.path.Trim() } else { "" }
        if (-not (Test-RelativePath -RelPath $relPath -RowNum $rowNum)) { exit 1 }

        $repoTypeRaw = if ($row.repo_type) { $row.repo_type.Trim() } else { "" }
        $repoType = Normalize-RepoType -Raw $repoTypeRaw
        if ($repoType -eq "INVALID") {
            Write-Host "ERROR: Invalid repo_type '$repoTypeRaw' for service '$name'." -ForegroundColor Red
            exit 1
        }

        $emoji = if ($row.emoji -and $row.emoji.Trim() -ne "-") { $row.emoji.Trim() } else { "" }

        $portRaw = if ($row.port) { $row.port.Trim() } else { "" }
        $portNum = $null
        if ($portRaw -eq "-") {
            $portNum = $null
        } elseif (-not $portRaw) {
            switch ($repoType) {
                "spring-boot" { $portNum = 8080 }
                "flutter-web" { $portNum = 3000 }
                "vite"        { $portNum = 5173 }
                default       { $portNum = $null }
            }
        } else {
            $parsedPort = 0
            if (-not [int]::TryParse($portRaw, [ref]$parsedPort) -or $parsedPort -lt 1 -or $parsedPort -gt 65535) {
                Write-Host "ERROR: Invalid port '$portRaw' for service '$name' in services.csv." -ForegroundColor Red
                exit 1
            }
            $portNum = $parsedPort
        }

        $cmdWin = if ($row.cmd_win -and $row.cmd_win.Trim()) { $row.cmd_win.Trim() } else { "" }

        $loadRaw = if ($row.load_env_file) { $row.load_env_file.Trim().ToLower() } else { "" }
        $loadEnv = $false
        if ($loadRaw -eq "true") { $loadEnv = $true }
        elseif ($loadRaw -and $loadRaw -ne "false") {
            Write-Host "ERROR: Invalid load_env_file '$($row.load_env_file)' for service '$name' (expected true/false)." -ForegroundColor Red
            exit 1
        }

        $stopRaw = if ($row.stop_pattern) { $row.stop_pattern.Trim() } else { "" }
        if (-not $stopRaw) {
            if ($repoType -eq "spring-boot") { $stopRaw = "spring-boot:run" }
            elseif ($repoType -eq "vite") { $stopRaw = "vite" }
        }
        $stopPatterns = @()
        if ($stopRaw) {
            foreach ($p in ($stopRaw -split ';')) {
                $tp = $p.Trim()
                if ($tp) { $stopPatterns += $tp }
            }
        }

        $hints = if ($row.hints) { $row.hints.Trim() } else { "" }
        if (-not $hints -and $repoType -eq "flutter-web") {
            $hints = "[r] Hot reload  [R] Hot restart  [h] Help  [d] DevTools  [q] Quit"
        }

        $loaded += [pscustomobject]@{
            Name         = $name
            Slug         = $slug
            Emoji        = $emoji
            RelPath      = $relPath
            RepoType     = $repoType
            Dir          = (Join-Path $script:WorkspaceDir ($relPath -replace '/', [System.IO.Path]::DirectorySeparatorChar))
            Port         = $portNum
            CmdWin       = $cmdWin
            LoadEnvFile  = $loadEnv
            StopPatterns = $stopPatterns
            Hints        = $hints
        }
    }

    $script:services = $loaded
}

