#!/bin/bash
# search.sh — Search wiki pages by keyword
# Always runs locally (no need for Claude Code dispatch).
#
# Usage: search.sh <search-term...>
# Env: WIKI_PATH

set -e

# Bootstrap: resolve config if not called via wiki-entry.sh
source "$(dirname "${BASH_SOURCE[0]}")/_bootstrap.sh"

QUERY="$*"

if [ -z "$QUERY" ]; then
    echo '{"error": "Usage: /wiki search <term>"}'
    exit 1
fi

PAGES_DIR="$WIKI_PATH/pages"

if [ ! -d "$PAGES_DIR" ]; then
    jq -n '{"results": [], "total": 0, "message": "No wiki pages yet."}'
    exit 0
fi

# Search in page content and filenames
RESULTS="[]"
COUNT=0

# Search filenames
for page in "$PAGES_DIR"/*.md; do
    [ -f "$page" ] || continue
    PAGE_NAME="$(basename "$page" .md)"
    TITLE=$(awk '/^---$/{n++; next} n==1 && /^title:/{gsub(/^title: *"?|"? *$/,"",$0); sub(/^title: */,"",$0); print; exit}' "$page" 2>/dev/null || echo "$PAGE_NAME")

    # Check filename match
    FILENAME_MATCH=false
    if echo "$PAGE_NAME" | grep -qi "$(echo "$QUERY" | tr ' ' '.')" 2>/dev/null; then
        FILENAME_MATCH=true
    fi

    # Check content match — get matching lines with context
    CONTENT_MATCHES=$(grep -in "$QUERY" "$page" 2>/dev/null | head -3 || true)

    if [ "$FILENAME_MATCH" = true ] || [ -n "$CONTENT_MATCHES" ]; then
        # Get entity type from frontmatter
        TYPE=$(awk '/^---$/{n++; next} n==1 && /^type:/{print $2; exit}' "$page" 2>/dev/null || echo "unknown")
        CONFIDENCE=$(awk '/^---$/{n++; next} n==1 && /^confidence:/{print $2; exit}' "$page" 2>/dev/null || echo "")

        SNIPPET=""
        if [ -n "$CONTENT_MATCHES" ]; then
            SNIPPET=$(echo "$CONTENT_MATCHES" | head -1 | sed 's/^[0-9]*://' | head -c 200)
        fi

        RESULTS=$(echo "$RESULTS" | jq \
            --arg name "$PAGE_NAME" \
            --arg title "$TITLE" \
            --arg type "$TYPE" \
            --arg confidence "$CONFIDENCE" \
            --arg snippet "$SNIPPET" \
            --argjson filename_match "$FILENAME_MATCH" \
            '. + [{
                page: $name,
                title: $title,
                type: $type,
                confidence: $confidence,
                snippet: $snippet,
                filename_match: $filename_match
            }]')
        COUNT=$((COUNT + 1))
    fi
done

jq -n \
    --arg query "$QUERY" \
    --argjson results "$RESULTS" \
    --argjson total "$COUNT" \
    '{
        action: "search",
        query: $query,
        total: $total,
        results: $results
    }'
