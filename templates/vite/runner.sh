# Modular runner for repo_type: vite
run_template_vite() {
    export PORT="${PORT:-5173}"
    local dev_cmd="${DEV_CMD:-npm run dev}"
    bash -c "$dev_cmd"
}

