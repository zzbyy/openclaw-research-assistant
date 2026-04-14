#!/bin/bash
# remote-install.sh — One-liner installer for the Wiki skill
# Clones the repo to a temp dir, runs install.sh, cleans up.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/zzbyy/openclaw-research-assistant/main/remote-install.sh | bash
#   curl -sSL ... | bash -s -- --ref dev
#
# Options:
#   --ref <branch|tag>  — checkout a specific branch or tag (default: main)

set -e

# Parse args
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

# Check dependencies
for cmd in git jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: $cmd is required. Install it first."
        exit 1
    fi
done

# Clone to temp dir
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Cloning openclaw-research-assistant (ref: $REF)..."
git clone --depth 1 --branch "$REF" \
    https://github.com/zzbyy/openclaw-research-assistant.git \
    "$TMPDIR/openclaw-research-assistant" 2>/dev/null || {
    # If --branch fails (e.g., ref is a commit), clone and checkout
    git clone https://github.com/zzbyy/openclaw-research-assistant.git \
        "$TMPDIR/openclaw-research-assistant"
    cd "$TMPDIR/openclaw-research-assistant"
    git checkout "$REF"
}

echo ""

# Run installer with stdin from terminal (not the pipe)
cd "$TMPDIR/openclaw-research-assistant"
chmod +x install.sh
exec bash install.sh </dev/tty
