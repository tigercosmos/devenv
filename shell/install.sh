#!/usr/bin/env bash
# shell/install.sh — wire shell/devenv.sh into the login profile and verify
# the required aliases resolve.
#   macOS: ~/.zprofile    Linux: ~/.bashrc and ~/.profile
#   DEVENV_PROFILE overrides the profile choice.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

PROFILE=$(profile_file)
LOGIN_PROFILE=$(additional_login_profile)
BEGIN='# >>> devenv >>>'
END='# <<< devenv <<<'

block="$BEGIN
export DEVENV_HOME=\"$DEVENV_HOME\"
[ -f \"\$DEVENV_HOME/shell/devenv.sh\" ] && . \"\$DEVENV_HOME/shell/devenv.sh\"
$END"

install_profile_block() {
    local profile="$1" current tmp
    log "shell profile: $profile"
    touch "$profile"
    if grep -qF "$BEGIN" "$profile"; then
        current=$(sed -n "/^$BEGIN\$/,/^$END\$/p" "$profile")
        if [ "$current" = "$block" ]; then
            ok "devenv block already present"
            return
        fi
        # Replace a stale block (e.g. the repo moved) in place.
        tmp=$(mktemp)
        awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$profile" >"$tmp"
        printf '%s\n' "$block" >>"$tmp"
        cat "$tmp" >"$profile"
        rm -f "$tmp"
        ok "devenv block updated"
    else
        printf '\n%s\n' "$block" >>"$profile"
        ok "devenv block appended"
    fi
}

install_profile_block "$PROFILE"
if [ -n "$LOGIN_PROFILE" ] && [ "$LOGIN_PROFILE" != "$PROFILE" ]; then
    install_profile_block "$LOGIN_PROFILE"
fi

chmod +x "$DEVENV_HOME"/scripts/devenv-* 2>/dev/null || true

log "verify aliases (sourcing $PROFILE in a clean $(profile_shell "$PROFILE"))"
check_aliases "$PROFILE" || die "alias check failed — see above"

log "verify PATH"
# Expand PATH inside the clean profile shell, not in this installer.
# shellcheck disable=SC2016
path_out=$(eval_in_profile "$PROFILE" 'echo "$PATH"')
for d in "$LOCAL_BIN" "$DEVENV_HOME/scripts"; do
    case ":$path_out:" in
        *":$d:"*) ok "PATH contains $d" ;;
        *) fail "PATH is missing $d"; exit 1 ;;
    esac
done
if [ -n "$LOGIN_PROFILE" ] && [ "$LOGIN_PROFILE" != "$PROFILE" ]; then
    log "verify login PATH (sourcing $LOGIN_PROFILE)"
    # shellcheck disable=SC2016
    login_path_out=$(eval_in_profile "$LOGIN_PROFILE" 'echo "$PATH"')
    for d in "$LOCAL_BIN" "$DEVENV_HOME/scripts"; do
        case ":$login_path_out:" in
            *":$d:"*) ok "login PATH contains $d" ;;
            *) fail "login PATH is missing $d"; exit 1 ;;
        esac
    done
fi

echo
echo "Open a new terminal, or run:  source $PROFILE"
