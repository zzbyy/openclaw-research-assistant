#!/bin/bash
# install.sh — Installer for the Wiki skill
# First install: interactive prompts for scope and vault path
# Upgrade: auto-detects existing config, updates scripts only — no prompts
#
# Usage: install.sh              # auto-detect: fresh install or upgrade
#        install.sh --upgrade    # force upgrade mode (skip all prompts)
# Env overrides: WIKI_VAULT_PATH, WIKI_INSTALL_SCOPE (global|workspace), WIKI_AGENT_ID

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Ensure interactive stdin (for curl | bash) ──────────────────────────────
if [[ ! -t 0 ]]; then
    if [[ -e /dev/tty ]]; then
        exec </dev/tty
    else
        echo "Error: No terminal available for interactive input."
        echo "Run install.sh directly instead of piping."
        exit 1
    fi
fi

prompt() {
    local msg="$1"
    local default="$2"
    local result
    if [ -n "$default" ]; then
        read -r -p "$msg [$default]: " result
        echo "${result:-$default}"
    else
        read -r -p "$msg: " result
        echo "$result"
    fi
}

# ── Detect upgrade vs fresh install ──────────────────────────────────────────

FORCE_UPGRADE=false
if [ "$1" = "--upgrade" ]; then
    FORCE_UPGRADE=true
fi

# Search for existing config.json in known locations
find_existing_install() {
    # Check common skill locations
    for candidate in \
        "$HOME/.openclaw/skills/wiki/config.json" \
        "$HOME/.agents/skills/wiki/config.json" \
        "$HOME/.openclaw/workspace/skills/wiki/config.json"; do
        [ -f "$candidate" ] && echo "$(dirname "$candidate")" && return 0
    done

    # Check agent workspaces from openclaw.json
    local oc_config="$HOME/.openclaw/openclaw.json"
    if [ -f "$oc_config" ]; then
        while IFS= read -r ws; do
            [ -z "$ws" ] || [ "$ws" = "null" ] && continue
            # Tilde expansion
            [[ "$ws" == '~/'* ]] && ws="$HOME/${ws:2}"
            [ -f "$ws/skills/wiki/config.json" ] && echo "$ws/skills/wiki" && return 0
        done < <(jq -r '(.agents.list // [])[] | .workspace // empty' "$oc_config" 2>/dev/null)

        # Check default workspace
        local default_ws="$HOME/.openclaw/workspace"
        [ -f "$default_ws/skills/wiki/config.json" ] && echo "$default_ws/skills/wiki" && return 0
    fi

    return 1
}

EXISTING_INSTALL=""
EXISTING_INSTALL=$(find_existing_install) || true

if [ -n "$EXISTING_INSTALL" ] || [ "$FORCE_UPGRADE" = true ]; then
    # ═══════════════════════════════════════════════════════════════════════
    # UPGRADE MODE
    # ═══════════════════════════════════════════════════════════════════════

    if [ -z "$EXISTING_INSTALL" ]; then
        echo "No existing installation found. Run without --upgrade for fresh install."
        exit 1
    fi

    SKILL_DEST="$EXISTING_INSTALL"
    CONFIG_FILE="$SKILL_DEST/config.json"

    # Read existing config
    _resolve_path() {
        local p="$1"
        [[ "$p" == '~/'* ]] && p="$HOME/${p:2}"
        [[ "$p" == '~' ]] && p="$HOME"
        echo "$p"
    }
    VAULT_PATH="$(_resolve_path "$(jq -r '.vault_path' "$CONFIG_FILE")")"
    WIKI_DIR_NAME="$(jq -r '.wiki_dir // "wiki"' "$CONFIG_FILE")"
    WIKI_DIR="$VAULT_PATH/$WIKI_DIR_NAME"

    echo "========================================"
    echo "  Wiki Skill — Upgrade"
    echo "========================================"
    echo ""
    echo "Existing installation found:"
    echo "  Skill:  $SKILL_DEST"
    echo "  Vault:  $VAULT_PATH"
    echo "  Config: $CONFIG_FILE (preserved)"
    echo ""

    # Update scripts
    echo "Updating skill scripts..."
    mkdir -p "$SKILL_DEST/scripts"
    cp "$REPO_DIR/skill/wiki/SKILL.md" "$SKILL_DEST/SKILL.md"
    cp "$REPO_DIR/skill/wiki/CLAUDE.md" "$SKILL_DEST/CLAUDE.md"
    for script in "$REPO_DIR/skill/wiki/scripts/"*.sh; do
        cp "$script" "$SKILL_DEST/scripts/"
        chmod +x "$SKILL_DEST/scripts/$(basename "$script")"
    done
    echo "  [OK] SKILL.md"
    echo "  [OK] CLAUDE.md"
    echo "  [OK] scripts/ ($(ls "$SKILL_DEST/scripts/"*.sh 2>/dev/null | wc -l | tr -d ' ') files)"

    # Update vault schema (.schema.md only — index.md and log.md are user data)
    echo ""
    echo "Updating wiki schema..."
    if [ -d "$WIKI_DIR" ]; then
        cp "$REPO_DIR/wiki-schema/.schema.md" "$WIKI_DIR/.schema.md"
        # Clean up old CLAUDE.md if it exists
        [ -f "$WIKI_DIR/CLAUDE.md" ] && rm -f "$WIKI_DIR/CLAUDE.md" && echo "  [OK] removed old wiki/CLAUDE.md"
        echo "  [OK] wiki/.schema.md (schema updated)"
        echo "  [--] wiki/index.md (preserved)"
        echo "  [--] wiki/log.md (preserved)"
    else
        echo "  [!!] Wiki directory not found at $WIKI_DIR — skipping schema update"
    fi

    echo ""
    echo "========================================"
    echo "  Upgrade Complete"
    echo "========================================"
    echo ""
    echo "Config preserved at: $CONFIG_FILE"
    echo "Wiki pages, index, log, and sources are untouched."
    echo ""

    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
