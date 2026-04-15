#!/bin/bash
# _bootstrap.sh — Shared config bootstrap for all wiki scripts
# Sources config.json and sets WIKI_PATH, WIKI_SOURCES_PATH, WIKI_CONFIG_FILE.
# Works whether called via wiki-entry.sh (env vars pre-set) or directly.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/_bootstrap.sh"

# Skip if already bootstrapped
[ -n "$WIKI_PATH" ] && [ -n "$WIKI_SOURCES_PATH" ] && return 0 2>/dev/null || true

_BOOT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_BOOT_SKILL_DIR="$(cd "$_BOOT_SCRIPT_DIR/.." && pwd)"
_BOOT_CONFIG="$_BOOT_SKILL_DIR/config.json"

if [ ! -f "$_BOOT_CONFIG" ]; then
    echo '{"error": "Config not found at '"$_BOOT_CONFIG"'. Run install.sh first."}' >&2
    exit 1
fi

_boot_resolve() {
    local p="$1"
    [[ "$p" == '~/'* ]] && p="$HOME/${p:2}"
    [[ "$p" == '~' ]] && p="$HOME"
    echo "$p"
}

_VAULT_PATH="$(_boot_resolve "$(jq -r '.vault_path // empty' "$_BOOT_CONFIG" 2>/dev/null)")"
_WIKI_DIR="$(jq -r '.wiki_dir // "wiki"' "$_BOOT_CONFIG" 2>/dev/null)"
_SOURCES_DIR="$(jq -r '.sources_dir // "sources"' "$_BOOT_CONFIG" 2>/dev/null)"

if [ -z "$_VAULT_PATH" ]; then
    echo '{"error": "vault_path not set in config.json"}' >&2
    exit 1
fi

export WIKI_VAULT_PATH="$_VAULT_PATH"
export WIKI_PATH="${_VAULT_PATH}/${_WIKI_DIR}"
export WIKI_SOURCES_PATH="${_VAULT_PATH}/${_SOURCES_DIR}"
export WIKI_CONFIG_FILE="$_BOOT_CONFIG"
