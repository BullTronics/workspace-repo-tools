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

if (-not $env:PORT) { $env:PORT = "5173" }
$devCmd = if ($env:DEV_CMD) { $env:DEV_CMD } else { "npm run dev" }

Write-Host "Starting Node/Vite dev server on port $($env:PORT)..." -ForegroundColor Cyan
& cmd.exe /c $devCmd

