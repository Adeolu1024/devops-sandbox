#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

LOG_FILE="$LOGS_DIR/cleanup.log"

log() {
    echo "$(timestamp) $*" >> "$LOG_FILE"
}

run_destroy() {
    local env_id="$1"
    "$SCRIPT_DIR/destroy_env.sh" "$env_id" 2>&1 | while IFS= read -r line; do
        log "$line"
    done
}

log "cleanup daemon started"

while true; do
    NOW="$(date -u +%s)"
    for state_file in "$ENVS_DIR"/*.json; do
        [ -e "$state_file" ] || continue
        ENV_ID="$(json_value "$state_file" id)"
        CREATED_AT="$(json_value "$state_file" created_at)"
        TTL="$(json_value "$state_file" ttl)"
        EXPIRES_AT=$((CREATED_AT + TTL))

        if [ "$NOW" -gt "$EXPIRES_AT" ]; then
            log "ttl expired for $ENV_ID, destroying"
            if run_destroy "$ENV_ID"; then
                log "destroyed $ENV_ID"
            else
                log "failed to destroy $ENV_ID"
            fi
        fi
    done
    sleep 60
done
