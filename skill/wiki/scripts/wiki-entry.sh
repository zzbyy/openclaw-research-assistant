#!/bin/bash
# wiki-entry.sh — Main router for /wiki commands
# Parses subcommand and flags, reads config, dispatches to the appropriate script.
#
# Usage: wiki-entry.sh <subcommand> [args...]
#   e.g. wiki-entry.sh ingest ~/papers/attention.pdf
#   e.g. wiki-entry.sh query "how does self-attention work?"
#   e.g. wiki-entry.sh lint --backend cc
#   e.g. wiki-entry.sh cron lint --every "sunday 9am"

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$SKILL_DIR/config.json"

# ── Read config ──────────────────────────────────────────────────────────────

_wiki_config() {
    [ -f "$CONFIG_FILE" ] && jq -r "$1 // empty" "$CONFIG_FILE" 2>/dev/null || echo ""
}

# Resolve vault path (safe tilde expansion)
_resolve_path() {
    local p="$1"
    if [[ "$p" == '~/'* ]]; then
        p="$HOME/${p:2}"
    elif [[ "$p" == '~' ]]; then
        p="$HOME"
    fi
    echo "$p"
}

VAULT_PATH="$(_resolve_path "$(_wiki_config '.vault_path')")"
WIKI_DIR="$(_wiki_config '.wiki_dir')"
SOURCES_DIR="$(_wiki_config '.sources_dir')"
DEFAULT_BACKEND="$(_wiki_config '.default_backend')"

WIKI_PATH="${VAULT_PATH:?Wiki vault_path not configured}/${WIKI_DIR:-wiki}"
SOURCES_PATH="${VAULT_PATH}/${SOURCES_DIR:-sources}"

export WIKI_VAULT_PATH="$VAULT_PATH"
export WIKI_PATH="$WIKI_PATH"
export WIKI_SOURCES_PATH="$SOURCES_PATH"
export WIKI_CONFIG_FILE="$CONFIG_FILE"

# ── Parse subcommand ─────────────────────────────────────────────────────────

if [ $# -lt 1 ]; then
    echo '{"error": "Usage: /wiki <subcommand> [args...]. Subcommands: ingest, query, lint, search, status, browse, related, config, cron"}'
    exit 1
fi

SUBCOMMAND="$1"
shift

# Extract --backend flag from remaining args
BACKEND="$DEFAULT_BACKEND"
REMAINING_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --backend|-b)
            BACKEND="$2"
            shift 2
            ;;
        *)
            REMAINING_ARGS+=("$1")
            shift
            ;;
    esac
done

export WIKI_BACKEND="${BACKEND:-cc}"

# ── Dispatch ─────────────────────────────────────────────────────────────────

case "$SUBCOMMAND" in
    ingest)
        exec "$SCRIPT_DIR/ingest.sh" "${REMAINING_ARGS[@]}"
        ;;
    query)
        exec "$SCRIPT_DIR/query.sh" "${REMAINING_ARGS[@]}"
        ;;
    lint)
        exec "$SCRIPT_DIR/lint.sh" "${REMAINING_ARGS[@]}"
        ;;
    search)
        exec "$SCRIPT_DIR/search.sh" "${REMAINING_ARGS[@]}"
        ;;
    status)
        exec "$SCRIPT_DIR/status.sh" "${REMAINING_ARGS[@]}"
        ;;
    browse)
        exec "$SCRIPT_DIR/browse.sh" "${REMAINING_ARGS[@]}"
        ;;
    related)
        exec "$SCRIPT_DIR/related.sh" "${REMAINING_ARGS[@]}"
        ;;
    config)
        exec "$SCRIPT_DIR/config.sh" "${REMAINING_ARGS[@]}"
        ;;
    cron)
        exec "$SCRIPT_DIR/cron.sh" "${REMAINING_ARGS[@]}"
        ;;
    catalog)
        exec "$SCRIPT_DIR/catalog.sh" "${REMAINING_ARGS[@]}"
        ;;
    init)
        exec "$SCRIPT_DIR/init.sh" "${REMAINING_ARGS[@]}"
        ;;
    batch)
        exec "$SCRIPT_DIR/batch.sh" "${REMAINING_ARGS[@]}"
        ;;
    upgrade)
        exec "$SCRIPT_DIR/upgrade.sh" "${REMAINING_ARGS[@]}"
        ;;
    *)
        jq -n --arg cmd "$SUBCOMMAND" '{"error": ("Unknown subcommand: " + $cmd + ". Use: ingest, query, lint, search, status, browse, related, config, cron, catalog, init, batch, upgrade")}'
        exit 1
        ;;
esac
