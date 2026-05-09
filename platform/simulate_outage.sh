#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

require_command docker
require_command python3

ENV_ID=""
MODE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --env) ENV_ID="${2:-}"; shift 2 ;;
        --mode) MODE="${2:-}"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$ENV_ID" ] || [ -z "$MODE" ]; then
    echo "Usage: $0 --env <env_id> --mode <crash|pause|network|recover>" >&2
    exit 1
fi

validate_env_id "$ENV_ID"

STATE_FILE="$ENVS_DIR/$ENV_ID.json"
if [ ! -f "$STATE_FILE" ]; then
    echo "No state file found for $ENV_ID" >&2
    exit 1
fi

CONTAINER="$(json_value "$STATE_FILE" container_name)"
NETWORK="$(json_value "$STATE_FILE" network)"

case "$CONTAINER" in
    "$NGINX_CONTAINER"|*daemon*|*cleanup*)
        echo "Refusing to simulate outage against protected container: $CONTAINER" >&2
        exit 1
        ;;
esac

update_outage_mode() {
    python3 - "$STATE_FILE" "$1" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
mode = sys.argv[2]
data = json.loads(path.read_text(encoding="utf-8"))
data["outage_mode"] = mode
tmp = path.with_suffix(path.suffix + ".tmp")
tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
tmp.replace(path)
PY
}

update_log_pid() {
    python3 - "$STATE_FILE" "$1" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
log_pid = int(sys.argv[2])
data = json.loads(path.read_text(encoding="utf-8"))
data["log_pid"] = log_pid
tmp = path.with_suffix(path.suffix + ".tmp")
tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
tmp.replace(path)
PY
}

ensure_log_shipper() {
    local current_pid
    current_pid="$(json_value "$STATE_FILE" log_pid)"
    if [ -n "$current_pid" ] && kill -0 "$current_pid" 2>/dev/null; then
        return
    fi

    mkdir -p "$LOGS_DIR/$ENV_ID"
    docker logs -f "$CONTAINER" >> "$LOGS_DIR/$ENV_ID/app.log" 2>&1 &
    update_log_pid "$!"
}

case "$MODE" in
    crash)
        docker kill "$CONTAINER" >/dev/null
        update_outage_mode crash
        ;;
    pause)
        docker pause "$CONTAINER" >/dev/null
        update_outage_mode pause
        ;;
    network)
        docker network disconnect "$NETWORK" "$CONTAINER" >/dev/null
        update_outage_mode network
        ;;
    recover)
        OUTAGE_MODE="$(json_value "$STATE_FILE" outage_mode)"
        if [ "$OUTAGE_MODE" = "pause" ]; then
            docker unpause "$CONTAINER" >/dev/null 2>&1 || true
        elif [ "$OUTAGE_MODE" = "network" ]; then
            docker network connect --alias "$CONTAINER" "$NETWORK" "$CONTAINER" >/dev/null 2>&1 || true
        elif [ "$OUTAGE_MODE" = "crash" ]; then
            docker start "$CONTAINER" >/dev/null 2>&1 || true
            ensure_log_shipper
        fi
        update_outage_mode none
        ;;
    *)
        echo "Unsupported mode: $MODE" >&2
        exit 1
        ;;
esac

echo "Outage mode '$MODE' applied to $ENV_ID"
