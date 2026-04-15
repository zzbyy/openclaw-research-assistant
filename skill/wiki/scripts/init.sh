#!/bin/bash
# init.sh — First-time wiki initialization
# Runs catalog to show what you have, then dispatches batch ingestion.
#
# Usage: init.sh [--limit <count>] [--format <type>] [--topic <id>]
# Env: WIKI_BACKEND, WIKI_PATH, WIKI_SOURCES_PATH, WIKI_CONFIG_FILE

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse args ───────────────────────────────────────────────────────────────

LIMIT="15"
FORMAT=""
TOPIC=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --limit|-n)
            LIMIT="$2"
            shift 2
            ;;
        --format)
            FORMAT="$2"
            shift 2
            ;;
        --topic)
            TOPIC="$2"
            shift 2
            ;;
        --all)
            LIMIT="999999"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# ── Step 1: Run catalog ─────────────────────────────────────────────────────

echo "Step 1/2: Counting sources..." >&2
CATALOG_RESULT=$("$SCRIPT_DIR/catalog.sh" --quick 2>/dev/null)
TOTAL=$(echo "$CATALOG_RESULT" | jq -r '.total')
PENDING=$(echo "$CATALOG_RESULT" | jq -r '.pending')
INGESTED=$(echo "$CATALOG_RESULT" | jq -r '.ingested')
BY_FORMAT=$(echo "$CATALOG_RESULT" | jq -r '.by_format')

echo "  Found $TOTAL documents ($INGESTED already ingested, $PENDING pending)" >&2
echo "$BY_FORMAT" | jq -r 'to_entries[] | "  - \(.key): \(.value)"' >&2
echo "" >&2

if [ "$PENDING" -eq 0 ]; then
    jq -n --argjson total "$TOTAL" --argjson ingested "$INGESTED" '{
        action: "init",
        status: "all_ingested",
        total: $total,
        ingested: $ingested,
        message: "All sources are already ingested. Nothing to do."
    }'
    exit 0
fi

# ── Step 2: Dispatch batch ───────────────────────────────────────────────────

echo "Step 2/2: Dispatching batch ingestion (limit: $LIMIT)..." >&2

BATCH_ARGS=(--limit "$LIMIT")
[ -n "$FORMAT" ] && BATCH_ARGS+=(--format "$FORMAT")
[ -n "$TOPIC" ] && BATCH_ARGS+=(--topic "$TOPIC")

BATCH_RESULT=$("$SCRIPT_DIR/batch.sh" "${BATCH_ARGS[@]}" 2>/dev/null)
DISPATCHED=$(echo "$BATCH_RESULT" | jq -r '.dispatched // 0')
REMAINING=$(echo "$BATCH_RESULT" | jq -r '.remaining // 0')

# ── Output ───────────────────────────────────────────────────────────────────

jq -n \
    --arg action "init" \
    --argjson total_sources "$TOTAL" \
    --argjson dispatched "$DISPATCHED" \
    --argjson remaining "$REMAINING" \
    --argjson by_format "$BY_FORMAT" \
    '{
        action: $action,
        total_sources: $total_sources,
        dispatched: $dispatched,
        remaining: $remaining,
        by_format: $by_format,
        message: ("Wiki initialization started. " + ($dispatched | tostring) + " documents dispatched for ingestion. " + ($remaining | tostring) + " remaining for later batches."),
        next_steps: [
            "Review results in Obsidian after ingestion completes",
            "Run /wiki status to check progress",
            "Run /wiki batch --limit 10 to continue ingesting more",
            "Run /wiki query to start asking questions"
        ]
    }'
