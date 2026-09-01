#!/usr/bin/env bash
# Install the local credential server or the remote credential client.
set -euo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/../lib/common.sh"

role="${1:-${CRED_FORWARD_ROLE:-}}"
if [ -z "$role" ]; then
    if [ -t 0 ]; then
        printf 'Install cred-forward as server or client? [server]: '
        IFS= read -r role || role=""
    fi
    role="${role:-server}"
fi

case "$role" in
    server|agent)
        role=server
        installer_role=agent
        ;;
    client)
        installer_role=client
        ;;
    *)
        die "cred-forward role must be server or client (got: $role)"
        ;;
esac

case "$(os)" in
    macos) installer="$DEVENV_HOME/cred-forward/install/install-macos.sh" ;;
    linux) installer="$DEVENV_HOME/cred-forward/install/install-linux.sh" ;;
    *) die "cred-forward supports macOS and Linux only" ;;
esac

log "cred-forward ($role)"
"$installer" "$installer_role"
ok "cred-forward installed as $role"
