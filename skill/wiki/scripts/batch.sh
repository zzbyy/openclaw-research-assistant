#!/bin/bash
# batch.sh — Extract sources + dedup + list pending entries for the agent
#
# The script handles mechanical work: extraction, dedup, entry listing.
# The AGENT handles LLM work: reading entries and creating wiki pages.
#
# Usage: batch.sh [--limit N] [--auto] [--match <pattern>] [--dry-run]
# Env: WIKI_PATH, WIKI_SOURCES_PATH, WIKI_CONFIG_FILE

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
            LIMIT=999999
            shift
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

# ── Step 1.5: Dedup entries ──────────────────────────────────────────────────

CONTENT_HASHES="$ENTRIES_DIR/.content-hashes"
DEDUPED_FILE="$ENTRIES_DIR/.deduped"
touch "$CONTENT_HASHES" "$DEDUPED_FILE"

DEDUP_NEW=0
DEDUP_DUPES=0

echo "Step 1.5: Deduplicating entries..." >&2

for entry in "$ENTRIES_DIR"/*.md; do
    [ -f "$entry" ] || continue
    ENTRY_NAME="$(basename "$entry")"

    grep -qF "$ENTRY_NAME" "$CONTENT_HASHES" 2>/dev/null && continue
    grep -qxF "$ENTRY_NAME" "$DEDUPED_FILE" 2>/dev/null && continue

    BODY_HASH=$(awk '/^---$/{n++; next} n>=2{print}' "$entry" | md5 -q 2>/dev/null || \
                awk '/^---$/{n++; next} n>=2{print}' "$entry" | md5sum 2>/dev/null | cut -d' ' -f1 || echo "")

    [ -z "$BODY_HASH" ] && continue

    if grep -q "^${BODY_HASH}" "$CONTENT_HASHES" 2>/dev/null; then
        echo "$ENTRY_NAME" >> "$DEDUPED_FILE"
        DEDUP_DUPES=$((DEDUP_DUPES + 1))
    else
        printf '%s\t%s\n' "$BODY_HASH" "$ENTRY_NAME" >> "$CONTENT_HASHES"
        DEDUP_NEW=$((DEDUP_NEW + 1))
    fi
done

if [ "$DEDUP_DUPES" -gt 0 ]; then
    echo "  Dedup: $DEDUP_DUPES duplicates found, $DEDUP_NEW unique new entries" >&2
    wiki_notify "[Wiki] Dedup: $DEDUP_DUPES duplicates skipped"
elif [ "$DEDUP_NEW" -gt 0 ]; then
    echo "  Dedup: $DEDUP_NEW new unique entries, no duplicates" >&2
fi

# ── Step 2: Find pending entries ─────────────────────────────────────────────

ENTRIES_JSON="[]"
COUNT=0

# Extracted entries in .entries/
for entry in "$ENTRIES_DIR"/*.md; do
    [ -f "$entry" ] || continue
    ENTRY_NAME="$(basename "$entry")"

    grep -qxF "$ENTRY_NAME" "$ABSORBED_FILE" 2>/dev/null && continue
    grep -qxF "$ENTRY_NAME" "$DEDUPED_FILE" 2>/dev/null && continue

    if [ -n "$MATCH_PATTERN" ]; then
        echo "$ENTRY_NAME" | grep -qi "$MATCH_PATTERN" 2>/dev/null || continue
    fi

    [ "$COUNT" -ge "$LIMIT" ] && break
    ENTRIES_JSON=$(echo "$ENTRIES_JSON" | jq --arg e ".entries/$ENTRY_NAME" '. + [$e]')
    COUNT=$((COUNT + 1))
done

# Markdown/HTML source files (readable directly)
if [ "$COUNT" -lt "$LIMIT" ]; then
    for subdir in markdown html; do
        srcdir="$WIKI_SOURCES_PATH/$subdir"
        [ -d "$srcdir" ] || continue
        for srcfile in "$srcdir"/*.md "$srcdir"/*.txt "$srcdir"/*.html "$srcdir"/*.htm; do
            [ -f "$srcfile" ] || continue
            srcname="source_$(basename "$srcfile")"

            grep -qxF "$srcname" "$ABSORBED_FILE" 2>/dev/null && continue

            if [ -n "$MATCH_PATTERN" ]; then
                echo "$srcname" | grep -qi "$MATCH_PATTERN" 2>/dev/null || continue
            fi

            [ "$COUNT" -ge "$LIMIT" ] && break
            REL_PATH="../sources/$subdir/$(basename "$srcfile")"
            ENTRIES_JSON=$(echo "$ENTRIES_JSON" | jq --arg e "$REL_PATH" '. + [$e]')
            COUNT=$((COUNT + 1))
        done
    done
fi

TOTAL_ABSORBED=$(wc -l < "$ABSORBED_FILE" | tr -d ' ')

# ── Output ───────────────────────────────────────────────────────────────────

if [ "$COUNT" -eq 0 ]; then
    echo "No pending entries to absorb." >&2
    jq -n --argjson extracted "${EXTRACTED:-0}" '{
        action: "batch",
        status: "nothing_to_absorb",
        extracted: $extracted,
        message: ("Extraction done (" + ($extracted | tostring) + " new). No pending entries to absorb.")
    }'
    exit 0
fi

if [ "$DRY_RUN" = true ]; then
    jq -n \
        --argjson extracted "${EXTRACTED:-0}" \
        --argjson pending "$COUNT" \
        --argjson entries "$ENTRIES_JSON" \
        '{
            action: "batch_dry_run",
            extracted: $extracted,
            pending: $pending,
            entries: $entries,
            message: ("Dry run: would absorb " + ($pending | tostring) + " entries.")
        }'
    exit 0
fi

echo "Step 2: $COUNT entries ready for absorption." >&2
wiki_notify "[Wiki] $COUNT entries ready for agent to absorb"

jq -n \
    --arg action "batch" \
    --argjson extracted "${EXTRACTED:-0}" \
    --argjson dedup_skipped "$DEDUP_DUPES" \
    --argjson pending "$COUNT" \
    --argjson total_absorbed "$TOTAL_ABSORBED" \
    --argjson entries "$ENTRIES_JSON" \
    --arg wiki_path "$WIKI_PATH" \
    --arg absorbed_file "$ABSORBED_FILE" \
    '{
        action: $action,
        extracted: $extracted,
        dedup_skipped: $dedup_skipped,
        pending: $pending,
        total_absorbed: $total_absorbed,
        wiki_path: $wiki_path,
        absorbed_file: $absorbed_file,
        entries: $entries,
        instructions: "Read each entry file listed in entries[]. For each entry, create wiki pages in appropriate type subdirectories following .schema.md. After processing each entry, append its filename to the absorbed_file. Update index.md and log.md. Run wiki-entry.sh reindex after finishing."
    }'
