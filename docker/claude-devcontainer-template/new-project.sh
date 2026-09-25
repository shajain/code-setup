#!/usr/bin/env bash
# Usage: ./new-project.sh /path/to/your/project
#
# Copies the .devcontainer template into an existing project folder
# so it can immediately be opened in Cursor as a dev container.

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 /path/to/your/project"
  exit 1
fi

TARGET="$1"
TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.devcontainer"

if [ ! -d "$TARGET" ]; then
  echo "Project folder does not exist: $TARGET"
  exit 1
fi

if [ -d "$TARGET/.devcontainer" ]; then
  echo "This project already has a .devcontainer folder — not overwriting."
  exit 1
fi

cp -r "$TEMPLATE_DIR" "$TARGET/.devcontainer"

echo "Added .devcontainer to: $TARGET"
echo "Now: open '$TARGET' in Cursor, then Cmd+Shift+P -> 'Dev Containers: Reopen in Container'"
