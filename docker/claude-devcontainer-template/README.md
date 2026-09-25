# Claude Code + OrbStack + Cursor: reusable project template

## How this is architected

- **OrbStack** runs Docker in the background — you don't interact with it directly.
- **One container per project.** Cursor's Dev Containers extension builds and
  runs an isolated container for whatever folder you open. Each container only
  ever sees that project's files — nothing from other projects or the rest of
  your Mac is mounted in.
- **Miniconda is installed and initialized automatically** via the official
  `conda` dev container feature, with `conda init` run on container creation —
  `conda activate` works in any new terminal with no manual step.
- **Claude Code is installed via the official Anthropic dev container feature**,
  not baked manually — Docker caches the image layers, so after the first
  project, spinning up a new one is fast and doesn't re-download/reinstall
  anything.
- **Auth is shared across every project.** Two small files
  (`~/.claude-shared/.claude/` and `~/.claude-shared/.claude.json`) live on
  your Mac and are bind-mounted into every container. Log in once, anywhere,
  and every future project container is already authenticated.

## One-time setup (do this once, ever)

1. Make sure OrbStack is installed and running (it replaces Docker Desktop —
   `docker` commands just work once it's running).
2. Make sure the **Dev Containers** extension is installed in Cursor
   (Extensions panel -> search "Dev Containers").
3. Run:
   ```bash
   ./setup-shared-claude-auth.sh
   ```
   This creates `~/.claude-shared/` — the folder every project will share.
   If you're already logged in to Claude Code natively on your Mac
   (`~/.claude/.credentials.json` exists), the script copies that login in
   automatically — no need to log in again inside a container.
   If your Mac instead uses an `ANTHROPIC_API_KEY` environment variable
   (no credentials file), the script will tell you — in that case, add the
   key to `containerEnv` in `devcontainer.json` instead of relying on this
   mount.

## Every time you start a new project

```bash
./new-project.sh /path/to/your/project
```

Then in Cursor:
1. Open that project folder.
2. `Cmd+Shift+P` -> **Dev Containers: Reopen in Container**.
3. Cursor builds (or reuses cached layers for) the container and attaches to it.
4. First time ever only: open a terminal in Cursor and run `claude`, log in
   via the browser flow once. From then on, every project's container is
   already logged in — you'll never see that prompt again.

## Customizing per project

Edit the copied `.devcontainer/devcontainer.json` inside that specific
project if it needs a different language runtime — e.g. swap the `node`
feature for `python`, or add another one. The Claude Code feature and the
auth mounts should stay as-is so sharing keeps working.

## What's isolated vs. shared

| | Isolated per container | Shared across all containers |
|---|---|---|
| Project files | ✅ (only that project's folder is mounted) | |
| Claude Code writes/edits | ✅ (confined to that container) | |
| Claude Code login/auth | | ✅ (one login, ever) |
| Claude Code + tooling install | | ✅ (cached Docker layers, installed once) |

If you ever want to reset Claude Code's login (e.g. switching accounts),
just delete `~/.claude-shared/` and run `setup-shared-claude-auth.sh` again —
every project container will prompt for login again on next use.
