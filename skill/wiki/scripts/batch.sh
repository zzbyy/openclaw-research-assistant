#!/bin/bash
# batch.sh — Two-phase batch pipeline: extract sources → absorb into wiki
#
# Step 1: Python extracts text from all pending sources → .entries/
# Step 2: Absorb unprocessed entries into wiki pages (via Claude Code or agent)
#
# Usage: batch.sh [--limit N] [--auto] [--match <pattern>] [--dry-run] [--topic <id>]
# Env: WIKI_BACKEND, WIKI_PATH, WIKI_SOURCES_PATH, WIKI_CONFIG_FILE

set -e

# Bootstrap
source "$(dirname "${BASH_SOURCE[0]}")/_bootstrap.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_notify.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Parse args ───────────────────────────────────────────────────────────────

DEFAULT_LIMIT=$([ -f "$WIKI_CONFIG_FILE" ] && jq -r '.batch.default_limit // 10' "$WIKI_CONFIG_FILE" 2>/dev/null || echo "10")
LIMIT="$DEFAULT_LIMIT"
MATCH_PATTERN=""
DRY_RUN=false
AUTO=false
TOPIC=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --limit|-n)
            LIMIT="$2"
            shift 2
            ;;
        --match|-m)
            MATCH_PATTERN="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --auto)
            AUTO=true
            shift
            ;;
        --topic)
            TOPIC="$2"
            shift 2
            ;;
        --all)
            LIMIT=999999
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# ── Paths ────────────────────────────────────────────────────────────────────

ENTRIES_DIR="$WIKI_PATH/.entries"
ABSORBED_FILE="$ENTRIES_DIR/.absorbed"
INGEST_PY="$WIKI_PATH/ingest.py"

# Find ingest.py
if [ ! -f "$INGEST_PY" ]; then
    INGEST_PY="$SKILL_DIR/ingest.py"
fi

mkdir -p "$ENTRIES_DIR"
touch "$ABSORBED_FILE"

# ── Step 1: Extract — Python processes all pending sources ───────────────────

HAS_PYTHON=false
if [ -f "$INGEST_PY" ] && command -v python3 &>/dev/null; then
    HAS_PYTHON=true
fi

if [ "$HAS_PYTHON" = true ]; then
    echo "Step 1: Extracting text from pending sources..." >&2
    wiki_notify "[Wiki] Step 1: Extracting text from sources..."

    EXTRACT_OUT=$(WIKI_VAULT_PATH="$WIKI_VAULT_PATH" python3 "$INGEST_PY" 2>&1) || true

    # Parse extraction summary
    EXTRACTED=$(echo "$EXTRACT_OUT" | grep -oE 'Success: [0-9]+' | grep -oE '[0-9]+' || echo "0")
    EXTRACT_FAILED=$(echo "$EXTRACT_OUT" | grep -oE 'Failed: +[0-9]+' | grep -oE '[0-9]+' || echo "0")
    EXTRACT_SKIPPED=$(echo "$EXTRACT_OUT" | grep -oE 'Skipped: [0-9]+' | grep -oE '[0-9]+' || echo "0")

    echo "  Extracted: $EXTRACTED new, $EXTRACT_SKIPPED already done, $EXTRACT_FAILED failed" >&2
    [ "$EXTRACTED" -gt 0 ] && wiki_notify "[Wiki] Extracted $EXTRACTED new entries ($EXTRACT_FAILED failed)"
else
    echo "Step 1: Skipping extraction (no ingest.py or python3)" >&2
    EXTRACTED=0
    EXTRACT_FAILED=0
fi

# ── Step 2: Find unabsorbed entries ──────────────────────────────────────────

