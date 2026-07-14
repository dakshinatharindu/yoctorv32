#!/usr/bin/env bash
# Symlinks ~/.claude and ~/.claude.json into the workspace folder so Claude
# Code's session history/config survive devcontainer rebuilds (the container's
# home directory is ephemeral, but the workspace bind mount is not).
set -euo pipefail

PERSIST_DIR="/workspaces/yoctorv32/.devcontainer/.claude-persist"
mkdir -p "$PERSIST_DIR"

# Migrate any existing state on first run, without clobbering later ones.
if [ -d "$HOME/.claude" ] && [ ! -L "$HOME/.claude" ]; then
  if [ -d "$PERSIST_DIR/claude" ]; then
    cp -rn "$HOME/.claude/." "$PERSIST_DIR/claude/" 2>/dev/null || true
    rm -rf "$HOME/.claude"
  else
    mv "$HOME/.claude" "$PERSIST_DIR/claude"
  fi
fi
if [ -f "$HOME/.claude.json" ] && [ ! -L "$HOME/.claude.json" ]; then
  if [ ! -f "$PERSIST_DIR/claude.json" ]; then
    mv "$HOME/.claude.json" "$PERSIST_DIR/claude.json"
  else
    rm -f "$HOME/.claude.json"
  fi
fi

mkdir -p "$PERSIST_DIR/claude"
touch "$PERSIST_DIR/claude.json"

ln -sfn "$PERSIST_DIR/claude" "$HOME/.claude"
ln -sf "$PERSIST_DIR/claude.json" "$HOME/.claude.json"
