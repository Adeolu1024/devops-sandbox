#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

require_command docker
require_command python3

NAME="${1:-}"
TTL="${2:-$DEFAULT_TTL_SECONDS}"

if [ -z "$NAME" ]; then
    echo "Usage: $0 <name> [ttl_seconds]" >&2
    exit 1
fi

if [ "${#NAME}" -gt 80 ]; then
    echo "Environment name must be 80 characters or fewer" >&2
    exit 1
fi

if ! [[ "$TTL" =~ ^[0-9]+$ ]]; then
    echo "TTL must be a number of seconds" >&2
    exit 1
fi

ENV_ID="env-$(date +%s)-$(python3 -c 'import secrets; print(secrets.token_hex(3))')"
validate_env_id "$ENV_ID"
NETWORK="${ENV_ID}-net"
CONTAINER="${ENV_ID}-app"
STATE_FILE="$ENVS_DIR/$ENV_ID.json"
ENV_LOG_DIR="$LOGS_DIR/$ENV_ID"
APP_LOG="$ENV_LOG_DIR/app.log"
CREATED_AT="$(date -u +%s)"

mkdir -p "$ENV_LOG_DIR"

docker network create "$NETWORK" >/dev/null

if docker ps --format '{{.Names}}' | grep -qx "$NGINX_CONTAINER"; then
    docker network connect "$NETWORK" "$NGINX_CONTAINER" 2>/dev/null || true
fi

docker run -d \
    --name "$CONTAINER" \
    --network "$NETWORK" \
    --network-alias "$CONTAINER" \
    --label "sandbox.env=$ENV_ID" \
    --label "sandbox.name=$NAME" \
    -e "SANDBOX_ENV_ID=$ENV_ID" \
    -e "SANDBOX_ENV_NAME=$NAME" \
    "$DEMO_IMAGE" >/dev/null

CONTAINER_ID="$(docker inspect -f '{{.Id}}' "$CONTAINER")"

nohup docker logs -f "$CONTAINER_ID" >> "$APP_LOG" 2>&1 &
LOG_PID="$!"

write_nginx_config_atomic "$ENV_ID" "$CONTAINER"
reload_nginx

export ENV_ID NAME CREATED_AT TTL CONTAINER_ID CONTAINER NETWORK LOG_PID
python3 - "$STATE_FILE" <<PY
import json
import os
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
data = {
    "id": os.environ["ENV_ID"],
    "name": os.environ["NAME"],
    "created_at": int(os.environ["CREATED_AT"]),
    "ttl": int(os.environ["TTL"]),
    "status": "running",
    "container_id": os.environ["CONTAINER_ID"],
    "container_name": os.environ["CONTAINER"],
    "network": os.environ["NETWORK"],
    "log_pid": int(os.environ["LOG_PID"]),
    "outage_mode": "none",
}
tmp_path = state_path.with_suffix(state_path.suffix + ".tmp")
tmp_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
tmp_path.replace(state_path)
PY

echo "Environment created"
echo "ID: $ENV_ID"
echo "URL: http://$ENV_ID.$HOST_DOMAIN:$NGINX_HTTP_PORT/"
echo "TTL: $TTL seconds"
