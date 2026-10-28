#!/usr/bin/env bash
# Usage: ./new-server-container.sh [options] /path/to/project
#
# Options:
#   -p PORT                 SSH port on the server's localhost (default: the first
#                           free port from 2222 up; the server may be shared)
#   -m SRC[:DEST][:ro]      also mount the server folder SRC into the container,
#                           at DEST (default: the same path as on the server).
#                           Add :ro to make it read-only. Repeat -m for more folders.
#   -e ENV_NAME             the project's conda environment (default: the project
#                           folder's name, e.g. mdsampling-main-claude)
#   -y PYTHON_VERSION       Python for a newly created environment (default: 3.12);
#                           an existing environment is used as it is
#
# Examples:
#   ./new-server-container.sh ~/MDSampling-main-claude
#   ./new-server-container.sh -m /data/md -m /scratch/shajain:/scratch -m /shared/refs:ro ~/MDSampling-main-claude
#
# Run this ON THE SERVER. It builds and starts a dev container that you
# connect to with VS Code's Remote-SSH extension (no Dev Containers extension).
# VS Code's server then runs inside the container's modern Ubuntu, not on the
# server's own (older) Linux.
#
# Same settings as the dev container template:
#   - you work as your own user (default: shajain), with the server's UID/GID,
#     so files in mounted folders keep the right owner
#   - /workspaces is owned by you and can be entered
#   - git uses your Mac's SSH agent (forwarded over SSH); no key files copied
#   - Claude Code (shared program and login) and the AI commenting tool are installed, and
#     `ai-commenting build .` / `install-agent .` are run
#
# Shared setup folder (always mounted, same path inside every container):
#   $SETUP_DIR/miniforge3           conda (Miniforge), also linked as /opt/conda;
#                                   one environment per project in miniforge3/envs
#   $SETUP_DIR/AI-commenting-tool   the tool's clone (the package source)
#   $SETUP_DIR/pip-cache            downloaded packages, reused by every environment
#   $SETUP_DIR/claude-home          the Claude Code program, installed once
#   $SETUP_DIR/claude-config        Claude Code's login and settings (CLAUDE_CONFIG_DIR),
#                                   so you log in once and every container is logged in
# conda and the clone are installed once and reused by every container. Each
# project's environment gets the tool with an editable pip install from the
# shared clone, so a 'git pull' there updates the tool in every environment.
# In any other environment, run: install-ai-commenting
# Claude Code doesn't update itself here (all containers share one copy); update
# it for every container with: dev-update-claude
#
# Environment overrides:
#   CONTAINER_USER  user inside the container   (default: shajain)
#   SETUP_DIR       shared setup folder         (default: /data/shajain/container_setup)
#   BASE_IMAGE      base image                  (default: ubuntu:22.04)
#   DOCKER          docker command              (default: docker; e.g. "sudo docker")
#   DRY_RUN=1       only write the build files and print where they are

set -euo pipefail

usage() {
  echo "Usage: $0 [-p PORT] [-m SRC[:DEST][:ro]]... [-e ENV_NAME] [-y PYTHON_VERSION] /path/to/project"
  exit 1
}

PORT=""
MOUNT_SPECS=()
ENV_NAME=""
PY_VERSION="3.12"
while getopts ":p:m:e:y:h" opt; do
  case "$opt" in
    p) PORT="$OPTARG" ;;
    m) MOUNT_SPECS+=("$OPTARG") ;;
    e) ENV_NAME="$OPTARG" ;;
    y) PY_VERSION="$OPTARG" ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || usage
case "$PORT" in ''|[0-9]*) ;; *) echo "Port must be a number: $PORT"; exit 1 ;; esac
case "$PORT" in *[!0-9]*) echo "Port must be a number: $PORT"; exit 1 ;; esac

PROJECT="$(cd "$1" 2>/dev/null && pwd)" || { echo "Project folder does not exist: $1"; exit 1; }
CONTAINER_USER="${CONTAINER_USER:-shajain}"
BASE_IMAGE="${BASE_IMAGE:-ubuntu:22.04}"
DOCKER="${DOCKER:-docker}"
TOOL_REPO="git@github.com:shajain/AI-commenting-tool.git"
SETUP_DIR="${SETUP_DIR:-/data/shajain/container_setup}"
SETUP_DIR="${SETUP_DIR%/}"

