#!/bin/bash
set -e

cd "$(dirname "$0")" || exit 1

if [ -f .env ]; then
    echo "Loading environment variables from .env"
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

JVM_ARGS="${JVM_ARGS:--Duser.timezone=UTC}"
mvn spring-boot:run "-Dspring-boot.run.jvmArguments=$JVM_ARGS"

