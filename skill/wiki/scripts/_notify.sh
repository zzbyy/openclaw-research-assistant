#!/bin/bash
# _notify.sh — Send progress notifications to user's messaging channel
# Sources openclaw message send, same pattern as cc-bridge hooks.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/_notify.sh"
#        wiki_notify "message text"
#
# Config (in wiki config.json):
#   notifications.channel: "telegram" | "feishu" (auto-detected if not set)
#   notifications.target: group/chat ID (auto-detected if not set)
#   notifications.progress_interval: send progress every N dispatches (default: 10)

_NOTIFY_LOADED=true

# Read notification config
_notify_config() {
    [ -f "$WIKI_CONFIG_FILE" ] && jq -r "$1 // empty" "$WIKI_CONFIG_FILE" 2>/dev/null || echo ""
}

# Auto-detect channel and target from openclaw.json
_NOTIFY_CHANNEL="$(_notify_config '.notifications.channel')"
_NOTIFY_TARGET="$(_notify_config '.notifications.target')"
_NOTIFY_INTERVAL="$(_notify_config '.notifications.progress_interval')"
_NOTIFY_INTERVAL="${_NOTIFY_INTERVAL:-10}"

if [ -z "$_NOTIFY_CHANNEL" ] || [ -z "$_NOTIFY_TARGET" ]; then
    OC_FILE="$HOME/.openclaw/openclaw.json"
    if [ -f "$OC_FILE" ]; then
        # Try Feishu first (user's preferred channel)
        if [ -z "$_NOTIFY_CHANNEL" ]; then
            FEISHU_ENABLED=$(jq -r '.channels.feishu.enabled // false' "$OC_FILE" 2>/dev/null)
            TELEGRAM_ENABLED=$(jq -r '.channels.telegram.enabled // false' "$OC_FILE" 2>/dev/null)
            if [ "$FEISHU_ENABLED" = "true" ]; then
                _NOTIFY_CHANNEL="feishu"
            elif [ "$TELEGRAM_ENABLED" = "true" ]; then
                _NOTIFY_CHANNEL="telegram"
            fi
        fi
        # Try to get target from env or config
        if [ -z "$_NOTIFY_TARGET" ]; then
            if [ "$_NOTIFY_CHANNEL" = "telegram" ]; then
                _NOTIFY_TARGET="${CC_TELEGRAM_GROUP:-}"
            fi
            # Feishu target is typically auto-routed by openclaw
        fi
    fi
fi

# Send a notification message
# Usage: wiki_notify "message"
wiki_notify() {
    local message="$1"
    command -v openclaw &>/dev/null || return 0

    # Build args
    local args=(message send --message "$message")

    if [ -n "$_NOTIFY_CHANNEL" ]; then
        args+=(--channel "$_NOTIFY_CHANNEL")
    fi
    if [ -n "$_NOTIFY_TARGET" ]; then
        args+=(--target "$_NOTIFY_TARGET")
    fi

    # Send in background (non-blocking)
    openclaw "${args[@]}" > /dev/null 2>&1 &
}

# Check if we should send progress at this count
# Usage: if should_notify_progress 10; then wiki_notify "..."; fi
should_notify_progress() {
    local count="$1"
    [ "$count" -gt 0 ] && [ $((count % _NOTIFY_INTERVAL)) -eq 0 ]
}
