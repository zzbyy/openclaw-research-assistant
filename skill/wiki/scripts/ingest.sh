#!/bin/bash
# ingest.sh — Ingest a source document into the wiki
# Copies source to vault/sources/, dispatches to Claude Code or returns info for agent.
#
# Usage: ingest.sh <source-path> [--topic <id>]
# Env: WIKI_BACKEND (cc|agent), WIKI_PATH, WIKI_SOURCES_PATH, WIKI_CONFIG_FILE

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse args ───────────────────────────────────────────────────────────────

SOURCE_PATH=""
TOPIC=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --topic)
            TOPIC="$2"
            shift 2
            ;;
        *)
            SOURCE_PATH="$1"
            shift
            ;;
    esac
done

if [ -z "$SOURCE_PATH" ]; then
    echo '{"error": "Usage: /wiki ingest <source-path>"}'
    exit 1
fi

# Safe tilde expansion
if [[ "$SOURCE_PATH" == '~/'* ]]; then
    SOURCE_PATH="$HOME/${SOURCE_PATH:2}"
fi

if [ ! -f "$SOURCE_PATH" ]; then
    jq -n --arg p "$SOURCE_PATH" '{"error": ("Source file not found: " + $p)}'
    exit 1
fi

# ── Detect format and copy to sources ────────────────────────────────────────

FILENAME="$(basename "$SOURCE_PATH")"
EXTENSION="${FILENAME##*.}"
EXTENSION_LOWER="$(echo "$EXTENSION" | tr '[:upper:]' '[:lower:]')"

case "$EXTENSION_LOWER" in
    pdf)      SUBDIR="pdfs" ;;
    html|htm) SUBDIR="html" ;;
    epub)     SUBDIR="epub" ;;
    md|txt)   SUBDIR="markdown" ;;
    *)        SUBDIR="other" ;;
esac

DEST_DIR="${WIKI_SOURCES_PATH}/${SUBDIR}"
mkdir -p "$DEST_DIR"

DEST_FILE="${DEST_DIR}/${FILENAME}"
if [ -f "$DEST_FILE" ]; then
    jq -n --arg f "$FILENAME" --arg d "$SUBDIR" \
        '{"warning": ("Source already exists in sources/" + $d + "/" + $f + ". Proceeding with existing copy.")}'
else
    cp "$SOURCE_PATH" "$DEST_FILE"
fi

# Relative path from wiki/ to the source (for wiki page references)
REL_SOURCE="../${WIKI_SOURCES_PATH##*/}/${SUBDIR}/${FILENAME}"

# ── Dispatch ─────────────────────────────────────────────────────────────────

if [ "$WIKI_BACKEND" = "cc" ]; then
    # Dispatch to Claude Code via cc-bridge
    _wiki_config() {
        [ -f "$WIKI_CONFIG_FILE" ] && jq -r "$1 // empty" "$WIKI_CONFIG_FILE" 2>/dev/null || echo ""
    }

    DISPATCH_PATH="$(_wiki_config '.cc_bridge.dispatch_path')"
    CC_MODEL="$(_wiki_config '.cc_bridge.model')"
    CC_TIMEOUT="$(_wiki_config '.cc_bridge.timeout_minutes')"

    # Safe tilde expansion for dispatch path
    if [[ "$DISPATCH_PATH" == '~/'* ]]; then
        DISPATCH_PATH="$HOME/${DISPATCH_PATH:2}"
    fi

    if [ ! -f "$DISPATCH_PATH" ]; then
        jq -n --arg p "$DISPATCH_PATH" \
            '{"error": ("cc-bridge dispatch.sh not found at: " + $p + ". Install cc-bridge or use --backend agent")}'
        exit 1
    fi

    # Build the ingest prompt
    PROMPT="Ingest this source document into the wiki. Follow the wiki schema in .schema.md.

Source file: ${REL_SOURCE}
Filename: ${FILENAME}

Instructions:
1. Read the source document completely
2. Scan existing wiki pages via index.md to understand current state
3. Check for contradictions against existing pages
4. Create or update wiki pages with full v2 frontmatter (type, confidence, relationships)
5. Update index.md with new entries
6. Append to log.md
7. If contradictions found, add > [!warning] Contradiction callouts and flag them"

    # Build dispatch args
    DISPATCH_ARGS=(--dir "$WIKI_PATH")
    if [ -n "$CC_MODEL" ]; then
        DISPATCH_ARGS+=(--model "$CC_MODEL")
    fi
    if [ -n "$CC_TIMEOUT" ]; then
        DISPATCH_ARGS+=(--timeout "$CC_TIMEOUT")
    fi
    if [ -n "$TOPIC" ]; then
        DISPATCH_ARGS+=(--topic "$TOPIC")
    fi

    # Dispatch
    exec "$DISPATCH_PATH" "${DISPATCH_ARGS[@]}" -- "$PROMPT"

else
    # Backend: agent — return structured info for the research agent to process
    jq -n \
        --arg action "ingest" \
        --arg source "$DEST_FILE" \
        --arg rel_source "$REL_SOURCE" \
        --arg filename "$FILENAME" \
        --arg format "$SUBDIR" \
        --arg wiki_path "$WIKI_PATH" \
        '{
            action: $action,
            source: $source,
            rel_source: $rel_source,
            filename: $filename,
            format: $format,
            wiki_path: $wiki_path,
            instructions: "Read the source document, create/update wiki pages following .schema.md, check for contradictions, update index.md and log.md."
        }'
fi
