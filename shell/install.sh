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
    local profile="$1" current trailing tmp
    log "shell profile: $profile"
    touch "$profile"
    if grep -qF "$BEGIN" "$profile"; then
        current=$(sed -n "/^$BEGIN\$/,/^$END\$/p" "$profile")
        # The block must stay last. Another installer that appends its own
        # PATH line after it puts ~/.local/bin back in front of the
        # credential wrappers, and the real gh then hides the wrapper.
        trailing=$(awk -v e="$END" 'seen && $0!="" {print "yes"; exit} $0==e {seen=1}' "$profile")
        if [ "$current" = "$block" ] && [ -z "$trailing" ]; then
            ok "devenv block already present"
            return
        fi
        # Take the block out, with the blank lines that followed it, and
        # write it again at the end. Trailing blank lines are dropped so a
        # repeated move does not grow the file.
        tmp=$(mktemp)
        awk -v b="$BEGIN" -v e="$END" '
            $0==b { skip=1 }
            skip  { if ($0==e) { skip=0; eat=1 }; next }
            $0=="" { if (!eat) blank++; next }
            { while (blank > 0) { print ""; blank-- }; eat=0; print }
        ' "$profile" >"$tmp"
        [ ! -s "$tmp" ] || printf '\n' >>"$tmp"
        printf '%s\n' "$block" >>"$tmp"
        cat "$tmp" >"$profile"
        rm -f "$tmp"
        if [ "$current" = "$block" ]; then
            ok "devenv block moved to the end of $profile"
        else
            ok "devenv block updated"
        fi
    else
        printf '\n%s\n' "$block" >>"$profile"
        ok "devenv block appended"
    fi
}

install_profile_block "$PROFILE"
if [ -n "$LOGIN_PROFILE" ] && [ "$LOGIN_PROFILE" != "$PROFILE" ]; then
    install_profile_block "$LOGIN_PROFILE"
fi

chmod +x "$DEVENV_HOME"/scripts/devenv "$DEVENV_HOME"/scripts/devenv-* 2>/dev/null || true

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
