#!/bin/bash
# upgrade.sh — Pull latest from GitHub and update skill scripts in place
# Can be run from Feishu via /wiki upgrade — no terminal needed.
#
# Usage: upgrade.sh [--ref <branch|tag>]
# Env: WIKI_CONFIG_FILE

set -e

# Bootstrap: resolve config if not called via wiki-entry.sh
source "$(dirname "${BASH_SOURCE[0]}")/_bootstrap.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Parse args ───────────────────────────────────────────────────────────────

REF="main"
while [[ $# -gt 0 ]]; do
    case $1 in
        --ref)
            REF="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# ── Clone latest ─────────────────────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Pulling latest from GitHub (ref: $REF)..." >&2

if ! git clone --depth 1 --branch "$REF" \
    https://github.com/zzbyy/openclaw-research-assistant.git \
    "$TMPDIR/repo" 2>/dev/null; then
    jq -n '{"error": "Failed to clone repo. Check network connection."}'
    exit 1
fi

REPO_DIR="$TMPDIR/repo"

# ── Update scripts ───────────────────────────────────────────────────────────

echo "Updating skill scripts..." >&2

# Count changes
UPDATED=0

# SKILL.md and CLAUDE.md (skill instructions)
for f in SKILL.md CLAUDE.md; do
    if ! diff -q "$REPO_DIR/skill/wiki/$f" "$SKILL_DIR/$f" >/dev/null 2>&1; then
        cp "$REPO_DIR/skill/wiki/$f" "$SKILL_DIR/$f"
        UPDATED=$((UPDATED + 1))
        echo "  [OK] $f updated" >&2
    else
        echo "  [--] $f unchanged" >&2
    fi
done

# Scripts
for script in "$REPO_DIR/skill/wiki/scripts/"*.sh; do
    BASENAME="$(basename "$script")"
    DEST="$SKILL_DIR/scripts/$BASENAME"
    if [ ! -f "$DEST" ] || ! diff -q "$script" "$DEST" >/dev/null 2>&1; then
        cp "$script" "$DEST"
        chmod +x "$DEST"
        UPDATED=$((UPDATED + 1))
        echo "  [OK] $BASENAME updated" >&2
    else
        echo "  [--] $BASENAME unchanged" >&2
    fi
done

# ── Update vault schema ─────────────────────────────────────────────────────

CONFIG_FILE="$SKILL_DIR/config.json"
if [ -f "$CONFIG_FILE" ]; then
    _resolve_path() {
        local p="$1"
        [[ "$p" == '~/'* ]] && p="$HOME/${p:2}"
        echo "$p"
    }
    VAULT_PATH="$(_resolve_path "$(jq -r '.vault_path' "$CONFIG_FILE")")"
    WIKI_DIR_NAME="$(jq -r '.wiki_dir // "wiki"' "$CONFIG_FILE")"
    WIKI_DIR="$VAULT_PATH/$WIKI_DIR_NAME"

    if [ -d "$WIKI_DIR" ]; then
        echo "" >&2
        echo "Updating wiki schema..." >&2
        if ! diff -q "$REPO_DIR/wiki-schema/.schema.md" "$WIKI_DIR/.schema.md" >/dev/null 2>&1; then
            cp "$REPO_DIR/wiki-schema/.schema.md" "$WIKI_DIR/.schema.md"
            # Clean up old CLAUDE.md if it exists
            [ -f "$WIKI_DIR/CLAUDE.md" ] && rm -f "$WIKI_DIR/CLAUDE.md" && echo "  [OK] removed old wiki/CLAUDE.md" >&2
            UPDATED=$((UPDATED + 1))
            echo "  [OK] wiki/.schema.md updated" >&2
        else
            echo "  [--] wiki/.schema.md unchanged" >&2
        fi
        echo "  [--] wiki/index.md preserved" >&2
        echo "  [--] wiki/log.md preserved" >&2
    fi
fi

# ── Output ───────────────────────────────────────────────────────────────────

jq -n \
    --arg action "upgrade" \
    --argjson updated "$UPDATED" \
    --arg ref "$REF" \
    --arg skill_dir "$SKILL_DIR" \
    '{
        action: $action,
        ref: $ref,
        files_updated: $updated,
        skill_dir: $skill_dir,
        message: (if $updated > 0 then ($updated | tostring) + " files updated to latest." else "Already up to date." end),
        preserved: ["config.json", "wiki/index.md", "wiki/log.md", "wiki/pages/*", "sources/*"]
    }'
