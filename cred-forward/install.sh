#!/usr/bin/env bash
# Install the local credential server or the remote credential client.
set -euo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/../lib/common.sh"
. "$DEVENV_HOME/cred-forward/install/_configure.sh"

role="${1:-${CRED_FORWARD_ROLE:-}}"
if [ -z "$role" ] && [ -f "$CRED_FORWARD_ROLE_FILE" ]; then
    role=$(sed -n '1p' "$CRED_FORWARD_ROLE_FILE")
fi
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
agent_signature_before=$(cksum "$LOCAL_BIN/cred-agent" "$LOCAL_BIN/cred-agent-launch" 2>/dev/null || true)
"$installer" "$installer_role"
agent_signature_after=$(cksum "$LOCAL_BIN/cred-agent" "$LOCAL_BIN/cred-agent-launch" 2>/dev/null || true)
[ "$agent_signature_before" != "$agent_signature_after" ] && CRED_FORWARD_AGENT_RESTART=1
case "$role" in
    server)
        record_cred_forward_role "$role"
        configure_cred_forward_server
        ;;
    client)
        record_cred_forward_role "$role"
        verify_cred_forward_client_path
        ;;
esac
ok "cred-forward installed and configured as $role"
