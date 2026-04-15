#!/bin/bash
# init.sh — First-time wiki initialization
# Thin wrapper around batch.sh — extracts all sources then absorbs first batch.
#
# Usage: init.sh [--limit <count>] [--auto] [--topic <id>]
# Env: WIKI_BACKEND, WIKI_PATH, WIKI_SOURCES_PATH, WIKI_CONFIG_FILE

set -e

# Bootstrap: resolve config if not called via wiki-entry.sh
source "$(dirname "${BASH_SOURCE[0]}")/_bootstrap.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pass all args through to batch.sh
exec "$SCRIPT_DIR/batch.sh" "$@"
