#!/bin/bash
# status.sh — Wiki statistics and health overview
# Always runs locally.
#
# Usage: status.sh
# Env: WIKI_PATH, WIKI_SOURCES_PATH

set -e

# Bootstrap: resolve config if not called via wiki-entry.sh
source "$(dirname "${BASH_SOURCE[0]}")/_bootstrap.sh"

PAGES_DIR="$WIKI_PATH/pages"
INDEX_FILE="$WIKI_PATH/index.md"
LOG_FILE="$WIKI_PATH/log.md"

# ── Page counts ──────────────────────────────────────────────────────────────

TOTAL_PAGES=0
TYPE_COUNTS="{}"
CONFIDENCE_COUNTS='{"high": 0, "medium": 0, "low": 0}'
STATUS_COUNTS='{"draft": 0, "consolidated": 0, "stale": 0}'

if [ -d "$PAGES_DIR" ]; then
    for page in "$PAGES_DIR"/*.md; do
        [ -f "$page" ] || continue
        TOTAL_PAGES=$((TOTAL_PAGES + 1))

        TYPE=$(awk '/^---$/{n++; next} n==1 && /^type:/{print $2; exit}' "$page" 2>/dev/null || echo "unknown")
        CONF=$(awk '/^---$/{n++; next} n==1 && /^confidence:/{print $2; exit}' "$page" 2>/dev/null || echo "unknown")
        STAT=$(awk '/^---$/{n++; next} n==1 && /^status:/{print $2; exit}' "$page" 2>/dev/null || echo "unknown")

        TYPE_COUNTS=$(echo "$TYPE_COUNTS" | jq --arg t "$TYPE" '.[$t] = ((.[$t] // 0) + 1)')
        CONFIDENCE_COUNTS=$(echo "$CONFIDENCE_COUNTS" | jq --arg c "$CONF" 'if .[$c] != null then .[$c] += 1 else . end')
        STATUS_COUNTS=$(echo "$STATUS_COUNTS" | jq --arg s "$STAT" 'if .[$s] != null then .[$s] += 1 else . end')
    done
fi

# ── Source counts ────────────────────────────────────────────────────────────

SOURCE_COUNTS="{}"
TOTAL_SOURCES=0

if [ -d "$WIKI_SOURCES_PATH" ]; then
    for subdir in "$WIKI_SOURCES_PATH"/*/; do
        [ -d "$subdir" ] || continue
        FORMAT="$(basename "$subdir")"
        COUNT=$(find "$subdir" -maxdepth 1 -type f | wc -l | tr -d ' ')
        TOTAL_SOURCES=$((TOTAL_SOURCES + COUNT))
        SOURCE_COUNTS=$(echo "$SOURCE_COUNTS" | jq --arg f "$FORMAT" --argjson c "$COUNT" '.[$f] = $c')
    done
fi

# ── Recent activity ──────────────────────────────────────────────────────────

RECENT_ACTIVITY="[]"
if [ -f "$LOG_FILE" ]; then
    # Get last 5 non-header lines from log table
    RECENT_ACTIVITY=$(tail -10 "$LOG_FILE" | grep '^|' | grep -v '^| Date' | grep -v '^|---' | tail -5 | \
        while IFS='|' read -r _ date op details pages notes _; do
            date=$(echo "$date" | xargs)
            op=$(echo "$op" | xargs)
            details=$(echo "$details" | xargs)
            jq -n --arg d "$date" --arg o "$op" --arg det "$details" \
                '{"date": $d, "operation": $o, "details": $det}'
        done | jq -s '.' 2>/dev/null || echo "[]")
fi

# ── Output ───────────────────────────────────────────────────────────────────

jq -n \
    --arg wiki_path "$WIKI_PATH" \
    --argjson total_pages "$TOTAL_PAGES" \
    --argjson total_sources "$TOTAL_SOURCES" \
    --argjson type_counts "$TYPE_COUNTS" \
    --argjson confidence_counts "$CONFIDENCE_COUNTS" \
    --argjson status_counts "$STATUS_COUNTS" \
    --argjson source_counts "$SOURCE_COUNTS" \
    --argjson recent_activity "$RECENT_ACTIVITY" \
    '{
        action: "status",
        wiki_path: $wiki_path,
        pages: {
            total: $total_pages,
            by_type: $type_counts,
            by_confidence: $confidence_counts,
            by_status: $status_counts
        },
        sources: {
            total: $total_sources,
            by_format: $source_counts
        },
        recent_activity: $recent_activity
    }'
