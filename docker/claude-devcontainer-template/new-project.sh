#!/usr/bin/env bash
# Usage: ./new-project.sh /path/to/your/project
#
# Copies the .devcontainer template into an existing project folder so it can
# be opened as a dev container, and sets it up so that:
#   - you work as the "vscode" user, not root
#   - /workspaces can be entered and written by that user
#   - git works over SSH through the Mac's SSH agent (no key files mounted)
#
# Run this on the Mac (the host), not inside a container.

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 /path/to/your/project"
  exit 1
fi

TARGET="$(cd "$1" 2>/dev/null && pwd)" || { echo "Project folder does not exist: $1"; exit 1; }
TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.devcontainer"
DEST="$TARGET/.devcontainer"

if [ ! -d "$TEMPLATE_DIR" ]; then
  echo "Template not found: $TEMPLATE_DIR"
  exit 1
fi

if [ -d "$DEST" ]; then
  echo "This project already has a .devcontainer folder — not overwriting."
  exit 1
fi

cp -r "$TEMPLATE_DIR" "$DEST"
echo "Added .devcontainer to: $TARGET"

# ---------------------------------------------------------------------------
# 1. Post-create script: runs inside the container after it's built.
# ---------------------------------------------------------------------------
cat > "$DEST/post-create.sh" <<'EOF'
#!/usr/bin/env bash
# Runs inside the container once, after it is created (as the remoteUser).
set -uo pipefail

ME="$(id -un)"

# /workspaces sometimes comes up as root-owned with mode drw-------, which
# means nobody but root can cd into it or create sibling folders there.
sudo chown "$ME:$ME" /workspaces 2>/dev/null || true
sudo chmod 755 /workspaces 2>/dev/null || true

# A place you own for cloning other repos (e.g. ~/tools/AI-commenting-tool).
mkdir -p "$HOME/tools"

# The project is bind-mounted from the Mac and may show as owned by root.
# Tell git that's fine, so it doesn't refuse with "dubious ownership".
# Uses the system config: ~/.gitconfig is mounted from the Mac as a single
# file and can't be rewritten from inside the container.
sudo git config --system --add safe.directory "$PWD" \
  || echo "WARNING: could not mark $PWD as a git safe.directory."

# Check the project folder is writable (ACLs on Mac mounts usually allow it).
if touch .write-test 2>/dev/null; then
  rm -f .write-test
else
  echo "WARNING: $PWD is not writable by $ME."
  echo "         Fix the folder's permissions on the Mac, then rebuild the container."
fi

# Check the SSH agent forwarded from the Mac has a key in it.
if ssh-add -l >/dev/null 2>&1; then
  echo "SSH agent OK: $(ssh-add -l | head -n1)"
else
  echo "WARNING: the forwarded SSH agent has no keys."
  echo "         On the Mac run: ssh-add --apple-use-keychain ~/.ssh/id_rsa"
  echo "         then rebuild the container to finish setup."
  exit 0
fi

# ---------------------------------------------------------------------------
# Install the AI commenting tool and set up this project with it.
# ---------------------------------------------------------------------------
PROJECT="$PWD"
TOOL_REPO="git@github.com:shajain/AI-commenting-tool.git"
TOOL_DIR="$HOME/tools/AI-commenting-tool"

# pip may put the command in ~/.local/bin; make sure this script can find it.
export PATH="$HOME/.local/bin:$PATH"

# Accept GitHub's host key without an interactive prompt.
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"

if [ -d "$TOOL_DIR/.git" ]; then
  echo "Updating $TOOL_DIR..."
  git -C "$TOOL_DIR" pull --ff-only || echo "WARNING: git pull failed; using the existing copy."
else
  echo "Cloning AI-commenting-tool into $TOOL_DIR..."
  if ! git clone "$TOOL_REPO" "$TOOL_DIR"; then
    echo "WARNING: clone failed. Check 'ssh -T git@github.com', then rebuild the container."
    exit 0
  fi
fi

cd "$TOOL_DIR"
if ! python3 -m pip install -e .; then
  echo "WARNING: pip install failed; see the error above."
  exit 0
fi

# The editor extension is installed by post-attach.sh instead: the editor's
# 'code' command doesn't exist yet at this point in container creation.

cd "$PROJECT"
if command -v ai-commenting >/dev/null 2>&1; then
  ai-commenting build . || echo "WARNING: 'ai-commenting build .' failed."
  ai-commenting install-agent . || echo "WARNING: 'ai-commenting install-agent .' failed."
else
  echo "WARNING: ai-commenting command not found on PATH after install."
fi
EOF
chmod +x "$DEST/post-create.sh"

