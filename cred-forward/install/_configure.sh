#!/usr/bin/env bash
# Role-specific setup used by the top-level devenv installer.

CRED_FORWARD_STATE_DIR="$HOME/.local/share/cred-forward"
CRED_FORWARD_ROLE_FILE="$CRED_FORWARD_STATE_DIR/role"
CRED_FORWARD_AGENT_CONFIG="$HOME/.config/cred-forward/agent.env"
CRED_FORWARD_LOCAL_SOCKET="$HOME/.cache/cred-agent.sock"
CRED_FORWARD_SSH_FRAGMENT="$HOME/.ssh/config.d/cred-forward.conf"
CRED_FORWARD_MANAGED_MARKER='Managed by devenv cred-forward.'
CRED_FORWARD_AGENT_RESTART=0
CRED_FORWARD_LAST_WRITE=0
CRED_FORWARD_OLD_AGENT_PID=""

require_owner_only_regular_file() {
    local path="$1" mode
    case "$(uname -s)" in
        Darwin) mode=$(stat -f '%Lp' "$path") ;;
        Linux) mode=$(stat -c '%a' "$path") ;;
        *) die "unsupported platform" ;;
    esac
    if [ -L "$path" ] || [ ! -f "$path" ] || [ ! -O "$path" ] \
        || (( (8#$mode & 8#077) != 0 )); then
        die "$path must be an owner-only regular file"
    fi
}

install_managed_text() {
    local destination="$1" mode="$2" backup_name="$3" content="$4"
    local parent tmp backup_dir
    CRED_FORWARD_LAST_WRITE=0
    parent=$(dirname "$destination")
    mkdir -p "$parent"
    tmp=$(mktemp "$parent/.cred-forward.XXXXXX")
    printf '%s\n' "$content" >"$tmp"
    chmod "$mode" "$tmp"
    if [ -f "$destination" ] && cmp -s "$tmp" "$destination"; then
        rm -f "$tmp"
        chmod "$mode" "$destination"
        ok "already configured: $destination"
        return
    fi
    if [ -e "$destination" ] && ! grep -qF "$CRED_FORWARD_MANAGED_MARKER" "$destination" 2>/dev/null; then
        if [ "$FORCE" != 1 ]; then
            rm -f "$tmp"
            die "preserving existing $destination (set FORCE=1 to replace it)"
        fi
        backup_dir="$CRED_FORWARD_STATE_DIR/.devenv-backup/$(date +%Y%m%d%H%M%S)-$$"
        mkdir -p "$backup_dir"
        mv "$destination" "$backup_dir/$backup_name"
        warn "moved existing $destination to $backup_dir/$backup_name"
    fi
    mv "$tmp" "$destination"
    chmod "$mode" "$destination"
    CRED_FORWARD_LAST_WRITE=1
    ok "configured $destination"
}

record_cred_forward_role() {
    local tmp
    mkdir -p "$CRED_FORWARD_STATE_DIR"
    chmod 0700 "$CRED_FORWARD_STATE_DIR"
    tmp=$(mktemp)
    printf '%s\n' "$1" >"$tmp"
    install -m 0600 "$tmp" "$CRED_FORWARD_ROLE_FILE"
    rm -f "$tmp"
}

configure_agent_file() {
    local content
    content="# $CRED_FORWARD_MANAGED_MARKER
# Add CRED_AGENT_*_COMMAND assignments here to override built-in providers.
# The managed service always uses ~/.cache/cred-agent.sock.
# Do not put credential values in this file."
    if [ ! -e "$CRED_FORWARD_AGENT_CONFIG" ]; then
        install_managed_text "$CRED_FORWARD_AGENT_CONFIG" 0600 agent.env "$content"
        [ "$CRED_FORWARD_LAST_WRITE" = 1 ] && CRED_FORWARD_AGENT_RESTART=1
    elif grep -qF "$CRED_FORWARD_MANAGED_MARKER" "$CRED_FORWARD_AGENT_CONFIG"; then
        ok "already configured: $CRED_FORWARD_AGENT_CONFIG"
    else
        ok "using existing provider configuration: $CRED_FORWARD_AGENT_CONFIG"
    fi
    require_owner_only_regular_file "$CRED_FORWARD_AGENT_CONFIG"
}

configure_claude_login() {
    local secret_dir="$CRED_FORWARD_STATE_DIR/secrets"
    local secret_file="$secret_dir/claude-oauth"
    local declined_file="$CRED_FORWARD_STATE_DIR/claude-setup-declined"
    local setup_mode="${CRED_FORWARD_CLAUDE_SETUP:-prompt}"
    local answer token tmp
    if [ -s "$secret_file" ]; then
        ok "Claude subscription credential is configured locally"
        return
    fi
    case "$setup_mode" in
        prompt|skip|force) ;;
        *) die "CRED_FORWARD_CLAUDE_SETUP must be prompt, skip, or force" ;;
    esac
    if [ "$setup_mode" = skip ]; then
        warn "Claude subscription forwarding skipped by CRED_FORWARD_CLAUDE_SETUP=skip"
        return
    fi
    if [ "$setup_mode" != force ] && [ -f "$declined_file" ]; then
        ok "Claude subscription forwarding was previously declined"
        return
    fi
    if [ ! -t 0 ] || ! have claude; then
        warn "Claude subscription forwarding is not configured; run make install in a terminal to add it"
        return
    fi
    printf 'Configure the local Claude subscription for forwarding now? [Y/n]: '
    IFS= read -r answer || answer=n
    case "$answer" in
        n|N|no|NO)
            mkdir -p "$CRED_FORWARD_STATE_DIR"
            chmod 0700 "$CRED_FORWARD_STATE_DIR"
            tmp=$(mktemp "$CRED_FORWARD_STATE_DIR/.claude-setup-declined.XXXXXX")
            printf '%s\n' declined >"$tmp"
            chmod 0600 "$tmp"
            mv "$tmp" "$declined_file"
            warn "Claude subscription forwarding skipped"
            return
            ;;
    esac
    printf '%s\n' 'Claude will create a setup token. Copy it, then return to this prompt.'
    warn "Claude prints the setup token in this terminal; clear terminal scrollback after setup"
    claude setup-token || { warn "claude setup-token failed"; return; }
    printf 'Paste the Claude setup token (input hidden): '
    IFS= read -r -s token || token=""
    printf '\n'
    token="${token#"${token%%[![:space:]]*}"}"
    token="${token%"${token##*[![:space:]]}"}"
    if [ -z "$token" ] || [[ "$token" == *$'\n'* || "$token" == *$'\r'* ]]; then
        unset token
        warn "Claude setup token was empty or invalid"
        return
    fi
    mkdir -p "$secret_dir"
    chmod 0700 "$secret_dir"
    tmp=$(mktemp)
    printf '%s\n' "$token" >"$tmp"
    install -m 0600 "$tmp" "$secret_file"
    rm -f "$tmp"
    rm -f "$declined_file"
    unset token
    ok "stored the Claude setup token in the local owner-only credential store"
}

