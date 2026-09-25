#!/usr/bin/env bash
# Run this ONCE, ever, on your Mac (not inside any container).
# It creates the shared folder that every future project container
# will bind-mount for Claude Code credentials — and if you're already
# logged in to Claude Code natively on your Mac, it reuses that login
# instead of making you log in again inside a container.

set -euo pipefail

SHARED_DIR="$HOME/.claude-shared"
NATIVE_CREDS="$HOME/.claude/.credentials.json"
NATIVE_CLAUDE_JSON="$HOME/.claude.json"

mkdir -p "$SHARED_DIR/.claude"

# --- .credentials.json (OAuth tokens) ---
if [ -f "$SHARED_DIR/.claude/.credentials.json" ]; then
  echo "Shared credentials already present — leaving as-is."
elif [ -f "$NATIVE_CREDS" ]; then
  cp "$NATIVE_CREDS" "$SHARED_DIR/.claude/.credentials.json"
  echo "Copied existing Mac login (.credentials.json) into shared folder."
else
  echo "No existing .credentials.json found on your Mac."
  echo "You'll need to log in once inside a container (run 'claude' there)."
fi

# --- .claude.json (onboarding/account metadata) ---
if [ -f "$SHARED_DIR/.claude.json" ]; then
  echo "Shared .claude.json already present — leaving as-is."
elif [ -f "$NATIVE_CLAUDE_JSON" ]; then
  cp "$NATIVE_CLAUDE_JSON" "$SHARED_DIR/.claude.json"
  echo "Copied existing Mac .claude.json into shared folder."
else
  echo "{}" > "$SHARED_DIR/.claude.json"
  echo "No existing .claude.json found — created an empty placeholder."
fi

if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ ! -f "$NATIVE_CREDS" ]; then
  echo ""
  echo "Note: if your Mac uses an ANTHROPIC_API_KEY instead of browser login,"
  echo "there's no credentials file to copy — add the key to devcontainer.json's"
  echo "containerEnv instead of relying on this mount."
fi

echo ""
echo "Shared Claude Code auth folder ready at: $SHARED_DIR"
echo "If nothing was copied above (no native Mac login found), open any"
echo "project in Cursor with the .devcontainer template, Reopen in"
echo "Container, then run 'claude' once inside it to log in."
echo "Every project container after that will already be authenticated."
