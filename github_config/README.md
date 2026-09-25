# github_config — project bootstrap templates

Reusable git and DVC setup for starting a new project. Copy this folder
wherever you like; nothing in it depends on ExTSP.

```
github_config/
├── README.md          this file
├── init-git.sh        step 1 — set up the git repository
├── gitignore          template, copied to <project>/.gitignore
├── gitattributes      template, copied to <project>/.gitattributes
└── dvc/
    ├── init-dvc.sh    step 2 — hand the data folder over to DVC
    └── dvcignore      template, copied to <project>/.dvcignore
```

The three templates have **no leading dot** on purpose. A file literally named
`.gitignore` sitting here would be a live ignore file affecting whatever repo
holds this folder. Without the dot they are inert text, copied and renamed by
the scripts.

## The two-stage model

**Stage 1 — git only.** `init-git.sh` creates the repo and the layout.
`src/<project>/data` is tracked **by git**. Fine while the data is small.

**Stage 2 — add DVC.** `init-dvc.sh` removes that folder from git's index
(files stay on disk), runs `dvc add`, and from then on:

| | tracks | what it stores |
|---|---|---|
| **git** | `src/<project>/data.dvc` | a few lines of YAML holding a checksum |
| **DVC** | `src/<project>/data` | the actual bytes, in its cache and on a remote |

The switch is automatic: `dvc add` writes a `.gitignore` next to the data that
excludes it. You never edit the main `.gitignore` to make this happen.

## Usage

```bash
# Stage 1
./init-git.sh ~/code/myproject          # or no argument for the current dir
./init-git.sh -n my_pkg ~/code/foo      # override the package name
./init-git.sh -f                        # overwrite existing config files

# Stage 2, whenever the data outgrows git
./dvc/init-dvc.sh ~/code/myproject
./dvc/init-dvc.sh -r ~/Backups/dvc-store ~/code/myproject   # also set a remote
./dvc/init-dvc.sh -r s3://bucket/path ~/code/myproject
```

Both scripts are safe to re-run — each step checks whether it has already been
done and skips rather than clobbering.

## What init-git.sh sets up

1. `git init -b main`
2. Copies in `.gitignore` and `.gitattributes`
3. Sets `core.fileMode false` — see below
4. Creates `src/<project>/__init__.py` and `src/<project>/data/`
5. Makes the first commit

### Why `core.fileMode false`

Git records one permission bit per file: is it executable? OneDrive, Dropbox
and Box rewrite Unix permissions when syncing, flipping that bit across the
whole tree. Git then reports every file as modified although no byte changed.
This setting tells git to ignore the bit. It lives in `.git/config` and is not
committed, so each collaborator sets it for themselves.

### Why `.gitattributes` matters

It contains `* text=auto`, which normalises line endings. macOS uses LF,
Windows uses CRLF, and git compares bytes — so without it a Windows
collaborator makes every line of every file look changed. This belongs in a
committed file rather than each person's `core.autocrlf`, because a committed
file applies to everyone automatically.

## Checking your work

```bash
git status --ignored          # everything the ignore rules are hiding
git check-ignore -v <path>    # the exact rule and line hiding one file
dvc status                    # is the working data in sync with data.dvc?
dvc remote list               # where does dvc push send data?
```

## Set a DVC remote

Without one, your data exists only in `.dvc/cache` on a single machine — a
fresh clone cannot `dvc pull`, and a disk failure loses everything.

```bash
dvc remote add -d storage <url-or-path>
dvc push
```

A plain filesystem path works, and is a reasonable choice as long as it points
**outside** any cloud-synced folder.

## Verified

Tested end to end on bash 3.2 (the version macOS ships): create project →
commit data to git → hand over to DVC → `dvc push` → `git clone` elsewhere →
`dvc pull` → data restored byte-identical, with the cloned repo at 212K before
the pull.
