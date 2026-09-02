# shell/devenv.sh — devenv shell integration. POSIX sh / bash / zsh.
# Sourced from ~/.zprofile (macOS) or ~/.bashrc (Linux) by shell/install.sh.
#
# * puts credential wrappers, ~/.local/bin, and $DEVENV_HOME/scripts on PATH
# * defines the agent aliases, unless the profile already defines its own
#   (so a customised alias defined earlier in the profile is left alone)

DEVENV_HOME="${DEVENV_HOME:-$HOME/devenv}"
export DEVENV_HOME

_devenv_prepend_path() {
    _devenv_target=$1
    _devenv_new_path=""
    _devenv_path_rest="$PATH:"
    _devenv_path_first=1
    while [ -n "$_devenv_path_rest" ]; do
        _devenv_path_entry=${_devenv_path_rest%%:*}
        _devenv_path_rest=${_devenv_path_rest#*:}
        [ "$_devenv_path_entry" = "$_devenv_target" ] && continue
        if [ "$_devenv_path_first" = 1 ]; then
            _devenv_new_path=$_devenv_path_entry
            _devenv_path_first=0
        else
            _devenv_new_path="$_devenv_new_path:$_devenv_path_entry"
        fi
    done
    if [ "$_devenv_path_first" = 1 ]; then
        PATH=$_devenv_target
    else
        PATH="$_devenv_target:$_devenv_new_path"
    fi
}

_devenv_prepend_path "$DEVENV_HOME/scripts"
_devenv_prepend_path "$HOME/.local/bin"
_DEVENV_CRED_WRAPPERS="$HOME/.local/share/cred-forward/wrappers"
_DEVENV_CRED_ROLE=$(sed -n '1p' "$HOME/.local/share/cred-forward/role" 2>/dev/null || true)
if [ "$_DEVENV_CRED_ROLE" = client ] && [ -d "$_DEVENV_CRED_WRAPPERS" ]; then
    _devenv_prepend_path "$_DEVENV_CRED_WRAPPERS"
fi
unset _DEVENV_CRED_ROLE _DEVENV_CRED_WRAPPERS _devenv_new_path \
    _devenv_path_entry _devenv_path_first _devenv_path_rest _devenv_target
unset -f _devenv_prepend_path
export PATH

alias codex  >/dev/null 2>&1 || alias codex="codex --dangerously-bypass-approvals-and-sandbox"
alias claude >/dev/null 2>&1 || alias claude="claude --permission-mode bypassPermissions"
alias cc     >/dev/null 2>&1 || alias cc="claude --permission-mode bypassPermissions"
