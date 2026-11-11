# Modular runner for repo_type: go
function Invoke-TemplateGo {
    $entrypoint = if ($env:GO_ENTRYPOINT) { $env:GO_ENTRYPOINT } else { "." }
    & go run $entrypoint
}

