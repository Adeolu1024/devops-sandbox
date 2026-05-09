#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

require_command docker
require_command python3

ENV_ID="${1:-}"

if [ -z "$ENV_ID" ]; then
    echo "Usage: $0 <env_id>" >&2
    exit 1
fi

validate_env_id "$ENV_ID"

STATE_FILE="$ENVS_DIR/$ENV_ID.json"
ENV_LOG_DIR="$LOGS_DIR/$ENV_ID"

if [ ! -f "$STATE_FILE" ]; then
    echo "No state file found for $ENV_ID" >&2
    exit 1
fi

NETWORK="$(json_value "$STATE_FILE" network)"
LOG_PID="$(json_value "$STATE_FILE" log_pid)"

if [ -n "$LOG_PID" ] && kill -0 "$LOG_PID" 2>/dev/null; then
    kill "$LOG_PID" 2>/dev/null || true
fi

docker ps -aq --filter "label=sandbox.env=$ENV_ID" | xargs -r docker rm -f >/dev/null

if docker ps --format '{{.Names}}' | grep -qx "$NGINX_CONTAINER"; then
    docker network disconnect "$NETWORK" "$NGINX_CONTAINER" 2>/dev/null || true
fi

docker network rm "$NETWORK" >/dev/null 2>&1 || true

rm -f "$NGINX_CONF_DIR/$ENV_ID.conf"
reload_nginx

mkdir -p "$ARCHIVE_DIR"
if [ -d "$ENV_LOG_DIR" ]; then
    rm -rf "$ARCHIVE_DIR/$ENV_ID"
    mv "$ENV_LOG_DIR" "$ARCHIVE_DIR/$ENV_ID"
fi

rm -f "$STATE_FILE"
echo "Destroyed $ENV_ID"
