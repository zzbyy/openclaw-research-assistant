#!/bin/bash
# catalog.sh — Scan sources/ and build a lightweight catalog of all documents
# No deep ingestion — just metadata from filenames, file size, format.
# Creates/updates wiki/catalog.md and marks ingestion status.
# Optimized for large collections (1000+ files) — bulk operations, minimal subprocesses.
#
# Usage: catalog.sh [--format pdf|html|epub|markdown] [--quick]
# Env: WIKI_PATH, WIKI_SOURCES_PATH

set -e

# Bootstrap: resolve config if not called via wiki-entry.sh
source "$(dirname "${BASH_SOURCE[0]}")/_bootstrap.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse args ───────────────────────────────────────────────────────────────

FORMAT_FILTER=""
QUICK=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --format)
            FORMAT_FILTER="$2"
            shift 2
            ;;
        --quick)
            QUICK=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# ── Setup ────────────────────────────────────────────────────────────────────

CATALOG_FILE="$WIKI_PATH/.catalog.json"
INGESTED_FILE="$WIKI_PATH/.ingested"
LOG_FILE="$WIKI_PATH/log.md"

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# Build combined ingested list
INGESTED_TMP="$TMPDIR_WORK/ingested"
touch "$INGESTED_TMP"

[ -f "$INGESTED_FILE" ] && cat "$INGESTED_FILE" >> "$INGESTED_TMP"

if [ -f "$LOG_FILE" ]; then
    awk -F'|' '$3 ~ /ingest/ { gsub(/^ +| +$/, "", $4); if ($4 != "") print $4 }' "$LOG_FILE" >> "$INGESTED_TMP"
fi

# Sort and deduplicate for fast lookup
sort -u "$INGESTED_TMP" -o "$INGESTED_TMP"

# ── Quick mode: counts only, no catalog.md ───────────────────────────────────

if [ "$QUICK" = true ]; then
    FORMAT_JSON="{}"
    TOTAL=0
    for subdir in "$WIKI_SOURCES_PATH"/*/; do
        [ -d "$subdir" ] || continue
        FORMAT="$(basename "$subdir")"
        [ -n "$FORMAT_FILTER" ] && [ "$FORMAT" != "$FORMAT_FILTER" ] && continue
        COUNT=$(find "$subdir" -maxdepth 1 -type f | wc -l | tr -d ' ')
        TOTAL=$((TOTAL + COUNT))
        FORMAT_JSON=$(echo "$FORMAT_JSON" | jq --arg f "$FORMAT" --argjson c "$COUNT" '.[$f] = $c')
    done

    INGESTED_COUNT=$(wc -l < "$INGESTED_TMP" | tr -d ' ')
    PENDING=$((TOTAL - INGESTED_COUNT))
    [ "$PENDING" -lt 0 ] && PENDING=0

    jq -n \
        --arg action "catalog" \
        --argjson total "$TOTAL" \
        --argjson ingested "$INGESTED_COUNT" \
        --argjson pending "$PENDING" \
        --argjson by_format "$FORMAT_JSON" \
        '{
            action: $action,
            total: $total,
            ingested: $ingested,
            pending: $pending,
            by_format: $by_format,
            message: ("Quick catalog: " + ($total | tostring) + " documents (" + ($ingested | tostring) + " ingested, " + ($pending | tostring) + " pending).")
        }'
    exit 0
fi

# ── Full catalog: build .catalog.json ────────────────────────────────────────

# Hidden JSON file — machine-readable, fast to load, invisible in Obsidian
ENTRIES_TMP="$TMPDIR_WORK/entries.jsonl"
FORMAT_TMP="$TMPDIR_WORK/formats"

TOTAL=0
TOTAL_INGESTED=0
TOTAL_PENDING=0

for subdir in "$WIKI_SOURCES_PATH"/*/; do
    [ -d "$subdir" ] || continue
    FORMAT="$(basename "$subdir")"
    [ -n "$FORMAT_FILTER" ] && [ "$FORMAT" != "$FORMAT_FILTER" ] && continue

    # Get all files with sizes in one find call (macOS stat format)
    find "$subdir" -maxdepth 1 -type f -exec stat -f '%z %N' {} \; 2>/dev/null | \
    while IFS= read -r line; do
        SIZE="${line%% *}"
        FILEPATH="${line#* }"
        FILENAME="$(basename "$FILEPATH")"

        # Ingestion status
        if grep -qxF "$FILENAME" "$INGESTED_TMP" 2>/dev/null; then
            STATUS="ingested"
        else
            STATUS="pending"
        fi

        # Output as JSON line (compact)
        jq -cn --arg f "$FILENAME" --arg fmt "$FORMAT" --argjson sz "$SIZE" --arg st "$STATUS" \
            '{filename:$f, format:$fmt, size:$sz, status:$st}'
    done
done > "$ENTRIES_TMP"

# Count totals
TOTAL=$(wc -l < "$ENTRIES_TMP" | tr -d ' ')
TOTAL_INGESTED=$(grep -c '"ingested"' "$ENTRIES_TMP" 2>/dev/null || echo "0")
TOTAL_PENDING=$((TOTAL - TOTAL_INGESTED))

# Format counts
for subdir in "$WIKI_SOURCES_PATH"/*/; do
    [ -d "$subdir" ] || continue
    FORMAT="$(basename "$subdir")"
    [ -n "$FORMAT_FILTER" ] && [ "$FORMAT" != "$FORMAT_FILTER" ] && continue
    COUNT=$(grep -c "\"$FORMAT\"" "$ENTRIES_TMP" 2>/dev/null || echo "0")
    [ "$COUNT" -gt 0 ] && echo "$FORMAT $COUNT"
done > "$FORMAT_TMP"

# ── Write .catalog.json ─────────────────────────────────────────────────────

FORMAT_JSON="{}"
while read -r fmt count; do
    FORMAT_JSON=$(echo "$FORMAT_JSON" | jq --arg f "$fmt" --argjson c "$count" '.[$f] = $c')
done < "$FORMAT_TMP"

# Combine JSONL entries into a JSON array and wrap with metadata
jq -s --argjson total "$TOTAL" --argjson ingested "$TOTAL_INGESTED" \
    --argjson pending "$TOTAL_PENDING" --argjson by_format "$FORMAT_JSON" \
    --arg updated "$(date +%Y-%m-%d)" \
    '{
        updated: $updated,
        total: $total,
        ingested: $ingested,
        pending: $pending,
        by_format: $by_format,
        entries: .
    }' "$ENTRIES_TMP" > "$CATALOG_FILE"

# ── Output JSON summary ─────────────────────────────────────────────────────

jq -n \
    --arg action "catalog" \
    --argjson total "$TOTAL" \
    --argjson ingested "$TOTAL_INGESTED" \
    --argjson pending "$TOTAL_PENDING" \
    --argjson by_format "$FORMAT_JSON" \
    --arg catalog_file "$CATALOG_FILE" \
    '{
        action: $action,
        total: $total,
        ingested: $ingested,
        pending: $pending,
        by_format: $by_format,
        catalog_file: $catalog_file,
        message: ("Catalog written to .catalog.json. " + ($total | tostring) + " documents (" + ($ingested | tostring) + " ingested, " + ($pending | tostring) + " pending).")
    }'
