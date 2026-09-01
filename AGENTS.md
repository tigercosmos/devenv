# AGENTS.md

Instructions for AI coding agents (Claude Code, Codex, Cursor) working in this
repository. `CLAUDE.md` is a symlink to this file.

## What this repo is

`devenv` bootstraps a development environment with one command. `make install`
installs the CLI dependencies, the AI tools and skills, the utility scripts,
and the shell configuration into the user's home directory. See
[README.md](README.md) for the user-facing description.

## Layout

| Path | Contents |
|------|----------|
| `Makefile`, `install.ps1` | entry points; every target delegates to a `*/install.sh` or `*/install.ps1` |
| `lib/common.sh`, `lib/common.ps1` | helpers shared by every installer: logging, `os()`, `have()`, `FORCE`, `PATH` setup |
| `dependencies/` | installs `gh`, `codex`, `claude`, cursor `agent` |
| `skills/` | the vendored agent skills plus the installer that links them into `~/.claude/skills` |
| `scripts/` | `devenv-doctor`, `devenv-update`, `devenv-sync-skills` — the commands that end up on `PATH` |
| `shell/` | `devenv.sh` / `devenv.ps1` and the installer that wires them into the login profile |

## Rules

- **Every change is cross-platform.** The repo supports macOS, Linux, and
  Windows (native PowerShell). A change to a `.sh` file needs the matching
  change in the `.ps1` file, and the other way round.
  `cred-forward/` is an explicit, standalone macOS/Linux-only exception.
- **Source `lib/common.sh` (or `lib/common.ps1`); do not duplicate helpers.**
  Use `log`, `ok`, `warn`, `fail`, `die`, `have`, and `os` instead of raw
  `echo` and `command -v`.
  The standalone `cred-forward/` installers are an explicit exception.
- **Installers are idempotent.** A second run must not change anything and
  must not fail. Something already installed is left alone unless `FORCE=1`.
- **Never write outside the user's home directory** (`~/.local/bin`,
  `~/.claude/skills`, the login profile) and never `sudo`.
- **Existing user files are preserved.** Replace one only under `FORCE=1`, and
  move the original to a `.devenv-backup` location first.
- **Follow the surrounding style**: `bash` with `set -euo pipefail`, POSIX-ish
  constructs, quoted variables, and comments that explain why, not what.

## Verifying

There is no test suite. Verify a change by running it:

```sh
make install          # full run
make doctor           # report what is installed and what is missing
FORCE=1 make install  # the upgrade path
```

Run `make install` twice to prove idempotency. For a change to
`dependencies/` or `shell/`, verify in a clean container
(`docker run --rm -it ubuntu:24.04`) so the host environment does not hide a
missing step. Report what you actually ran and what the output was.

## Commits and pull requests

- Subject line in the imperative mood, under 72 characters, no trailing
  period. Body wrapped at 72 columns, explaining the problem and the fix.
- **Do not add AI co-author or attribution trailers.** No
  `Co-Authored-By: Claude`, no `Generated with ...` line, no
  `🤖` marker — in commit messages, pull request bodies, or code comments.
  Commits are authored by the repo owner alone.
- Commit or push only when asked.