# FRESH INSTALL
# ═══════════════════════════════════════════════════════════════════════════════

echo "========================================"
echo "  Wiki Skill Installer"
echo "  Karpathy's LLM Wiki + v2 Extensions"
echo "========================================"
echo ""

# ── Prerequisites ────────────────────────────────────────────────────────────

echo "Checking prerequisites..."

# jq — required
if command -v jq &>/dev/null; then
    echo "  [OK] jq"
else
    echo "  [!!] jq — not found (required)"
    if command -v brew &>/dev/null; then
        INSTALL_JQ=$(prompt "  Install jq via Homebrew? (Y/n)" "Y")
        if [[ ! "$INSTALL_JQ" =~ ^[Nn] ]]; then
            brew install jq
            echo "  [OK] jq installed"
        else
            echo "  jq is required. Aborting."
            exit 1
        fi
    else
        echo "  Install jq manually: https://jqlang.github.io/jq/download/"
        exit 1
    fi
fi

# Claude Code — needed for --backend cc
HAS_CLAUDE=true
if command -v claude &>/dev/null; then
    echo "  [OK] claude"
else
    HAS_CLAUDE=false
    echo "  [!!] claude — not found (needed for --backend cc)"
    INSTALL_CLAUDE=$(prompt "  Install Claude Code now? (Y/n)" "Y")
    if [[ ! "$INSTALL_CLAUDE" =~ ^[Nn] ]]; then
        echo ""
        if command -v npm &>/dev/null; then
            echo "  Installing via npm..."
            npm install -g @anthropic-ai/claude-code && HAS_CLAUDE=true && echo "  [OK] claude installed" || {
                echo "  [!!] npm install failed. Trying brew..."
                if command -v brew &>/dev/null; then
                    brew install claude && HAS_CLAUDE=true && echo "  [OK] claude installed" || echo "  [!!] brew install also failed. Install manually: https://docs.anthropic.com/en/docs/claude-code"
                fi
            }
        elif command -v brew &>/dev/null; then
            echo "  Installing via Homebrew..."
            brew install claude && HAS_CLAUDE=true && echo "  [OK] claude installed" || echo "  [!!] Install failed. Install manually: https://docs.anthropic.com/en/docs/claude-code"
        else
            echo "  No npm or brew found. Install manually: https://docs.anthropic.com/en/docs/claude-code"
        fi
    else
        echo "  Skipping — /wiki commands with --backend cc won't work without it."
    fi
fi

# openclaw — recommended
if command -v openclaw &>/dev/null; then
    echo "  [OK] openclaw"
else
    echo "  [!!] openclaw — not found (recommended for Feishu integration)"
    echo "       Wiki skill will still work locally via scripts."
fi

echo ""

# ── Prompt 1: Install scope ─────────────────────────────────────────────────

INSTALL_SCOPE="${WIKI_INSTALL_SCOPE:-}"
OC_CONFIG="$HOME/.openclaw/openclaw.json"

