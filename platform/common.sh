#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVS_DIR="$ROOT_DIR/envs"
LOGS_DIR="$ROOT_DIR/logs"
NGINX_CONF_DIR="$ROOT_DIR/nginx/conf.d"
ARCHIVE_DIR="$LOGS_DIR/archived"

NGINX_CONTAINER="${NGINX_CONTAINER:-sandbox-nginx}"
DEMO_IMAGE="${DEMO_IMAGE:-sandbox-demo-app:latest}"
HOST_DOMAIN="${HOST_DOMAIN:-localhost}"
NGINX_HTTP_PORT="${NGINX_HTTP_PORT:-8080}"
DEFAULT_TTL_SECONDS="${DEFAULT_TTL_SECONDS:-1800}"

mkdir -p "$ENVS_DIR" "$LOGS_DIR" "$NGINX_CONF_DIR" "$ARCHIVE_DIR"

if [ -f "$ROOT_DIR/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$ROOT_DIR/.env"
    set +a
fi

timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

validate_env_id() {
    local env_id="$1"
    if ! [[ "$env_id" =~ ^env-[0-9]+-[a-f0-9]{6}$ ]]; then
        echo "Invalid env ID: $env_id" >&2
        exit 1
    fi
}

reload_nginx() {
    if docker ps --format '{{.Names}}' | grep -qx "$NGINX_CONTAINER"; then
        docker exec "$NGINX_CONTAINER" nginx -s reload >/dev/null
    else
        echo "Warning: $NGINX_CONTAINER is not running, skipped nginx reload" >&2
    fi
}

json_value() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

path, key = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
print(data.get(key, ""))
PY
}

write_state_atomic() {
    local state_path="$1"
    local tmp_path="${state_path}.tmp"
    cat > "$tmp_path"
    mv "$tmp_path" "$state_path"
}

write_nginx_config_atomic() {
    local env_id="$1"
    local container="$2"
    local conf_path="$NGINX_CONF_DIR/$env_id.conf"
    local tmp_path="${conf_path}.tmp"

    cat > "$tmp_path" <<NGINX
server {
    listen 80;
    server_name $env_id.$HOST_DOMAIN;

    location / {
        proxy_pass http://$container:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Sandbox-Env $env_id;
    }
}
NGINX

    mv "$tmp_path" "$conf_path"
}
