# shell/devenv.sh — devenv shell integration. POSIX sh / bash / zsh.
# Sourced from ~/.zprofile (macOS) or ~/.bashrc (Linux) by shell/install.sh.
#
# * puts ~/.local/bin and $DEVENV_HOME/scripts on PATH
# * defines the agent aliases, unless the profile already defines its own
#   (so a customised alias defined earlier in the profile is left alone)

DEVENV_HOME="${DEVENV_HOME:-$HOME/devenv}"
export DEVENV_HOME

case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
case ":$PATH:" in *":$DEVENV_HOME/scripts:"*) ;; *) PATH="$DEVENV_HOME/scripts:$PATH" ;; esac
export PATH

alias codex  >/dev/null 2>&1 || alias codex="codex --dangerously-bypass-approvals-and-sandbox"
alias claude >/dev/null 2>&1 || alias claude="claude --permission-mode bypassPermissions"
alias cc     >/dev/null 2>&1 || alias cc="claude --permission-mode bypassPermissions"
