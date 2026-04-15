#!/bin/bash
# batch.sh — Batch ingest multiple source files
# Skips already-ingested files. Supports limits, format filters, filename patterns.
#
# Usage: batch.sh [--limit N] [--format pdf|html|epub|markdown] [--match <pattern>] [--dry-run] [--topic <id>]
# Env: WIKI_BACKEND, WIKI_PATH, WIKI_SOURCES_PATH, WIKI_CONFIG_FILE

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse args ───────────────────────────────────────────────────────────────

LIMIT=10
FORMAT_FILTER=""
MATCH_PATTERN=""
DRY_RUN=false
TOPIC=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --limit|-n)
            LIMIT="$2"
            shift 2
            ;;
        --format)
            FORMAT_FILTER="$2"
            shift 2
            ;;
        --match|-m)
            MATCH_PATTERN="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --topic)
            TOPIC="$2"
            shift 2
            ;;
        --all)
            LIMIT=999999
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# ── Load ingestion state ────────────────────────────────────────────────────

INGESTED_FILE="$WIKI_PATH/.ingested"
LOG_FILE="$WIKI_PATH/log.md"

# Build combined ingested list in a temp file (compatible with Bash 3)
INGESTED_TMP=$(mktemp)
trap 'rm -f "$INGESTED_TMP"' EXIT

if [ -f "$INGESTED_FILE" ]; then
    cat "$INGESTED_FILE" >> "$INGESTED_TMP"
fi

if [ -f "$LOG_FILE" ]; then
    while IFS='|' read -r _ _ op details _ _; do
        op=$(echo "$op" | xargs 2>/dev/null || true)
        [ "$op" = "ingest" ] || continue
        details=$(echo "$details" | xargs 2>/dev/null || true)
        [ -n "$details" ] && echo "$details" >> "$INGESTED_TMP"
    done < "$LOG_FILE"
fi

is_ingested() {
    grep -qxF "$1" "$INGESTED_TMP" 2>/dev/null
}

# ── Find pending files ──────────────────────────────────────────────────────

PENDING=()

for subdir in "$WIKI_SOURCES_PATH"/*/; do
    [ -d "$subdir" ] || continue
    FORMAT="$(basename "$subdir")"

    # Apply format filter
    if [ -n "$FORMAT_FILTER" ] && [ "$FORMAT" != "$FORMAT_FILTER" ]; then
        continue
    fi

    for file in "$subdir"/*; do
        [ -f "$file" ] || continue
        FILENAME="$(basename "$file")"

        # Skip already ingested
        is_ingested "$FILENAME" && continue

        # Apply match pattern (case-insensitive grep on filename)
        if [ -n "$MATCH_PATTERN" ]; then
            echo "$FILENAME" | grep -qi "$MATCH_PATTERN" 2>/dev/null || continue
        fi

        PENDING+=("$file")
    done
done

TOTAL_PENDING=${#PENDING[@]}

if [ "$TOTAL_PENDING" -eq 0 ]; then
    jq -n '{
        action: "batch",
        status: "nothing_to_do",
        message: "No pending files match the criteria. All sources may already be ingested."
    }'
    exit 0
fi

# Apply limit
BATCH_SIZE="$LIMIT"
if [ "$BATCH_SIZE" -gt "$TOTAL_PENDING" ]; then
    BATCH_SIZE="$TOTAL_PENDING"
fi

# ── Dry run ──────────────────────────────────────────────────────────────────

if [ "$DRY_RUN" = true ]; then
    FILENAMES="[]"
    for ((i=0; i<BATCH_SIZE; i++)); do
        file="${PENDING[$i]}"
        FILENAMES=$(echo "$FILENAMES" | jq --arg f "$(basename "$file")" '. + [$f]')
    done

    jq -n \
        --arg action "batch_dry_run" \
        --argjson total_pending "$TOTAL_PENDING" \
        --argjson batch_size "$BATCH_SIZE" \
        --argjson files "$FILENAMES" \
        '{
            action: $action,
            total_pending: $total_pending,
            batch_size: $batch_size,
            files: $files,
            message: ("Dry run: would ingest " + ($batch_size | tostring) + " of " + ($total_pending | tostring) + " pending files.")
        }'
    exit 0
fi

# ── Dispatch batch ───────────────────────────────────────────────────────────

DISPATCHED=0
FAILED=0

for ((i=0; i<BATCH_SIZE; i++)); do
    file="${PENDING[$i]}"
    FILENAME="$(basename "$file")"

    echo "[$((i+1))/$BATCH_SIZE] Ingesting: $FILENAME" >&2

    # Build ingest args
    INGEST_ARGS=("$file")
    [ -n "$TOPIC" ] && INGEST_ARGS+=(--topic "$TOPIC")

    # Dispatch via ingest.sh
    if "$SCRIPT_DIR/ingest.sh" "${INGEST_ARGS[@]}" >/dev/null 2>&1; then
        # Track in .ingested manifest
        echo "$FILENAME" >> "$INGESTED_FILE"
        DISPATCHED=$((DISPATCHED + 1))
    else
        echo "  [!!] Failed: $FILENAME" >&2
        FAILED=$((FAILED + 1))
    fi
done

REMAINING=$((TOTAL_PENDING - BATCH_SIZE))

# ── Output ───────────────────────────────────────────────────────────────────

jq -n \
    --arg action "batch" \
    --argjson total_pending "$TOTAL_PENDING" \
    --argjson batch_size "$BATCH_SIZE" \
    --argjson dispatched "$DISPATCHED" \
    --argjson failed "$FAILED" \
    --argjson remaining "$REMAINING" \
    '{
        action: $action,
        total_pending: $total_pending,
        batch_size: $batch_size,
        dispatched: $dispatched,
        failed: $failed,
        remaining: $remaining,
        message: ("Batch complete. " + ($dispatched | tostring) + " dispatched, " + ($failed | tostring) + " failed, " + ($remaining | tostring) + " remaining.")
    }'
