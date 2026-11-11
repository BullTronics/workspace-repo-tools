# Modular runner for repo_type: vite
run_template_vite() {
    export PORT="${PORT:-5173}"
    if [[ -f "package.json" && ! -d "node_modules" ]]; then
        if [[ -f "pnpm-lock.yaml" ]] && command -v pnpm >/dev/null 2>&1; then
            echo "Installing dependencies with pnpm..."
            pnpm install || return 1
        elif [[ -f "yarn.lock" ]] && command -v yarn >/dev/null 2>&1; then
            echo "Installing dependencies with yarn..."
            yarn install || return 1
        else
            echo "Installing dependencies with npm..."
            npm install || return 1
        fi
    fi
    local dev_cmd="${DEV_CMD:-npm run dev}"
    bash -c "$dev_cmd"
}
