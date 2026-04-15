#!/bin/bash
# ingest.sh — Ingest a single source file
#
# For PDF/EPUB/MOBI: extracts text (Python) → dispatches to Claude Code for deep analysis
# For markdown/HTML/text: copies to sources/, agent absorbs directly (no CC needed)
#
# Usage: ingest.sh <source-path> [--topic <id>]
# Env: WIKI_PATH, WIKI_SOURCES_PATH, WIKI_CONFIG_FILE

set -e

# Bootstrap
source "$(dirname "${BASH_SOURCE[0]}")/_bootstrap.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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
    pdf)      SUBDIR="pdfs"; NEEDS_EXTRACTION=true ;;
    epub)     SUBDIR="epub"; NEEDS_EXTRACTION=true ;;
    mobi)     SUBDIR="epub"; NEEDS_EXTRACTION=true ;;
    html|htm) SUBDIR="html"; NEEDS_EXTRACTION=false ;;
    md|txt)   SUBDIR="markdown"; NEEDS_EXTRACTION=false ;;
    *)        SUBDIR="other"; NEEDS_EXTRACTION=false ;;
esac

DEST_DIR="${WIKI_SOURCES_PATH}/${SUBDIR}"
mkdir -p "$DEST_DIR"

DEST_FILE="${DEST_DIR}/${FILENAME}"
if [ ! -f "$DEST_FILE" ]; then
    cp "$SOURCE_PATH" "$DEST_FILE"
fi

# ── For text-readable files: return info for agent to absorb directly ────────

if [ "$NEEDS_EXTRACTION" = false ]; then
    REL_PATH="../sources/${SUBDIR}/${FILENAME}"
    jq -n \
        --arg action "ingest" \
        --arg filename "$FILENAME" \
        --arg format "$SUBDIR" \
        --arg entry_path "$REL_PATH" \
        --arg wiki_path "$WIKI_PATH" \
        '{
            action: $action,
            filename: $filename,
            format: $format,
            entry_path: $entry_path,
            wiki_path: $wiki_path,
            instructions: ("Source copied to sources/" + $format + "/. Read " + $entry_path + " and absorb into wiki pages following .schema.md. Create pages in type subdirectories. Update index.md and log.md.")
        }'
    exit 0
fi

# ── For binary files: extract text then dispatch to Claude Code ──────────────

echo "⚠️  Single file ingest uses Claude Code for deep analysis." >&2

# Phase 1: Python text extraction
ENTRIES_DIR="$WIKI_PATH/.entries"
INGEST_PY="$WIKI_PATH/ingest.py"
[ ! -f "$INGEST_PY" ] && INGEST_PY="$SKILL_DIR/ingest.py"

ENTRY_FILE=""
if [ -f "$INGEST_PY" ] && command -v python3 &>/dev/null; then
    echo "Phase 1: Extracting text from $FILENAME..." >&2
    EXTRACT_OUT=$(WIKI_VAULT_PATH="$WIKI_VAULT_PATH" python3 "$INGEST_PY" --file "$DEST_FILE" 2>&1) || true
    echo "$EXTRACT_OUT" | tail -3 >&2

    # Find the generated entry
    if [ -d "$ENTRIES_DIR" ]; then
        ENTRY_FILE=$(grep -rl "source_file: \"$FILENAME\"" "$ENTRIES_DIR"/*.md 2>/dev/null | head -1 || true)
    fi
fi

# Phase 2: Dispatch to Claude Code
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
    # No CC available — return entry info for agent to absorb
    if [ -n "$ENTRY_FILE" ]; then
        ENTRY_NAME="$(basename "$ENTRY_FILE")"
        jq -n \
            --arg action "ingest" \
            --arg filename "$FILENAME" \
            --arg entry_path ".entries/$ENTRY_NAME" \
            --arg wiki_path "$WIKI_PATH" \
            '{
                action: $action,
                filename: $filename,
                entry_path: $entry_path,
                wiki_path: $wiki_path,
                instructions: ("Text extracted. Claude Code not available. Read " + $entry_path + " and absorb into wiki pages following .schema.md.")
            }'
    else
        jq -n --arg f "$FILENAME" '{"error": ("Cannot ingest " + $f + ": no Claude Code and text extraction failed.")}'
    fi
    exit 0
fi

# Build the absorb prompt
if [ -n "$ENTRY_FILE" ]; then
    ENTRY_NAME="$(basename "$ENTRY_FILE")"
    PROMPT="Absorb this pre-extracted entry into the wiki. Follow the wiki schema in .schema.md.
If Obsidian skills are available, use them for creating and editing markdown files.

Entry file: .entries/${ENTRY_NAME}
Original source: ${FILENAME}

Instructions:
1. Read the entry from .entries/${ENTRY_NAME}
2. Scan index.md to understand current wiki state
3. Identify key concepts, methods, people, techniques
4. Create pages in appropriate type subdirectories (create dirs as needed)
5. Create a book/paper summary page for the source itself
6. Cross-reference with existing pages
7. Check for contradictions — add > [!warning] callouts if found
8. Update index.md with new entries
9. Append to log.md"
else
    PROMPT="Ingest this source document into the wiki. Follow the wiki schema in .schema.md.
If Obsidian skills are available, use them for creating and editing markdown files.

Source file: ../sources/${SUBDIR}/${FILENAME}

Note: Text extraction was not available. Read the source file directly.

Instructions:
1. Read the source document completely
2. Scan index.md to understand current wiki state
3. Identify key concepts, methods, people, techniques
4. Create pages in appropriate type subdirectories (create dirs as needed)
5. Create a book/paper summary page for the source itself
6. Cross-reference with existing pages
7. Check for contradictions — add > [!warning] callouts if found
8. Update index.md with new entries
9. Append to log.md"
fi

DISPATCH_ARGS=(--dir "$WIKI_PATH")
[ -n "$CC_MODEL" ] && DISPATCH_ARGS+=(--model "$CC_MODEL")
[ -n "$CC_TIMEOUT" ] && DISPATCH_ARGS+=(--timeout "$CC_TIMEOUT")
[ -n "$TOPIC" ] && DISPATCH_ARGS+=(--topic "$TOPIC")

echo "Phase 2: Dispatching to Claude Code..." >&2
"$DISPATCH_PATH" "${DISPATCH_ARGS[@]}" -- "$PROMPT"
