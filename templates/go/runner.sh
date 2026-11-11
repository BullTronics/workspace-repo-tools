# Modular runner for repo_type: go
run_template_go() {
    local entrypoint="${GO_ENTRYPOINT:-.}"
    go run "$entrypoint"
}

