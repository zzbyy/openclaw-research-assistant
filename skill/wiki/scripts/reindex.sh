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

# Check that wiki directory has content (any .md files in subdirectories)
if [ -z "$(find "$WIKI_PATH" -name '*.md' -not -name '.*' -type f 2>/dev/null | head -1)" ]; then
    jq -n '{"action": "reindex", "status": "skipped", "message": "No wiki pages found yet."}'
    exit 0
fi

# Check if wiki collection is registered (register the whole wiki dir, covers all type subdirs)
if ! qmd collections list 2>/dev/null | grep -q "wiki"; then
    echo "Registering wiki collection with QMD..." >&2
    qmd add "$WIKI_PATH" --name wiki 2>/dev/null || qmd add "$WIKI_PATH" 2>/dev/null
fi

# ── Check if first run (models not yet downloaded) ──────────────────────────

MODELS_DIR="$HOME/.cache/qmd/models"
if [ ! -d "$MODELS_DIR" ] || [ -z "$(ls -A "$MODELS_DIR" 2>/dev/null)" ]; then
    echo "" >&2
    echo "First run — QMD will download models (~2GB total):" >&2
    EMBED_MODEL="${QMD_EMBED_MODEL:-embeddinggemma-300M}"
    echo "  Embedding: $EMBED_MODEL" >&2
    echo "  Reranker:  qwen3-reranker-0.6B (~640MB)" >&2
    echo "  Query expansion: qmd-query-expansion-1.7B (~1.1GB)" >&2
    echo "  Cached to: $MODELS_DIR" >&2
    echo "This will take a few minutes. Subsequent runs are fast." >&2
    echo "" >&2
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

CURRENT_EMBED_MODEL="${QMD_EMBED_MODEL:-embeddinggemma-300M (default)}"

jq -n \
    --arg action "reindex" \
    --arg status "complete" \
    --arg updated "$UPDATED" \
    --arg embedded "$EMBEDDED" \
    --arg doc_count "$DOC_COUNT" \
    --arg chunk_count "$CHUNK_COUNT" \
    --arg embed_model "$CURRENT_EMBED_MODEL" \
    '{
        action: $action,
        status: $status,
        updated: $updated,
        embedded: $embedded,
        documents: $doc_count,
        chunks: $chunk_count,
        embed_model: $embed_model,
        message: ("Reindex complete. " + $doc_count + " documents, " + $chunk_count + " chunks indexed. Embedding model: " + $embed_model)
    }'