# ---------------------------------------------------------------------------
# 1b. Post-attach script: runs each time the editor connects, when the
#     editor's 'code' command is available. Installs the extension once.
# ---------------------------------------------------------------------------
cat > "$DEST/post-attach.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

TOOL_DIR="$HOME/tools/AI-commenting-tool"
[ -d "$TOOL_DIR" ] || exit 0   # post-create didn't install the tool; nothing to do
PY=python3
say() { echo "$@"; }

# --- Install the extension only when the tool's version is newer ------------
# Cursor/VS Code can't cleanly reinstall the SAME version of an extension
# that's in use, so this only ever installs a higher version number. To ship a
# changed extension, raise "version" in vscode-extension/package.json.
EDITOR_DIRS=("$HOME/.vscode-server" "$HOME/.vscode-server-insiders" "$HOME/.cursor-server")
PKG="$TOOL_DIR/vscode-extension/package.json"
BUILD_VER="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PKG" 2>/dev/null)"
if [ -z "$BUILD_VER" ]; then
  echo "WARNING: can't read the extension's version from $PKG"
  exit 0
fi

# Highest installed version, ignoring copies already marked for removal.
# Extension folders are named <publisher>.<name>-<version>.
installed_version() {
  local d ext base
  for d in "${EDITOR_DIRS[@]}"; do
    for ext in "$d"/extensions/*ai-commenting*; do
      [ -d "$ext" ] || continue
      base="$(basename "$ext")"
      grep -qF "\"$base\"" "$d/extensions/.obsolete" 2>/dev/null && continue
      echo "${base##*-}"
    done
  done | sort -V | tail -n1
}
version_gt() {   # is $1 a higher version than $2?
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

INSTALLED="$(installed_version)"
if [ -n "$INSTALLED" ] && ! version_gt "$BUILD_VER" "$INSTALLED"; then
  if [ "$INSTALLED" = "$BUILD_VER" ]; then
    say "AI commenting extension $INSTALLED is installed and up to date."
  else
    say "Installed AI commenting extension $INSTALLED is newer than the tool's $BUILD_VER; leaving it."
  fi
  say "(To install a changed extension, raise \"version\" in $PKG.)"
  exit 0
fi

# This exact version waiting to be removed blocks installing it again.
for d in "${EDITOR_DIRS[@]}"; do
  if grep -qF -- "-$BUILD_VER\"" "$d/extensions/.obsolete" 2>/dev/null \
     && grep -qi 'ai-commenting' "$d/extensions/.obsolete"; then
    say "Version $BUILD_VER of the extension is waiting to be removed by the editor."
    say "Restart the editor's server first (close the window and reconnect), then run this again."
    exit 0
  fi
done

# Find the editor's server program (VS Code: code-server, Cursor: cursor-server),
# whatever folder layout this editor version uses. Newest first.
find_editor_server() {
  local d
  for d in "${EDITOR_DIRS[@]}"; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 8 -type f -perm -u+x \
         \( -name code-server -o -name code-server-insiders -o -name cursor-server \) \
         -not -path '*/remote-cli/*' -printf '%T@ %p\n' 2>/dev/null
  done | sort -rn | head -n1 | cut -d' ' -f2-
}
SERVER="$(find_editor_server)"
if [ -z "$SERVER" ]; then
  say "Editor server not found yet; connect with VS Code or Cursor first, then run this again."
  say "(looked in ~/.vscode-server, ~/.vscode-server-insiders and ~/.cursor-server)"
  exit 0
fi

# Build the .vsix (without --install, which needs the editor's 'code' command).
cd "$TOOL_DIR"
"$PY" vscode-extension/package_vsix.py >/dev/null 2>&1 || true
VSIX="$(ls -t vscode-extension/dist/*-"$BUILD_VER".vsix 2>/dev/null | head -n1)"
[ -n "$VSIX" ] || VSIX="$(ls -t vscode-extension/dist/*.vsix 2>/dev/null | head -n1)"
[ -n "$VSIX" ] || { echo "WARNING: could not build the extension (.vsix not found)."; exit 0; }

# --force here only ever replaces a LOWER version, never the same one.
if "$SERVER" --install-extension "$VSIX" --force >/dev/null; then
  if [ -n "$INSTALLED" ]; then
    echo "AI commenting extension updated $INSTALLED -> $BUILD_VER. Run 'Developer: Reload Window' to use it."
  else
    echo "AI commenting extension $BUILD_VER installed. Run 'Developer: Reload Window' to activate it."
  fi
else
  echo "WARNING: extension install failed; see the error above."
fi
EOF
chmod +x "$DEST/post-attach.sh"

# ---------------------------------------------------------------------------
# 2. Patch devcontainer.json with the settings that prevent the root/SSH issues.
# ---------------------------------------------------------------------------
JSON="$DEST/devcontainer.json"
if [ -f "$JSON" ] && command -v python3 >/dev/null 2>&1; then
  python3 - "$JSON" <<'PY' || true
import json, re, sys

path = sys.argv[1]
text = open(path).read()

# devcontainer.json allows comments and trailing commas; strip them (strings are kept).
clean = re.sub(r'("(?:\\.|[^"\\])*")|//[^\n]*|/\*.*?\*/',
               lambda m: m.group(1) or '', text, flags=re.S)
