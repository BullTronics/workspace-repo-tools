# Modular runner for repo_type: vite
function Invoke-TemplateVite {
    if (-not $env:PORT) { $env:PORT = "5173" }
    $devCmd = if ($env:DEV_CMD) { $env:DEV_CMD } else { "npm run dev" }
    & cmd.exe /c $devCmd
}