PROJECT_BASE="$(basename "$PROJECT")"
SLUG="$(echo "$PROJECT_BASE" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '-' | sed 's/-*$//')"
NAME="$SLUG-dev"
ENV_NAME="${ENV_NAME:-$SLUG}"
case "$ENV_NAME" in base|''|*[!a-zA-Z0-9_.-]*) echo "Invalid environment name: '$ENV_NAME' (letters, digits, _ . - only; not 'base')"; exit 1 ;; esac
case "$PY_VERSION" in 3.1[0-9]*|3.[2-9][0-9]*) ;; *) echo "Python must be 3.10 or newer for the AI commenting tool: $PY_VERSION"; exit 1 ;; esac
IMAGE="$NAME-image"
WORKDIR="/workspaces/$PROJECT_BASE"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
AUTH_KEYS="$HOME/.ssh/authorized_keys"

# ---------------------------------------------------------------------------
# Extra mounts: SRC[:DEST][:ro]
# ---------------------------------------------------------------------------
MOUNT_ARGS=()
MOUNT_DESTS=()
MOUNT_SUMMARY=()
RESERVED=("/" "$WORKDIR" "/workspaces" "/home/$CONTAINER_USER" "/opt/conda" "$SETUP_DIR" "$SETUP_DIR/miniforge3" "/etc" "/usr" "/bin" "/etc/ssh/keys" "/etc/ssh/hostkeys")
for spec in "${MOUNT_SPECS[@]+"${MOUNT_SPECS[@]}"}"; do
  mode="rw"
  case "$spec" in *:ro) mode="ro"; spec="${spec%:ro}" ;; *:rw) spec="${spec%:rw}" ;; esac
  src="${spec%%:*}"
  if [ "$src" = "$spec" ]; then dest=""; else dest="${spec#*:}"; fi

  src_abs="$(cd "$src" 2>/dev/null && pwd)" || { echo "Mount folder does not exist on the server: $src"; exit 1; }
  dest="${dest:-$src_abs}"
  case "$dest" in /*) ;; *) echo "Mount destination must be an absolute path: $dest"; exit 1 ;; esac
  dest="${dest%/}"; [ -n "$dest" ] || dest="/"
  for r in "${RESERVED[@]}"; do
    [ "$dest" = "$r" ] && { echo "Can't mount over $dest inside the container; pick another destination."; exit 1; }
  done
  for d in "${MOUNT_DESTS[@]+"${MOUNT_DESTS[@]}"}"; do
    [ "$dest" = "$d" ] && { echo "Two mounts use the same destination: $dest"; exit 1; }
  done

  if [ "$mode" = "ro" ]; then MOUNT_ARGS+=(-v "$src_abs:$dest:ro"); else MOUNT_ARGS+=(-v "$src_abs:$dest"); fi
  MOUNT_DESTS+=("$dest")
  MOUNT_SUMMARY+=("$src_abs -> $dest ($mode)")
done

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
# Is anything (another user's container, any program) listening on this port?
port_in_use() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0
  if [ -z "${DRY_RUN:-}" ] && $DOCKER ps --format '{{.Ports}}' 2>/dev/null | grep -q ":$1->"; then
    return 0
  fi
  return 1
}

if [ -n "$PORT" ]; then
  if port_in_use "$PORT"; then
    echo "Port $PORT is already in use on this server. Pick another with -p, or leave -p out"
    echo "to use the first free port from 2222 up."
    exit 1
  fi
else
  for p in $(seq 2222 2399); do
    port_in_use "$p" || { PORT="$p"; break; }
  done
  [ -n "$PORT" ] || { echo "No free port between 2222 and 2399; pick one with -p."; exit 1; }
  echo "Using SSH port $PORT."
fi

if [ ! -f "$AUTH_KEYS" ]; then
  echo "No $AUTH_KEYS on this server. The container lets in the same SSH keys"
  echo "that can log in to this server, so add your Mac's public key there first."
  exit 1
fi

if ! mkdir -p "$SETUP_DIR" 2>/dev/null || [ ! -w "$SETUP_DIR" ]; then
  echo "Can't create or write to the shared setup folder: $SETUP_DIR"
  echo "Create it and make it yours first, e.g.: sudo mkdir -p $SETUP_DIR && sudo chown $(id -un) $SETUP_DIR"
  exit 1
fi

if [ -z "${DRY_RUN:-}" ]; then
  if ! $DOCKER info >/dev/null 2>&1; then
    echo "Can't talk to Docker with '$DOCKER'. Try: DOCKER=\"sudo docker\" $0 $*"
    exit 1
  fi
  if $DOCKER ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
    echo "A container named $NAME already exists — not overwriting."
    echo "To start over: $DOCKER rm -f $NAME   (add: $DOCKER volume rm $NAME-home  to also wipe its home folder)"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Build files
# ---------------------------------------------------------------------------
BUILD_DIR="$(mktemp -d)"
trap '[ -z "${DRY_RUN:-}" ] && rm -rf "$BUILD_DIR"' EXIT

cat > "$BUILD_DIR/Dockerfile" <<'EOF'
FROM @BASE_IMAGE@

ARG USER_NAME
ARG USER_UID
ARG USER_GID
ARG WORKDIR
ARG TOOL_REPO
ARG SETUP_DIR
ARG ENV_NAME
ARG PY_VERSION
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server sudo git curl ca-certificates locales procps less nano vim \
      build-essential bash-completion \
 && locale-gen en_US.UTF-8 \
 && rm -rf /var/lib/apt/lists/*

# Your user, with the server's UID/GID so the project folder's files match.
RUN set -e; \
    if getent passwd "$USER_UID" >/dev/null; then userdel -r "$(getent passwd "$USER_UID" | cut -d: -f1)" 2>/dev/null || true; fi; \
    if getent group "$USER_GID" >/dev/null; then GROUP="$(getent group "$USER_GID" | cut -d: -f1)"; \
    else groupadd -g "$USER_GID" "$USER_NAME"; GROUP="$USER_NAME"; fi; \
    useradd -m -s /bin/bash -u "$USER_UID" -g "$GROUP" "$USER_NAME"; \
    echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USER_NAME"; \
    chmod 440 "/etc/sudoers.d/$USER_NAME"

# conda lives in the shared setup folder (mounted at run time, installed by
# dev-setup the first time). /opt/conda is a link to it for convenience.
RUN ln -s "$SETUP_DIR/miniforge3" /opt/conda

# /workspaces owned by you and enterable (the drw------- problem from before).
RUN mkdir -p /workspaces /run/sshd /etc/ssh/keys /etc/ssh/hostkeys \
 && chown "$USER_UID:$USER_GID" /workspaces && chmod 755 /workspaces \
 && rm -f /etc/ssh/ssh_host_* \
 && git config --system --add safe.directory "$WORKDIR"

# Settings the helper scripts read.
RUN printf 'PROJECT=%s\nTOOL_REPO=%s\nSETUP_DIR=%s\nCONDA_DIR=%s\nTOOL_DIR=%s\nPROJECT_ENV=%s\nENV_DIR=%s\nPY_VERSION=%s\nPIP_CACHE_DIR=%s\n' \
      "$WORKDIR" "$TOOL_REPO" "$SETUP_DIR" "$SETUP_DIR/miniforge3" "$SETUP_DIR/AI-commenting-tool" \
      "$ENV_NAME" "$SETUP_DIR/miniforge3/envs/$ENV_NAME" "$PY_VERSION" "$SETUP_DIR/pip-cache" \
      > /etc/dev-container.env \
 && printf 'CLAUDE_HOME=%s\nCLAUDE_BIN_DIR=%s\nCLAUDE_CONFIG_DIR=%s\nDISABLE_AUTOUPDATER=1\n' \
      "$SETUP_DIR/claude-home" "$SETUP_DIR/claude-home/.local/bin" "$SETUP_DIR/claude-config" \
      >> /etc/dev-container.env \
 && printf 'CLAUDE_CONFIG_DIR=%s\nDISABLE_AUTOUPDATER=1\n' "$SETUP_DIR/claude-config" >> /etc/environment

COPY sshd.conf /etc/ssh/sshd_config.d/dev-container.conf
RUN echo "AllowUsers $USER_NAME" >> /etc/ssh/sshd_config.d/dev-container.conf
COPY entrypoint.sh dev-setup dev-install-extension install-ai-commenting dev-update-claude /usr/local/bin/
COPY bashrc-extra /tmp/bashrc-extra
COPY profile-path.sh /etc/profile.d/dev-container-path.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/dev-setup /usr/local/bin/dev-install-extension /usr/local/bin/install-ai-commenting /usr/local/bin/dev-update-claude \
 && cat /tmp/bashrc-extra >> /etc/bash.bashrc && rm /tmp/bashrc-extra

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
EOF
sed -i.bak "s|@BASE_IMAGE@|$BASE_IMAGE|" "$BUILD_DIR/Dockerfile" && rm -f "$BUILD_DIR/Dockerfile.bak"

cat > "$BUILD_DIR/sshd.conf" <<'EOF'
# Keys only, no passwords, no root. Keys come from the server's authorized_keys.
HostKey /etc/ssh/hostkeys/ssh_host_ed25519_key
HostKey /etc/ssh/hostkeys/ssh_host_rsa_key
AuthorizedKeysFile /etc/ssh/keys/%u
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
# VS Code's Remote-SSH needs TCP forwarding; git needs agent forwarding.
AllowTcpForwarding yes
AllowAgentForwarding yes
EOF

cat > "$BUILD_DIR/entrypoint.sh" <<'EOF'
#!/bin/bash
set -e
# Host keys live in a volume, so rebuilding the container doesn't trigger
# "REMOTE HOST IDENTIFICATION HAS CHANGED" on your Mac.
[ -f /etc/ssh/hostkeys/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/hostkeys/ssh_host_ed25519_key
[ -f /etc/ssh/hostkeys/ssh_host_rsa_key ] || ssh-keygen -q -t rsa -b 4096 -N '' -f /etc/ssh/hostkeys/ssh_host_rsa_key
mkdir -p /run/sshd
exec /usr/sbin/sshd -D -e
EOF

cat > "$BUILD_DIR/profile-path.sh" <<'EOF'
. /etc/dev-container.env
export PATH="$CONDA_DIR/bin:$CLAUDE_BIN_DIR:$HOME/.local/bin:$PATH"
export CLAUDE_CONFIG_DIR DISABLE_AUTOUPDATER
EOF

cat > "$BUILD_DIR/bashrc-extra" <<'EOF'

# --- dev container -----------------------------------------------------------
. /etc/dev-container.env
# Shared Claude Code comes before ~/.local/bin, so an older per-container copy
# there can't shadow it.
export PATH="$CONDA_DIR/bin:$CLAUDE_BIN_DIR:$HOME/.local/bin:$PATH"
export CLAUDE_CONFIG_DIR DISABLE_AUTOUPDATER
[ -f "$CONDA_DIR/etc/profile.d/conda.sh" ] && . "$CONDA_DIR/etc/profile.d/conda.sh"
export PIP_CACHE_DIR
# Run setup if it never finished in this container's home, or if the project's
# environment or the tool in it isn't there yet.
if { [ ! -f "$HOME/.dev-setup-done" ] || [ ! -x "$ENV_DIR/bin/ai-commenting" ] \
     || [ ! -x "$CLAUDE_BIN_DIR/claude" ] || [ ! -L "$HOME/.claude" ]; } \
   && [ -z "${DEV_SETUP_RUNNING:-}" ]; then
  /usr/local/bin/dev-setup
fi
# Every terminal starts in the project's environment.
[ -d "$ENV_DIR" ] && command -v conda >/dev/null 2>&1 && conda activate "$ENV_DIR"
# Install the editor extension once VS Code's server is present (fast no-op after).
/usr/local/bin/dev-install-extension --quiet
EOF

cat > "$BUILD_DIR/dev-setup" <<'EOF'
#!/usr/bin/env bash
# Setup, run as you. Safe to run again any time: `dev-setup`
# Shared parts (conda, the tool) are installed only if missing.
set -uo pipefail
export DEV_SETUP_RUNNING=1
. /etc/dev-container.env
export PATH="$CONDA_DIR/bin:$CLAUDE_BIN_DIR:$HOME/.local/bin:$PATH"
export CLAUDE_CONFIG_DIR DISABLE_AUTOUPDATER
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"

echo "==> Dev container setup"

if [ ! -w "$SETUP_DIR" ]; then
  echo "WARNING: shared setup folder $SETUP_DIR is not writable by $(id -un)."
  exit 1
fi
if touch "$PROJECT/.write-test" 2>/dev/null; then
  rm -f "$PROJECT/.write-test"
else
  echo "WARNING: $PROJECT is not writable by $(id -un); check its permissions on the server."
fi

have_agent() { ssh-add -l >/dev/null 2>&1; }

# Only one container at a time may install into the shared folder.
exec 9>"$SETUP_DIR/.setup.lock"
if ! flock -w 600 9; then
  echo "WARNING: another container has been running setup for 10 minutes; try dev-setup later."
  exit 1
fi

# 1. conda (Miniforge), shared: installed once.
if [ ! -x "$CONDA_DIR/bin/conda" ]; then
  if [ -d "$CONDA_DIR" ] && [ -n "$(ls -A "$CONDA_DIR" 2>/dev/null)" ]; then
    echo "WARNING: $CONDA_DIR exists but has no conda in it; move it aside and run dev-setup."
    exit 1
  fi
  echo "Installing Miniforge into $CONDA_DIR (first container only)..."
  curl -fsSL -o /tmp/miniforge.sh \
    "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-$(uname -m).sh" \
    && bash /tmp/miniforge.sh -b -u -p "$CONDA_DIR" \
    || { echo "WARNING: Miniforge install failed."; rm -f /tmp/miniforge.sh; exit 1; }
  rm -f /tmp/miniforge.sh
else
  # conda records its install path in its own files, so a copied or moved
  # installation points at a path that doesn't exist here.
  shebang="$(head -n1 "$CONDA_DIR/bin/conda" 2>/dev/null)"
  case "$shebang" in
    "#!$CONDA_DIR/bin/python"*) echo "conda: using shared $CONDA_DIR" ;;
    *)
      echo "WARNING: $CONDA_DIR was installed at a different path and then moved or copied"
      echo "         (its conda starts with: ${shebang:-<unreadable>}). conda can't be moved."
      echo "         On the server, set it aside so setup installs a fresh one:"
      echo "           mv $CONDA_DIR $CONDA_DIR.moved"
      echo "         then run: dev-setup"
      exit 1 ;;
  esac
fi

# Keep every environment and package cache inside the shared miniforge folder.
# Without this, conda falls back to ~/.conda (this container's home) whenever
# it decides it can't write to miniforge3.
# Miniforge keeps its own settings (the conda-forge channel) in this same file,
# so add to it rather than replacing it.
RC="$CONDA_DIR/.condarc"
mkdir -p "$CONDA_DIR/envs" "$CONDA_DIR/pkgs"
"$CONDA_DIR/bin/conda" config --file "$RC" --get envs_dirs 2>/dev/null | grep -qF "$CONDA_DIR/envs" \
  || "$CONDA_DIR/bin/conda" config --file "$RC" --prepend envs_dirs "$CONDA_DIR/envs"
"$CONDA_DIR/bin/conda" config --file "$RC" --get pkgs_dirs 2>/dev/null | grep -qF "$CONDA_DIR/pkgs" \
  || "$CONDA_DIR/bin/conda" config --file "$RC" --prepend pkgs_dirs "$CONDA_DIR/pkgs"
# Repair an install whose channel setting was lost (an earlier version of this
# script overwrote the file).
"$CONDA_DIR/bin/conda" config --file "$RC" --get channels 2>/dev/null | grep -q . \
  || "$CONDA_DIR/bin/conda" config --file "$RC" --add channels conda-forge
if [ -f "$HOME/.condarc" ] && grep -qE 'envs_dirs|pkgs_dirs' "$HOME/.condarc"; then
  echo "WARNING: $HOME/.condarc also sets envs_dirs/pkgs_dirs and takes priority;"
  echo "         remove those lines so environments stay in $CONDA_DIR/envs."
fi

# 2. The tool's clone, shared: cloned once, updated when the SSH agent is available.
if [ -d "$TOOL_DIR/.git" ]; then
  if have_agent; then
    git -C "$TOOL_DIR" pull --ff-only || echo "WARNING: git pull failed; using the existing copy."
  else
    echo "No SSH agent keys; skipping 'git pull' and using the existing copy of the tool."
  fi
else
  if ! have_agent; then
    echo "WARNING: no SSH agent keys, needed to clone the tool the first time. Connect with"
    echo "         'ForwardAgent yes', check 'ssh-add -l' on your Mac, then run: dev-setup"
    exit 1
  fi
  git clone "$TOOL_REPO" "$TOOL_DIR" || { echo "WARNING: clone failed. Check: ssh -T git@github.com"; exit 1; }
fi

# 3. The project's own environment in the shared conda: created once.
export PIP_CACHE_DIR
if [ ! -x "$ENV_DIR/bin/python" ]; then
  echo "Creating conda environment '$PROJECT_ENV' (Python $PY_VERSION)..."
  "$CONDA_DIR/bin/conda" create -y -p "$ENV_DIR" "python=$PY_VERSION" pip \
    || { echo "WARNING: could not create environment '$PROJECT_ENV'."; exit 1; }
else
  echo "conda environment '$PROJECT_ENV': already exists ($("$ENV_DIR/bin/python" --version 2>&1))"
fi

# 4. The tool in that environment: an editable install from the shared clone.
if [ ! -x "$ENV_DIR/bin/ai-commenting" ]; then
  /usr/local/bin/install-ai-commenting "$ENV_DIR/bin/python" || exit 1
else
  echo "ai-commenting: already installed in '$PROJECT_ENV'"
fi

# 5. Claude Code, shared: the program is installed once into $CLAUDE_HOME.
#    The installer puts it under $HOME/.local, so it runs with HOME pointed at
#    the shared folder.
mkdir -p "$CLAUDE_HOME"
if [ ! -x "$CLAUDE_BIN_DIR/claude" ]; then
  echo "Installing Claude Code into $CLAUDE_HOME (first container only)..."
  curl -fsSL https://claude.ai/install.sh | HOME="$CLAUDE_HOME" bash \
    || echo "WARNING: Claude Code install failed."
else
  echo "Claude Code: using shared $("$CLAUDE_BIN_DIR/claude" --version 2>/dev/null | head -n1)"
fi

# 6. Claude Code's login and settings, shared via CLAUDE_CONFIG_DIR.
mkdir -p "$CLAUDE_CONFIG_DIR" && chmod 700 "$CLAUDE_CONFIG_DIR"
# Reuse a login made earlier in this container, if the shared folder has none yet.
if [ ! -f "$CLAUDE_CONFIG_DIR/.credentials.json" ] && [ -f "$HOME/.claude/.credentials.json" ] \
   && [ ! -L "$HOME/.claude" ]; then
  cp -a "$HOME/.claude/." "$CLAUDE_CONFIG_DIR/"
  [ -f "$HOME/.claude.json" ] && [ ! -L "$HOME/.claude.json" ] && [ ! -f "$CLAUDE_CONFIG_DIR/.claude.json" ] \
    && cp -a "$HOME/.claude.json" "$CLAUDE_CONFIG_DIR/.claude.json"
  echo "Moved this container's Claude login into the shared folder."
fi
[ -f "$CLAUDE_CONFIG_DIR/.claude.json" ] || echo '{}' > "$CLAUDE_CONFIG_DIR/.claude.json"
# Point the usual locations at the shared folder too, for tools that read them
# directly (Claude Code itself uses CLAUDE_CONFIG_DIR).
for pair in ".claude:$CLAUDE_CONFIG_DIR" ".claude.json:$CLAUDE_CONFIG_DIR/.claude.json"; do
  name="${pair%%:*}"; target="${pair#*:}"
  if [ -L "$HOME/$name" ]; then
    ln -sfn "$target" "$HOME/$name"
  else
    [ -e "$HOME/$name" ] && mv "$HOME/$name" "$HOME/$name.per-container.bak"
    ln -s "$target" "$HOME/$name"
  fi
done

flock -u 9

# 7. This project, with the project's environment.
export PATH="$ENV_DIR/bin:$PATH"
cd "$PROJECT"
ai-commenting build . || echo "WARNING: 'ai-commenting build .' failed."
ai-commenting install-agent . || echo "WARNING: 'ai-commenting install-agent .' failed."

touch "$HOME/.dev-setup-done"
/usr/local/bin/dev-install-extension
echo "==> Setup finished."
EOF

cat > "$BUILD_DIR/install-ai-commenting" <<'EOF'
#!/usr/bin/env bash
# Installs the AI commenting tool from the shared clone into a Python environment.
#   install-ai-commenting              -> the active environment's python
#   install-ai-commenting /path/python -> that python
# Editable install: a 'git pull' in the shared clone updates every environment.
set -uo pipefail
. /etc/dev-container.env
export PIP_CACHE_DIR
PY="${1:-$(command -v python)}"
[ -n "$PY" ] && [ -x "$PY" ] || { echo "No python found; activate an environment first."; exit 1; }
[ -d "$TOOL_DIR" ] || { echo "Shared clone $TOOL_DIR not found; run dev-setup first."; exit 1; }
case "$PY" in "$CONDA_DIR/bin/python"*) echo "Refusing to install into conda's base; activate a project environment."; exit 1 ;; esac
if ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
  echo "The AI commenting tool needs Python 3.10 or newer; $PY is $("$PY" --version 2>&1)."
  exit 1
fi
echo "Installing the AI commenting tool into $("$PY" -c 'import sys; print(sys.prefix)')..."
"$PY" -m pip install -e "$TOOL_DIR" || { echo "WARNING: pip install failed."; exit 1; }
EOF

cat > "$BUILD_DIR/dev-update-claude" <<'EOF'
#!/usr/bin/env bash
# Updates the shared Claude Code for every container. Run in any container.
set -uo pipefail
. /etc/dev-container.env
export CLAUDE_CONFIG_DIR
exec 9>"$SETUP_DIR/.setup.lock"
flock -w 600 9 || { echo "Another container is running setup; try again later."; exit 1; }
before="$("$CLAUDE_BIN_DIR/claude" --version 2>/dev/null | head -n1)"
# Re-running the installer fetches the latest release into the shared folder.
curl -fsSL https://claude.ai/install.sh | HOME="$CLAUDE_HOME" bash \
  || { echo "WARNING: update failed."; exit 1; }
after="$("$CLAUDE_BIN_DIR/claude" --version 2>/dev/null | head -n1)"
echo "Claude Code: ${before:-not installed} -> ${after:-?}"
echo "Already-running Claude sessions keep the old version until restarted."
EOF

cat > "$BUILD_DIR/dev-install-extension" <<'EOF'
#!/usr/bin/env bash
# Installs the AI commenting editor extension into VS Code's (or Cursor's)
# server inside this container. Run by hand any time: dev-install-extension
set -uo pipefail
QUIET="${1:-}"
say() { [ -n "$QUIET" ] || echo "$@"; }
. /etc/dev-container.env
[ -d "$TOOL_DIR" ] || exit 0

if ls -d "$HOME"/.vscode-server/extensions/*ai-commenting* \
         "$HOME"/.vscode-server-insiders/extensions/*ai-commenting* \
         "$HOME"/.cursor-server/extensions/*ai-commenting* >/dev/null 2>&1; then
  say "AI commenting extension already installed."
  exit 0
fi

# Find the editor's server program (VS Code: code-server, Cursor: cursor-server),
# whatever folder layout this editor version uses. Newest first.
find_editor_server() {
  local d
  for d in "$HOME/.vscode-server" "$HOME/.vscode-server-insiders" "$HOME/.cursor-server"; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 8 -type f -perm -u+x \
         \( -name code-server -o -name code-server-insiders -o -name cursor-server \) \
         -not -path '*/remote-cli/*' -printf '%T@ %p\n' 2>/dev/null
  done | sort -rn | head -n1 | cut -d' ' -f2-
}
SERVER="$(find_editor_server)"
if [ -z "$SERVER" ]; then
  say "Editor server not found yet; connect with VS Code or Cursor first, then run: dev-install-extension"
  say "(looked in ~/.vscode-server, ~/.vscode-server-insiders and ~/.cursor-server)"
  exit 0
fi

cd "$TOOL_DIR"
"$ENV_DIR/bin/python" vscode-extension/package_vsix.py >/dev/null 2>&1 || true
VSIX="$(ls -t vscode-extension/dist/*.vsix 2>/dev/null | head -n1)"
[ -n "$VSIX" ] || { echo "WARNING: could not build the extension (.vsix not found)."; exit 0; }

if "$SERVER" --install-extension "$VSIX" --force >/dev/null; then
  echo "AI commenting extension installed. Run 'Developer: Reload Window' to activate it."
else
  echo "WARNING: extension install failed. Try: dev-install-extension"
fi
EOF

if [ -n "${DRY_RUN:-}" ]; then
  echo "Build files written to: $BUILD_DIR"
  exit 0
fi

# ---------------------------------------------------------------------------
# Build and run
# ---------------------------------------------------------------------------
echo "Building image $IMAGE (first build takes a few minutes)..."
$DOCKER build -t "$IMAGE" \
  --build-arg USER_NAME="$CONTAINER_USER" \
  --build-arg USER_UID="$HOST_UID" \
  --build-arg USER_GID="$HOST_GID" \
  --build-arg WORKDIR="$WORKDIR" \
  --build-arg TOOL_REPO="$TOOL_REPO" \
  --build-arg SETUP_DIR="$SETUP_DIR" \
  --build-arg ENV_NAME="$ENV_NAME" \
  --build-arg PY_VERSION="$PY_VERSION" \
  "$BUILD_DIR"

echo "Starting container $NAME on port $PORT..."
# The SSH port is bound to 127.0.0.1 only: it's reachable through the server
# (ProxyJump), not from the network.
$DOCKER run -d --name "$NAME" --hostname "$NAME" --restart unless-stopped \
  -p "127.0.0.1:$PORT:22" \
  -v "$PROJECT:$WORKDIR" \
  -v "$NAME-home:/home/$CONTAINER_USER" \
  -v "$SETUP_DIR:$SETUP_DIR" \
  -v "$NAME-hostkeys:/etc/ssh/hostkeys" \
  -v "$AUTH_KEYS:/etc/ssh/keys/$CONTAINER_USER:ro" \
  "${MOUNT_ARGS[@]+"${MOUNT_ARGS[@]}"}" \
  "$IMAGE" >/dev/null || {
  # docker run can create the container and then fail (e.g. the port was taken
  # in the meantime); remove the leftover so running this again works.
  $DOCKER rm -f "$NAME" >/dev/null 2>&1
  echo "Could not start the container (see the error above). Nothing was left behind;"
  echo "fix the problem and run this script again."
  exit 1
}

for _ in $(seq 1 20); do
  $DOCKER exec "$NAME" pgrep -x sshd >/dev/null 2>&1 && break
  sleep 1
done
if ! $DOCKER exec "$NAME" pgrep -x sshd >/dev/null 2>&1; then
  echo "The container's SSH server didn't start. Logs:"
  $DOCKER logs "$NAME" | tail -n 20
  exit 1
fi

# Let git work in any mounted folder that is a repo, even if owned by another user.
for d in "${MOUNT_DESTS[@]+"${MOUNT_DESTS[@]}"}"; do
  $DOCKER exec "$NAME" git config --system --add safe.directory "$d"
done

# Remember how this container was created, so it can be recreated the same way.
RECREATE="$0 -p $PORT -e '$ENV_NAME' -y '$PY_VERSION'"
for spec in "${MOUNT_SPECS[@]+"${MOUNT_SPECS[@]}"}"; do RECREATE="$RECREATE -m '$spec'"; done
RECREATE="$RECREATE '$PROJECT'"

SERVER_HOST="$(hostname -f 2>/dev/null || hostname)"
SERVER_USER="$(id -un)"

cat <<EOF

Container $NAME is running.
  Project: $PROJECT -> $WORKDIR
  Shared:  $SETUP_DIR -> $SETUP_DIR (conda + AI commenting tool)
  Conda environment: $ENV_NAME (Python $PY_VERSION if newly created)
$(for m in "${MOUNT_SUMMARY[@]+"${MOUNT_SUMMARY[@]}"}"; do echo "  Mount:   $m"; done)

Mounts are fixed when a container is created. To change them later:
  $DOCKER rm -f $NAME
  $RECREATE   (edit the -m options)
Your home folder (editor, shell settings) is kept in a volume, and conda, the
tool and Claude Code (program and login) are in $SETUP_DIR, so all survive this.

1. On your Mac, add this to ~/.ssh/config:

Host $NAME
    HostName localhost
    Port $PORT
    User $CONTAINER_USER
    ProxyJump $SERVER_USER@$SERVER_HOST
    ForwardAgent yes

2. On your Mac, make sure your key is in the agent:  ssh-add -l
   (if empty: ssh-add --apple-use-keychain ~/.ssh/id_rsa)

3. In VS Code: Remote-SSH: Connect to Host... -> $NAME, then open $WORKDIR

4. Open a terminal in VS Code. Setup runs once there automatically (clone, installs,
   ai-commenting build/install-agent, editor extension). Then: Developer: Reload Window.
   To re-run it later: dev-setup

Run 'claude' once in $WORKDIR and accept the trust prompt. The first time in any
container, also log in; every other container then shares that login.
Update Claude Code for all containers with: dev-update-claude
EOF
