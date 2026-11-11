# Modular runner for repo_type: vite
function Invoke-TemplateVite {
    if (-not $env:PORT) { $env:PORT = "5173" }
    if ((Test-Path "package.json" -PathType Leaf) -and -not (Test-Path "node_modules" -PathType Container)) {
        if ((Test-Path "pnpm-lock.yaml" -PathType Leaf) -and (Get-Command pnpm -ErrorAction SilentlyContinue)) {
            Write-Host "Installing dependencies with pnpm..." -ForegroundColor Cyan
            & pnpm install
        } elseif ((Test-Path "yarn.lock" -PathType Leaf) -and (Get-Command yarn -ErrorAction SilentlyContinue)) {
            Write-Host "Installing dependencies with yarn..." -ForegroundColor Cyan
            & yarn install
        } else {
            Write-Host "Installing dependencies with npm..." -ForegroundColor Cyan
            & npm install
        }
        if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = $LASTEXITCODE; return }
    }
    $devCmd = if ($env:DEV_CMD) { $env:DEV_CMD } else { "npm run dev" }
    & cmd.exe /c $devCmd
}