macos_agent_pid() {
    launchctl print "gui/$(id -u)/com.tigercosmos.cred-agent" 2>/dev/null \
        | awk '$1 == "pid" && $2 == "=" { print $3; exit }'
}

linux_agent_pid() {
    local pid
    pid=$(systemctl --user show --property MainPID --value cred-agent.service 2>/dev/null) \
        || return 1
    case "$pid" in
        ''|0|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$pid"
}

current_agent_pid() {
    case "$(os)" in
        macos) macos_agent_pid ;;
        linux) linux_agent_pid ;;
    esac
}

configure_macos_service() {
    local label=com.tigercosmos.cred-agent
    local plist="$HOME/Library/LaunchAgents/$label.plist"
    local content plist_changed current_pid
    mkdir -p "$HOME/Library/Logs"
    content="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
  <!-- Managed by devenv cred-forward. -->
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>$HOME/.local/bin/cred-agent-launch</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/cred-agent.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/cred-agent.err</string>
</dict>
</plist>"
    install_managed_text "$plist" 0600 "$label.plist" "$content"
    plist_changed=$CRED_FORWARD_LAST_WRITE
    [ "$CRED_FORWARD_LAST_WRITE" = 1 ] && CRED_FORWARD_AGENT_RESTART=1
    if [ "${CRED_FORWARD_SKIP_SERVICE:-0}" = 1 ]; then
        warn "service start skipped by CRED_FORWARD_SKIP_SERVICE=1"
        return
    fi
    if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
        current_pid=$(macos_agent_pid || true)
        if [ "$plist_changed" = 1 ]; then
            launchctl bootout "gui/$(id -u)/$label"
            local attempt=0
            while launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; do
                [ "$attempt" -lt 50 ] || die "timed out unloading the cred-agent LaunchAgent"
                sleep 0.1
                attempt=$((attempt + 1))
            done
            launchctl bootstrap "gui/$(id -u)" "$plist"
        elif [ "$CRED_FORWARD_AGENT_RESTART" = 1 ] || [ -z "$current_pid" ]; then
            CRED_FORWARD_AGENT_RESTART=1
            launchctl kickstart -k "gui/$(id -u)/$label"
        else
            ok "cred-agent LaunchAgent is already active"
        fi
    else
        CRED_FORWARD_AGENT_RESTART=1
        launchctl bootstrap "gui/$(id -u)" "$plist"
    fi
}

