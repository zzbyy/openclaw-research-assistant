#!/bin/bash
# install.sh — Interactive installer for the Wiki skill
# Three prompts: install scope, vault path, default backend
# Then auto-setup: directories, schema, skill, config
#
# Usage: install.sh
# Env overrides: WIKI_VAULT_PATH, WIKI_INSTALL_SCOPE (global|workspace), WIKI_AGENT_ID, WIKI_DEFAULT_BACKEND

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================"
echo "  Wiki Skill Installer"
echo "  Karpathy's LLM Wiki + v2 Extensions"
echo "========================================"
echo ""

# ── Prerequisites ────────────────────────────────────────────────────────────

check_prereq() {
    if command -v "$1" &>/dev/null; then
        echo "  [OK] $1"
        return 0
    else
        echo "  [!!] $1 — not found ($2)"
        return 1
    fi
}

echo "Checking prerequisites..."
check_prereq jq "required — install with: brew install jq" || exit 1
check_prereq openclaw "recommended — wiki commands via Feishu won't work without it" || true
HAS_CLAUDE=true
check_prereq claude "optional — needed for --backend cc (Claude Code dispatch)" || HAS_CLAUDE=false
echo ""

# ── Prompt 1: Install scope ─────────────────────────────────────────────────

INSTALL_SCOPE="${WIKI_INSTALL_SCOPE:-}"

if [ -z "$INSTALL_SCOPE" ]; then
    echo "Where should the wiki skill be installed?"
    echo "  1) Global — all agents can use it (~/.agents/skills/wiki/)"
    echo "  2) Agent workspace — specific agent only"
    echo ""
    read -r -p "Enter choice [1]: " SCOPE_CHOICE
    SCOPE_CHOICE="${SCOPE_CHOICE:-1}"

    case "$SCOPE_CHOICE" in
        1) INSTALL_SCOPE="global" ;;
        2) INSTALL_SCOPE="workspace" ;;
        *) echo "Invalid choice"; exit 1 ;;
    esac
fi

if [ "$INSTALL_SCOPE" = "global" ]; then
    SKILL_DEST="$HOME/.agents/skills/wiki"
else
    AGENT_ID="${WIKI_AGENT_ID:-}"
    if [ -z "$AGENT_ID" ]; then
        echo ""
        # List available workspaces if possible
        if [ -d "$HOME/.agents/workspaces" ]; then
            echo "Available agent workspaces:"
            for ws in "$HOME/.agents/workspaces"/*/; do
                [ -d "$ws" ] && echo "  - $(basename "$ws")"
            done
            echo ""
        fi
        read -r -p "Enter agent ID: " AGENT_ID
        if [ -z "$AGENT_ID" ]; then
            echo "Agent ID required for workspace install."
            exit 1
        fi
    fi
    SKILL_DEST="$HOME/.agents/workspaces/${AGENT_ID}/skills/wiki"
fi

echo ""

# ── Prompt 2: Obsidian vault path ───────────────────────────────────────────

VAULT_PATH="${WIKI_VAULT_PATH:-}"

if [ -z "$VAULT_PATH" ]; then
    read -r -p "Enter your Obsidian vault path: " VAULT_PATH
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
    echo "Vault directory does not exist: $VAULT_PATH"
    read -r -p "Create it? [y/N]: " CREATE_VAULT
    if [[ "$CREATE_VAULT" =~ ^[Yy] ]]; then
        mkdir -p "$VAULT_PATH"
    else
        exit 1
    fi
fi

echo ""

# ── Prompt 3: Default backend ───────────────────────────────────────────────

DEFAULT_BACKEND="${WIKI_DEFAULT_BACKEND:-}"

if [ -z "$DEFAULT_BACKEND" ]; then
    echo "Default backend for wiki operations?"
    echo "  1) cc — Claude Code via cc-bridge (recommended for heavy lifting)"
    echo "  2) agent — OpenClaw research agent handles directly"
    echo ""
    read -r -p "Enter choice [1]: " BACKEND_CHOICE
    BACKEND_CHOICE="${BACKEND_CHOICE:-1}"

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

# ── Check cc-bridge ──────────────────────────────────────────────────────────

echo ""
CC_DISPATCH="$HOME/.agents/skills/cc/scripts/dispatch.sh"
if [ -f "$CC_DISPATCH" ]; then
    echo "[OK] cc-bridge detected at $CC_DISPATCH"
else
    echo "[!!] cc-bridge not found."
    echo "     /wiki commands with --backend cc will fail."
    echo "     Install from: https://github.com/zzbyy/openclaw-cc-bridge"
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
