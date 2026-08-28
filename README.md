# devenv

One command sets up the development environment: the CLI dependencies, the AI
tools and skills, the utility scripts, and the shell configuration. Everything
is installed into the user's home directory and put on `PATH`. Supported on
macOS, Linux, and Windows (native PowerShell).

## Install

```sh
git clone https://github.com/tigercosmos/devenv ~/devenv
cd ~/devenv
make install          # macOS / Linux
```

```powershell
git clone https://github.com/tigercosmos/devenv $HOME\devenv
cd $HOME\devenv
powershell -ExecutionPolicy Bypass -File install.ps1     # Windows
```

Then open a new terminal. Tools that are already installed are left alone;
`make update` (or `FORCE=1 make install`) upgrades everything.

## What `make install` does

| Step | Target | Installs | Where |
|------|--------|----------|-------|
| 1 | `make deps` | `gh`, `codex`, `claude`, cursor `agent` | `~/.local/bin` (gh via Homebrew on macOS, winget on Windows) |
| 2 | `make skills` | [codexmon](https://github.com/tigercosmos/codexmon), [code-cortex-mcp](https://github.com/tigercosmos/code-cortex-mcp) | binaries in `~/.local/bin`, skills in `~/.claude/skills`, linked into `~/.codex/skills`, `~/.agents/skills`, `~/.cursor/skills` |
| 3 | `make scripts` | the utility scripts in [scripts/](scripts/) | on `PATH` via step 4 |
| 4 | `make shell` | a sourced block in the login profile | macOS `~/.zprofile`, Linux `~/.bashrc`, Windows `$PROFILE` |
| 5 | `make doctor` | — | reports the result |

`make shell` sources [shell/devenv.sh](shell/devenv.sh), which adds
`~/.local/bin` and `devenv/scripts` to `PATH` and defines the agent aliases,
then verifies that all three resolve:

```sh
alias codex="codex --dangerously-bypass-approvals-and-sandbox"
alias claude="claude --permission-mode bypassPermissions"
alias cc="claude --permission-mode bypassPermissions"
```

An alias the profile already defines (for example one that also sets an
environment variable) is kept; the check only requires that the flag is present.
On Windows the aliases are PowerShell functions with the same names.

## Scripts

| Script | Purpose |
|--------|---------|
| `devenv-doctor` | Check every tool, skill, alias, and `PATH` entry; exit 1 on a miss |
| `devenv-update` | Upgrade every tool to its latest release (`devenv-update gh codex` for a subset) |
| `devenv-sync-skills` | Link every skill in `~/.claude/skills` into the other agents' skill directories |

Each has a `.ps1` twin for Windows.

## Layout

```
Makefile            make install | deps | skills | scripts | shell | doctor | update
install.ps1         Windows entry point
dependencies/       install.sh / install.ps1 — gh, codex, claude, cursor agent
skills/             install.sh / install.ps1 — codexmon, code-cortex-mcp, skill sync
scripts/            utility scripts added to PATH
shell/              devenv.sh / devenv.ps1 (sourced) and their installers
lib/                helpers shared by the installers
```

## Environment variables

| Variable | Effect |
|----------|--------|
| `FORCE=1` | Reinstall or upgrade tools that are already present |
| `DEVENV_PROFILE` | Override the profile file `make shell` edits |
| `DEVENV_HOME` | Location of this repository (set by the profile block) |