find_pending_entries() {
    local pending=()

    # 1. Extracted entries in .entries/ (from PDF/EPUB/MOBI extraction)
    for entry in "$ENTRIES_DIR"/*.md; do
        [ -f "$entry" ] || continue
        ENTRY_NAME="$(basename "$entry")"

        # Skip if already absorbed
        grep -qxF "$ENTRY_NAME" "$ABSORBED_FILE" 2>/dev/null && continue

        # Apply match pattern
        if [ -n "$MATCH_PATTERN" ]; then
            echo "$ENTRY_NAME" | grep -qi "$MATCH_PATTERN" 2>/dev/null || continue
        fi

        pending+=("$entry")
    done

    # 2. Markdown/HTML/text source files (readable directly, no extraction needed)
    for subdir in markdown html; do
        local srcdir="$WIKI_SOURCES_PATH/$subdir"
        [ -d "$srcdir" ] || continue
        for srcfile in "$srcdir"/*.md "$srcdir"/*.txt "$srcdir"/*.html "$srcdir"/*.htm; do
            [ -f "$srcfile" ] || continue
            local srcname="source_$(basename "$srcfile")"

            # Skip if already absorbed
            grep -qxF "$srcname" "$ABSORBED_FILE" 2>/dev/null && continue

            # Apply match pattern
            if [ -n "$MATCH_PATTERN" ]; then
                echo "$srcname" | grep -qi "$MATCH_PATTERN" 2>/dev/null || continue
            fi

            pending+=("$srcfile")
        done
    done

    echo "${pending[@]}"
}

PENDING_STR=$(find_pending_entries)
read -ra PENDING <<< "$PENDING_STR"
TOTAL_PENDING=${#PENDING[@]}

if [ "$TOTAL_PENDING" -eq 0 ]; then
    echo "Step 2: No pending entries to absorb." >&2
    jq -n --argjson extracted "${EXTRACTED:-0}" '{
        action: "batch",
        status: "nothing_to_absorb",
        extracted: $extracted,
        message: ("Extraction done (" + ($extracted | tostring) + " new). No pending entries to absorb.")
    }'
    exit 0
fi

echo "Step 2: $TOTAL_PENDING entries pending absorption." >&2

# ── Dry run ──────────────────────────────────────────────────────────────────

if [ "$DRY_RUN" = true ]; then
    BATCH_SIZE="$LIMIT"
    [ "$BATCH_SIZE" -gt "$TOTAL_PENDING" ] && BATCH_SIZE="$TOTAL_PENDING"

    FILENAMES="[]"
    for ((i=0; i<BATCH_SIZE; i++)); do
        FILENAMES=$(echo "$FILENAMES" | jq --arg f "$(basename "${PENDING[$i]}")" '. + [$f]')
    done

    jq -n \
        --argjson extracted "${EXTRACTED:-0}" \
        --argjson total_pending "$TOTAL_PENDING" \
        --argjson batch_size "$BATCH_SIZE" \
        --argjson files "$FILENAMES" \
        '{
            action: "batch_dry_run",
            extracted: $extracted,
            total_pending: $total_pending,
            batch_size: $batch_size,
            files: $files,
            message: ("Dry run: " + ($extracted | tostring) + " extracted, would absorb " + ($batch_size | tostring) + " of " + ($total_pending | tostring) + " pending entries.")
        }'
    exit 0
fi

# ── Step 3: Absorb entries ───────────────────────────────────────────────────

_wiki_config() {
    [ -f "$WIKI_CONFIG_FILE" ] && jq -r "$1 // empty" "$WIKI_CONFIG_FILE" 2>/dev/null || echo ""
}

DISPATCH_PATH=""
if [ "$WIKI_BACKEND" = "cc" ]; then
    DISPATCH_PATH="$(_wiki_config '.cc_bridge.dispatch_path')"
    [[ "$DISPATCH_PATH" == '~/'* ]] && DISPATCH_PATH="$HOME/${DISPATCH_PATH:2}"
fi

CC_MODEL="$(_wiki_config '.cc_bridge.model')"
CC_TIMEOUT="$(_wiki_config '.cc_bridge.timeout_minutes')"

absorb_batch() {
    local batch_start="$1"
    local batch_size="$2"
    local batch_num="$3"
    local dispatched=0
    local failed=0

    wiki_notify "[Wiki] Absorbing batch $batch_num ($batch_size entries)..."

    for ((i=batch_start; i<batch_start+batch_size && i<TOTAL_PENDING; i++)); do
        entry="${PENDING[$i]}"
        ENTRY_NAME="$(basename "$entry")"
        ENTRY_IDX=$((i - batch_start + 1))

        # Determine entry path relative to wiki dir
        # Extracted entries are in .entries/, direct sources are in ../sources/
        if [[ "$entry" == "$ENTRIES_DIR"/* ]]; then
            ENTRY_REF=".entries/${ENTRY_NAME}"
            ABSORB_NAME="$ENTRY_NAME"
        else
            ENTRY_REF="../sources/$(basename "$(dirname "$entry")")/${ENTRY_NAME}"
            ABSORB_NAME="source_${ENTRY_NAME}"
        fi

        echo "  [$ENTRY_IDX/$batch_size] Absorbing: $ENTRY_NAME" >&2

        if [ "$WIKI_BACKEND" = "cc" ] && [ -n "$DISPATCH_PATH" ] && [ -f "$DISPATCH_PATH" ]; then
            # CC backend: dispatch to Claude Code
            PROMPT="Absorb this entry into the wiki. Follow the wiki schema in .schema.md.
If Obsidian skills are available, use them for creating and editing markdown files.

Entry file: ${ENTRY_REF}

Instructions:
1. Read the entry from ${ENTRY_REF}
2. Scan index.md to understand current wiki state
3. Identify key concepts, methods, people, techniques
4. Create pages in appropriate type subdirectories (create dirs as needed)
5. Create a book/paper summary page for the source itself
6. Cross-reference with existing pages
7. Check for contradictions — add > [!warning] callouts if found
8. Update index.md with new entries
9. Append to log.md"

            DISPATCH_ARGS=(--dir "$WIKI_PATH")
            [ -n "$CC_MODEL" ] && DISPATCH_ARGS+=(--model "$CC_MODEL")
            [ -n "$CC_TIMEOUT" ] && DISPATCH_ARGS+=(--timeout "$CC_TIMEOUT")
            [ -n "$TOPIC" ] && DISPATCH_ARGS+=(--topic "$TOPIC")

            DISPATCH_OUT=$("$DISPATCH_PATH" "${DISPATCH_ARGS[@]}" -- "$PROMPT" 2>&1) && {
                echo "$ABSORB_NAME" >> "$ABSORBED_FILE"
                dispatched=$((dispatched + 1))
                TASK_ID=$(echo "$DISPATCH_OUT" | jq -r '.task_id // empty' 2>/dev/null || true)
                [ -n "$TASK_ID" ] && echo "    -> dispatched (task: $TASK_ID)" >&2 || echo "    -> dispatched" >&2
            } || {
                echo "    [!!] Failed" >&2
                failed=$((failed + 1))
            }
        else
            # Agent backend: mark as queued, agent processes from the output JSON
            echo "$ABSORB_NAME" >> "$ABSORBED_FILE"
            dispatched=$((dispatched + 1))
            echo "    -> queued for agent" >&2
        fi

        # Progress notification
        if should_notify_progress "$ENTRY_IDX"; then
            wiki_notify "[Wiki] Batch $batch_num: $ENTRY_IDX/$batch_size absorbed..."
        fi
    done

    echo "$dispatched $failed"
}

# ── Run absorption (single batch or auto-loop) ──────────────────────────────

TOTAL_DISPATCHED=0
TOTAL_FAILED=0
BATCH_NUM=0

if [ "$AUTO" = true ]; then
    echo "Auto mode: processing all $TOTAL_PENDING pending entries in batches of $LIMIT..." >&2
    wiki_notify "[Wiki] Auto batch: $TOTAL_PENDING entries to process (batches of $LIMIT)"

    OFFSET=0
    while [ "$OFFSET" -lt "$TOTAL_PENDING" ]; do
        BATCH_NUM=$((BATCH_NUM + 1))
        CURRENT_BATCH="$LIMIT"
        REMAINING=$((TOTAL_PENDING - OFFSET))
        [ "$CURRENT_BATCH" -gt "$REMAINING" ] && CURRENT_BATCH="$REMAINING"

        RESULT=$(absorb_batch "$OFFSET" "$CURRENT_BATCH" "$BATCH_NUM")
        D=$(echo "$RESULT" | awk '{print $1}')
        F=$(echo "$RESULT" | awk '{print $2}')
        TOTAL_DISPATCHED=$((TOTAL_DISPATCHED + D))
        TOTAL_FAILED=$((TOTAL_FAILED + F))

        OFFSET=$((OFFSET + CURRENT_BATCH))

        # Reindex after each batch
        if command -v qmd &>/dev/null && [ "$D" -gt 0 ]; then
            echo "  Reindexing..." >&2
            "$SCRIPT_DIR/reindex.sh" >/dev/null 2>&1 || true
        fi
    done
else
    BATCH_NUM=1
    BATCH_SIZE="$LIMIT"
    [ "$BATCH_SIZE" -gt "$TOTAL_PENDING" ] && BATCH_SIZE="$TOTAL_PENDING"

    RESULT=$(absorb_batch 0 "$BATCH_SIZE" 1)
    TOTAL_DISPATCHED=$(echo "$RESULT" | awk '{print $1}')
    TOTAL_FAILED=$(echo "$RESULT" | awk '{print $2}')

    # Reindex
    if command -v qmd &>/dev/null && [ "$TOTAL_DISPATCHED" -gt 0 ]; then
        echo "Reindexing search index..." >&2
        REINDEX_OUT=$("$SCRIPT_DIR/reindex.sh" 2>&1) || true
        REINDEX_MSG=$(echo "$REINDEX_OUT" | jq -r '.message // empty' 2>/dev/null || true)
        [ -n "$REINDEX_MSG" ] && echo "  $REINDEX_MSG" >&2
    fi
fi

REMAINING=$((TOTAL_PENDING - TOTAL_DISPATCHED - TOTAL_FAILED))

# ── Completion ───────────────────────────────────────────────────────────────

SUMMARY="[Wiki] Complete: $TOTAL_DISPATCHED absorbed, $TOTAL_FAILED failed, $REMAINING remaining."
wiki_notify "$SUMMARY"

# Agent backend: return all pending entries for the agent to process
if [ "$WIKI_BACKEND" != "cc" ] && [ "$TOTAL_DISPATCHED" -gt 0 ]; then
    # Collect entry paths for agent
    ENTRIES_JSON="[]"
    while IFS= read -r absorbed_entry; do
        ENTRY_PATH="$ENTRIES_DIR/$absorbed_entry"
        [ -f "$ENTRY_PATH" ] || continue
        ENTRIES_JSON=$(echo "$ENTRIES_JSON" | jq --arg e ".entries/$absorbed_entry" '. + [$e]')
    done < <(tail -"$TOTAL_DISPATCHED" "$ABSORBED_FILE")

    jq -n \
        --arg action "batch" \
        --argjson extracted "${EXTRACTED:-0}" \
        --argjson total_pending "$TOTAL_PENDING" \
        --argjson dispatched "$TOTAL_DISPATCHED" \
        --argjson failed "$TOTAL_FAILED" \
        --argjson remaining "$REMAINING" \
        --argjson entries "$ENTRIES_JSON" \
        --arg wiki_path "$WIKI_PATH" \
        '{
            action: $action,
            extracted: $extracted,
            total_pending: $total_pending,
            dispatched: $dispatched,
            failed: $failed,
            remaining: $remaining,
            wiki_path: $wiki_path,
            entries: $entries,
            instructions: "Read each entry file listed above. For each entry, create wiki pages in appropriate type subdirectories following .schema.md. Update index.md and log.md after processing all entries."
        }'
else
    jq -n \
        --arg action "batch" \
        --argjson extracted "${EXTRACTED:-0}" \
        --argjson total_pending "$TOTAL_PENDING" \
        --argjson dispatched "$TOTAL_DISPATCHED" \
        --argjson failed "$TOTAL_FAILED" \
        --argjson remaining "$REMAINING" \
        --argjson batches "$BATCH_NUM" \
        '{
            action: $action,
            extracted: $extracted,
            total_pending: $total_pending,
            dispatched: $dispatched,
            failed: $failed,
            remaining: $remaining,
            batches: $batches,
            message: ("Batch complete. " + ($dispatched | tostring) + " absorbed, " + ($failed | tostring) + " failed, " + ($remaining | tostring) + " remaining.")
        }'
fi