configure_linux_service() {
    local unit="$HOME/.config/systemd/user/cred-agent.service"
    local content current_pid
    content="# $CRED_FORWARD_MANAGED_MARKER
[Unit]
Description=Local credential forwarding agent

[Service]
Type=simple
ExecStart=%h/.local/bin/cred-agent-launch
Restart=on-failure
RestartSec=2
UMask=0077

[Install]
WantedBy=default.target"
    install_managed_text "$unit" 0600 cred-agent.service "$content"
    [ "$CRED_FORWARD_LAST_WRITE" = 1 ] && CRED_FORWARD_AGENT_RESTART=1
    if [ "${CRED_FORWARD_SKIP_SERVICE:-0}" = 1 ]; then
        warn "service start skipped by CRED_FORWARD_SKIP_SERVICE=1"
        return
    fi
    have systemctl || die "systemctl is required to start cred-agent as a Linux user service"
    [ "$CRED_FORWARD_LAST_WRITE" = 1 ] && systemctl --user daemon-reload
    systemctl --user is-enabled cred-agent.service >/dev/null 2>&1 \
        || systemctl --user enable cred-agent.service
    current_pid=$(linux_agent_pid || true)
    if [ "$CRED_FORWARD_AGENT_RESTART" = 1 ] \
        || [ -z "$current_pid" ] \
        || ! systemctl --user is-active cred-agent.service >/dev/null 2>&1; then
        CRED_FORWARD_AGENT_RESTART=1
        systemctl --user restart cred-agent.service
    else
        ok "cred-agent systemd service is already active"
    fi
}

wait_for_agent_socket() {
    local attempt=0 current_pid
    [ "${CRED_FORWARD_SKIP_SERVICE:-0}" = 1 ] && return
    while [ "$attempt" -lt 50 ]; do
        if [ -S "$CRED_FORWARD_LOCAL_SOCKET" ]; then
            current_pid=$(current_agent_pid || true)
            if [ -n "$current_pid" ] \
                && { [ "$CRED_FORWARD_AGENT_RESTART" != 1 ] \
                    || [ -z "$CRED_FORWARD_OLD_AGENT_PID" ] \
                    || [ "$current_pid" != "$CRED_FORWARD_OLD_AGENT_PID" ]; }; then
                ok "cred-agent is listening on $CRED_FORWARD_LOCAL_SOCKET"
                return
            fi
        fi
        sleep 0.1
        attempt=$((attempt + 1))
    done
    die "cred-agent did not create $CRED_FORWARD_LOCAL_SOCKET"
}

existing_cred_forward_hosts() {
    [ -f "$CRED_FORWARD_SSH_FRAGMENT" ] || return 0
    sed -n 's/^# cred-forward-host: //p' "$CRED_FORWARD_SSH_FRAGMENT" | paste -sd ' ' -
}