if [ -z "$INSTALL_SCOPE" ]; then
    echo "Where should the wiki skill be installed?"
    echo ""

    OPTIONS_ID=()
    OPTIONS_DESC=()
    OPTIONS_WORKSPACE=()

    OPTIONS_ID+=("__global__")
    OPTIONS_DESC+=("Global — all agents can use it (~/.agents/skills/wiki/)")
    OPTIONS_WORKSPACE+=("")

    DEFAULT_WORKSPACE="$HOME/.openclaw/workspace"
    if [ -f "$OC_CONFIG" ]; then
        AGENT_LIST_COUNT=$(jq -r '.agents.list // [] | length' "$OC_CONFIG" 2>/dev/null || echo "0")
        if [ "$AGENT_LIST_COUNT" -gt 0 ]; then
            while IFS=$'\t' read -r agent_id agent_name agent_workspace; do
                [ -z "$agent_id" ] && continue
                display_name="${agent_name:-$agent_id}"
                if [ -z "$agent_workspace" ] || [ "$agent_workspace" = "null" ]; then
                    agent_workspace="$DEFAULT_WORKSPACE"
                fi
                OPTIONS_ID+=("$agent_id")
                OPTIONS_DESC+=("Agent: $display_name ($agent_workspace)")
                OPTIONS_WORKSPACE+=("$agent_workspace")
            done < <(jq -r '.agents.list[] | [.id, (.name // ""), (.workspace // "")] | @tsv' "$OC_CONFIG" 2>/dev/null)
        else
            OPTIONS_ID+=("main")
            OPTIONS_DESC+=("Agent: main ($DEFAULT_WORKSPACE)")
            OPTIONS_WORKSPACE+=("$DEFAULT_WORKSPACE")
        fi
    else
        OPTIONS_ID+=("main")
        OPTIONS_DESC+=("Agent: main ($DEFAULT_WORKSPACE)")
        OPTIONS_WORKSPACE+=("$DEFAULT_WORKSPACE")
    fi

    for i in "${!OPTIONS_DESC[@]}"; do
        echo "  $((i + 1))) ${OPTIONS_DESC[$i]}"
    done
    echo ""

    SCOPE_CHOICE=$(prompt "Enter choice" "1")

    if ! [[ "$SCOPE_CHOICE" =~ ^[0-9]+$ ]] || [ "$SCOPE_CHOICE" -lt 1 ] || [ "$SCOPE_CHOICE" -gt "${#OPTIONS_ID[@]}" ]; then
        echo "Invalid choice: $SCOPE_CHOICE"
        exit 1
    fi

    IDX=$((SCOPE_CHOICE - 1))
    SELECTED_ID="${OPTIONS_ID[$IDX]}"
    SELECTED_WORKSPACE="${OPTIONS_WORKSPACE[$IDX]}"

    if [ "$SELECTED_ID" = "__global__" ]; then
        INSTALL_SCOPE="global"
    else
        INSTALL_SCOPE="workspace"
        AGENT_ID="$SELECTED_ID"
        AGENT_WORKSPACE="$SELECTED_WORKSPACE"
    fi
fi

if [ "$INSTALL_SCOPE" = "global" ]; then
    SKILL_DEST="$HOME/.agents/skills/wiki"
    echo "  -> Installing globally to $SKILL_DEST"
else
    AGENT_ID="${AGENT_ID:-${WIKI_AGENT_ID:-}}"
    if [ -z "$AGENT_ID" ]; then
        AGENT_ID=$(prompt "Enter agent ID" "")
        if [ -z "$AGENT_ID" ]; then
            echo "Agent ID required for workspace install."
            exit 1
        fi
    fi

    if [ -z "$AGENT_WORKSPACE" ] && [ -f "$OC_CONFIG" ]; then
        AGENT_WORKSPACE=$(jq -r --arg id "$AGENT_ID" \
            '(.agents.list // [])[] | select(.id == $id) | .workspace // ""' \
            "$OC_CONFIG" 2>/dev/null || echo "")
    fi
    if [ -z "$AGENT_WORKSPACE" ] || [ "$AGENT_WORKSPACE" = "null" ]; then
        AGENT_WORKSPACE="$HOME/.openclaw/workspace"
    fi
    if [[ "$AGENT_WORKSPACE" == '~/'* ]]; then
        AGENT_WORKSPACE="$HOME/${AGENT_WORKSPACE:2}"
    fi

    SKILL_DEST="${AGENT_WORKSPACE}/skills/wiki"
    echo "  -> Installing to agent '$AGENT_ID' workspace: $SKILL_DEST"
fi

echo ""

# ── Prompt 2: Obsidian vault path ───────────────────────────────────────────

VAULT_PATH="${WIKI_VAULT_PATH:-}"

if [ -z "$VAULT_PATH" ]; then
    echo "Enter the path to your Obsidian vault."
    echo "(This is where wiki pages and sources will live.)"
    echo ""
    VAULT_PATH=$(prompt "Obsidian vault path" "")
