#!/bin/bash
# browse.sh — Browse a specific topic or page
# Reads and returns the content of a wiki page.
#
# Usage: browse.sh <page-name>
# Env: WIKI_PATH

set -e

# Bootstrap: resolve config if not called via wiki-entry.sh
source "$(dirname "${BASH_SOURCE[0]}")/_bootstrap.sh"

PAGE_NAME="$*"

if [ -z "$PAGE_NAME" ]; then
    echo '{"error": "Usage: /wiki browse <page-name>"}'
    exit 1
fi

# Normalize: remove .md extension if provided
PAGE_NAME=$(echo "$PAGE_NAME" | sed 's/\.md$//')

# Search across all type subdirectories (not just pages/)
PAGE_FILE=$(find "$WIKI_PATH" -name "${PAGE_NAME}.md" -not -path '*/.*' -type f 2>/dev/null | head -1)

# Try case-insensitive if exact match fails
if [ -z "$PAGE_FILE" ]; then
    PAGE_FILE=$(find "$WIKI_PATH" -iname "${PAGE_NAME}.md" -not -path '*/.*' -type f 2>/dev/null | head -1)
fi

if [ -z "$PAGE_FILE" ]; then
    # Try fuzzy match
    MATCHES=$(find "$WIKI_PATH" -iname "*${PAGE_NAME}*" -not -path '*/.*' -not -name 'index.md' -not -name 'log.md' -type f 2>/dev/null | head -5 || true)
    if [ -n "$MATCHES" ]; then
        SUGGESTIONS=$(echo "$MATCHES" | while read -r m; do basename "$m" .md; done | jq -R . | jq -s .)
        jq -n --arg name "$PAGE_NAME" --argjson suggestions "$SUGGESTIONS" \
            '{"error": ("Page not found: " + $name), "suggestions": $suggestions}'
    else
        jq -n --arg name "$PAGE_NAME" '{"error": ("Page not found: " + $name), "suggestions": []}'
    fi
    exit 1
fi

CONTENT=$(cat "$PAGE_FILE")

jq -n \
    --arg action "browse" \
    --arg page "$PAGE_NAME" \
    --arg path "$PAGE_FILE" \
    --arg content "$CONTENT" \
    '{
        action: $action,
        page: $page,
        path: $path,
        content: $content
    }'
