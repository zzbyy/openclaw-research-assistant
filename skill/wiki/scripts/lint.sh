#!/bin/bash
# lint.sh — Health-check the wiki for contradictions, orphans, staleness
# Full lint via Claude Code, or lightweight local checks for agent mode.
#
# Usage: lint.sh [--topic <id>]
# Env: WIKI_BACKEND (cc|agent), WIKI_PATH, WIKI_CONFIG_FILE

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse args ───────────────────────────────────────────────────────────────

TOPIC=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --topic)
            TOPIC="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# ── Dispatch ─────────────────────────────────────────────────────────────────

if [ "$WIKI_BACKEND" = "cc" ]; then
    _wiki_config() {
        [ -f "$WIKI_CONFIG_FILE" ] && jq -r "$1 // empty" "$WIKI_CONFIG_FILE" 2>/dev/null || echo ""
    }

    DISPATCH_PATH="$(_wiki_config '.cc_bridge.dispatch_path')"
    CC_MODEL="$(_wiki_config '.cc_bridge.model')"
    CC_TIMEOUT="$(_wiki_config '.cc_bridge.timeout_minutes')"

    if [[ "$DISPATCH_PATH" == '~/'* ]]; then
        DISPATCH_PATH="$HOME/${DISPATCH_PATH:2}"
    fi

    if [ ! -f "$DISPATCH_PATH" ]; then
        jq -n --arg p "$DISPATCH_PATH" \
            '{"error": ("cc-bridge dispatch.sh not found at: " + $p + ". Install cc-bridge or use --backend agent")}'
        exit 1
    fi

    STALE_DAYS="$(_wiki_config '.confidence.stale_after_days')"

    PROMPT="Lint the wiki — perform a full health check. Follow the wiki schema in .schema.md.

Instructions:
1. Contradiction scan: find pages with conflicting claims
2. Orphan detection: find pages not linked from index.md or any other page
3. Broken wikilinks: find [[links]] that point to non-existent pages
4. Missing cross-references: find pages discussing same topics without linking each other
5. Confidence decay: pages with last_verified older than ${STALE_DAYS:-90} days → mark stale, lower confidence
6. Entity relationship integrity: verify typed relationship links are valid and bidirectional
7. Index completeness: verify all pages in pages/ appear in index.md
8. Produce a structured report with findings per check
9. Append to log.md: date, 'lint', summary of findings"

    DISPATCH_ARGS=(--dir "$WIKI_PATH")
    [ -n "$CC_MODEL" ] && DISPATCH_ARGS+=(--model "$CC_MODEL")
    [ -n "$CC_TIMEOUT" ] && DISPATCH_ARGS+=(--timeout "$CC_TIMEOUT")
    [ -n "$TOPIC" ] && DISPATCH_ARGS+=(--topic "$TOPIC")

    exec "$DISPATCH_PATH" "${DISPATCH_ARGS[@]}" -- "$PROMPT"

else
    # Backend: agent — lightweight local checks
    PAGES_DIR="$WIKI_PATH/pages"
    INDEX_FILE="$WIKI_PATH/index.md"

    TOTAL_PAGES=0
    ORPHAN_PAGES=()
    BROKEN_LINKS=()
    STALE_PAGES=()

    if [ -d "$PAGES_DIR" ]; then
        STALE_DAYS="$([ -f "$WIKI_CONFIG_FILE" ] && jq -r '.confidence.stale_after_days // 90' "$WIKI_CONFIG_FILE" 2>/dev/null || echo 90)"
        STALE_CUTOFF=$(date -v-"${STALE_DAYS}"d +%Y-%m-%d 2>/dev/null || date -d "${STALE_DAYS} days ago" +%Y-%m-%d 2>/dev/null || echo "")

        for page in "$PAGES_DIR"/*.md; do
            [ -f "$page" ] || continue
            TOTAL_PAGES=$((TOTAL_PAGES + 1))
            PAGE_NAME="$(basename "$page" .md)"

            # Check if page is in index
            if [ -f "$INDEX_FILE" ] && ! grep -q "\[\[$PAGE_NAME\]\]" "$INDEX_FILE" 2>/dev/null; then
                ORPHAN_PAGES+=("$PAGE_NAME")
            fi

            # Check for broken wikilinks
            LINKS=$(grep -oE '\[\[[^]]+\]\]' "$page" 2>/dev/null | sed 's/\[\[//g;s/\]\]//g' || true)
            while IFS= read -r link; do
                [ -z "$link" ] && continue
                # Skip source links
                [[ "$link" == ../sources/* ]] && continue
                LINK_FILE="$PAGES_DIR/${link}.md"
                if [ ! -f "$LINK_FILE" ]; then
                    BROKEN_LINKS+=("$PAGE_NAME → $link")
                fi
            done <<< "$LINKS"

            # Check staleness via last_verified in frontmatter
            if [ -n "$STALE_CUTOFF" ]; then
                LAST_VERIFIED=$(awk '/^---$/{n++; next} n==1 && /^last_verified:/{print $2; exit}' "$page" 2>/dev/null || echo "")
                if [ -n "$LAST_VERIFIED" ] && [[ "$LAST_VERIFIED" < "$STALE_CUTOFF" ]]; then
                    STALE_PAGES+=("$PAGE_NAME (last verified: $LAST_VERIFIED)")
                fi
            fi
        done
    fi

    # Build report JSON
    jq -n \
        --arg action "lint" \
        --argjson total_pages "$TOTAL_PAGES" \
        --argjson orphan_count "${#ORPHAN_PAGES[@]}" \
        --argjson broken_count "${#BROKEN_LINKS[@]}" \
        --argjson stale_count "${#STALE_PAGES[@]}" \
        --arg orphans "$(printf '%s\n' "${ORPHAN_PAGES[@]}")" \
        --arg broken "$(printf '%s\n' "${BROKEN_LINKS[@]}")" \
        --arg stale "$(printf '%s\n' "${STALE_PAGES[@]}")" \
        --arg note "Lightweight local lint. For full contradiction scan and cross-reference analysis, use --backend cc." \
        '{
            action: $action,
            total_pages: $total_pages,
            issues: {
                orphan_pages: { count: $orphan_count, items: ($orphans | split("\n") | map(select(length > 0))) },
                broken_links: { count: $broken_count, items: ($broken | split("\n") | map(select(length > 0))) },
                stale_pages: { count: $stale_count, items: ($stale | split("\n") | map(select(length > 0))) }
            },
            note: $note
        }'
fi
