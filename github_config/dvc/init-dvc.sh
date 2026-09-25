#!/usr/bin/env bash
# ============================================================================
# init-dvc.sh — hand the project's data folder over from git to DVC.
#
# Run this AFTER init-git.sh, once the data is too big for git to carry
# comfortably (roughly: anything over a few hundred MB, or any file that
# changes often and is not plain text).
#
# WHAT IT DOES
#   1. Runs `dvc init` (skipped if DVC is already set up)
#   2. Installs .dvcignore from the template beside it
#   3. Removes src/<project>/data from git's index — the files stay on disk
#   4. Runs `dvc add` on that folder, which creates data.dvc and writes a
#      .gitignore next to the data so git leaves it alone from now on
#   5. Optionally configures a DVC remote
#   6. Stages everything git still needs to track
#
# THE KEY IDEA
#   Git tracks a small text pointer (data.dvc) holding a checksum of the
#   folder. DVC tracks the actual bytes, in its own cache and on a remote.
#   Your history stays small; your data stays versioned.
#
# USAGE
#   ./init-dvc.sh                                   # current directory
#   ./init-dvc.sh -n my_pkg ~/code/foo              # explicit name and path
#   ./init-dvc.sh -r ~/Backups/dvc-store            # also configure a remote
#   ./init-dvc.sh -r s3://my-bucket/dvc             # remote can be a URL
# ============================================================================

set -euo pipefail

TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


# --- Parse arguments -------------------------------------------------------
PROJECT_NAME=""
REMOTE_URL=""

while getopts ":n:r:h" opt; do
  case "$opt" in
    n) PROJECT_NAME="$OPTARG" ;;   # -n <name>: package name under src/
    r) REMOTE_URL="$OPTARG" ;;     # -r <url|path>: set up a default remote
    h) sed -n '2,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown option. Run with -h for help." >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

TARGET_DIR="$(cd "${1:-$PWD}" && pwd)"
cd "$TARGET_DIR"


# --- Preflight checks ------------------------------------------------------
# Fail early with a clear message rather than halfway through.
if [[ ! -d .git ]]; then
  echo "ERROR: $TARGET_DIR is not a git repository. Run init-git.sh first." >&2
  exit 1
fi

if ! command -v dvc >/dev/null 2>&1; then
  echo "ERROR: dvc is not installed. Try:  pip install dvc" >&2
  exit 1
fi

# Work out which package we are operating on. If -n was not given and there is
# exactly one folder under src/, use that; otherwise ask the user to be
# explicit rather than guessing wrong.
if [[ -z "$PROJECT_NAME" ]]; then
  # A read loop rather than bash 4's `mapfile`, so this also works on the
  # bash 3.2 that macOS ships by default.
  candidates=()
  while IFS= read -r d; do
    candidates+=("$d")
  done < <(find src -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null)
  if [[ "${#candidates[@]}" -eq 1 ]]; then
    PROJECT_NAME="${candidates[0]}"
  else
    echo "ERROR: could not determine the package name. Pass it with -n <name>." >&2
    exit 1
  fi
fi

DATA_DIR="src/$PROJECT_NAME/data"
if [[ ! -d "$DATA_DIR" ]]; then
  echo "ERROR: $DATA_DIR does not exist." >&2
  exit 1
fi

echo "Project directory : $TARGET_DIR"
echo "Data folder       : $DATA_DIR"
echo


# --- 1. Initialise DVC -----------------------------------------------------
if [[ -d .dvc ]]; then
  echo "[skip] DVC already initialised"
else
  # --no-scm would be for a non-git project; we want the git integration,
  # so we let dvc init wire itself into the repository.
  dvc init -q
  echo "[ok]   dvc init"
fi


# --- 2. Install .dvcignore -------------------------------------------------
# `dvc init` writes its own .dvcignore — a three-line comment stub with no
# actual rules. A plain "does the file exist?" check would therefore always
# find it and skip our template, so instead we ask whether the file contains
# any REAL rule: a line that is neither blank nor a comment.
#
#   grep -q  quiet, report via exit status only
#        -v  invert: match lines that are NOT blank-or-comment
#        -E  extended regular expressions
# Exit 0 means "found a real rule" -> the user customised it, leave it alone.
# [[:space:]] rather than \s because BSD grep on macOS lacks the shorthand.
if [[ -e .dvcignore ]] && grep -qvE '^[[:space:]]*(#.*)?$' .dvcignore; then
  echo "[skip] .dvcignore already has custom rules"
else
  cp "$TEMPLATE_DIR/dvcignore" .dvcignore
  echo "[ok]   wrote .dvcignore"
fi


# --- 3. Take the data out of git's index -----------------------------------
# If init-git.sh already committed the data, git is still tracking it. DVC
# cannot take over a path that git tracks, so we remove it from the index.
#
# --cached is the important flag: it removes the files from git's INDEX only
# and leaves them untouched on disk. Without it, git would delete your data.
if git ls-files --error-unmatch "$DATA_DIR" >/dev/null 2>&1; then
  git rm -r --cached -q "$DATA_DIR"
  echo "[ok]   removed $DATA_DIR from git's index (files kept on disk)"
else
  echo "[skip] $DATA_DIR was not tracked by git"
fi


# --- 4. Hand the folder to DVC ---------------------------------------------
# `dvc add` does three things:
#   • hashes every file and copies them into .dvc/cache
#   • writes <folder>.dvc — a small YAML pointer that git WILL track
#   • appends the folder to a .gitignore beside it, so git ignores the data
if [[ -f "$DATA_DIR.dvc" ]]; then
  echo "[skip] $DATA_DIR.dvc already exists — run 'dvc add $DATA_DIR' to refresh"
else
  dvc add "$DATA_DIR"
  echo "[ok]   dvc add $DATA_DIR"
fi


# --- 5. Configure a remote (optional but strongly recommended) -------------
# Without a remote, your data exists only in .dvc/cache on this one machine.
# A fresh clone cannot `dvc pull`, and a disk failure loses everything.
#
# -d makes it the default, so plain `dvc push` / `dvc pull` use it.
if [[ -n "$REMOTE_URL" ]]; then
  dvc remote add -d -f storage "$REMOTE_URL"
  echo "[ok]   dvc remote 'storage' -> $REMOTE_URL"
else
  echo "[warn] no remote configured — data lives only in this machine's cache"
fi


# --- 6. Stage what git should track ----------------------------------------
# Everything here is small text: the pointer file, DVC's own config, and the
# .gitignore that dvc add generated. The data itself is deliberately absent.
git add \
  "$DATA_DIR.dvc" \
  "src/$PROJECT_NAME/.gitignore" \
  .dvc/config \
  .dvc/.gitignore \
  .dvcignore 2>/dev/null || true

echo "[ok]   staged DVC metadata for commit"


# --- Done ------------------------------------------------------------------
cat <<EOF

────────────────────────────────────────────────────────────────────
Data is now managed by DVC.

  git  tracks -> $DATA_DIR.dvc   (a few lines of YAML)
  dvc  tracks -> $DATA_DIR       (the actual bytes)

Next steps
  git commit -m "Track $DATA_DIR with DVC"
$(if [[ -z "$REMOTE_URL" ]]; then
echo "  dvc remote add -d storage <url-or-path>   # REQUIRED before pushing"
fi)
  dvc push                        # upload data to the remote
  dvc status                      # is the working data in sync with the pointer?

On a fresh clone elsewhere
  git clone <url> && cd <repo> && dvc pull
────────────────────────────────────────────────────────────────────
EOF
