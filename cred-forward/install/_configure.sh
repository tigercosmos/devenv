#!/usr/bin/env bash
# Role-specific setup used by the top-level devenv installer.

# Paths and readers of the shared state live in lib/common.sh.
CRED_FORWARD_AGENT_CONFIG="$HOME/.config/cred-forward/agent.env"
CRED_FORWARD_GIT_CONFIG="$HOME/.config/cred-forward/gitconfig"
CRED_FORWARD_LOCAL_SOCKET="$HOME/.cache/cred-agent.sock"
CRED_FORWARD_SSH_FRAGMENT="$HOME/.ssh/config.d/cred-forward.conf"
CRED_FORWARD_MANAGED_MARKER='Managed by devenv cred-forward.'
CRED_FORWARD_LINK_SCRIPT="$DEVENV_HOME/cred-forward/service/cred-forward-link"
CRED_FORWARD_AGENT_RESTART=0
CRED_FORWARD_LINK_RESTART=0
CRED_FORWARD_LAST_WRITE=0
CRED_FORWARD_OLD_AGENT_PID=""
CRED_FORWARD_ADMIN_ACTION_REQUIRED=0
export CRED_FORWARD_ADMIN_ACTION_REQUIRED

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

# write_state_file FILE CONTENT — replace an owner-only state file atomically;
# empty CONTENT removes it.
write_state_file() {
    local file="$1" content="$2" dir tmp
    if [ -z "$content" ]; then
        rm -f "$file"
        return
    fi
    dir=$(dirname "$file")
    mkdir -p "$dir"
    [ "$dir" != "$CRED_FORWARD_STATE_DIR" ] || chmod 0700 "$dir"
    tmp=$(mktemp "$dir/.$(basename "$file").XXXXXX")
    printf '%s\n' "$content" >"$tmp"
    chmod 0600 "$tmp"
    mv "$tmp" "$file"
}

record_cred_forward_role() { write_state_file "$CRED_FORWARD_ROLE_FILE" "$1"; }

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
    local secret_file="$CRED_FORWARD_CLAUDE_SECRET"
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
            write_state_file "$declined_file" declined
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

current_agent_pid() {
    case "$(os)" in
        macos) macos_service_pid com.tigercosmos.cred-agent ;;
        linux) linux_service_pid cred-agent.service ;;
    esac
}

# apply_macos_service NAME LABEL PLIST-CONTENT RESTART
# Installs the LaunchAgent and (re)starts it when the plist changed, when
# RESTART is 1, or when it is not running. Succeeds when it (re)started.
apply_macos_service() {
    local name="$1" label="$2" content="$3" restart="$4"
    local plist="$HOME/Library/LaunchAgents/$label.plist"
    local plist_changed current_pid
    install_managed_text "$plist" 0600 "$label.plist" "$content"
    plist_changed=$CRED_FORWARD_LAST_WRITE
    [ "$plist_changed" = 1 ] && restart=1
    if [ "${CRED_FORWARD_SKIP_SERVICE:-0}" = 1 ]; then
        warn "$name service start skipped by CRED_FORWARD_SKIP_SERVICE=1"
        [ "$restart" = 1 ]
        return
    fi
    if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
        current_pid=$(macos_service_pid "$label" || true)
        if [ "$plist_changed" = 1 ]; then
            launchctl bootout "gui/$(id -u)/$label"
            local attempt=0
            while launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; do
                [ "$attempt" -lt 50 ] || die "timed out unloading the $name LaunchAgent"
                sleep 0.1
                attempt=$((attempt + 1))
            done
            launchctl bootstrap "gui/$(id -u)" "$plist"
        elif [ "$restart" = 1 ] || [ -z "$current_pid" ]; then
            restart=1
            launchctl kickstart -k "gui/$(id -u)/$label"
        else
            ok "$name LaunchAgent is already active"
        fi
    else
        restart=1
        launchctl bootstrap "gui/$(id -u)" "$plist"
    fi
    [ "$restart" = 1 ]
}

