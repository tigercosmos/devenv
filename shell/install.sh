#!/usr/bin/env bash
# shell/install.sh — wire shell/devenv.sh into the login profile and verify
# the required aliases resolve.
#   macOS: ~/.zprofile    Linux: ~/.bashrc    (override with DEVENV_PROFILE=...)
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

PROFILE=$(profile_file)
BEGIN='# >>> devenv >>>'
END='# <<< devenv <<<'

log "shell profile: $PROFILE"
touch "$PROFILE"

block="$BEGIN
export DEVENV_HOME=\"$DEVENV_HOME\"
[ -f \"\$DEVENV_HOME/shell/devenv.sh\" ] && . \"\$DEVENV_HOME/shell/devenv.sh\"
$END"

if grep -qF "$BEGIN" "$PROFILE"; then
    current=$(sed -n "/^$BEGIN\$/,/^$END\$/p" "$PROFILE")
    if [ "$current" = "$block" ]; then
        ok "devenv block already present"
    else
        # Replace a stale block (e.g. the repo moved) in place.
        tmp=$(mktemp)
        awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$PROFILE" > "$tmp"
        printf '%s\n' "$block" >> "$tmp"
        cat "$tmp" > "$PROFILE"; rm -f "$tmp"
        ok "devenv block updated"
    fi
else
    printf '\n%s\n' "$block" >> "$PROFILE"
    ok "devenv block appended"
fi

chmod +x "$DEVENV_HOME"/scripts/devenv-* 2>/dev/null || true

log "verify aliases (sourcing $PROFILE in a clean $(profile_shell "$PROFILE"))"
check_aliases "$PROFILE" || die "alias check failed — see above"

log "verify PATH"
path_out=$(eval_in_profile "$PROFILE" 'echo "$PATH"')
for d in "$LOCAL_BIN" "$DEVENV_HOME/scripts"; do
    case ":$path_out:" in
        *":$d:"*) ok "PATH contains $d" ;;
        *) fail "PATH is missing $d"; exit 1 ;;
    esac
done

echo
echo "Open a new terminal, or run:  source $PROFILE"
