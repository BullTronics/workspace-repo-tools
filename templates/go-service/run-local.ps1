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

$appName = if ($env:APP_NAME) { $env:APP_NAME } else { Split-Path -Leaf $PSScriptRoot }
$entrypoint = if ($env:GO_ENTRYPOINT) { $env:GO_ENTRYPOINT } else { "." }

try { $Host.UI.RawUI.WindowTitle = $appName } catch {}
Write-Host "Starting $appName ($entrypoint)..." -ForegroundColor Cyan

& go run $entrypoint

