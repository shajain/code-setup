#!/usr/bin/env bash
#
# Create a git worktree on a new "<prefix>-claude" branch, for running a
# Claude session in isolation from the main checkout.
#
#   new-worktree.sh isoform
#     -> branch  isoform-claude   (off main)
#     -> path    ~/MEGA/<repo>-isoform-claude
#
# <repo> is the name of the directory containing .git. Must be run from inside
# that main checkout, not from a linked worktree.
#
# Optional: a ".worktree-links" file at the repo root lists paths git will not
# carry into a fresh worktree (untracked or ignored) but the project still
# needs -- one relative path per line, "#" comments ignored. Each is symlinked
# back to the main checkout.
#
set -euo pipefail

DEFAULT_BASE="main"
DEFAULT_LOCATION="$HOME/MEGA"
LINKS_FILE=".worktree-links"

die() { printf '%s\n' "error: $*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }

usage() {
  cat >&2 <<EOF
usage: $(basename "$0") <prefix> [base-branch] [location]

  prefix       required. New branch is "<prefix>-claude".
  base-branch  branch to fork from. default: $DEFAULT_BASE
               (falls back to origin/<base-branch> if no local copy)
  location     parent directory for the worktree. default: $DEFAULT_LOCATION

The worktree is created at <location>/<repo>-<prefix>-claude, where <repo> is
the directory containing .git. Run from inside the main checkout.
EOF
  exit 2
}

case "${1:-}" in
  ''|-h|--help) usage ;;
esac

PREFIX="$1"
BASE="${2:-$DEFAULT_BASE}"
LOCATION="${3:-$DEFAULT_LOCATION}"

BRANCH="${PREFIX}-claude"
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 \
  || die "'$BRANCH' is not a valid branch name"

# --git-common-dir is the shared .git; --git-dir is the current worktree's own
# git dir. They are the same path only in the main checkout -- in a linked
# worktree --git-dir is <shared>/worktrees/<name>. Use that to require that we
# were invoked from the main checkout.
COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
  || die "not inside a git repository"
GIT_DIR="$(git rev-parse --path-format=absolute --git-dir)"
MAIN="$(dirname "$COMMON_DIR")"
REPO="$(basename "$MAIN")"

if [ "$GIT_DIR" != "$COMMON_DIR" ]; then
  die "run this from the main checkout ($MAIN), not from a linked worktree"
fi

DEST="${LOCATION%/}/${REPO}-${BRANCH}"

# Nesting a worktree inside the repo makes every tool recurse into a duplicate
# copy of the tree. Refuse.
case "$DEST/" in
  "$MAIN"/*) die "refusing to create a worktree inside the repo: $DEST" ;;
esac

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  die "branch '$BRANCH' already exists (git worktree list, or pick another prefix)"
fi
if [ -e "$DEST" ]; then
  die "path already exists: $DEST"
fi

if git show-ref --verify --quiet "refs/heads/$BASE"; then
  START="$BASE"
elif git show-ref --verify --quiet "refs/remotes/origin/$BASE"; then
  START="origin/$BASE"
  note "no local '$BASE'; forking from origin/$BASE"
else
  die "base branch '$BASE' not found locally or on origin"
fi

mkdir -p "$LOCATION"
git -C "$MAIN" worktree add -b "$BRANCH" "$DEST" "$START"

linked=0
if [ -f "$MAIN/$LINKS_FILE" ]; then
  while IFS= read -r rel || [ -n "$rel" ]; do
    rel="${rel%%#*}"
    rel="$(printf '%s' "$rel" | tr -d '[:space:]')"
    [ -n "$rel" ] || continue

    src="$MAIN/$rel"
    dst="$DEST/$rel"
    if [ ! -e "$src" ]; then
      note "skip link: $rel (missing in main checkout)"
    elif [ -e "$dst" ] || [ -L "$dst" ]; then
      note "skip link: $rel (already in worktree)"
    else
      mkdir -p "$(dirname "$dst")"
      ln -s "$src" "$dst"
      note "linked: $rel -> $src"
      linked=$((linked + 1))
    fi
  done < "$MAIN/$LINKS_FILE"
fi

cat <<EOF

worktree  $DEST
branch    $BRANCH (from $START)

  cd "$DEST"
EOF

if [ "$linked" -gt 0 ]; then
  cat <<EOF

$linked linked path(s) are shared with the main checkout -- writes there are NOT isolated.
EOF
fi

cat <<EOF
Remove when done:  git -C "$MAIN" worktree remove "$DEST"
EOF
