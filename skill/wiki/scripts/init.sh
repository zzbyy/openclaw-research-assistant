#!/bin/bash
# init.sh — Guided first-time wiki initialization
# Runs catalog, shows summary, then dispatches ingestion of selected papers.
#
# Usage: init.sh [--auto <count>]    # auto-pick <count> largest PDFs
#        init.sh [--topic <id>]
# Env: WIKI_BACKEND, WIKI_PATH, WIKI_SOURCES_PATH, WIKI_CONFIG_FILE

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse args ───────────────────────────────────────────────────────────────

AUTO_COUNT=""
TOPIC=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --auto)
            AUTO_COUNT="$2"
            shift 2
            ;;
        --topic)
            TOPIC="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# ── Step 1: Run catalog ─────────────────────────────────────────────────────

echo "Step 1/3: Cataloging all sources..." >&2
CATALOG_RESULT=$("$SCRIPT_DIR/catalog.sh" 2>/dev/null)
TOTAL=$(echo "$CATALOG_RESULT" | jq -r '.total')
PENDING=$(echo "$CATALOG_RESULT" | jq -r '.pending')
INGESTED=$(echo "$CATALOG_RESULT" | jq -r '.ingested')
BY_FORMAT=$(echo "$CATALOG_RESULT" | jq -r '.by_format')

echo "  Found $TOTAL documents ($INGESTED already ingested, $PENDING pending)" >&2
echo "$BY_FORMAT" | jq -r 'to_entries[] | "  - \(.key): \(.value)"' >&2
echo "" >&2

# ── Step 2: Select foundational papers ───────────────────────────────────────

# Find PDFs sorted by size (larger papers tend to be more comprehensive)
PDFS_DIR="$WIKI_SOURCES_PATH/pdfs"
CANDIDATES="[]"

if [ -d "$PDFS_DIR" ]; then
    # Get ingested manifest
    INGESTED_FILE="$WIKI_PATH/.ingested"

    while IFS=$'\t' read -r size filepath; do
        [ -z "$filepath" ] && continue
        filename="$(basename "$filepath")"

        # Skip already ingested
        if [ -f "$INGESTED_FILE" ] && grep -qF "$filename" "$INGESTED_FILE" 2>/dev/null; then
            continue
        fi

        # Title from filename
        title="${filename%.*}"
        title=$(echo "$title" | tr '-_' '  ')

        human_size="$((size / 1024))KB"
        [ "$size" -ge 1048576 ] && human_size="$((size / 1048576))MB"

        CANDIDATES=$(echo "$CANDIDATES" | jq \
            --arg path "$filepath" \
            --arg name "$filename" \
            --arg title "$title" \
            --arg size "$human_size" \
            --argjson bytes "$size" \
            '. + [{"path": $path, "filename": $name, "title": $title, "size": $size, "bytes": $bytes}]')
    done < <(find "$PDFS_DIR" -type f -name "*.pdf" -exec stat -f$'%z\t%N' {} \; 2>/dev/null || \
             find "$PDFS_DIR" -type f -name "*.pdf" -printf '%s\t%p\n' 2>/dev/null || true)

    # Sort by size descending (larger = likely more comprehensive)
    CANDIDATES=$(echo "$CANDIDATES" | jq 'sort_by(-.bytes)')
fi

CANDIDATE_COUNT=$(echo "$CANDIDATES" | jq 'length')

if [ "$CANDIDATE_COUNT" -eq 0 ]; then
    jq -n '{
        action: "init",
        status: "no_candidates",
        message: "No pending PDF files found in sources/pdfs/. Add some papers first, then run /wiki init again."
    }'
    exit 0
fi

echo "Step 2/3: Selecting foundational papers..." >&2
echo "  $CANDIDATE_COUNT pending PDFs found." >&2

# Pick papers: auto mode or suggest top N
PICK_COUNT="${AUTO_COUNT:-15}"
if [ "$PICK_COUNT" -gt "$CANDIDATE_COUNT" ]; then
    PICK_COUNT="$CANDIDATE_COUNT"
fi

SELECTED=$(echo "$CANDIDATES" | jq --argjson n "$PICK_COUNT" '.[:$n]')

echo "  Selected top $PICK_COUNT by file size (larger papers first):" >&2
echo "$SELECTED" | jq -r '.[] | "    - \(.title) (\(.size))"' >&2
echo "" >&2

# ── Step 3: Dispatch ingestion ───────────────────────────────────────────────

echo "Step 3/3: Dispatching ingestion..." >&2

RESULTS="[]"
IDX=0
TOTAL_SELECTED=$(echo "$SELECTED" | jq 'length')

echo "$SELECTED" | jq -c '.[]' | while IFS= read -r paper; do
    IDX=$((IDX + 1))
    FILEPATH=$(echo "$paper" | jq -r '.path')
    FILENAME=$(echo "$paper" | jq -r '.filename')
    TITLE=$(echo "$paper" | jq -r '.title')

    echo "  [$IDX/$TOTAL_SELECTED] Ingesting: $TITLE" >&2

    # Build ingest args
    INGEST_ARGS=("$FILEPATH")
    [ -n "$TOPIC" ] && INGEST_ARGS+=(--topic "$TOPIC")

    # Dispatch via ingest.sh
    RESULT=$("$SCRIPT_DIR/ingest.sh" "${INGEST_ARGS[@]}" 2>/dev/null || echo '{"error": "ingest failed"}')

    # Track in .ingested manifest
    echo "$FILENAME" >> "$WIKI_PATH/.ingested"

    echo "    -> dispatched" >&2
done

# ── Output ───────────────────────────────────────────────────────────────────

jq -n \
    --arg action "init" \
    --argjson total_sources "$TOTAL" \
    --argjson selected "$TOTAL_SELECTED" \
    --argjson pending_after "$((PENDING - TOTAL_SELECTED))" \
    --argjson papers "$SELECTED" \
    '{
        action: $action,
        total_sources: $total_sources,
        selected_for_ingestion: $selected,
        remaining_pending: $pending_after,
        papers: [$papers[] | {filename, title, size}],
        message: ("Wiki initialization started. " + ($selected | tostring) + " papers dispatched for ingestion. " + ($pending_after | tostring) + " remaining for later batches."),
        next_steps: [
            "Review results in Obsidian after ingestion completes",
            "Run /wiki status to check progress",
            "Run /wiki batch to continue ingesting more papers",
            "Run /wiki query to start asking questions"
        ]
    }'