# apply_linux_service NAME UNIT-CONTENT RESTART
# The systemd counterpart of apply_macos_service.
apply_linux_service() {
    local name="$1" content="$2" restart="$3"
    local unit="$HOME/.config/systemd/user/$name.service"
    install_managed_text "$unit" 0600 "$name.service" "$content"
    [ "$CRED_FORWARD_LAST_WRITE" = 1 ] && restart=1
    if [ "${CRED_FORWARD_SKIP_SERVICE:-0}" = 1 ]; then
        warn "$name service start skipped by CRED_FORWARD_SKIP_SERVICE=1"
        [ "$restart" = 1 ]
        return
    fi
    have systemctl || die "systemctl is required to start $name as a Linux user service"
    [ "$CRED_FORWARD_LAST_WRITE" = 1 ] && systemctl --user daemon-reload
    systemctl --user is-enabled "$name.service" >/dev/null 2>&1 \
        || systemctl --user enable "$name.service"
    if [ "$restart" = 1 ] || ! systemctl --user is-active "$name.service" >/dev/null 2>&1; then
        restart=1
        systemctl --user restart "$name.service"
    else
        ok "$name systemd service is already active"
    fi
    [ "$restart" = 1 ]
}

configure_macos_service() {
    local label=com.tigercosmos.cred-agent content
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
  <key>EnvironmentVariables</key>
  <dict>
    <key>CRED_AGENT_AUDIT_LOG</key><string>$HOME/Library/Logs/cred-agent.log</string>
  </dict>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/cred-agent.err</string>
</dict>
</plist>"
    if apply_macos_service cred-agent "$label" "$content" "$CRED_FORWARD_AGENT_RESTART"; then CRED_FORWARD_AGENT_RESTART=1; fi
}

configure_linux_service() {
    local content
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
    if apply_linux_service cred-agent "$content" "$CRED_FORWARD_AGENT_RESTART"; then CRED_FORWARD_AGENT_RESTART=1; fi
}

# The link service holds the one SSH connection per host that owns the remote
# credential socket. It needs non-interactive SSH authentication (a key
# without a passphrase, or one loaded in the SSH agent that launchd or systemd
# exposes to user services).
configure_macos_link_service() {
    local label=com.tigercosmos.cred-forward-link content
    mkdir -p "$HOME/Library/Logs"
    content="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
  <!-- Managed by devenv cred-forward. -->
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>$HOME/.local/bin/cred-forward-link</string></array>
  <key>RunAtLoad</key><true/>
  <!-- The script exits 0 when every host is switched off; only a failure restarts it. -->
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/cred-forward-link.log</string>
</dict>
</plist>"
    if apply_macos_service cred-forward-link "$label" "$content" "$CRED_FORWARD_LINK_RESTART"; then CRED_FORWARD_LINK_RESTART=1; fi
}

configure_linux_link_service() {
    local content
    content="# $CRED_FORWARD_MANAGED_MARKER
[Unit]
Description=SSH links that forward the local credential socket
After=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/cred-forward-link
Restart=on-failure
RestartSec=5
UMask=0077

[Install]
WantedBy=default.target"
    if apply_linux_service cred-forward-link "$content" "$CRED_FORWARD_LINK_RESTART"; then CRED_FORWARD_LINK_RESTART=1; fi
}

configure_link_service() {
    local hosts off active
    hosts=$(existing_cred_forward_hosts)
    if [ -z "$hosts" ]; then
        warn "no SSH hosts configured; the cred-forward link service is not started"
        return
    fi
    off=$(link_off_hosts)
    active=$(active_cred_forward_hosts "$hosts" "$off")
    if [ -z "$active" ]; then
        # A supervisor started under an older host list may still hold links;
        # restarted, it reads the off list and exits cleanly.
        [ -z "$(link_service_pid || true)" ] || restart_link_service
        warn "credential forwarding is switched off; the link service stays stopped (devenv server on)"
        return
    fi
    case "$(os)" in
        macos) configure_macos_link_service ;;
        linux) configure_linux_link_service ;;
    esac
    if [ "$CRED_FORWARD_LINK_RESTART" = 1 ]; then
        ok "cred-forward link service (re)started for: $active"
    fi
    [ "$active" = "$hosts" ] || warn "switched off hosts: $off (devenv server on HOST)"
}

