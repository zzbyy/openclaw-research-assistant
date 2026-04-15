#!/bin/bash
# reindex.sh — Update QMD search index after wiki changes
# Runs qmd update (rescan files) + qmd embed (generate vectors).
# Safe to call repeatedly — only processes new/changed files.
#
# Usage: reindex.sh [--full]    # --full forces re-embedding of all pages
# Env: WIKI_PATH

set -e

# Bootstrap: resolve config if not called via wiki-entry.sh
source "$(dirname "${BASH_SOURCE[0]}")/_bootstrap.sh"

# ── Check QMD ────────────────────────────────────────────────────────────────

if ! command -v qmd &>/dev/null; then
    jq -n '{
        "action": "reindex",
        "status": "skipped",
        "message": "QMD not installed. Search uses grep fallback. Install QMD for semantic search: npm install -g qmd"
    }'
    exit 0
fi

# ── Parse args ───────────────────────────────────────────────────────────────

FULL=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --full)
            FULL=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# ── Ensure collection exists ─────────────────────────────────────────────────

PAGES_DIR="$WIKI_PATH/pages"
if [ ! -d "$PAGES_DIR" ]; then
    jq -n '{"action": "reindex", "status": "skipped", "message": "No pages directory found."}'
    exit 0
fi

# Check if wiki collection is registered
if ! qmd collections list 2>/dev/null | grep -q "wiki"; then
    echo "Registering wiki collection with QMD..." >&2
    qmd add "$PAGES_DIR" --name wiki 2>/dev/null || qmd add "$PAGES_DIR" 2>/dev/null
fi

# ── Update index ─────────────────────────────────────────────────────────────

echo "Scanning for new/changed files..." >&2
UPDATE_OUT=$(qmd update 2>&1)
UPDATED=$(echo "$UPDATE_OUT" | grep -oE '[0-9]+ (added|updated|new)' | head -1 || echo "0")

# ── Generate embeddings ──────────────────────────────────────────────────────

echo "Generating embeddings..." >&2
if [ "$FULL" = true ]; then
    EMBED_OUT=$(qmd embed 2>&1)
else
    # Only embed new/changed chunks
    EMBED_OUT=$(qmd embed 2>&1)
fi
EMBEDDED=$(echo "$EMBED_OUT" | grep -oE '[0-9]+ (embedded|chunks)' | head -1 || echo "0")

# ── Output ───────────────────────────────────────────────────────────────────

# Get current stats
STATS=$(qmd status --format json 2>/dev/null || echo '{}')
DOC_COUNT=$(echo "$STATS" | jq -r '.documents // .docs // 0' 2>/dev/null || echo "0")
CHUNK_COUNT=$(echo "$STATS" | jq -r '.chunks // 0' 2>/dev/null || echo "0")

jq -n \
    --arg action "reindex" \
    --arg status "complete" \
    --arg updated "$UPDATED" \
    --arg embedded "$EMBEDDED" \
    --arg doc_count "$DOC_COUNT" \
    --arg chunk_count "$CHUNK_COUNT" \
    '{
        action: $action,
        status: $status,
        updated: $updated,
        embedded: $embedded,
        documents: $doc_count,
        chunks: $chunk_count,
        message: ("Reindex complete. " + $doc_count + " documents, " + $chunk_count + " chunks indexed.")
    }'
