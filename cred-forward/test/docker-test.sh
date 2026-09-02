#!/bin/bash
set -euo pipefail

go test ./...
make build
shellcheck -x wrappers/* install/*.sh

test_root=$(mktemp -d)
trap 'jobs -pr | xargs -r kill; rm -rf "$test_root"' EXIT

install_home=$test_root/install-home
mkdir -p "$install_home"
HOME=$install_home ./install/install-linux.sh all >"$test_root/install.log"
[ -x "$install_home/.local/bin/cred-agent" ]
[ -x "$install_home/.local/bin/cred-client" ]
[ -x "$install_home/.local/share/cred-forward/wrappers/gh" ]
[ "$(stat -c '%a' "$install_home/.cache")" = 700 ]
find "$install_home/.local" -type f -exec stat -c '%n:%i:%Y:%a' {} + \
    | sort >"$test_root/install-before"
sleep 1
HOME=$install_home ./install/install-linux.sh all >"$test_root/reinstall.log"
find "$install_home/.local" -type f -exec stat -c '%n:%i:%Y:%a' {} + \
    | sort >"$test_root/install-after"
cmp "$test_root/install-before" "$test_root/install-after"

preserve_home=$test_root/preserve-home
mkdir -p "$preserve_home/.local/share/cred-forward/wrappers"
printf '%s\n' user-owned >"$preserve_home/.local/share/cred-forward/wrappers/gh"
if HOME=$preserve_home ./install/install-linux.sh client >"$test_root/preserve.log" 2>&1; then
    echo "installer unexpectedly succeeded after preserving a conflicting file" >&2
    exit 1
fi
[ "$(cat "$preserve_home/.local/share/cred-forward/wrappers/gh")" = user-owned ]
FORCE=1 HOME=$preserve_home ./install/install-linux.sh client >"$test_root/force.log"
grep -Rqx user-owned "$preserve_home/.local/share/cred-forward/.devenv-backup"
cmp wrappers/gh "$preserve_home/.local/share/cred-forward/wrappers/gh"

printf '\n# upgraded\n' >>wrappers/gh
HOME=$install_home ./install/install-linux.sh client >"$test_root/upgrade.log"
cmp wrappers/gh "$install_home/.local/share/cred-forward/wrappers/gh"

# The service launcher refuses unsafe shell configuration and pins the socket
# path used by the managed SSH setup.
launcher_home=$test_root/launcher-home
mkdir -p "$launcher_home/.local/bin" "$launcher_home/.config/cred-forward"
cat >"$launcher_home/.local/bin/cred-agent" <<'EOF'
#!/bin/sh
set -eu
printf '%s' "$CRED_AGENT_SOCKET"
EOF
chmod 0755 "$launcher_home/.local/bin/cred-agent"
printf '%s\n' 'CRED_AGENT_SOCKET=/tmp/not-the-managed-socket' \
    >"$launcher_home/.config/cred-forward/agent.env"
chmod 0644 "$launcher_home/.config/cred-forward/agent.env"
if HOME=$launcher_home ./service/cred-agent-launch >"$test_root/unsafe-agent.out" \
    2>"$test_root/unsafe-agent.err"; then
    echo 'launcher unexpectedly sourced a non-owner-only agent.env' >&2
    exit 1
fi
grep -Fq 'agent.env must be an owner-only regular file' "$test_root/unsafe-agent.err"
chmod 0600 "$launcher_home/.config/cred-forward/agent.env"
HOME=$launcher_home ./service/cred-agent-launch >"$test_root/managed-socket.out"
[ "$(cat "$test_root/managed-socket.out")" = "$launcher_home/.cache/cred-agent.sock" ]

# The top-level installer completes role-specific setup. Stub service and SSH
# commands so this test does not need a running systemd user manager or another
# host outside the container.
server_home=$test_root/server-home
mkdir -p "$server_home/.local/bin" "$server_home/.codex" \
    "$server_home/.local/share/cred-forward/secrets" "$server_home/.ssh" \
    "$server_home/dotfiles"
printf '%s\n' 'Host existing-host' >"$server_home/dotfiles/ssh-config"
ln -s ../dotfiles/ssh-config "$server_home/.ssh/config"
cat >"$server_home/.local/bin/systemctl" <<'EOF'
#!/bin/sh
set -eu
case "$*" in
    *'show --property MainPID --value cred-agent.service')
        if [ -f "$HOME/cred-agent.pid" ] \
            && kill -0 "$(cat "$HOME/cred-agent.pid")" 2>/dev/null; then
            cat "$HOME/cred-agent.pid"
        else
            printf '%s\n' 0
        fi
        ;;
    *'is-active cred-agent.service')
        [ -f "$HOME/cred-agent.pid" ] \
            && kill -0 "$(cat "$HOME/cred-agent.pid")" 2>/dev/null
        ;;
    *'restart cred-agent.service')
        if [ -f "$HOME/cred-agent.pid" ]; then
            kill "$(cat "$HOME/cred-agent.pid")" 2>/dev/null || true
            wait "$(cat "$HOME/cred-agent.pid")" 2>/dev/null || true
        fi
        "$HOME/.local/bin/cred-agent-launch" >"$HOME/cred-agent.out" 2>"$HOME/cred-agent.err" &
        printf '%s\n' "$!" >"$HOME/cred-agent.pid"
        ;;
esac
EOF
cat >"$server_home/.local/bin/ssh" <<'EOF'
#!/bin/sh
set -eu
if [ "${1:-}" = -G ]; then
    printf '%s\n' 'hostname fake.example' 'user remote'
    if grep -Fq 'Include ~/.ssh/config.d/*.conf' "$HOME/.ssh/config" 2>/dev/null; then
        printf 'remoteforward /home/remote/.cache/cred.sock %s/.cache/cred-agent.sock\n' "$HOME"
    fi
    exit 0
fi
[ "${1:-}" = -o ]
[ "${2:-}" = ClearAllForwardings=yes ]
[ "${3:-}" = -o ]
[ "${4:-}" = ConnectTimeout=5 ]
[ "${5:-}" = sim0 ]
[ "${6:-}" = sh ]
[ "${7:-}" = -s ]
printf '%s\n' probe >>"$HOME/ssh-remote-probed"
printf '%s' /home/remote
EOF
cat >"$server_home/.local/bin/gh" <<'EOF'
#!/bin/sh
set -eu
[ "$1 $2" = 'auth token' ]
printf github-login
EOF
chmod 0755 "$server_home/.local/bin/systemctl" "$server_home/.local/bin/ssh" "$server_home/.local/bin/gh"
printf '%s\n' '{"tokens":{"access_token":"chatgpt-login","account_id":"account-id"}}' \
    >"$server_home/.codex/auth.json"
printf '%s\n' claude-login >"$server_home/.local/share/cred-forward/secrets/claude-oauth"
chmod 0600 "$server_home/.codex/auth.json" \
    "$server_home/.local/share/cred-forward/secrets/claude-oauth"
server_path="$server_home/.local/bin:/usr/local/go/bin:/usr/bin:/bin"
HOME=$server_home PATH=$server_path DEVENV_HOME=/src CRED_FORWARD_ROLE=server \
    CRED_FORWARD_HOSTS=sim0 /src/cred-forward/install.sh >"$test_root/server-install.log"
first_server_pid=$(cat "$server_home/cred-agent.pid")
chmod 0644 "$server_home/.ssh/config.d/cred-forward.conf"
HOME=$server_home PATH=$server_path DEVENV_HOME=/src CRED_FORWARD_ROLE=server \
    CRED_FORWARD_HOSTS=sim0 /src/cred-forward/install.sh >"$test_root/server-reinstall.log"
[ "$(cat "$server_home/cred-agent.pid")" = "$first_server_pid" ]
[ "$(wc -l <"$server_home/ssh-remote-probed")" = 1 ]
[ "$(cat "$server_home/.local/share/cred-forward/role")" = server ]
[ -S "$server_home/.cache/cred-agent.sock" ]
[ -L "$server_home/.ssh/config" ]
grep -Fqx 'Include ~/.ssh/config.d/*.conf' "$server_home/.ssh/config"
grep -Fqx 'Host existing-host' "$server_home/.ssh/config"
grep -Fq 'Host sim0' "$server_home/.ssh/config.d/cred-forward.conf"
if grep -Fq 'ForwardAgent yes' "$server_home/.ssh/config.d/cred-forward.conf"; then
    echo 'SSH-agent forwarding unexpectedly enabled by default' >&2
    exit 1
fi
[ "$(stat -c '%a' "$server_home/.ssh/config.d/cred-forward.conf")" = 600 ]
HOME=$server_home CRED_FORWARD_SOCKET="$server_home/.cache/cred-agent.sock" \
    /src/cred-forward/dist/linux-amd64/cred-client github >"$test_root/server-github"
[ "$(cat "$test_root/server-github")" = github-login ]
HOME=$server_home CRED_FORWARD_SOCKET="$server_home/.cache/cred-agent.sock" \
    /src/cred-forward/dist/linux-amd64/cred-client anthropicoauth >"$test_root/server-claude"
[ "$(cat "$test_root/server-claude")" = claude-login ]
HOME=$server_home CRED_FORWARD_SOCKET="$server_home/.cache/cred-agent.sock" \
    /src/cred-forward/dist/linux-amd64/cred-client openaichatgpt >"$test_root/server-codex"
[ "$(cat "$test_root/server-codex")" = chatgpt-login ]
printf '\n# upgraded launcher\n' >>service/cred-agent-launch
HOME=$server_home PATH=$server_path DEVENV_HOME=/src CRED_FORWARD_ROLE=server \
    CRED_FORWARD_HOSTS=sim0 /src/cred-forward/install.sh >"$test_root/server-upgrade.log"
[ "$(cat "$server_home/cred-agent.pid")" != "$first_server_pid" ]
HOME=$server_home CRED_FORWARD_SOCKET="$server_home/.cache/cred-agent.sock" \
    /src/cred-forward/dist/linux-amd64/cred-client github >"$test_root/server-upgraded-github"
[ "$(cat "$test_root/server-upgraded-github")" = github-login ]
kill "$(cat "$server_home/cred-agent.pid")"

# Exercise the remote cleanup script instead of short-circuiting it in the SSH
# stub. The lsof stub accepts only the portable argument form and reports that
# the planted Unix socket has no listener.
cleanup_local_home=$test_root/cleanup-local-home
cleanup_remote_home=$test_root/cleanup-remote-home
cleanup_bin=$test_root/cleanup-bin
mkdir -p "$cleanup_local_home" "$cleanup_remote_home/.cache" "$cleanup_bin"
cat >"$test_root/make-stale-socket.go" <<'EOF'
package main

import (
	"net"
	"os"
)

func main() {
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: os.Args[1], Net: "unix"})
	if err != nil {
		panic(err)
	}
	listener.SetUnlinkOnClose(false)
	if err := listener.Close(); err != nil {
		panic(err)
	}
}
EOF
go run "$test_root/make-stale-socket.go" "$cleanup_remote_home/.cache/cred.sock"
cat >"$cleanup_bin/lsof" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = -a ]
[ "$2" = -U ]
[ "$3" = -- ]
[ "$4" = "$HOME/.cache/cred.sock" ]
: >"$HOME/lsof-probed"
exit 1
EOF
cat >"$cleanup_bin/ssh" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = -o ]
[ "$2" = ClearAllForwardings=yes ]
[ "$3" = -o ]
[ "$4" = ConnectTimeout=5 ]
[ "$5" = sim0 ]
shift 5
HOME="$CRED_FORWARD_TEST_REMOTE_HOME" "$@"
EOF
chmod 0755 "$cleanup_bin/lsof" "$cleanup_bin/ssh"
HOME=$cleanup_local_home PATH="$cleanup_bin:/usr/local/go/bin:/usr/bin:/bin" \
    DEVENV_HOME=/src CRED_FORWARD_TEST_REMOTE_HOME=$cleanup_remote_home bash -c '
        set -euo pipefail
        . /src/lib/common.sh
        . /src/cred-forward/install/_configure.sh
        prepare_remote_socket sim0
    ' >"$test_root/cleanup-remote-home.out"
[ "$(cat "$test_root/cleanup-remote-home.out")" = "$cleanup_remote_home" ]
[ -f "$cleanup_remote_home/lsof-probed" ]
[ ! -e "$cleanup_remote_home/.cache/cred.sock" ]

client_home=$test_root/client-home
mkdir -p "$client_home"
cat >"$client_home/.bashrc" <<'EOF'
export DEVENV_HOME=/src
. /src/shell/devenv.sh
# Common toolchains prepend their own directory after the devenv block.
export PATH="/opt/late-toolchain:$PATH"
EOF
client_path="/usr/local/go/bin:/usr/bin:/bin"
HOME=$client_home PATH=$client_path DEVENV_HOME=/src DEVENV_PROFILE="$client_home/.bashrc" \
    CRED_FORWARD_ROLE=client /src/cred-forward/install.sh >"$test_root/client-install.log"
HOME=$client_home PATH=$client_path DEVENV_HOME=/src DEVENV_PROFILE="$client_home/.bashrc" \
    /src/cred-forward/install.sh >"$test_root/client-reinstall.log"
[ "$(cat "$client_home/.local/share/cred-forward/role")" = client ]
HOME=$client_home bash --noprofile --norc -i -c \
    'source "$HOME/.bashrc"; [ "$(type -P codex)" = "$HOME/.local/share/cred-forward/wrappers/codex" ]'
HOME=$client_home bash --noprofile --norc -c '
    PATH="$HOME/.local/bin:$HOME/.local/share/cred-forward/wrappers:/usr/bin:$HOME/.local/bin"
    source "$HOME/.bashrc"
    [ "$(type -P gh)" = "$HOME/.local/share/cred-forward/wrappers/gh" ]
    [ "$(type -P claude)" = "$HOME/.local/share/cred-forward/wrappers/claude" ]
    [ "$(type -P codex)" = "$HOME/.local/share/cred-forward/wrappers/codex" ]
    [ "$(printf "%s" "$PATH" | tr : "\n" | grep -Fxc "$HOME/.local/bin")" = 1 ]
'

mac_home=$test_root/mac-home
mkdir -p "$mac_home"
HOME=$mac_home DEVENV_HOME=/src FORCE=0 CRED_FORWARD_SKIP_SERVICE=1 bash -c '
    set -euo pipefail
    . /src/lib/common.sh
    . /src/cred-forward/install/_configure.sh
    configure_macos_service
' >"$test_root/mac-service.log"
grep -Fq '<string>com.tigercosmos.cred-agent</string>' \
    "$mac_home/Library/LaunchAgents/com.tigercosmos.cred-agent.plist"
[ "$(stat -c '%a' "$mac_home/Library/LaunchAgents/com.tigercosmos.cred-agent.plist")" = 600 ]
mkdir -p "$mac_home/.local/bin"
cat >"$mac_home/.local/bin/launchctl" <<'EOF'
#!/bin/sh
set -eu
case "$1" in
    print) [ ! -e "$HOME/launchctl-unloaded" ] ;;
    bootout)
        : >"$HOME/launchctl-unloaded"
        printf '%s\n' "$*" >>"$HOME/launchctl.log"
        ;;
    *) printf '%s\n' "$*" >>"$HOME/launchctl.log" ;;
esac
EOF
chmod 0755 "$mac_home/.local/bin/launchctl"
printf '%s\n' '<!-- Managed by devenv cred-forward. -->' \
    >"$mac_home/Library/LaunchAgents/com.tigercosmos.cred-agent.plist"
HOME=$mac_home PATH="$mac_home/.local/bin:$PATH" DEVENV_HOME=/src FORCE=0 bash -c '
    set -euo pipefail
    . /src/lib/common.sh
    . /src/cred-forward/install/_configure.sh
    configure_macos_service
' >"$test_root/mac-service-reload.log"
grep -Fq 'bootout gui/' "$mac_home/launchctl.log"
grep -Fq 'bootstrap gui/' "$mac_home/launchctl.log"
if grep -Fq 'kickstart' "$mac_home/launchctl.log"; then
    echo 'changed LaunchAgent was restarted without reloading its plist' >&2
    exit 1
fi
rm -f "$mac_home/launchctl-unloaded" "$mac_home/launchctl.log"
HOME=$mac_home PATH="$mac_home/.local/bin:$PATH" DEVENV_HOME=/src FORCE=0 bash -c '
    set -euo pipefail
    . /src/lib/common.sh
    . /src/cred-forward/install/_configure.sh
    configure_macos_service
' >"$test_root/mac-service-crashed.log"
grep -Fq 'kickstart -k gui/' "$mac_home/launchctl.log"

failed_server_home=$test_root/failed-server-home
mkdir -p "$failed_server_home"
if HOME=$failed_server_home PATH=/usr/local/go/bin:/usr/bin:/bin DEVENV_HOME=/src \
    CRED_FORWARD_ROLE=server CRED_FORWARD_SKIP_SERVICE=1 \
    CRED_FORWARD_HOSTS=-invalid /src/cred-forward/install.sh \
    >"$test_root/failed-server.out" 2>"$test_root/failed-server.err"; then
    echo 'server setup unexpectedly accepted an invalid SSH host' >&2
    exit 1
fi
[ "$(cat "$failed_server_home/.local/share/cred-forward/role")" = server ]

existing_cache_home=$test_root/existing-cache-home
mkdir -p "$existing_cache_home/.cache"
chmod 0755 "$existing_cache_home/.cache"
HOME=$existing_cache_home ./install/install-linux.sh agent >"$test_root/existing-cache-install.log"
[ "$(stat -c '%a' "$existing_cache_home/.cache")" = 755 ]

export CRED_AGENT_GITHUB=fake-github-token
export CRED_AGENT_ANTHROPIC=fake-anthropic-token
export CRED_AGENT_OPENAI=fake-openai-token
local_socket=$test_root/cred-agent.sock
./dist/linux-amd64/cred-agent -socket "$local_socket" 2>"$test_root/agent.log" &
agent_pid=$!
for _ in $(seq 1 50); do
    [ -S "$local_socket" ] && break
    sleep 0.05
done
[ "$(stat -c '%a' "$local_socket")" = 600 ]
[ "$(CRED_FORWARD_SOCKET=$local_socket ./dist/linux-amd64/cred-client github)" = fake-github-token ]

mkdir -p "$test_root/real" "$test_root/wrappers"
cp wrappers/* "$test_root/wrappers/"
chmod +x "$test_root/wrappers/gh" "$test_root/wrappers/claude" "$test_root/wrappers/codex"
for tool in gh claude codex; do
    cat >"$test_root/real/$tool" <<'EOF'
#!/bin/sh
set -eu

case "$(basename "$0")" in
    gh) test "$GH_TOKEN" = fake-github-token ;;
    claude)
        if [ "${EXPECT_LOGIN_KIND:-api}" = oauth ]; then
            test "$CLAUDE_CODE_OAUTH_TOKEN" = fake-anthropic-oauth-token
            test -z "${ANTHROPIC_API_KEY:-}"
        else
            test -z "${ANTHROPIC_API_KEY:-}"
            test "$1" = --settings
            case "$2" in
                *apiKeyHelper*cred-client*anthropic*) ;;
                *) exit 1 ;;
            esac
        fi
        ;;
    codex)
        test "$1" = -c
        test "$2" = 'model_provider="cred_forward"'
        test ! -e "$HOME/.codex/auth.json"
        if [ "${EXPECT_LOGIN_KIND:-api}" = oauth ]; then
            test -z "${OPENAI_API_KEY:-}"
            test "$CRED_FORWARD_OPENAI_ACCOUNT_ID" = fake-openai-account
            test "${10}" = 'model_providers.cred_forward.auth.command="/src/cred-forward/dist/linux-amd64/cred-client"'
            test "${12}" = 'model_providers.cred_forward.auth.args=["openaichatgpt"]'
        else
            test -z "${OPENAI_API_KEY:-}"
            test "${8}" = 'model_providers.cred_forward.auth.command="/src/cred-forward/dist/linux-amd64/cred-client"'
            test "${10}" = 'model_providers.cred_forward.auth.args=["openai"]'
        fi
        ;;
esac
printf 'wrapper-ok:%s\n' "$(basename "$0")"
EOF
    chmod +x "$test_root/real/$tool"
done
export CRED_FORWARD_SOCKET=$local_socket
export CRED_FORWARD_CLIENT=/src/cred-forward/dist/linux-amd64/cred-client
export PATH="$test_root/wrappers:$test_root/real:$PATH"
[ "$(gh test-argument)" = wrapper-ok:gh ]
[ "$(claude test-argument)" = wrapper-ok:claude ]
[ "$(codex test-argument)" = wrapper-ok:codex ]

mkdir -p "$test_root/symlink-bin"
for tool in gh claude codex; do
    ln -s "../wrappers/$tool" "$test_root/symlink-bin/$tool"
done
export PATH="$test_root/symlink-bin:$test_root/wrappers:$test_root/real:$PATH"
[ "$(gh test-argument)" = wrapper-ok:gh ]
[ "$(claude test-argument)" = wrapper-ok:claude ]
[ "$(codex test-argument)" = wrapper-ok:codex ]

kill "$agent_pid"
wait "$agent_pid" || true
export CRED_AGENT_ANTHROPIC_OAUTH=fake-anthropic-oauth-token
export CRED_AGENT_OPENAI_CHATGPT=fake-openai-chatgpt-token
export CRED_AGENT_OPENAI_ACCOUNT=fake-openai-account
./dist/linux-amd64/cred-agent -socket "$local_socket" 2>>"$test_root/agent.log" &
agent_pid=$!
for _ in $(seq 1 50); do
    [ -S "$local_socket" ] && break
    sleep 0.05
done
export EXPECT_LOGIN_KIND=oauth
[ "$(./dist/linux-amd64/cred-client -socket "$local_socket" anthropicoauth)" = fake-anthropic-oauth-token ]
[ "$(./dist/linux-amd64/cred-client -socket "$local_socket" openaichatgpt)" = fake-openai-chatgpt-token ]
[ "$(claude test-argument)" = wrapper-ok:claude ]
[ "$(codex test-argument)" = wrapper-ok:codex ]

kill "$agent_pid"
wait "$agent_pid" || true
unset CRED_AGENT_OPENAI_CHATGPT EXPECT_LOGIN_KIND
./dist/linux-amd64/cred-agent -socket "$local_socket" 2>>"$test_root/agent.log" &
agent_pid=$!
for _ in $(seq 1 50); do
    [ -S "$local_socket" ] && break
    sleep 0.05
done
[ "$(codex test-argument)" = wrapper-ok:codex ]

install -d -m 0700 /home/remote/.ssh /home/remote/.cache
ssh-keygen -q -t ed25519 -N '' -f "$test_root/id_ed25519"
install -m 0600 "$test_root/id_ed25519.pub" /home/remote/.ssh/authorized_keys
chown -R remote:remote /home/remote/.ssh /home/remote/.cache
ssh-keygen -A
mkdir -p /run/sshd
cat >"$test_root/sshd_config" <<EOF
Port 2222
ListenAddress 127.0.0.1
HostKey /etc/ssh/ssh_host_ed25519_key
PidFile $test_root/sshd.pid
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowUsers remote
AllowStreamLocalForwarding yes
StreamLocalBindMask 0177
StreamLocalBindUnlink yes
Subsystem sftp internal-sftp
EOF
/usr/sbin/sshd -D -e -f "$test_root/sshd_config" 2>"$test_root/sshd.log" &
sshd_pid=$!
sleep 0.2

install -m 0755 ./dist/linux-amd64/cred-client /tmp/cred-client

ssh_base_opts=(
    -F /dev/null -p 2222 -i "$test_root/id_ed25519"
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
)
ssh_forward_opts=(
    "${ssh_base_opts[@]}"
    -o ExitOnForwardFailure=yes -o StreamLocalBindMask=0177
    -o StreamLocalBindUnlink=yes
    -o "RemoteForward=/home/remote/.cache/cred.sock $local_socket"
)
ssh "${ssh_forward_opts[@]}" remote@127.0.0.1 \
    CRED_FORWARD_SOCKET=/home/remote/.cache/cred.sock /tmp/cred-client github \
    >"$test_root/forwarded-token"
[ "$(cat "$test_root/forwarded-token")" = fake-github-token ]

# The root test harness owns the output files around the sudo invocation.
# shellcheck disable=SC2024
if sudo -iu remote env CRED_FORWARD_SOCKET=/home/remote/.cache/cred.sock \
    /tmp/cred-client github \
    >"$test_root/post-session.out" 2>"$test_root/post-session.err"; then
    echo "cred-client unexpectedly worked through sudo after SSH forwarding ended" >&2
    exit 1
fi
grep -Fq 'forwarded credential socket is unavailable' "$test_root/post-session.err"

kill "$agent_pid" "$sshd_pid"
wait "$agent_pid" || true
wait "$sshd_pid" || true
echo "Docker credential-forwarding tests passed"