# active_cred_forward_hosts HOSTS OFF — HOSTS minus the ones OFF covers.
active_cred_forward_hosts() {
    local host result=""
    for host in $1; do
        link_host_is_off "$host" "$2" || result="${result:+$result }$host"
    done
    printf '%s\n' "$result"
}

# link_service_is_off — true when no configured host may be linked.
link_service_is_off() {
    local hosts
    hosts=$(existing_cred_forward_hosts)
    [ -n "$hosts" ] && [ -z "$(active_cred_forward_hosts "$hosts" "$(link_off_hosts)")" ]
}

# write_link_off HOSTS — record the switched-off hosts ("*" for all); an empty
# list removes the file.
write_link_off() { write_state_file "$CRED_FORWARD_LINK_OFF" "$(printf '%s\n' "$1" | tr ' ' '\n')"; }

# restart_link_service — make the supervisor read the off file again. It
# exits cleanly when every host is off, and the service manager restarts
# only failures, so this is also how the links go down.
restart_link_service() {
    case "$(os)" in
        macos)
            if launchctl print "gui/$(id -u)/$CRED_FORWARD_LINK_LABEL" >/dev/null 2>&1; then
                launchctl kickstart -k "gui/$(id -u)/$CRED_FORWARD_LINK_LABEL"
            fi
            ;;
        linux)
            have systemctl || die "systemctl is required to restart the link service"
            systemctl --user restart cred-forward-link.service
            ;;
    esac
}

