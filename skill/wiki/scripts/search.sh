#!/bin/bash
# search.sh — Search wiki pages by keyword or semantic similarity
# Uses QMD when available (hybrid search), falls back to grep.
# Always runs locally (no Claude Code dispatch).
#
# Usage: search.sh <search-term...> [--semantic]
# Env: WIKI_PATH

set -e

# Bootstrap: resolve config if not called via wiki-entry.sh
source "$(dirname "${BASH_SOURCE[0]}")/_bootstrap.sh"

# ── Parse args ───────────────────────────────────────────────────────────────

SEMANTIC=false
QUERY_PARTS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --semantic|-s)
            SEMANTIC=true
            shift
            ;;
        *)
            QUERY_PARTS+=("$1")
            shift
            ;;
    esac
done

QUERY="${QUERY_PARTS[*]}"

if [ -z "$QUERY" ]; then
    echo '{"error": "Usage: /wiki search <term> [--semantic]"}'
    exit 1
fi

# ── Try QMD first ────────────────────────────────────────────────────────────

if command -v qmd &>/dev/null; then
    SEARCH_METHOD="qmd"

    if [ "$SEMANTIC" = true ]; then
        # Full hybrid: BM25 + vector + reranker
        QMD_RESULTS=$(qmd query "$QUERY" -n 15 --format json 2>/dev/null || echo "")
    else
        # Keyword only (faster)
        QMD_RESULTS=$(qmd search "$QUERY" -n 15 --format json 2>/dev/null || echo "")
    fi

    if [ -n "$QMD_RESULTS" ] && echo "$QMD_RESULTS" | jq -e '.' >/dev/null 2>&1; then
        RESULTS=$(echo "$QMD_RESULTS" | jq '[.[] | {
            page: (.path | split("/") | last | rtrimstr(".md")),
            title: (.title // (.path | split("/") | last | rtrimstr(".md"))),
            snippet: (.content // .chunk // "")[0:200],
            score: (.score // 0)
        }]' 2>/dev/null || echo "[]")
        TOTAL=$(echo "$RESULTS" | jq 'length')

        jq -n \
            --arg action "search" \
            --arg query "$QUERY" \
            --arg search_method "$SEARCH_METHOD" \
            --argjson results "$RESULTS" \
            --argjson total "$TOTAL" \
            '{action: $action, query: $query, search_method: $search_method, total: $total, results: $results}'
        exit 0
    fi
fi

# ── Fallback to grep ─────────────────────────────────────────────────────────

SEARCH_METHOD="grep"

# Find all wiki pages across type subdirectories (exclude hidden dirs)
WIKI_PAGES=$(find "$WIKI_PATH" -name '*.md' -not -path '*/.*' -not -name 'index.md' -not -name 'log.md' -type f 2>/dev/null)

if [ -z "$WIKI_PAGES" ]; then
    jq -n '{"results": [], "total": 0, "search_method": "grep", "message": "No wiki pages yet."}'
    exit 0
fi

RESULTS="[]"
COUNT=0

echo "$WIKI_PAGES" | while IFS= read -r page; do
    [ -f "$page" ] || continue
    PAGE_NAME="$(basename "$page" .md)"
    TITLE=$(awk '/^---$/{n++; next} n==1 && /^title:/{gsub(/^title: *"?|"? *$/,"",$0); sub(/^title: */,"",$0); print; exit}' "$page" 2>/dev/null || echo "$PAGE_NAME")

    # Check filename match
    FILENAME_MATCH=false
    if echo "$PAGE_NAME" | grep -qi "$(echo "$QUERY" | tr ' ' '.')" 2>/dev/null; then
        FILENAME_MATCH=true
    fi

    # Check content match
    CONTENT_MATCHES=$(grep -in "$QUERY" "$page" 2>/dev/null | head -3 || true)

    if [ "$FILENAME_MATCH" = true ] || [ -n "$CONTENT_MATCHES" ]; then
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
            '. + [{page: $name, title: $title, type: $type, confidence: $confidence, snippet: $snippet, filename_match: $filename_match}]')
        COUNT=$((COUNT + 1))
    fi
done

jq -n \
    --arg action "search" \
    --arg query "$QUERY" \
    --arg search_method "$SEARCH_METHOD" \
    --argjson results "$RESULTS" \
    --argjson total "$COUNT" \
    '{action: $action, query: $query, search_method: $search_method, total: $total, results: $results}'