clean = re.sub(r',(\s*[}\]])', r'\1', clean)

try:
    cfg = json.loads(clean)
except json.JSONDecodeError as e:
    print(f"Could not parse {path} ({e}); add the settings below by hand.")
    sys.exit(1)

cfg["remoteUser"] = "vscode"
cfg["updateRemoteUserUID"] = True

post = 'bash "${containerWorkspaceFolder}/.devcontainer/post-create.sh"'
existing = cfg.get("postCreateCommand")
if existing is None:
    cfg["postCreateCommand"] = post
elif isinstance(existing, str):
    if "post-create.sh" not in existing:
        cfg["postCreateCommand"] = f"{post} && {existing}"
else:
    # array or object form: add ours as a named step if it's an object
    if isinstance(existing, dict):
        existing.setdefault("permissions-and-ssh", post)
    else:
        print("postCreateCommand is a list; add post-create.sh to it by hand.")

attach = 'bash "${containerWorkspaceFolder}/.devcontainer/post-attach.sh"'
existing = cfg.get("postAttachCommand")
if existing is None:
    cfg["postAttachCommand"] = attach
elif isinstance(existing, str):
    if "post-attach.sh" not in existing:
        cfg["postAttachCommand"] = f"{attach} && {existing}"
elif isinstance(existing, dict):
    existing.setdefault("ai-commenting-extension", attach)
else:
    print("postAttachCommand is a list; add post-attach.sh to it by hand.")

# Mounting ~/.ssh makes it read-only and root-owned inside the container.
# The editor forwards the Mac's SSH agent automatically, so the mount isn't needed.
mounts = cfg.get("mounts", [])
kept = [m for m in mounts if ".ssh" not in json.dumps(m)]
if len(kept) != len(mounts):
    print("Removed the ~/.ssh mount (SSH agent forwarding is used instead).")
    if kept:
        cfg["mounts"] = kept
    else:
        cfg.pop("mounts", None)

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print("Updated devcontainer.json (remoteUser, updateRemoteUserUID, postCreateCommand, postAttachCommand).")
PY
  [ $? -eq 0 ] || cat <<'EOF'

Add these to .devcontainer/devcontainer.json manually:
  "remoteUser": "vscode",
  "updateRemoteUserUID": true,
  "postCreateCommand": "bash \"${containerWorkspaceFolder}/.devcontainer/post-create.sh\"",
  "postAttachCommand": "bash \"${containerWorkspaceFolder}/.devcontainer/post-attach.sh\""
and remove any "mounts" entry for ~/.ssh.
EOF
else
  echo "No devcontainer.json found (or no python3); add remoteUser/postCreateCommand by hand."
fi

# ---------------------------------------------------------------------------
# 3. Make sure the Mac's SSH agent holds your key, so the container can use it.
# ---------------------------------------------------------------------------
set +e
ssh-add -l >/dev/null 2>&1
agent_status=$?
set -e

if [ $agent_status -eq 0 ]; then
  echo "SSH agent already has a key loaded."
elif [ $agent_status -eq 1 ]; then
  KEY=""
  for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
    [ -f "$k" ] && { KEY="$k"; break; }
  done
  if [ -n "$KEY" ]; then
    chmod 700 "$HOME/.ssh"
    chmod 600 "$KEY"
    echo "Loading $KEY into the SSH agent (you may be asked for its passphrase)..."
    if [ "$(uname)" = "Darwin" ]; then
      ssh-add --apple-use-keychain "$KEY"   # remembered across restarts
    else
      ssh-add "$KEY"
    fi
  else
    echo "No SSH key found in ~/.ssh. Create one with: ssh-keygen -t ed25519"
  fi
else
  echo "No SSH agent is running on this machine; start one with: eval \"\$(ssh-agent -s)\""
fi

echo
echo "Now: open '$TARGET' in VS Code, then Cmd+Shift+P -> 'Dev Containers: Reopen in Container'"
echo "Inside the container, clone other repos into ~/tools (no sudo needed)."