# start_link_service — install the service if needed and (re)start it.
start_link_service() {
    CRED_FORWARD_LINK_RESTART=1
    configure_link_service
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

# existing_cred_forward_hosts — the configured link hosts, space-separated.
# A fragment from before the links file existed still names its hosts in
# "# cred-forward-host:" comments; they seed the migration.
existing_cred_forward_hosts() {
    if [ -f "$CRED_FORWARD_LINKS" ]; then
        config_lines "$CRED_FORWARD_LINKS" | awk '{ print $1 }' | paste -sd ' ' -
    elif [ -f "$CRED_FORWARD_SSH_FRAGMENT" ]; then
        sed -n 's/^# cred-forward-host: //p' "$CRED_FORWARD_SSH_FRAGMENT" | paste -sd ' ' -
    fi
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

# configure_ssh_hosts — record one "HOST REMOTE-SOCKET" line per host in the
# links file that cred-forward-link reads. The link passes the RemoteForward
# on its own ssh command line, so ~/.ssh/config never carries it and ordinary
# logins cannot bind the remote socket. The managed SSH fragment exists only
# to add ForwardAgent when CRED_FORWARD_SSH_AGENT=1.
configure_ssh_hosts() {
    local hosts="${CRED_FORWARD_HOSTS:-}" existing answer host remote_home
    local links="# $CRED_FORWARD_MANAGED_MARKER"
    local -a host_list
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
    # Saved hosts go through the regular path so that an outdated setup is
    # migrated and the link service still gets checked.
    [ -n "$hosts" ] || hosts=$existing
    if [ -z "$hosts" ]; then
        warn "no SSH hosts configured; set CRED_FORWARD_HOSTS and rerun make install"
        return
    fi
    case "${CRED_FORWARD_SSH_AGENT:-0}" in
        0|1) ;;
        *) die "CRED_FORWARD_SSH_AGENT must be 0 or 1" ;;
    esac
    read -r -a host_list <<<"$hosts"
    for host in "${host_list[@]}"; do
        case "$host" in -*|*[!A-Za-z0-9._-]*|'') die "invalid SSH host alias: $host" ;; esac
        # sun_path holds 104 bytes on macOS (108 on Linux); the agent refuses
        # a longer per-host socket and would then serve nothing at all.
        [ "$(printf '%s' "$(cred_forward_host_socket "$host")" | wc -c)" -le 103 ] \
            || die "SSH host alias too long for a socket path: $host"
    done
    if [ -f "$CRED_FORWARD_LINKS" ] && [ "${host_list[*]}" = "$existing" ]; then
        links=$(cat "$CRED_FORWARD_LINKS")
        ok "reusing SSH forwarding hosts without reconnecting: $existing"
    else
        for host in "${host_list[@]}"; do
            remote_home=$(bash "$CRED_FORWARD_LINK_SCRIPT" prepare "$host") \
                || die "could not prepare the remote socket directory on $host"
            case "$remote_home" in /*) ;; *) die "invalid remote home returned by $host" ;; esac
            case "$remote_home" in *[[:space:]]*) die "invalid remote home returned by $host" ;; esac
            links="$links
$host $remote_home/.cache/cred.sock"
        done
    fi
    install_managed_text "$CRED_FORWARD_LINKS" 0600 links "$links"
    if [ "$CRED_FORWARD_LAST_WRITE" = 1 ]; then
        CRED_FORWARD_LINK_RESTART=1
        # The agent opens one local socket per host, so it restarts too.
        CRED_FORWARD_AGENT_RESTART=1
    fi
    configure_ssh_fragment "${host_list[@]}"
    ok "SSH credential forwarding configured for: ${host_list[*]}"
}

# configure_ssh_fragment HOST... — with CRED_FORWARD_SSH_AGENT=1, add
# ForwardAgent for the hosts through the managed fragment and make sure
# ~/.ssh/config includes it. Otherwise remove a managed fragment; a fragment
# from before the links file also carried the RemoteForward on every login.
configure_ssh_fragment() {
    local host fragment="# $CRED_FORWARD_MANAGED_MARKER"
    local ssh_dir="$HOME/.ssh" ssh_config_link="$HOME/.ssh/config" ssh_config include='Include ~/.ssh/config.d/*.conf'
    local tmp backup_dir
    if [ "${CRED_FORWARD_SSH_AGENT:-0}" != 1 ]; then
        if [ -f "$CRED_FORWARD_SSH_FRAGMENT" ] \
            && grep -qF "$CRED_FORWARD_MANAGED_MARKER" "$CRED_FORWARD_SSH_FRAGMENT"; then
            rm -f "$CRED_FORWARD_SSH_FRAGMENT"
            ok "removed the managed SSH fragment; the link service owns the forward now"
        fi
        return
    fi
    for host in "$@"; do
        fragment="$fragment
Host $host
    ForwardAgent yes"
    done
    mkdir -p "$ssh_dir/config.d"
    chmod 0700 "$ssh_dir" "$ssh_dir/config.d"
    install_managed_text "$CRED_FORWARD_SSH_FRAGMENT" 0600 cred-forward.conf "$fragment"
    ssh_config=$(resolve_symlink_target "$ssh_config_link")
    if [ ! -f "$ssh_config" ]; then
        mkdir -p "$(dirname "$ssh_config")"
        printf '%s\n' "$include" >"$ssh_config"
        chmod 0600 "$ssh_config"
        ok "configured $ssh_config_link"
    elif ! ssh -G "$1" 2>/dev/null | grep -qx 'forwardagent yes'; then
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
    for host in "$@"; do
        ssh -G "$host" 2>/dev/null | grep -qx 'forwardagent yes' \
            || die "OpenSSH did not load ForwardAgent for $host from the cred-forward fragment"
    done
}

configure_cred_forward_server() {
    configure_agent_file
    configure_claude_login
    configure_gh_pin_file
    # Hosts first: the agent reads the links file to open its per-host sockets.
    configure_ssh_hosts
    CRED_FORWARD_OLD_AGENT_PID=$(current_agent_pid || true)
    case "$(os)" in
        macos) configure_macos_service ;;
        linux) configure_linux_service ;;
    esac
    wait_for_agent_socket
    configure_link_service
}

# The pin file is user configuration like the client's account map: seeded
# once with comments only, then owned by `devenv server gh use`.
configure_gh_pin_file() {
    local content
    content="# $CRED_FORWARD_MANAGED_MARKER
# Pins the GitHub login that forwarded gh and git requests use, whatever the
# remote asked for. One \"HOST ACCOUNT\" pair per line; \"*\" covers every host.
# The agent reads this file on every request. Edit it with:
#   devenv server gh use ACCOUNT [--host HOST]
#   devenv server gh use auto [--host HOST]"
    if [ ! -e "$CRED_FORWARD_GH_PIN" ]; then
        install_managed_text "$CRED_FORWARD_GH_PIN" 0600 gh-account "$content"
    else
        ok "already configured: $CRED_FORWARD_GH_PIN"
    fi
}

verify_cred_forward_client_path() {
    local profile login_profile tool resolved
    local wrappers="$HOME/.local/share/cred-forward/wrappers"
    local -a profiles
    profile=$(profile_file)
    login_profile=$(additional_login_profile)
    profiles=("$profile")
    if [ -n "$login_profile" ] && [ "$login_profile" != "$profile" ]; then
        profiles+=("$login_profile")
    fi
    for profile in "${profiles[@]}"; do
        for tool in gh claude codex; do
            resolved=$(profile_executable "$profile" "$tool") || resolved=""
            [ "$resolved" = "$wrappers/$tool" ] \
                || die "$tool does not resolve to the credential wrapper in $profile"
        done
        ok "credential wrappers are active in $profile"
    done
}

# Route HTTPS git credentials for github.com through the forwarded login.
# The managed file is included from the end of the global git config, so its
# helper reset overrides an earlier "gh auth setup-git" entry.
configure_git_credentials() {
    local helper="$HOME/.local/share/cred-forward/wrappers/git-credential-cred-forward"
    local include="$CRED_FORWARD_GIT_CONFIG" content backup_dir global_config
    if ! have git; then
        warn "git is not installed; HTTPS git credentials are not forwarded"
        return
    fi
    content="# $CRED_FORWARD_MANAGED_MARKER
[credential \"https://github.com\"]
	helper =
	helper = !$helper
	useHttpPath = true"
    install_managed_text "$include" 0600 gitconfig "$content"
    # git expands the tilde in include.path itself; keep the value portable.
    # shellcheck disable=SC2088
    if git config --global --includes --get-all include.path 2>/dev/null \
        | grep -Fxq -e "$include" -e "~/.config/cred-forward/gitconfig"; then
        ok "global git config already includes $include"
    else
        # git exits 128 when no global config exists yet; that is not an error.
        global_config=$(git config --global --list --show-origin 2>/dev/null \
            | sed -n 's/^file:\([^\t]*\)\t.*/\1/p' | sed -n '1p' || true)
        if [ -n "$global_config" ] && [ -f "$global_config" ]; then
            backup_dir="$CRED_FORWARD_STATE_DIR/.devenv-backup/$(date +%Y%m%d%H%M%S)-$$"
            mkdir -p "$backup_dir"
            cp -p "$global_config" "$backup_dir/gitconfig"
        fi
        # shellcheck disable=SC2088
        git config --global --add include.path "~/.config/cred-forward/gitconfig"
        ok "added the cred-forward include to the global git config"
    fi
    git_credentials_use_cred_forward \
        || die "another git credential helper for github.com overrides $helper"
    ok "HTTPS git credentials for github.com use the forwarded login"
}

request_ssh_server_setup() {
    local admin_script="$DEVENV_HOME/cred-forward/install/configure-sshd.sh"
    if sshd_policy_is_configured; then
        ok "SSH daemon policy supports safe credential socket replacement"
        return
    fi
    CRED_FORWARD_ADMIN_ACTION_REQUIRED=1
    warn "administrator action is required for reliable SSH socket forwarding"
    printf '%s\n' 'Run this separate command on the client machine:'
    printf '  sudo %q\n' "$admin_script"
    printf '%s\n' 'Then reconnect with SSH. make install never runs sudo.'
}
