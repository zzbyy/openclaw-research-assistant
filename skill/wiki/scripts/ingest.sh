#!/bin/bash
# ingest.sh — Two-phase ingest: extract text (Python) → absorb into wiki (Claude Code or agent)
#
# Phase 1: Python extracts text from PDF/EPUB/MOBI/HTML → .entries/
# Phase 2: Claude Code (or agent) reads the entry and creates wiki pages
#
# Usage: ingest.sh <source-path> [--topic <id>] [--skip-extract]
# Env: WIKI_BACKEND (cc|agent), WIKI_PATH, WIKI_SOURCES_PATH, WIKI_CONFIG_FILE

set -e

# Bootstrap: resolve config if not called via wiki-entry.sh
source "$(dirname "${BASH_SOURCE[0]}")/_bootstrap.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Parse args ───────────────────────────────────────────────────────────────

SOURCE_PATH=""
TOPIC=""
SKIP_EXTRACT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --topic)
            TOPIC="$2"
            shift 2
            ;;
        --skip-extract)
            SKIP_EXTRACT=true
            shift
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
    mobi)     SUBDIR="epub" ;;
    *)        SUBDIR="other" ;;
esac

DEST_DIR="${WIKI_SOURCES_PATH}/${SUBDIR}"
mkdir -p "$DEST_DIR"

DEST_FILE="${DEST_DIR}/${FILENAME}"
if [ ! -f "$DEST_FILE" ]; then
    cp "$SOURCE_PATH" "$DEST_FILE"
fi

# ── Phase 1: Python text extraction ──────────────────────────────────────────

ENTRIES_DIR="$WIKI_PATH/.entries"
INGEST_PY="$WIKI_PATH/ingest.py"

# Find ingest.py: in vault wiki/ dir, or in skill dir
if [ ! -f "$INGEST_PY" ]; then
    INGEST_PY="$SKILL_DIR/ingest.py"
fi
if [ ! -f "$INGEST_PY" ]; then
    # Fallback: copy from wiki-schema if available
    SCHEMA_PY="$(cd "$SKILL_DIR" && pwd)/../../wiki-schema/ingest.py"
    [ -f "$SCHEMA_PY" ] && INGEST_PY="$SCHEMA_PY"
fi

ENTRY_FILE=""
if [ "$SKIP_EXTRACT" = false ] && [ -f "$INGEST_PY" ] && command -v python3 &>/dev/null; then
    echo "Phase 1: Extracting text from $FILENAME..." >&2
    EXTRACT_OUT=$(WIKI_VAULT_PATH="$WIKI_VAULT_PATH" python3 "$INGEST_PY" --file "$DEST_FILE" 2>&1) || true
    echo "$EXTRACT_OUT" | tail -3 >&2

    # Find the generated entry file
    if [ -d "$ENTRIES_DIR" ]; then
        # Match by source filename in the entry's frontmatter
        ENTRY_FILE=$(grep -rl "source_file: \"$FILENAME\"" "$ENTRIES_DIR"/*.md 2>/dev/null | head -1 || true)
    fi
fi

# ── Phase 2: Dispatch to Claude Code or agent ───────────────────────────────

_wiki_config() {
    [ -f "$WIKI_CONFIG_FILE" ] && jq -r "$1 // empty" "$WIKI_CONFIG_FILE" 2>/dev/null || echo ""
}

if [ "$WIKI_BACKEND" = "cc" ]; then
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

    # Build the absorb prompt — point to extracted entry if available
    if [ -n "$ENTRY_FILE" ]; then
        ENTRY_BASENAME="$(basename "$ENTRY_FILE")"
        PROMPT="Absorb this pre-extracted entry into the wiki. Follow the wiki schema in .schema.md.
If Obsidian skills are available, use them for creating and editing markdown files.

Entry file: .entries/${ENTRY_BASENAME}
Original source: ${FILENAME}

Instructions:
1. Read the entry from .entries/${ENTRY_BASENAME} (already extracted text with metadata)
2. Scan index.md to understand current wiki state
3. Identify key concepts, methods, people, techniques from this source
4. Create pages in the appropriate type subdirectories (concepts/, methods/, books/, etc.)
5. Create a book/paper summary page for the source itself
6. Cross-reference with existing pages
7. Check for contradictions — add > [!warning] callouts if found
8. Update index.md with new entries
9. Append to log.md"
    else
        PROMPT="Ingest this source document into the wiki. Follow the wiki schema in .schema.md.
If Obsidian skills are available, use them for creating and editing markdown files.

Source file: ../sources/${SUBDIR}/${FILENAME}
Filename: ${FILENAME}

Note: No pre-extracted entry available. Read the source file directly.

Instructions:
1. Read the source document completely
2. Scan index.md to understand current wiki state
3. Identify key concepts, methods, people, techniques
4. Create pages in the appropriate type subdirectories (concepts/, methods/, books/, etc.)
5. Create a book/paper summary page for the source itself
6. Cross-reference with existing pages
7. Check for contradictions — add > [!warning] callouts if found
8. Update index.md with new entries
9. Append to log.md"
    fi

    # Build dispatch args
    DISPATCH_ARGS=(--dir "$WIKI_PATH")
    [ -n "$CC_MODEL" ] && DISPATCH_ARGS+=(--model "$CC_MODEL")
    [ -n "$CC_TIMEOUT" ] && DISPATCH_ARGS+=(--timeout "$CC_TIMEOUT")
    [ -n "$TOPIC" ] && DISPATCH_ARGS+=(--topic "$TOPIC")

    echo "Phase 2: Dispatching to Claude Code..." >&2
    "$DISPATCH_PATH" "${DISPATCH_ARGS[@]}" -- "$PROMPT"

    # Reindex picks up pages from previous ingests
    if command -v qmd &>/dev/null; then
        echo "Reindexing search..." >&2
        "$SCRIPT_DIR/reindex.sh" >&2 || true
    fi

else
    # Backend: agent — return structured info for the agent to process
    ENTRY_INFO=""
    [ -n "$ENTRY_FILE" ] && ENTRY_INFO="$(basename "$ENTRY_FILE")"

    jq -n \
        --arg action "ingest" \
        --arg source "$DEST_FILE" \
        --arg filename "$FILENAME" \
        --arg format "$SUBDIR" \
        --arg wiki_path "$WIKI_PATH" \
        --arg entry_file "$ENTRY_INFO" \
        '{
            action: $action,
            source: $source,
            filename: $filename,
            format: $format,
            wiki_path: $wiki_path,
            entry_file: (if $entry_file != "" then (".entries/" + $entry_file) else null end),
            instructions: ("Read " + (if $entry_file != "" then ".entries/" + $entry_file else "the source file" end) + " and absorb into wiki pages following .schema.md. Create pages in type subdirectories (concepts/, methods/, books/, etc.). Update index.md and log.md.")
        }'

    # Auto-reindex after agent creates pages
    if command -v qmd &>/dev/null; then
        echo "Reindexing search..." >&2
        "$SCRIPT_DIR/reindex.sh" >&2 || true
    fi
fi
