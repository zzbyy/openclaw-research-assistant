#!/bin/bash
# query.sh — Query the wiki with a question
# Dispatches to Claude Code or returns context for agent-side synthesis.
#
# Usage: query.sh <question...>
# Env: WIKI_BACKEND (cc|agent), WIKI_PATH, WIKI_CONFIG_FILE

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse args ───────────────────────────────────────────────────────────────

TOPIC=""
QUESTION_PARTS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --topic)
            TOPIC="$2"
            shift 2
            ;;
        *)
            QUESTION_PARTS+=("$1")
            shift
            ;;
    esac
done

QUESTION="${QUESTION_PARTS[*]}"

if [ -z "$QUESTION" ]; then
    echo '{"error": "Usage: /wiki query <question>"}'
    exit 1
fi

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

    PROMPT="Query the wiki to answer this question. Follow the wiki schema in .schema.md.

Question: ${QUESTION}

Instructions:
1. Search relevant pages via index.md, tags, and wikilinks
2. Read the matching pages
3. Synthesize an answer with [[wikilinks]] as citations
4. Note confidence levels for claims
5. If the wiki doesn't cover this topic, say so and note the gap
6. Append to log.md: date, 'query', the question, pages referenced"

    DISPATCH_ARGS=(--dir "$WIKI_PATH")
    [ -n "$CC_MODEL" ] && DISPATCH_ARGS+=(--model "$CC_MODEL")
    [ -n "$CC_TIMEOUT" ] && DISPATCH_ARGS+=(--timeout "$CC_TIMEOUT")
    [ -n "$TOPIC" ] && DISPATCH_ARGS+=(--topic "$TOPIC")

    exec "$DISPATCH_PATH" "${DISPATCH_ARGS[@]}" -- "$PROMPT"

else
    # Backend: agent — search wiki pages and return context for synthesis
    PAGES_DIR="$WIKI_PATH/pages"
    INDEX_FILE="$WIKI_PATH/index.md"
    MATCHES=""

    if [ -d "$PAGES_DIR" ]; then
        # Search for pages containing question keywords
        # Extract key words (skip common words)
        SEARCH_TERMS=$(echo "$QUESTION" | tr '[:upper:]' '[:lower:]' | \
            tr -cs '[:alnum:]' '\n' | \
            grep -vE '^(the|a|an|is|are|was|were|what|how|why|when|where|who|do|does|did|can|could|would|should|in|on|at|to|for|of|with|and|or|but|not)$' | \
            head -10)

        if [ -n "$SEARCH_TERMS" ]; then
            # Build grep pattern
            PATTERN=$(echo "$SEARCH_TERMS" | tr '\n' '|' | sed 's/|$//')
            MATCHES=$(grep -ril "$PATTERN" "$PAGES_DIR" 2>/dev/null | head -10 || true)
        fi
    fi

    # Build result with matched page paths and snippets
    if [ -n "$MATCHES" ]; then
        PAGES_JSON="[]"
        while IFS= read -r match; do
            PAGE_NAME="$(basename "$match" .md)"
            # Get first 3 lines after frontmatter
            SNIPPET=$(awk '/^---$/{n++; next} n>=2{print; if(++c>=3) exit}' "$match" 2>/dev/null || echo "")
            PAGES_JSON=$(echo "$PAGES_JSON" | jq --arg name "$PAGE_NAME" --arg path "$match" --arg snippet "$SNIPPET" \
                '. + [{"name": $name, "path": $path, "snippet": $snippet}]')
        done <<< "$MATCHES"
    else
        PAGES_JSON="[]"
    fi

    jq -n \
        --arg action "query" \
        --arg question "$QUESTION" \
        --arg wiki_path "$WIKI_PATH" \
        --arg index_file "$INDEX_FILE" \
        --argjson matched_pages "$PAGES_JSON" \
        '{
            action: $action,
            question: $question,
            wiki_path: $wiki_path,
            index_file: $index_file,
            matched_pages: $matched_pages,
            instructions: "Read the matched pages (and any others linked from them), synthesize an answer with [[wikilinks]] and confidence levels. If no pages match, note the gap."
        }'
fi
