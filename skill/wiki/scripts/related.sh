#!/bin/bash
# related.sh — Find related pages via typed relationships
# Reads a page's frontmatter and follows depends_on, used_by, supersedes, related links.
#
# Usage: related.sh <page-name>
# Env: WIKI_PATH

set -e

PAGE_NAME="$*"

if [ -z "$PAGE_NAME" ]; then
    echo '{"error": "Usage: /wiki related <page-name>"}'
    exit 1
fi

PAGES_DIR="$WIKI_PATH/pages"
PAGE_NAME=$(echo "$PAGE_NAME" | sed 's/\.md$//; s/ /-/g' | tr '[:upper:]' '[:lower:]')
PAGE_FILE="$PAGES_DIR/${PAGE_NAME}.md"

if [ ! -f "$PAGE_FILE" ]; then
    jq -n --arg name "$PAGE_NAME" '{"error": ("Page not found: " + $name)}'
    exit 1
fi

# Extract typed relationships from frontmatter
extract_links() {
    local field="$1"
    local file="$2"
    awk -v field="$field:" '
        /^---$/ { n++; next }
        n == 1 && $0 ~ "^"field { capture=1; next }
        n == 1 && capture && /^  - / {
            gsub(/^  - "?\[\[|"?\]\]"?/, "", $0)
            print
            next
        }
        n == 1 && capture && !/^  - / { capture=0 }
        n >= 2 { exit }
    ' "$file" 2>/dev/null
}

build_relation_json() {
    local relation_type="$1"
    local links="$2"
    local result="[]"

    while IFS= read -r link; do
        [ -z "$link" ] && continue
        LINK_FILE="$PAGES_DIR/${link}.md"
        EXISTS=false
        TITLE="$link"
        TYPE="unknown"
        if [ -f "$LINK_FILE" ]; then
            EXISTS=true
            TITLE=$(awk '/^---$/{n++; next} n==1 && /^title:/{gsub(/^title: *"?|"? *$/,"",$0); sub(/^title: */,"",$0); print; exit}' "$LINK_FILE" 2>/dev/null || echo "$link")
            TYPE=$(awk '/^---$/{n++; next} n==1 && /^type:/{print $2; exit}' "$LINK_FILE" 2>/dev/null || echo "unknown")
        fi
        result=$(echo "$result" | jq \
            --arg name "$link" \
            --arg title "$TITLE" \
            --arg type "$TYPE" \
            --argjson exists "$EXISTS" \
            '. + [{"page": $name, "title": $title, "type": $type, "exists": $exists}]')
    done <<< "$links"

    echo "$result"
}

DEPENDS_ON=$(extract_links "depends_on" "$PAGE_FILE")
USED_BY=$(extract_links "used_by" "$PAGE_FILE")
SUPERSEDES=$(extract_links "supersedes" "$PAGE_FILE")
RELATED=$(extract_links "related" "$PAGE_FILE")
AUTHORED_BY=$(extract_links "authored_by" "$PAGE_FILE")

# Also find pages that link TO this page (reverse references)
BACKLINKS="[]"
for page in "$PAGES_DIR"/*.md; do
    [ -f "$page" ] || continue
    OTHER_NAME="$(basename "$page" .md)"
    [ "$OTHER_NAME" = "$PAGE_NAME" ] && continue
    if grep -q "\[\[$PAGE_NAME\]\]" "$page" 2>/dev/null; then
        OTHER_TITLE=$(awk '/^---$/{n++; next} n==1 && /^title:/{gsub(/^title: *"?|"? *$/,"",$0); sub(/^title: */,"",$0); print; exit}' "$page" 2>/dev/null || echo "$OTHER_NAME")
        BACKLINKS=$(echo "$BACKLINKS" | jq --arg name "$OTHER_NAME" --arg title "$OTHER_TITLE" \
            '. + [{"page": $name, "title": $title}]')
    fi
done

jq -n \
    --arg action "related" \
    --arg page "$PAGE_NAME" \
    --argjson depends_on "$(build_relation_json "depends_on" "$DEPENDS_ON")" \
    --argjson used_by "$(build_relation_json "used_by" "$USED_BY")" \
    --argjson supersedes "$(build_relation_json "supersedes" "$SUPERSEDES")" \
    --argjson related "$(build_relation_json "related" "$RELATED")" \
    --argjson authored_by "$(build_relation_json "authored_by" "$AUTHORED_BY")" \
    --argjson backlinks "$BACKLINKS" \
    '{
        action: $action,
        page: $page,
        relationships: {
            depends_on: $depends_on,
            used_by: $used_by,
            supersedes: $supersedes,
            related: $related,
            authored_by: $authored_by
        },
        backlinks: $backlinks
    }'
