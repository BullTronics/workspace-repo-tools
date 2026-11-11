# Modular runner for repo_type: go
function Invoke-TemplateGo {
    $entrypoint = $env:GO_ENTRYPOINT
    if (-not $entrypoint) {
        $rootGo = Get-ChildItem -Path . -Filter "*.go" -File -ErrorAction SilentlyContinue
        if ($rootGo -and $rootGo.Count -gt 0) {
            $entrypoint = "."
        } else {
            $candidates = @()
            if (Test-Path "cmd" -PathType Container) {
                Get-ChildItem -Path "cmd" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    if (Test-Path (Join-Path $_.FullName "main.go") -PathType Leaf) {
                        $candidates += "./cmd/$($_.Name)"
                    }
                }
            }
            if ($candidates.Count -eq 1) {
                $entrypoint = $candidates[0]
            } elseif ($candidates.Count -gt 1) {
                $joined = $candidates -join ", "
                Write-Host "ERROR: Multiple Go entrypoints found ($joined). Set GO_ENTRYPOINT in .env or cmd_win in services.csv." -ForegroundColor Red
                return 1
            } else {
                $entrypoint = "."
            }
        }
    }

    if ($env:GO_RUN_ARGS) {
        $extra = $env:GO_RUN_ARGS.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
        & go run $entrypoint @extra
    } else {
        & go run $entrypoint
    }
}