fi

if [ -z "$VAULT_PATH" ]; then
    echo "Vault path is required."
    exit 1
fi

if [[ "$VAULT_PATH" == '~/'* ]]; then
    VAULT_PATH="$HOME/${VAULT_PATH:2}"
elif [[ "$VAULT_PATH" == '~' ]]; then
    VAULT_PATH="$HOME"
fi

if [ ! -d "$VAULT_PATH" ]; then
    echo ""
    echo "Vault directory does not exist: $VAULT_PATH"
    CREATE_VAULT=$(prompt "Create it? (y/N)" "N")
    if [[ "$CREATE_VAULT" =~ ^[Yy] ]]; then
        mkdir -p "$VAULT_PATH"
        echo "  [OK] Created $VAULT_PATH"
    else
        exit 1
    fi
fi

echo ""

# Default backend: auto-detect
HAS_CLAUDE=${HAS_CLAUDE:-false}
if [ "$HAS_CLAUDE" = true ]; then
    DEFAULT_BACKEND="cc"
else
    DEFAULT_BACKEND="agent"
fi

echo "========================================"
echo "  Installing..."
echo "========================================"
echo ""

# ── Create vault wiki structure ──────────────────────────────────────────────

WIKI_DIR="$VAULT_PATH/wiki"
PAGES_DIR="$WIKI_DIR/pages"
SOURCES_DIR="$VAULT_PATH/sources"

echo "Creating wiki directories..."
mkdir -p "$PAGES_DIR"
mkdir -p "$SOURCES_DIR"/{pdfs,html,epub,markdown}
echo "  [OK] $WIKI_DIR/"
echo "  [OK] $WIKI_DIR/pages/"
echo "  [OK] $SOURCES_DIR/{pdfs,html,epub,markdown}/"

# ── Install schema files ────────────────────────────────────────────────────

echo ""
echo "Installing schema files..."

install_if_missing() {
    local src="$1"
    local dest="$2"
    if [ -f "$dest" ]; then
        echo "  [--] $(basename "$dest") already exists, skipping"
    else
        cp "$src" "$dest"
        echo "  [OK] $(basename "$dest")"
    fi
}

install_if_missing "$REPO_DIR/wiki-schema/.schema.md" "$WIKI_DIR/.schema.md"
install_if_missing "$REPO_DIR/wiki-schema/index.md" "$WIKI_DIR/index.md"
install_if_missing "$REPO_DIR/wiki-schema/log.md" "$WIKI_DIR/log.md"

# ── Install skill ───────────────────────────────────────────────────────────

echo ""
echo "Installing skill to $SKILL_DEST..."
mkdir -p "$SKILL_DEST/scripts"

cp "$REPO_DIR/skill/wiki/SKILL.md" "$SKILL_DEST/SKILL.md"
cp "$REPO_DIR/skill/wiki/CLAUDE.md" "$SKILL_DEST/CLAUDE.md"

for script in "$REPO_DIR/skill/wiki/scripts/"*.sh; do
    cp "$script" "$SKILL_DEST/scripts/"
    chmod +x "$SKILL_DEST/scripts/$(basename "$script")"
done

echo "  [OK] SKILL.md"
echo "  [OK] CLAUDE.md"
echo "  [OK] scripts/ ($(ls "$SKILL_DEST/scripts/"*.sh 2>/dev/null | wc -l | tr -d ' ') files)"

# ── Write config ─────────────────────────────────────────────────────────────

CONFIG_FILE="$SKILL_DEST/config.json"

echo ""
echo "Writing config to $CONFIG_FILE..."

VAULT_PATH_CONFIG="$VAULT_PATH"
if [[ "$VAULT_PATH" == "$HOME"* ]]; then
    VAULT_PATH_CONFIG="~${VAULT_PATH#$HOME}"
fi

jq -n \
    --arg vault "$VAULT_PATH_CONFIG" \
    --arg backend "$DEFAULT_BACKEND" \
    '{
        vault_path: $vault,
        wiki_dir: "wiki",
        sources_dir: "sources",
        default_backend: $backend,
        cc_bridge: {
            dispatch_path: "~/.agents/skills/cc/scripts/dispatch.sh",
            model: "",
            timeout_minutes: 30
        },
        notifications: {
            ingest_complete: true,
            query_result: true,
            lint_report: true
        },
        cron: {
            lint: { enabled: false, schedule: "sunday 9am", backend: "cc" },
            ingest: { enabled: false, schedule: "daily 6am", backend: "cc" }
        },
        confidence: {
            stale_after_days: 90
        }
    }' > "$CONFIG_FILE"