resolve_symlink_target() {
    local current="$1" link next parent count=0
    while [ -L "$current" ]; do
        count=$((count + 1))
        [ "$count" -le 20 ] || die "too many symlinks while resolving $1"
        link=$(readlink "$current")
        case "$link" in
            /*) next="$link" ;;
            *) next="$(dirname "$current")/$link" ;;
        esac
        parent=$(cd "$(dirname "$next")" && pwd -P) \
            || die "cannot resolve SSH config symlink: $1"
        current="$parent/$(basename "$next")"
    done
    printf '%s\n' "$current"
}

prepare_remote_socket() {
    local host="$1"
    ssh -o ClearAllForwardings=yes -o ConnectTimeout=5 "$host" sh -s <<'REMOTE_SCRIPT'
        umask 077
        mkdir -p "$HOME/.cache"
        socket="$HOME/.cache/cred.sock"
        if [ -S "$socket" ]; then
            if command -v ss >/dev/null 2>&1; then
                ss -xl 2>/dev/null | grep -Fq -- "$socket" || rm -f -- "$socket"
            elif command -v lsof >/dev/null 2>&1; then
                lsof -a -U -- "$socket" >/dev/null 2>&1 || rm -f -- "$socket"
            fi
        fi
        printf "%s" "$HOME"
REMOTE_SCRIPT
}

ssh_config_has_forward() {
    local host="$1"
    ssh -G "$host" 2>/dev/null \
        | awk -v local_socket="$CRED_FORWARD_LOCAL_SOCKET" '
            $1 == "remoteforward" && $3 == local_socket { found = 1 }
            END { exit !found }
        '
}

configure_ssh_hosts() {
    local hosts="${CRED_FORWARD_HOSTS:-}" existing answer host remote_home forward_agent_line=""
    local normalized_hosts current_forward_agent=0 reuse_fragment=0
    local -a host_list
    local ssh_dir="$HOME/.ssh" ssh_config_link="$HOME/.ssh/config" ssh_config include='Include ~/.ssh/config.d/*.conf'
    local fragment="# $CRED_FORWARD_MANAGED_MARKER" tmp backup_dir
    existing=$(existing_cred_forward_hosts)
    if [ -z "$hosts" ] && [ -t 0 ]; then
        if [ -n "$existing" ]; then
            printf 'SSH hosts for credential forwarding [%s]: ' "$existing"
        else
            printf 'SSH hosts for credential forwarding (space-separated): '
        fi
        IFS= read -r answer || answer=""
        hosts="${answer:-$existing}"
    fi
    if [ -z "$hosts" ]; then
        if [ -n "$existing" ]; then
            ok "SSH forwarding already configured for: $existing"
        else
            warn "no SSH hosts configured; set CRED_FORWARD_HOSTS and rerun make install"
        fi
        return
    fi
    ssh_config=$(resolve_symlink_target "$ssh_config_link")
    case "${CRED_FORWARD_SSH_AGENT:-0}" in
        0) ;;
        1) forward_agent_line=$'\n    ForwardAgent yes' ;;
        *) die "CRED_FORWARD_SSH_AGENT must be 0 or 1" ;;
    esac
    read -r -a host_list <<<"$hosts"
    for host in "${host_list[@]}"; do
        case "$host" in -*|*[!A-Za-z0-9._-]*|'') die "invalid SSH host alias: $host" ;; esac
    done
    normalized_hosts="${host_list[*]}"
    if grep -Fq 'ForwardAgent yes' "$CRED_FORWARD_SSH_FRAGMENT" 2>/dev/null; then
        current_forward_agent=1
    fi
    if [ -f "$CRED_FORWARD_SSH_FRAGMENT" ] && [ "$normalized_hosts" = "$existing" ] \
        && [ "$current_forward_agent" = "${CRED_FORWARD_SSH_AGENT:-0}" ]; then
        fragment=$(cat "$CRED_FORWARD_SSH_FRAGMENT")
        reuse_fragment=1
        ok "reusing SSH forwarding hosts without reconnecting: $existing"
    fi
    if [ "$reuse_fragment" != 1 ]; then
        for host in "${host_list[@]}"; do
            remote_home=$(prepare_remote_socket "$host") \
                || die "could not prepare the remote socket directory on $host"
            case "$remote_home" in /*) ;; *) die "invalid remote home returned by $host" ;; esac
            case "$remote_home" in *[[:space:]]*) die "invalid remote home returned by $host" ;; esac
            fragment="$fragment
# cred-forward-host: $host
Host $host$forward_agent_line
    RemoteForward $remote_home/.cache/cred.sock $CRED_FORWARD_LOCAL_SOCKET"
        done
    fi
    mkdir -p "$ssh_dir/config.d"
    chmod 0700 "$ssh_dir" "$ssh_dir/config.d"
    install_managed_text "$CRED_FORWARD_SSH_FRAGMENT" 0600 cred-forward.conf "$fragment"
    if [ ! -f "$ssh_config" ]; then
        mkdir -p "$(dirname "$ssh_config")"
        printf '%s\n' "$include" >"$ssh_config"
        chmod 0600 "$ssh_config"
        ok "configured $ssh_config_link"
    elif ! ssh_config_has_forward "${host_list[0]}"; then
        backup_dir="$ssh_dir/.devenv-backup"
        mkdir -p "$backup_dir"
        chmod 0700 "$backup_dir"
        cp -p "$ssh_config" "$backup_dir/config-$(date +%Y%m%d%H%M%S)-$$"
        tmp=$(mktemp "$ssh_dir/.config.XXXXXX")
        { printf '%s\n\n' "$include"; cat "$ssh_config"; } >"$tmp"
        chmod 0600 "$tmp"
        mv "$tmp" "$ssh_config"
        ok "added the cred-forward Include to $ssh_config_link"
    else
        ok "SSH config already loads the cred-forward fragment"
    fi
    for host in "${host_list[@]}"; do
        ssh_config_has_forward "$host" \
            || die "OpenSSH did not load the cred-forward RemoteForward for $host"
        ok "SSH credential forwarding configured for $host"
    done
}

configure_cred_forward_server() {
    configure_agent_file
    configure_claude_login
    CRED_FORWARD_OLD_AGENT_PID=$(current_agent_pid || true)
    case "$(os)" in
        macos) configure_macos_service ;;
        linux) configure_linux_service ;;
    esac
    wait_for_agent_socket
    configure_ssh_hosts
}

verify_cred_forward_client_path() {
    local profile tool resolved wrappers="$HOME/.local/share/cred-forward/wrappers"
    profile=$(profile_file)
    for tool in gh claude codex; do
        resolved=$(profile_executable "$profile" "$tool") || resolved=""
        [ "$resolved" = "$wrappers/$tool" ] \
            || die "$tool does not resolve to the credential wrapper in $profile"
    done
    ok "credential wrappers are active in the profile PATH"
}
