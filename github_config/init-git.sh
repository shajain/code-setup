#!/usr/bin/env bash
# ============================================================================
# init-git.sh — set up a new project as a git repository.
#
# WHAT IT DOES
#   1. Runs `git init` (skipped if the folder is already a repo)
#   2. Installs .gitignore and .gitattributes from the templates beside it
#   3. Sets core.fileMode false so cloud-sync clients cannot create phantom
#      "modified" files
#   4. Creates src/<project>/data/{raw,filtered,processed}
#   5. Makes the first commit
#
# AFTER THIS SCRIPT, your data under src/<project>/data is tracked BY GIT.
# That is fine while the data is small. Once it is not, run dvc/init-dvc.sh,
# which hands the data over to DVC and takes it out of git.
#
# USAGE
#   ./init-git.sh                      # use the current directory
#   ./init-git.sh ~/code/myproject     # use that directory (creates it)
#   ./init-git.sh -n my_pkg ~/code/foo # override the package name
#   ./init-git.sh -f                   # overwrite existing config files
# ============================================================================

# `set -e` stop on the first error; `-u` treat unset variables as errors;
# `-o pipefail` make a pipeline fail if ANY stage fails, not just the last.
# Together these stop the script from ploughing on after something breaks.
set -euo pipefail


# --- Locate the templates --------------------------------------------------
# BASH_SOURCE[0] is this script's own path. Resolving it means the script
# works no matter which directory you call it from.
TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


# --- Parse arguments -------------------------------------------------------
PROJECT_NAME=""
FORCE=0

while getopts ":n:fh" opt; do
  case "$opt" in
    n) PROJECT_NAME="$OPTARG" ;;   # -n <name>: override the package name
    f) FORCE=1 ;;                  # -f: overwrite existing config files
    h) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown option. Run with -h for help." >&2; exit 1 ;;
  esac
done
# Drop the options we just consumed so $1 is the positional argument.
shift $((OPTIND - 1))

TARGET_DIR="${1:-$PWD}"
mkdir -p "$TARGET_DIR"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"   # make it absolute

# Default the package name to the folder name, with characters that are not
# valid in a Python identifier replaced by underscores.
if [[ -z "$PROJECT_NAME" ]]; then
  PROJECT_NAME="$(basename "$TARGET_DIR" | tr -c '[:alnum:]_' '_' | sed 's/_*$//')"
fi

echo "Project directory : $TARGET_DIR"
echo "Package name      : $PROJECT_NAME"
echo


# --- 1. Initialise the repository ------------------------------------------
cd "$TARGET_DIR"
if [[ -d .git ]]; then
  echo "[skip] already a git repository"
else
  # -b main names the default branch explicitly, so behaviour does not depend
  # on the git version or the user's init.defaultBranch setting.
  git init -b main >/dev/null
  echo "[ok]   git init (branch: main)"
fi


# --- 2. Install the config templates ---------------------------------------
# install_template <source-in-template-dir> <destination-in-project>
install_template() {
  local src="$TEMPLATE_DIR/$1" dest="$TARGET_DIR/$2"
  if [[ -e "$dest" && "$FORCE" -ne 1 ]]; then
    echo "[skip] $2 already exists (use -f to overwrite)"
  else
    cp "$src" "$dest"
    echo "[ok]   wrote $2"
  fi
}

install_template gitignore     .gitignore
install_template gitattributes .gitattributes


# --- 3. Stop cloud sync from faking file changes ---------------------------
# Git records one permission bit per file: is it executable? Dropbox, OneDrive
# and Box routinely rewrite Unix permissions when syncing, which flips that bit
# on every file and makes the whole repo look modified even though no byte
# changed. Setting core.fileMode false tells git to ignore the bit entirely.
#
# This is a LOCAL setting — it lives in .git/config and is not committed, so
# each collaborator sets it for themselves if they need it.
git config core.fileMode false
echo "[ok]   core.fileMode = false (ignores executable-bit churn)"


# --- 4. Create the package and data layout ---------------------------------
# A "src layout": the importable package lives under src/, which keeps the repo
# root clean and stops Python from accidentally importing from the working
# directory instead of the installed package.
#
# Only data/ itself is created. How you organise what goes inside it is a
# per-project decision, so the template takes no position on it.
mkdir -p "src/$PROJECT_NAME/data"

# Git cannot track an empty directory — it only tracks files. .gitkeep is a
# zero-byte placeholder that exists purely so the folder survives a clone.
touch "src/$PROJECT_NAME/data/.gitkeep"

# Make the package importable.
touch "src/$PROJECT_NAME/__init__.py"
echo "[ok]   created src/$PROJECT_NAME/{__init__.py,data/}"


# --- 5. First commit -------------------------------------------------------
# `git rev-parse --verify HEAD` fails when there are no commits yet, which is
# how we detect a brand-new repository.
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  echo "[skip] repository already has commits — staging nothing"
else
  git add .
  git commit -q -m "Initial commit: project scaffold, git config, data layout"
  echo "[ok]   initial commit created"
fi


# --- Done ------------------------------------------------------------------
cat <<EOF

────────────────────────────────────────────────────────────────────
Done. Data under src/$PROJECT_NAME/data is currently tracked BY GIT.

Next steps
  • Add a remote:   git remote add origin <url> && git push -u origin main
  • Move data to DVC once it grows:
        $TEMPLATE_DIR/dvc/init-dvc.sh -n $PROJECT_NAME "$TARGET_DIR"

Useful checks
  git status --ignored          # see what the ignore rules are hiding
  git check-ignore -v <path>    # find the exact rule hiding a given file
────────────────────────────────────────────────────────────────────
EOF