echo "  [OK] config.json"

# ── Check / install cc-bridge ────────────────────────────────────────────────

echo ""
CC_DISPATCH="$HOME/.agents/skills/cc/scripts/dispatch.sh"
if [ -f "$CC_DISPATCH" ]; then
    echo "[OK] cc-bridge detected at $CC_DISPATCH"
else
    echo "[!!] cc-bridge not found."
    echo "     /wiki commands with --backend cc require cc-bridge."
    if [ "$HAS_CLAUDE" = true ]; then
        INSTALL_BRIDGE=$(prompt "  Install cc-bridge now? (Y/n)" "Y")
        if [[ ! "$INSTALL_BRIDGE" =~ ^[Nn] ]]; then
            echo "  Installing cc-bridge from GitHub..."
            BRIDGE_TMPDIR=$(mktemp -d)
            if git clone --depth 1 https://github.com/zzbyy/openclaw-cc-bridge.git "$BRIDGE_TMPDIR/openclaw-cc-bridge" 2>/dev/null; then
                chmod +x "$BRIDGE_TMPDIR/openclaw-cc-bridge/install.sh"
                bash "$BRIDGE_TMPDIR/openclaw-cc-bridge/install.sh"
                rm -rf "$BRIDGE_TMPDIR"
                if [ -f "$CC_DISPATCH" ]; then
                    echo "  [OK] cc-bridge installed"
                else
                    echo "  [!!] cc-bridge install may have partially failed. Check ~/.agents/skills/cc/"
                fi
            else
                rm -rf "$BRIDGE_TMPDIR"
                echo "  [!!] Failed to clone cc-bridge. Install manually:"
                echo "       curl -sSL https://raw.githubusercontent.com/zzbyy/openclaw-cc-bridge/main/remote-install.sh | bash"
            fi
        else
            echo "  Skipping — install later with:"
            echo "  curl -sSL https://raw.githubusercontent.com/zzbyy/openclaw-cc-bridge/main/remote-install.sh | bash"
        fi
    else
        echo "  Claude Code is also not installed, so cc-bridge won't help yet."
        echo "  Install both later, or use --backend agent for now."
    fi
fi

# ── Check / install QMD (semantic search) ────────────────────────────────────

echo ""
if command -v qmd &>/dev/null; then
    echo "[OK] QMD detected — semantic search enabled"
    # Register wiki pages collection if not already
    if ! qmd collections list 2>/dev/null | grep -q "wiki"; then
        echo "  Registering wiki pages with QMD..."
        qmd add "$PAGES_DIR" --name wiki 2>/dev/null || qmd add "$PAGES_DIR" 2>/dev/null || true
        echo "  [OK] wiki collection registered"
    fi
else
    echo "[!!] QMD not installed (optional — enables semantic search)"
    INSTALL_QMD=$(prompt "  Install QMD now? (Y/n)" "Y")
    if [[ ! "$INSTALL_QMD" =~ ^[Nn] ]]; then
        echo "  Installing QMD..."
        if command -v npm &>/dev/null; then
            npm install -g qmd 2>&1 | tail -3 && {
                echo "  [OK] QMD installed"
                echo "  Registering wiki pages..."
                qmd add "$PAGES_DIR" --name wiki 2>/dev/null || qmd add "$PAGES_DIR" 2>/dev/null || true
                echo "  [OK] wiki collection registered"
                echo "  Run '/wiki reindex' after ingesting pages to build the search index."
            } || echo "  [!!] QMD install failed. Install manually: npm install -g qmd"
        else
            echo "  No npm found. Install manually: npm install -g qmd"
        fi
    else
        echo "  Skipping — search will use grep fallback."
        echo "  Install later: npm install -g qmd"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "========================================"
echo "  Installation Complete"
echo "========================================"
echo ""
echo "Wiki location:   $WIKI_DIR/"
echo "Sources:         $SOURCES_DIR/"
echo "Skill installed: $SKILL_DEST/"
echo "Config:          $CONFIG_FILE"
echo "Default backend: $DEFAULT_BACKEND"
echo ""
echo "Next steps — follow the walkthrough to get started:"
echo "  https://github.com/zzbyy/openclaw-research-assistant/blob/main/WALKTHROUGH.md"
echo ""
echo "Quick start:"
echo "  1. /wiki status                              — verify installation"
echo "  2. /wiki ingest ~/papers/your-paper.pdf      — ingest your first paper"
echo "  3. /wiki query \"what is ...?\"                 — ask the wiki a question"
echo "  4. /wiki reindex                             — build search index (after ingesting)"
