#!/bin/bash
# cron.sh — Manage OpenClaw cron jobs for periodic lint and auto-ingest
#
# Usage: cron.sh lint --every "sunday 9am"
#        cron.sh ingest --every "daily 6am"
#        cron.sh lint --disable
#        cron.sh status
# Env: WIKI_CONFIG_FILE, WIKI_PATH

set -e

# Bootstrap: resolve config if not called via wiki-entry.sh
source "$(dirname "${BASH_SOURCE[0]}")/_bootstrap.sh"

CONFIG_FILE="$WIKI_CONFIG_FILE"

if [ ! -f "$CONFIG_FILE" ]; then
    echo '{"error": "Config file not found. Run install.sh first."}'
    exit 1
fi

# ── Parse args ───────────────────────────────────────────────────────────────

if [ $# -lt 1 ]; then
    echo '{"error": "Usage: /wiki cron <lint|ingest|status> [--every <schedule>] [--disable] [--backend <cc|agent>]"}'
    exit 1
fi

JOB_TYPE="$1"
shift

SCHEDULE=""
DISABLE=false
BACKEND=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --every)
            SCHEDULE="$2"
            shift 2
            ;;
        --disable)
            DISABLE=true
            shift
            ;;
        --backend)
            BACKEND="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# ── Status ───────────────────────────────────────────────────────────────────

if [ "$JOB_TYPE" = "status" ]; then
    LINT_ENABLED=$(jq -r '.cron.lint.enabled // false' "$CONFIG_FILE")
    LINT_SCHEDULE=$(jq -r '.cron.lint.schedule // "not set"' "$CONFIG_FILE")
    LINT_BACKEND=$(jq -r '.cron.lint.backend // "cc"' "$CONFIG_FILE")
    INGEST_ENABLED=$(jq -r '.cron.ingest.enabled // false' "$CONFIG_FILE")
    INGEST_SCHEDULE=$(jq -r '.cron.ingest.schedule // "not set"' "$CONFIG_FILE")
    INGEST_BACKEND=$(jq -r '.cron.ingest.backend // "cc"' "$CONFIG_FILE")

    jq -n \
        --argjson lint_enabled "$LINT_ENABLED" \
        --arg lint_schedule "$LINT_SCHEDULE" \
        --arg lint_backend "$LINT_BACKEND" \
        --argjson ingest_enabled "$INGEST_ENABLED" \
        --arg ingest_schedule "$INGEST_SCHEDULE" \
        --arg ingest_backend "$INGEST_BACKEND" \
        '{
            cron: {
                lint: { enabled: $lint_enabled, schedule: $lint_schedule, backend: $lint_backend },
                ingest: { enabled: $ingest_enabled, schedule: $ingest_schedule, backend: $ingest_backend }
            }
        }'
    exit 0
fi

# ── Validate job type ────────────────────────────────────────────────────────

if [ "$JOB_TYPE" != "lint" ] && [ "$JOB_TYPE" != "ingest" ]; then
    jq -n --arg t "$JOB_TYPE" '{"error": ("Unknown cron job type: " + $t + ". Use: lint, ingest, status")}'
    exit 1
fi

# ── Disable ──────────────────────────────────────────────────────────────────

if [ "$DISABLE" = true ]; then
    jq ".cron.${JOB_TYPE}.enabled = false" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
        && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # Remove OpenClaw cron job
    if command -v openclaw &>/dev/null; then
        openclaw cron remove "wiki-${JOB_TYPE}" 2>/dev/null || true
    fi

    jq -n --arg job "$JOB_TYPE" '{"action": "cron_disabled", "job": $job}'
    exit 0
fi

# ── Enable / Update ──────────────────────────────────────────────────────────

if [ -z "$SCHEDULE" ]; then
    echo '{"error": "Specify a schedule with --every, e.g. --every \"sunday 9am\" or --every \"daily 6am\""}'
    exit 1
fi

# Update config
jq --arg sched "$SCHEDULE" ".cron.${JOB_TYPE}.enabled = true | .cron.${JOB_TYPE}.schedule = \$sched" \
    "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
    && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

if [ -n "$BACKEND" ]; then
    jq --arg b "$BACKEND" ".cron.${JOB_TYPE}.backend = \$b" \
        "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
        && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
fi

ACTUAL_BACKEND=$(jq -r ".cron.${JOB_TYPE}.backend // \"cc\"" "$CONFIG_FILE")

# Register OpenClaw cron job
# The cron job calls wiki-entry.sh with the appropriate subcommand
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIKI_COMMAND="$SKILL_DIR/scripts/wiki-entry.sh $JOB_TYPE --backend $ACTUAL_BACKEND"

if [ "$JOB_TYPE" = "ingest" ]; then
    # Auto-ingest: scan sources/ for new files not in .ingested manifest
    WIKI_COMMAND="$SKILL_DIR/scripts/wiki-entry.sh ingest --auto --backend $ACTUAL_BACKEND"
fi

if command -v openclaw &>/dev/null; then
    openclaw cron set "wiki-${JOB_TYPE}" --schedule "$SCHEDULE" --command "$WIKI_COMMAND" 2>/dev/null || {
        jq -n --arg job "$JOB_TYPE" --arg sched "$SCHEDULE" \
            '{"warning": "Config updated but could not register OpenClaw cron job. Register manually.", "job": $job, "schedule": $sched}'
        exit 0
    }
fi

jq -n \
    --arg job "$JOB_TYPE" \
    --arg schedule "$SCHEDULE" \
    --arg backend "$ACTUAL_BACKEND" \
    --arg command "$WIKI_COMMAND" \
    '{
        action: "cron_enabled",
        job: $job,
        schedule: $schedule,
        backend: $backend,
        command: $command
    }'
