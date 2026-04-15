#!/bin/bash
# config.sh — View or update wiki configuration
#
# Usage: config.sh                    # show all config
#        config.sh <key>              # show specific key
#        config.sh <key> <value>      # set key to value
# Env: WIKI_CONFIG_FILE

set -e

# Bootstrap: resolve config if not called via wiki-entry.sh
source "$(dirname "${BASH_SOURCE[0]}")/_bootstrap.sh"

CONFIG_FILE="$WIKI_CONFIG_FILE"

if [ ! -f "$CONFIG_FILE" ]; then
    echo '{"error": "Config file not found. Run install.sh first."}'
    exit 1
fi

# Whitelist of allowed config keys (prevent jq injection)
ALLOWED_KEYS=(
    "vault_path"
    "wiki_dir"
    "sources_dir"
    "default_backend"
    "cc_bridge.dispatch_path"
    "cc_bridge.model"
    "cc_bridge.timeout_minutes"
    "notifications.ingest_complete"
    "notifications.query_result"
    "notifications.lint_report"
    "cron.lint.enabled"
    "cron.lint.schedule"
    "cron.lint.backend"
    "cron.ingest.enabled"
    "cron.ingest.schedule"
    "cron.ingest.backend"
    "confidence.stale_after_days"
)

is_allowed_key() {
    local key="$1"
    for allowed in "${ALLOWED_KEYS[@]}"; do
        if [ "$key" = "$allowed" ]; then
            return 0
        fi
    done
    return 1
}

if [ $# -eq 0 ]; then
    # Show all config
    cat "$CONFIG_FILE"
    exit 0
fi

KEY="$1"

if [ $# -eq 1 ]; then
    # Show specific key
    if ! is_allowed_key "$KEY"; then
        jq -n --arg k "$KEY" '{"error": ("Unknown config key: " + $k)}'
        exit 1
    fi
    jq -r ".${KEY}" "$CONFIG_FILE"
    exit 0
fi

# Set key to value
shift
VALUE="$*"

if ! is_allowed_key "$KEY"; then
    jq -n --arg k "$KEY" '{"error": ("Unknown config key: " + $k)}'
    exit 1
fi

# Determine value type and set accordingly
if [ "$VALUE" = "true" ] || [ "$VALUE" = "false" ]; then
    jq --argjson v "$VALUE" ".${KEY} = \$v" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
        && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
elif [[ "$VALUE" =~ ^[0-9]+$ ]]; then
    jq --argjson v "$VALUE" ".${KEY} = \$v" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
        && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
else
    jq --arg v "$VALUE" ".${KEY} = \$v" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
        && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
fi

jq -n --arg key "$KEY" --arg value "$VALUE" '{"updated": $key, "value": $value}'
