# Modular runner for repo_type: go
run_template_go() {
    local entrypoint="${GO_ENTRYPOINT:-}"
    if [[ -z "$entrypoint" ]]; then
        local has_root_go=0 f
        for f in *.go; do
            if [[ -f "$f" ]]; then
                has_root_go=1
                break
            fi
        done
        if [[ $has_root_go -eq 1 ]]; then
            entrypoint="."
        else
            local candidates=()
            for f in cmd/*/main.go; do
                if [[ -f "$f" ]]; then
                    candidates+=("./$(dirname "$f")")
                fi
            done
            if [[ ${#candidates[@]} -eq 1 ]]; then
                entrypoint="${candidates[0]}"
            elif [[ ${#candidates[@]} -gt 1 ]]; then
                error "Multiple Go entrypoints found (${candidates[*]}). Set GO_ENTRYPOINT in .env or cmd_unix in services.csv."
                return 1
            else
                entrypoint="."
            fi
        fi
    fi

    if [[ -n "${GO_RUN_ARGS:-}" ]]; then
        # shellcheck disable=SC2206
        local extra=($GO_RUN_ARGS)
        go run "$entrypoint" "${extra[@]}"
    else
        go run "$entrypoint"
    fi
}
