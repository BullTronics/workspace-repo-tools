#!/bin/bash

cd "$(dirname "$0")" || exit 1

# Clear Flutter's stale chrome-device cache
rm -rf .dart_tool/chrome-device

if [ -f .env ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == export[[:space:]]* ]] && line="${line#export}" && line=$(echo "$line" | sed -e 's/^[[:space:]]*//')
        if [[ "$line" == *=* ]]; then
            key="${line%%=*}"
            value="${line#*=}"
            key=$(echo "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            value=$(echo "$value" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
            if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                export "$key=$value"
            fi
        fi
    done < .env
fi

DEFAULT_SLUG=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')
APP_SLUG="${APP_SLUG:-$DEFAULT_SLUG}"
WEB_PORT="${PORT:-3000}"
CHROME_DATA="${CHROME_USER_DATA_DIR:-/tmp/${APP_SLUG}-chrome-data}"

CMD_ARGS=(-d chrome --web-port "$WEB_PORT" --web-browser-flag="--user-data-dir=$CHROME_DATA")
if [ -f .env ]; then
    CMD_ARGS+=(--dart-define-from-file=.env)
fi

if [ -n "${FLUTTER_EXTRA_ARGS:-}" ]; then
    # shellcheck disable=SC2206
    EXTRA=($FLUTTER_EXTRA_ARGS)
    CMD_ARGS+=("${EXTRA[@]}")
fi

flutter run "${CMD_ARGS[@]}"

