# Modular runner for repo_type: flutter-web
run_template_flutter_web() {
    rm -rf .dart_tool/chrome-device

    local default_slug
    default_slug=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')
    local app_slug="${APP_SLUG:-$default_slug}"
    local web_port="${PORT:-3000}"
    local chrome_data="${CHROME_USER_DATA_DIR:-/tmp/${app_slug}-chrome-data}"

    local cmd_args=(-d chrome --web-port "$web_port" --web-browser-flag="--user-data-dir=$chrome_data")
    if [[ -f .env ]]; then
        cmd_args+=(--dart-define-from-file=.env)
    fi

    if [[ -n "${FLUTTER_EXTRA_ARGS:-}" ]]; then
        # shellcheck disable=SC2206
        local extra=($FLUTTER_EXTRA_ARGS)
        cmd_args+=("${extra[@]}")
    fi

    flutter run "${cmd_args[@]}"
}

