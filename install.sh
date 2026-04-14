#!/bin/bash
# install.sh — Interactive installer for the Wiki skill
# Prompts for: install scope (global or agent workspace), vault path, default backend
# Then auto-setup: directories, schema, skill, config
#
# Usage: install.sh
# Env overrides: WIKI_VAULT_PATH, WIKI_INSTALL_SCOPE (global|workspace), WIKI_AGENT_ID, WIKI_DEFAULT_BACKEND

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Ensure interactive stdin ─────────────────────────────────────────────────
# When run via curl | bash, stdin is the pipe. Reopen from /dev/tty so read works.
if [[ ! -t 0 ]]; then
    if [[ -e /dev/tty ]]; then
        exec </dev/tty
    else
        echo "Error: No terminal available for interactive input."
        echo "Run install.sh directly instead of piping."
        exit 1
    fi
fi

# Helper: prompt with default value, always waits for input
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
        INSTALL_JQ=$(prompt "  Install jq via Homebrew? [Y/n]" "Y")
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

    # Build the options list: global + agents from openclaw.json agents.list[]
    OPTIONS_ID=()
    OPTIONS_DESC=()
    OPTIONS_WORKSPACE=()

    # Option 1: Global
    OPTIONS_ID+=("__global__")
    OPTIONS_DESC+=("Global — all agents can use it (~/.agents/skills/wiki/)")
    OPTIONS_WORKSPACE+=("")

    # Read agents from openclaw.json .agents.list[]
    DEFAULT_WORKSPACE="$HOME/.openclaw/workspace"
    if [ -f "$OC_CONFIG" ]; then
        AGENT_LIST_COUNT=$(jq -r '.agents.list // [] | length' "$OC_CONFIG" 2>/dev/null || echo "0")
        if [ "$AGENT_LIST_COUNT" -gt 0 ]; then
            while IFS=$'\t' read -r agent_id agent_name agent_workspace; do
                [ -z "$agent_id" ] && continue
                display_name="${agent_name:-$agent_id}"
                # If no workspace specified, use default
                if [ -z "$agent_workspace" ] || [ "$agent_workspace" = "null" ]; then
                    agent_workspace="$DEFAULT_WORKSPACE"
                fi
                OPTIONS_ID+=("$agent_id")
                OPTIONS_DESC+=("Agent: $display_name ($agent_workspace)")
                OPTIONS_WORKSPACE+=("$agent_workspace")
            done < <(jq -r '.agents.list[] | [.id, (.name // ""), (.workspace // "")] | @tsv' "$OC_CONFIG" 2>/dev/null)
        else
            # No agents.list — single default agent
            OPTIONS_ID+=("main")
            OPTIONS_DESC+=("Agent: main ($DEFAULT_WORKSPACE)")
            OPTIONS_WORKSPACE+=("$DEFAULT_WORKSPACE")
        fi
    else
        # No openclaw.json — offer default
        OPTIONS_ID+=("main")
        OPTIONS_DESC+=("Agent: main ($DEFAULT_WORKSPACE)")
        OPTIONS_WORKSPACE+=("$DEFAULT_WORKSPACE")
    fi

    # Display numbered list
    for i in "${!OPTIONS_DESC[@]}"; do
        echo "  $((i + 1))) ${OPTIONS_DESC[$i]}"
    done
    echo ""

    SCOPE_CHOICE=$(prompt "Enter choice" "1")

    # Validate choice
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

    # Resolve workspace path if not already set from the picker
    if [ -z "$AGENT_WORKSPACE" ] && [ -f "$OC_CONFIG" ]; then
        AGENT_WORKSPACE=$(jq -r --arg id "$AGENT_ID" \
            '(.agents.list // [])[] | select(.id == $id) | .workspace // ""' \
            "$OC_CONFIG" 2>/dev/null || echo "")
    fi
    # Fallback to default workspace
    if [ -z "$AGENT_WORKSPACE" ] || [ "$AGENT_WORKSPACE" = "null" ]; then
        AGENT_WORKSPACE="$HOME/.openclaw/workspace"
    fi
    # Safe tilde expansion
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

# Safe tilde expansion
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

# ── Prompt 3: Default backend ───────────────────────────────────────────────

DEFAULT_BACKEND="${WIKI_DEFAULT_BACKEND:-}"

if [ -z "$DEFAULT_BACKEND" ]; then
    echo "Default backend for wiki operations?"
    echo ""
    if [ "$HAS_CLAUDE" = true ]; then
        echo "  1) cc    — Claude Code via cc-bridge (recommended for heavy lifting)"
        echo "  2) agent — OpenClaw research agent handles directly"
        echo ""
        BACKEND_CHOICE=$(prompt "Enter choice" "1")
    else
        echo "  Claude Code is not installed — defaulting to agent backend."
        echo "  You can switch later with: /wiki config default_backend cc"
        echo ""
        echo "  1) agent — OpenClaw research agent (recommended)"
        echo "  2) cc    — Claude Code via cc-bridge (install Claude Code first)"
        echo ""
        BACKEND_CHOICE=$(prompt "Enter choice" "1")
        # Remap: 1=agent, 2=cc when Claude not installed
        case "$BACKEND_CHOICE" in
            1) BACKEND_CHOICE="2" ;;  # maps to agent
            2) BACKEND_CHOICE="1" ;;  # maps to cc
        esac
    fi

    case "$BACKEND_CHOICE" in
        1) DEFAULT_BACKEND="cc" ;;
        2) DEFAULT_BACKEND="agent" ;;
        *) echo "Invalid choice"; exit 1 ;;
    esac
fi

echo ""
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

install_if_missing "$REPO_DIR/wiki-schema/CLAUDE.md" "$WIKI_DIR/CLAUDE.md"
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

CONFIG_DIR="$HOME/.openclaw/wiki"
CONFIG_FILE="$CONFIG_DIR/config.json"

echo ""
echo "Writing config to $CONFIG_FILE..."
mkdir -p "$CONFIG_DIR"

# Use raw vault path (with ~ for portability) if it starts with $HOME
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
echo "Commands available:"
echo "  /wiki ingest <path>     — Ingest a paper or article"
echo "  /wiki query <question>  — Ask the wiki a question"
echo "  /wiki lint              — Health check the wiki"
echo "  /wiki search <term>     — Search wiki pages"
echo "  /wiki status            — Wiki statistics"
echo "  /wiki browse <page>     — Read a wiki page"
echo "  /wiki related <page>    — Find related pages"
echo "  /wiki config            — View/update configuration"
echo "  /wiki cron              — Manage scheduled jobs"
echo ""
echo "Quick test:"
echo "  /wiki status"
echo ""
echo "To ingest your first paper:"
echo "  /wiki ingest ~/papers/your-paper.pdf"
