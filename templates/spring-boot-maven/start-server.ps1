$ErrorActionPreference = "Stop"

Set-Location $PSScriptRoot

if (Test-Path .env) {
    Get-Content .env -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#")) { return }
        if ($line -match '^export\s+(.+)$') { $line = $Matches[1].Trim() }
        if (-not $line.Contains("=")) { return }
        $name, $value = $line -split '=', 2
        $name = $name.Trim()
        $value = $value.Trim().Trim('"').Trim("'")
        if ($name -match '^[A-Za-z_][A-Za-z0-9_]*$') {
            [System.Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
}

$jarPath = $env:JAR_FILE
if (-not $jarPath) {
    $jarCandidate = Get-ChildItem -Path (Join-Path $PSScriptRoot "target") -Filter "*.jar" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '\.original$' } |
        Select-Object -First 1
    if ($jarCandidate) {
        $jarPath = $jarCandidate.FullName
    }
}

if (-not $jarPath -or -not (Test-Path $jarPath)) {
    Write-Host "ERROR: Executable JAR not found. Build with 'mvn package' or set JAR_FILE in .env." -ForegroundColor Red
    exit 1
}

$jvmArgs = if ($env:JVM_ARGS) { $env:JVM_ARGS } else { "-Duser.timezone=UTC" }
& java $jvmArgs -jar $jarPath

