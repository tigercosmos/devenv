#!/bin/bash
set -euo pipefail

go test ./...
make build
shellcheck -x wrappers/* install/*.sh service/cred-forward-link
(cd /src && shellcheck -x scripts/devenv scripts/devenv-doctor scripts/devenv-update scripts/devenv-sync-skills lib/doctor.sh)

test_root=$(mktemp -d)
trap 'jobs -pr | xargs -r kill; rm -rf "$test_root"' EXIT
trap 'echo "docker-test.sh: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

install_home=$test_root/install-home
mkdir -p "$install_home"
HOME=$install_home ./install/install-linux.sh all >"$test_root/install.log"
[ -x "$install_home/.local/bin/cred-agent" ]
[ -x "$install_home/.local/bin/cred-client" ]
[ -x "$install_home/.local/share/cred-forward/wrappers/gh" ]
[ -x "$install_home/.local/share/cred-forward/wrappers/git-credential-cred-forward" ]
[ "$(stat -c '%a' "$install_home/.cache")" = 700 ]
cmp config/github-accounts "$install_home/.config/cred-forward/github-accounts"
[ "$(stat -c '%a' "$install_home/.config/cred-forward/github-accounts")" = 600 ]
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

# The account map is user configuration: FORCE=1 must not replace an edited one.
mkdir -p "$preserve_home/.config/cred-forward"
printf '%s\n' 'my-org my-login' >"$preserve_home/.config/cred-forward/github-accounts"
FORCE=1 HOME=$preserve_home ./install/install-linux.sh client >"$test_root/force-config.log"
[ "$(cat "$preserve_home/.config/cred-forward/github-accounts")" = 'my-org my-login' ]

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
[ $# -eq 0 ] || printf ' %s' "$@"
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
# Every link host gets its own local socket so the agent knows who asks.
printf '%s\n' '# managed' 'sim0 /home/remote/.cache/cred.sock' 'sim4 /home/remote/.cache/cred.sock' \
    >"$launcher_home/.config/cred-forward/links"
HOME=$launcher_home ./service/cred-agent-launch >"$test_root/host-sockets.out"
[ "$(cat "$test_root/host-sockets.out")" = "$launcher_home/.cache/cred-agent.sock -host-socket sim0=$launcher_home/.cache/cred-agent-sim0.sock -host-socket sim4=$launcher_home/.cache/cred-agent-sim4.sock" ]
rm -f "$launcher_home/.config/cred-forward/links"
# The agent itself rejects a malformed host name.
if ./dist/linux-amd64/cred-agent -socket "$test_root/x.sock" -host-socket 'bad;host=/tmp/x' 2>"$test_root/bad-host.err"; then
    echo 'cred-agent unexpectedly accepted an invalid link host' >&2
    exit 1
fi
grep -Fq 'invalid host name' "$test_root/bad-host.err"
# The link service skips every host the off file lists, on several lines.
off_home=$test_root/off-home
mkdir -p "$off_home/.config/cred-forward" "$off_home/.local/share/cred-forward"
printf '%s\n' 'sim0 /home/remote/.cache/cred.sock' 'sim2 /home/remote/.cache/cred.sock' 'sim4 /home/remote/.cache/cred.sock' \
    >"$off_home/.config/cred-forward/links"
printf '%s\n' '# off' sim0 sim4 >"$off_home/.local/share/cred-forward/link-off"
[ "$(HOME=$off_home bash service/cred-forward-link active)" = sim2 ]
[ "$(HOME=$off_home bash service/cred-forward-link hosts | paste -sd ' ' -)" = 'sim0 sim2 sim4' ]
printf '%s\n' '*' >"$off_home/.local/share/cred-forward/link-off"
[ -z "$(HOME=$off_home bash service/cred-forward-link active)" ]

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
    *'show --property MainPID --value cred-forward-link.service')
        if [ -f "$HOME/cred-forward-link.pid" ]; then
            cat "$HOME/cred-forward-link.pid"
        else
            printf '%s\n' 0
        fi
        ;;
    *'is-active cred-forward-link.service')
        [ -f "$HOME/cred-forward-link.pid" ]
        ;;
    *'restart cred-forward-link.service')
        printf '%s\n' restart >>"$HOME/cred-forward-link-restarts"
        printf '%s\n' 4242 >"$HOME/cred-forward-link.pid"
        ;;
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
if [ "${3:-} ${4:-} ${5:-}" = '--hostname github.com --user' ]; then
    printf 'github-login-%s' "$6"
else
    printf github-login
fi
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
chmod 0644 "$server_home/.config/cred-forward/links"
HOME=$server_home PATH=$server_path DEVENV_HOME=/src CRED_FORWARD_ROLE=server \
    CRED_FORWARD_HOSTS=sim0 /src/cred-forward/install.sh >"$test_root/server-reinstall.log"
[ "$(cat "$server_home/cred-agent.pid")" = "$first_server_pid" ]
[ "$(wc -l <"$server_home/ssh-remote-probed")" = 1 ]
[ "$(cat "$server_home/.local/share/cred-forward/role")" = server ]
[ -S "$server_home/.cache/cred-agent.sock" ]
[ -S "$server_home/.cache/cred-agent-sim0.sock" ]
[ "$(stat -c '%a' "$server_home/.config/cred-forward/gh-account")" = 600 ]
[ -z "$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$server_home/.config/cred-forward/gh-account")" ]
# The forward lives in the links file that the link service reads, never in
# an SSH config entry, so ordinary logins cannot bind the remote socket.
[ -L "$server_home/.ssh/config" ]
grep -Fqx 'Host existing-host' "$server_home/.ssh/config"
[ ! -e "$server_home/.ssh/config.d/cred-forward.conf" ]
grep -Fxq 'sim0 /home/remote/.cache/cred.sock' "$server_home/.config/cred-forward/links"
[ "$(stat -c '%a' "$server_home/.config/cred-forward/links")" = 600 ]
[ -x "$server_home/.local/bin/cred-forward-link" ]
[ -f "$server_home/.config/systemd/user/cred-forward-link.service" ]
# The link service starts once and is left alone by an unchanged reinstall.
[ "$(wc -l <"$server_home/cred-forward-link-restarts")" = 1 ]
[ "$(HOME=$server_home "$server_home/.local/bin/cred-forward-link" hosts)" = sim0 ]
[ "$(HOME=$server_home "$server_home/.local/bin/cred-forward-link" active)" = sim0 ]

# devenv server on|off stops and starts the link service and survives a
# reinstall; devenv server gh use pins the login without an agent restart.
devenv_server() {
    HOME=$server_home PATH=$server_path DEVENV_HOME=/src /src/scripts/devenv "$@"
}
devenv_server status >"$test_root/server-status.log" 2>&1
grep -Fq 'sim0: on' "$test_root/server-status.log"
devenv_server server off >"$test_root/server-off.log" 2>&1
[ "$(cat "$server_home/.local/share/cred-forward/link-off")" = '*' ]
# Off is a restart: the supervisor reads the off file and exits cleanly.
[ "$(wc -l <"$server_home/cred-forward-link-restarts")" = 2 ]
[ -z "$(HOME=$server_home "$server_home/.local/bin/cred-forward-link" active)" ]
HOME=$server_home "$server_home/.local/bin/cred-forward-link" run >"$test_root/link-off-run.out" 2>"$test_root/link-off-run.err"
grep -Fq 'switched off' "$test_root/link-off-run.err"
HOME=$server_home PATH=$server_path DEVENV_HOME=/src CRED_FORWARD_ROLE=server \
    CRED_FORWARD_HOSTS=sim0 /src/cred-forward/install.sh >"$test_root/server-reinstall-off.log" 2>&1
grep -Fq 'switched off' "$test_root/server-reinstall-off.log"
# The stub never exits, so it looks alive and the installer restarts it once
# more to make it re-read the off list.
[ "$(wc -l <"$server_home/cred-forward-link-restarts")" = 3 ]
devenv_server status >"$test_root/server-status-off.log" 2>&1
grep -Fq 'credential links: off' "$test_root/server-status-off.log"
devenv_server server on >"$test_root/server-on.log" 2>&1
[ ! -e "$server_home/.local/share/cred-forward/link-off" ]
[ "$(wc -l <"$server_home/cred-forward-link-restarts")" = 4 ]
# Switching off the only host is the same as switching everything off.
devenv_server server off sim0 >"$test_root/server-off-host.log" 2>&1
[ "$(cat "$server_home/.local/share/cred-forward/link-off")" = '*' ]
devenv_server server on sim0 >"$test_root/server-on-host.log" 2>&1
[ ! -e "$server_home/.local/share/cred-forward/link-off" ]
[ "$(wc -l <"$server_home/cred-forward-link-restarts")" = 6 ]
if devenv_server server off nosuch >/dev/null 2>"$test_root/server-off-unknown.err"; then
    echo 'devenv server off unexpectedly accepted an unknown host' >&2
    exit 1
fi
grep -Fq 'unknown host: nosuch' "$test_root/server-off-unknown.err"
if devenv_server client off >/dev/null 2>"$test_root/server-client.err"; then
    echo 'devenv client unexpectedly ran on a server' >&2
    exit 1
fi
grep -Fq 'this machine is a cred-forward server' "$test_root/server-client.err"
server_client() {
    CRED_FORWARD_SOCKET=$1 /src/cred-forward/dist/linux-amd64/cred-client github "${@:2}"
}
devenv_server server gh use anchi-t2 >"$test_root/gh-use.log" 2>&1
grep -Fxq '* anchi-t2' "$server_home/.config/cred-forward/gh-account"
[ "$(server_client "$server_home/.cache/cred-agent-sim0.sock" tigercosmos)" = github-login-anchi-t2 ]
[ "$(server_client "$server_home/.cache/cred-agent.sock")" = github-login-anchi-t2 ]
devenv_server server gh use tigercosmos --host sim0 >"$test_root/gh-use-host.log" 2>&1
grep -Fxq 'sim0 tigercosmos' "$server_home/.config/cred-forward/gh-account"
grep -Fxq '* anchi-t2' "$server_home/.config/cred-forward/gh-account"
[ "$(server_client "$server_home/.cache/cred-agent-sim0.sock" anchi-t2)" = github-login-tigercosmos ]
[ "$(server_client "$server_home/.cache/cred-agent.sock" tigercosmos)" = github-login-anchi-t2 ]
devenv_server server gh status >"$test_root/gh-status.log" 2>&1
grep -Fq 'sim0 -> tigercosmos' "$test_root/gh-status.log"
grep -Fq 'every host -> anchi-t2' "$test_root/gh-status.log"
devenv_server server gh use auto --host sim0 >/dev/null 2>&1
devenv_server server gh use auto >/dev/null 2>&1
[ -z "$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$server_home/.config/cred-forward/gh-account")" ]
grep -Fq 'Managed by devenv cred-forward' "$server_home/.config/cred-forward/gh-account"
[ "$(server_client "$server_home/.cache/cred-agent-sim0.sock" anchi-t2)" = github-login-anchi-t2 ]
# The refresh commands are interactive; without a terminal they change nothing.
devenv_server server claude status >"$test_root/claude-status.log" 2>&1
grep -Fq 'remotes receive the setup token stored' "$test_root/claude-status.log"
devenv_server server codex status >"$test_root/codex-status.log" 2>&1
grep -Fq 'remotes receive the ChatGPT login' "$test_root/codex-status.log"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$server_home/.local/bin/claude"
chmod 0755 "$server_home/.local/bin/claude"
if devenv_server server claude refresh </dev/null >/dev/null 2>"$test_root/claude-refresh.err"; then
    echo 'devenv server claude refresh unexpectedly ran without a terminal' >&2
    exit 1
fi
grep -Fq 'needs a terminal' "$test_root/claude-refresh.err"
[ "$(cat "$server_home/.local/share/cred-forward/secrets/claude-oauth")" = claude-login ]
if devenv_server server gh use 'bad;login' >/dev/null 2>&1; then
    echo 'devenv server gh use unexpectedly accepted a malformed login' >&2
    exit 1
fi
if devenv_server server gh use anchi-t2 --host nosuch >/dev/null 2>&1; then
    echo 'devenv server gh use unexpectedly accepted an unknown host' >&2
    exit 1
fi
HOME=$server_home CRED_FORWARD_SOCKET="$server_home/.cache/cred-agent.sock" \
    /src/cred-forward/dist/linux-amd64/cred-client github >"$test_root/server-github"
[ "$(cat "$test_root/server-github")" = github-login ]
CRED_FORWARD_SOCKET=$server_home/.cache/cred-agent.sock \
    /src/cred-forward/dist/linux-amd64/cred-client github anchi-t2 >"$test_root/server-github-account"
[ "$(cat "$test_root/server-github-account")" = github-login-anchi-t2 ]
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

# Exercise the remote preparation script instead of short-circuiting it in
# the SSH stub: it creates the socket directory and removes a leftover file.
cleanup_local_home=$test_root/cleanup-local-home
cleanup_remote_home=$test_root/cleanup-remote-home
cleanup_bin=$test_root/cleanup-bin
mkdir -p "$cleanup_local_home" "$cleanup_remote_home" "$cleanup_bin"
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
chmod 0755 "$cleanup_bin/ssh"
HOME=$cleanup_local_home PATH="$cleanup_bin:/usr/local/go/bin:/usr/bin:/bin" \
    CRED_FORWARD_TEST_REMOTE_HOME=$cleanup_remote_home \
    bash service/cred-forward-link prepare sim0 >"$test_root/cleanup-remote-home.out"
[ "$(cat "$test_root/cleanup-remote-home.out")" = "$cleanup_remote_home" ]
[ "$(stat -c '%a' "$cleanup_remote_home/.cache")" = 700 ]
: >"$cleanup_remote_home/.cache/cred.sock"
HOME=$cleanup_local_home PATH="$cleanup_bin:/usr/local/go/bin:/usr/bin:/bin" \
    CRED_FORWARD_TEST_REMOTE_HOME=$cleanup_remote_home \
    bash service/cred-forward-link prepare sim0 >/dev/null
[ ! -e "$cleanup_remote_home/.cache/cred.sock" ]

client_home=$test_root/client-home
mkdir -p "$client_home"
cat >"$client_home/.bashrc" <<'EOF'
# Common toolchains prepend their own directory after the devenv block.
export PATH="/opt/late-toolchain:$PATH"
EOF
cat >"$client_home/.profile" <<'EOF'
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
# A stock Ubuntu profile prepends this directory after it sources .bashrc.
export PATH="$HOME/.local/bin:$PATH"
EOF
client_path="/usr/local/go/bin:/usr/bin:/bin"
printf '%s\n' '[credential "https://github.com"]' '	helper = ' '	helper = !/usr/bin/gh auth git-credential' \
    >"$client_home/.gitconfig"
HOME=$client_home PATH=$client_path SHELL=/bin/bash DEVENV_HOME=/src \
    /src/shell/install.sh >"$test_root/client-shell-install.log"
HOME=$client_home PATH=$client_path SHELL=/bin/bash DEVENV_HOME=/src \
    /src/shell/install.sh >"$test_root/client-shell-reinstall.log"
HOME=$client_home PATH=$client_path SHELL=/bin/bash DEVENV_HOME=/src \
    CRED_FORWARD_ROLE=client /src/cred-forward/install.sh \
    >"$test_root/client-install.log" 2>&1
HOME=$client_home PATH=$client_path SHELL=/bin/bash DEVENV_HOME=/src \
    /src/cred-forward/install.sh >"$test_root/client-reinstall.log" 2>&1
[ "$(cat "$client_home/.local/share/cred-forward/role")" = client ]
devenv_client() {
    HOME=$client_home PATH=$client_path DEVENV_HOME=/src /src/scripts/devenv "$@"
}
devenv_client client off gh >"$test_root/client-off-gh.log" 2>&1
[ "$(cat "$client_home/.local/share/cred-forward/disabled")" = gh ]
[ "$(stat -c '%a' "$client_home/.local/share/cred-forward/disabled")" = 600 ]
devenv_client client off >"$test_root/client-off.log" 2>&1
[ "$(paste -sd ' ' "$client_home/.local/share/cred-forward/disabled")" = 'gh claude codex' ]
devenv_client client on claude >"$test_root/client-on-claude.log" 2>&1
[ "$(paste -sd ' ' "$client_home/.local/share/cred-forward/disabled")" = 'gh codex' ]
devenv_client status >"$test_root/client-status.log" 2>&1
grep -Fq 'claude: forwarded login' "$test_root/client-status.log"
grep -Fq 'gh: local login' "$test_root/client-status.log"
grep -Fq 'git (HTTPS): local gh login' "$test_root/client-status.log"
devenv_client client on >"$test_root/client-on.log" 2>&1
[ ! -e "$client_home/.local/share/cred-forward/disabled" ]
[ "$(devenv_client client off --once -- sh -c 'printf %s "$CRED_FORWARD_DISABLED"')" = 'gh claude codex' ]
[ "$(devenv_client client off gh --once -- sh -c 'printf %s "$CRED_FORWARD_DISABLED"')" = gh ]
[ ! -e "$client_home/.local/share/cred-forward/disabled" ]
if devenv_client client off gh -- true >/dev/null 2>&1; then
    echo 'devenv client off unexpectedly accepted a command without --once' >&2
    exit 1
fi
if devenv_client client off vim >/dev/null 2>&1; then
    echo 'devenv client off unexpectedly accepted an unknown tool' >&2
    exit 1
fi
if devenv_client server off >/dev/null 2>"$test_root/client-server.err"; then
    echo 'devenv server unexpectedly ran on a client' >&2
    exit 1
fi
grep -Fq 'this machine is a cred-forward client' "$test_root/client-server.err"
# The client install routes HTTPS git credentials through the helper, once,
# after any helper that gh auth setup-git configured earlier.
[ "$(HOME=$client_home git config --global --get-all include.path | grep -Fxc '~/.config/cred-forward/gitconfig')" = 1 ]
[ "$(HOME=$client_home git config --global --includes --get-all credential.https://github.com.helper | sed -n '$p')" \
    = "!$client_home/.local/share/cred-forward/wrappers/git-credential-cred-forward" ]
[ "$(HOME=$client_home git config --global --includes --get credential.https://github.com.useHttpPath)" = true ]
grep -Fq '!/usr/bin/gh auth git-credential' "$client_home/.gitconfig"
[ -f "$client_home/.local/share/cred-forward/.devenv-backup/"*/gitconfig ]
grep -Fq 'sudo /src/cred-forward/install/configure-sshd.sh' "$test_root/client-install.log"
[ ! -e /etc/ssh/sshd_config.d/10-cred-forward.conf ]
[ ! -e /etc/cred-forward/sshd-policy ]
[ "$(grep -Fxc '# >>> devenv >>>' "$client_home/.bashrc")" = 1 ]
[ "$(grep -Fxc '# >>> devenv >>>' "$client_home/.profile")" = 1 ]
HOME=$client_home bash --noprofile --norc -i -c \
    'source "$HOME/.bashrc"; [ "$(type -P codex)" = "$HOME/.local/share/cred-forward/wrappers/codex" ]'
HOME=$client_home bash --noprofile --norc -i -c '
    source "$HOME/.profile"
    [ "$(type -P gh)" = "$HOME/.local/share/cred-forward/wrappers/gh" ]
    [ "$(type -P claude)" = "$HOME/.local/share/cred-forward/wrappers/claude" ]
    [ "$(type -P codex)" = "$HOME/.local/share/cred-forward/wrappers/codex" ]
'
HOME=$client_home bash --noprofile --norc -c '
    PATH="$HOME/.local/bin:$HOME/.local/share/cred-forward/wrappers:/usr/bin:$HOME/.local/bin"
    source "$HOME/.bashrc"
    [ "$(type -P gh)" = "$HOME/.local/share/cred-forward/wrappers/gh" ]
    [ "$(type -P claude)" = "$HOME/.local/share/cred-forward/wrappers/claude" ]
    [ "$(type -P codex)" = "$HOME/.local/share/cred-forward/wrappers/codex" ]
    [ "$(printf "%s" "$PATH" | tr : "\n" | grep -Fxc "$HOME/.local/bin")" = 1 ]
'

# Reject a login profile that reorders PATH after it sources .bashrc, even
# when the interactive profile itself resolves all wrappers correctly.
mkdir -p "$client_home/.local/bin"
for tool in gh claude codex; do
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$client_home/.local/bin/$tool"
    chmod 0755 "$client_home/.local/bin/$tool"
done
cp -p "$client_home/.profile" "$test_root/client-profile.good"
awk '
    $0 == "# >>> devenv >>>" { skip=1 }
    !skip { print }
    $0 == "# <<< devenv <<<" { skip=0 }
' "$client_home/.profile" >"$test_root/client-profile.bad"
cp "$test_root/client-profile.bad" "$client_home/.profile"
if HOME=$client_home PATH=$client_path SHELL=/bin/bash DEVENV_HOME=/src \
    CRED_FORWARD_ROLE=client /src/cred-forward/install.sh \
    >"$test_root/client-bad-profile.out" 2>"$test_root/client-bad-profile.err"; then
    echo 'client setup unexpectedly accepted a reordered login PATH' >&2
    exit 1
fi
grep -Fq "does not resolve to the credential wrapper in $client_home/.profile" \
    "$test_root/client-bad-profile.err"
cp -p "$test_root/client-profile.good" "$client_home/.profile"

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
grep -Fq '<key>CRED_AGENT_AUDIT_LOG</key>' \
    "$mac_home/Library/LaunchAgents/com.tigercosmos.cred-agent.plist"
grep -Fq '<key>StandardOutPath</key><string>/dev/null</string>' \
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
export CRED_AGENT_GITHUB_TOKEN_ANCHI_T2=fake-work-token
export CRED_AGENT_GITHUB_TOKEN_TIGERCOSMOS=fake-personal-token
export CRED_AGENT_ANTHROPIC=fake-anthropic-token
export CRED_AGENT_OPENAI=fake-openai-token
local_socket=$test_root/cred-agent.sock
host_socket=$test_root/cred-agent-sim4.sock
gh_pin=$test_root/gh-account
./dist/linux-amd64/cred-agent -socket "$local_socket" -host-socket "sim4=$host_socket" \
    -github-pin "$gh_pin" >"$test_root/agent.log" 2>&1 &
agent_pid=$!
for _ in $(seq 1 50); do
    [ -S "$local_socket" ] && [ -S "$host_socket" ] && break
    sleep 0.05
done
[ "$(stat -c '%a' "$local_socket")" = 600 ]
[ "$(stat -c '%a' "$host_socket")" = 600 ]
[ "$(CRED_FORWARD_SOCKET=$local_socket ./dist/linux-amd64/cred-client github)" = fake-github-token ]
# A per-host pin overrides the requested account on that host's socket only;
# the "*" pin covers the rest. The agent reads the file on every request.
[ "$(CRED_FORWARD_SOCKET=$host_socket ./dist/linux-amd64/cred-client github anchi-t2)" = fake-work-token ]
printf '%s\n' 'sim4 tigercosmos' >"$gh_pin"
[ "$(CRED_FORWARD_SOCKET=$host_socket ./dist/linux-amd64/cred-client github anchi-t2)" = fake-personal-token ]
[ "$(CRED_FORWARD_SOCKET=$host_socket ./dist/linux-amd64/cred-client github)" = fake-personal-token ]
[ "$(CRED_FORWARD_SOCKET=$local_socket ./dist/linux-amd64/cred-client github anchi-t2)" = fake-work-token ]
printf '%s\n' '* anchi-t2' 'sim4 tigercosmos' >"$gh_pin"
[ "$(CRED_FORWARD_SOCKET=$local_socket ./dist/linux-amd64/cred-client github tigercosmos)" = fake-work-token ]
[ "$(CRED_FORWARD_SOCKET=$host_socket ./dist/linux-amd64/cred-client github)" = fake-personal-token ]
printf '%s\n' '* not-a-login!' >"$gh_pin"
if CRED_FORWARD_SOCKET=$host_socket ./dist/linux-amd64/cred-client github >/dev/null 2>&1; then
    echo 'agent unexpectedly served a credential with a malformed pin file' >&2
    exit 1
fi
rm -f "$gh_pin"
[ "$(CRED_FORWARD_SOCKET=$host_socket ./dist/linux-amd64/cred-client github anchi-t2)" = fake-work-token ]
grep -Fq 'host=sim4 service=github account=anchi-t2 pinned=tigercosmos status=ok' "$test_root/agent.log"
grep -Fq 'host=- service=github account=- pinned=- status=ok' "$test_root/agent.log"
# An unreachable agent is exit 3; an agent that refuses is exit 1.
if CRED_FORWARD_SOCKET=$test_root/nowhere.sock ./dist/linux-amd64/cred-client github 2>/dev/null; then
    echo 'cred-client unexpectedly succeeded without a socket' >&2
    exit 1
fi
CRED_FORWARD_SOCKET=$test_root/nowhere.sock ./dist/linux-amd64/cred-client github 2>/dev/null || [ $? = 3 ]
CRED_FORWARD_SOCKET=$local_socket ./dist/linux-amd64/cred-client github nobody 2>/dev/null || [ $? = 1 ]

mkdir -p "$test_root/real" "$test_root/wrappers"
cp wrappers/* "$test_root/wrappers/"
chmod +x "$test_root/wrappers/gh" "$test_root/wrappers/claude" "$test_root/wrappers/codex" \
    "$test_root/wrappers/git-credential-cred-forward"
for tool in gh claude codex; do
    cat >"$test_root/real/$tool" <<'EOF'
#!/bin/sh
set -eu

# The local gh login that the git helper asks for when forwarding is off.
if [ "${1:-}" = auth ] && [ "${2:-}" = token ]; then
    [ "${6:-}" != nobody ] || exit 1
    printf 'local-token-%s' "${6:-default}"
    exit 0
fi
# EXPECT_LOCAL=1: the wrapper must run the real tool untouched.
if [ "${EXPECT_LOCAL:-0}" = 1 ]; then
    test -z "${GH_TOKEN:-}"
    test -z "${CLAUDE_CODE_OAUTH_TOKEN:-}"
    test "$*" = test-argument
    printf 'local-ok:%s\n' "$(basename "$0")"
    exit 0
fi
case "$(basename "$0")" in
    gh) test "$GH_TOKEN" = "${EXPECT_GH_TOKEN:-fake-github-token}" ;;
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

# `devenv client off` lists tools in the disabled file; `--once` uses the
# environment. A listed tool runs untouched, the others stay forwarded.
[ "$(CRED_FORWARD_DISABLED=gh EXPECT_LOCAL=1 gh test-argument)" = local-ok:gh ]
[ "$(CRED_FORWARD_DISABLED=gh claude test-argument)" = wrapper-ok:claude ]
[ "$(CRED_FORWARD_DISABLED=all EXPECT_LOCAL=1 claude test-argument)" = local-ok:claude ]
[ "$(CRED_FORWARD_DISABLED='gh codex' EXPECT_LOCAL=1 codex test-argument)" = local-ok:codex ]
export CRED_FORWARD_STATE_DIR=$test_root/client-state
mkdir -p "$CRED_FORWARD_STATE_DIR"
printf '%s\n' '# comment' claude >"$CRED_FORWARD_STATE_DIR/disabled"
[ "$(EXPECT_LOCAL=1 claude test-argument)" = local-ok:claude ]
[ "$(gh test-argument)" = wrapper-ok:gh ]
[ "$(codex test-argument)" = wrapper-ok:codex ]
rm -f "$CRED_FORWARD_STATE_DIR/disabled"
[ "$(claude test-argument)" = wrapper-ok:claude ]

# An unreachable agent never falls back on its own: without a terminal the
# wrapper fails with exit 3 unless CRED_FORWARD_FALLBACK=1 says otherwise.
for tool in gh claude codex; do
    if CRED_FORWARD_SOCKET=$test_root/nowhere.sock "$tool" test-argument </dev/null \
        >"$test_root/unreachable-$tool.out" 2>"$test_root/unreachable-$tool.err"; then
        echo "$tool wrapper unexpectedly succeeded without an agent" >&2
        exit 1
    fi
    CRED_FORWARD_SOCKET=$test_root/nowhere.sock "$tool" test-argument </dev/null >/dev/null 2>&1 || [ $? = 3 ]
    grep -Fq 'no terminal is attached' "$test_root/unreachable-$tool.err"
    grep -Fq "devenv client off $tool" "$test_root/unreachable-$tool.err"
    [ "$(CRED_FORWARD_SOCKET=$test_root/nowhere.sock CRED_FORWARD_FALLBACK=1 EXPECT_LOCAL=1 "$tool" test-argument </dev/null)" = "local-ok:$tool" ]
    if CRED_FORWARD_SOCKET=$test_root/nowhere.sock CRED_FORWARD_FALLBACK=0 EXPECT_LOCAL=1 "$tool" test-argument </dev/null >/dev/null 2>&1; then
        echo "$tool wrapper fell back although CRED_FORWARD_FALLBACK=0" >&2
        exit 1
    fi
done
# An agent that answers with an error is not "unreachable": no fallback.
if CRED_FORWARD_FALLBACK=1 CRED_FORWARD_GITHUB_ACCOUNT=nobody EXPECT_LOCAL=1 gh test-argument </dev/null >/dev/null 2>&1; then
    echo 'gh wrapper fell back after the agent refused the account' >&2
    exit 1
fi

# The gh wrapper selects the login from the repository owner. Without an
# account map it keeps using the active login.
[ "$(CRED_FORWARD_GITHUB_ACCOUNTS=$test_root/missing-map gh pr list -R t2-auto/proj)" = wrapper-ok:gh ]
export CRED_FORWARD_GITHUB_ACCOUNTS=$test_root/github-accounts
cp config/github-accounts "$CRED_FORWARD_GITHUB_ACCOUNTS"
[ "$(EXPECT_GH_TOKEN=fake-work-token gh pr list -R t2-auto/proj)" = wrapper-ok:gh ]
[ "$(EXPECT_GH_TOKEN=fake-work-token gh pr list --repo=https://github.com/T2-Auto/proj)" = wrapper-ok:gh ]
[ "$(EXPECT_GH_TOKEN=fake-work-token GH_REPO=t2-auto/proj gh pr list)" = wrapper-ok:gh ]
[ "$(EXPECT_GH_TOKEN=fake-work-token gh pr list -R=t2-auto/proj)" = wrapper-ok:gh ]
[ "$(EXPECT_GH_TOKEN=fake-work-token gh pr list -Rt2-auto/proj)" = wrapper-ok:gh ]
[ "$(EXPECT_GH_TOKEN=fake-work-token gh repo clone t2-auto/proj)" = wrapper-ok:gh ]
[ "$(EXPECT_GH_TOKEN=fake-work-token gh repo clone -- t2-auto/proj)" = wrapper-ok:gh ]
[ "$(EXPECT_GH_TOKEN=fake-work-token gh repo view --web t2-auto/proj)" = wrapper-ok:gh ]
# Values of options the wrapper does not know are never taken for the repo.
[ "$(EXPECT_GH_TOKEN=fake-work-token gh repo view --branch main t2-auto/proj)" = wrapper-ok:gh ]
[ "$(EXPECT_GH_TOKEN=fake-work-token gh repo clone --upstream-remote-name upstream t2-auto/proj ./proj)" = wrapper-ok:gh ]
[ "$(EXPECT_GH_TOKEN=fake-personal-token gh repo view cli/cli)" = wrapper-ok:gh ]
[ "$(EXPECT_GH_TOKEN=fake-personal-token gh issue create docs/readme)" = wrapper-ok:gh ]
[ "$(EXPECT_GH_TOKEN=fake-personal-token gh test-argument)" = wrapper-ok:gh ]
git init -q "$test_root/work-repo"
git -C "$test_root/work-repo" remote add origin git@github.com:t2-auto/proj.git
[ "$(cd "$test_root/work-repo" && EXPECT_GH_TOKEN=fake-work-token gh pr list)" = wrapper-ok:gh ]
[ "$(cd "$test_root/work-repo" && EXPECT_GH_TOKEN=fake-personal-token gh pr list -R tigercosmos/devenv)" = wrapper-ok:gh ]
# Option values and non-repo operands never override the checkout's owner,
# but an explicit repository operand does.
[ "$(cd "$test_root/work-repo" && EXPECT_GH_TOKEN=fake-work-token gh pr create --title demo --body tigercosmos/devenv)" = wrapper-ok:gh ]
[ "$(cd "$test_root/work-repo" && EXPECT_GH_TOKEN=fake-work-token gh issue create tigercosmos/devenv)" = wrapper-ok:gh ]
[ "$(cd "$test_root/work-repo" && EXPECT_GH_TOKEN=fake-personal-token gh repo view cli/cli)" = wrapper-ok:gh ]
[ "$(cd "$test_root/work-repo" && EXPECT_GH_TOKEN=fake-personal-token gh repo view -- cli/cli)" = wrapper-ok:gh ]
# A non-GitHub upstream does not hide a GitHub origin.
git -C "$test_root/work-repo" remote add upstream https://gitlab.com/mirror/proj.git
[ "$(cd "$test_root/work-repo" && EXPECT_GH_TOKEN=fake-work-token gh pr list)" = wrapper-ok:gh ]
git init -q "$test_root/personal-repo"
git -C "$test_root/personal-repo" remote add origin https://github.com/tigercosmos/devenv.git
[ "$(cd "$test_root/personal-repo" && EXPECT_GH_TOKEN=fake-personal-token gh pr list)" = wrapper-ok:gh ]
# CRLF maps and comments parse; a malformed account fails closed.
printf '# comment\r\n\r\nT2-AUTO anchi-t2\r\n* tigercosmos\r\n' >"$test_root/crlf-map"
[ "$(CRED_FORWARD_GITHUB_ACCOUNTS=$test_root/crlf-map EXPECT_GH_TOKEN=fake-work-token gh pr list -R t2-auto/proj)" = wrapper-ok:gh ]
printf '%s\n' '* bad;login' >"$test_root/bad-map"
if CRED_FORWARD_GITHUB_ACCOUNTS=$test_root/bad-map gh test-argument 2>/dev/null; then
    echo "gh wrapper unexpectedly accepted a malformed account map" >&2
    exit 1
fi
if CRED_FORWARD_GITHUB_ACCOUNT=nobody gh test-argument 2>/dev/null; then
    echo "gh wrapper unexpectedly succeeded for an unconfigured account" >&2
    exit 1
fi
# The git credential helper answers from the same map and never stores.
helper=$test_root/wrappers/git-credential-cred-forward
credential_fill() {
    printf 'protocol=%s\nhost=%s\n%s\n' "$1" "$2" "${3:+path=$3}" | "$helper" get
}
[ "$(credential_fill https github.com t2-auto/proj.git)" = "$(printf 'username=anchi-t2\npassword=fake-work-token')" ]
[ "$(credential_fill https github.com cli/cli)" = "$(printf 'username=tigercosmos\npassword=fake-personal-token')" ]
[ "$(credential_fill https github.com '')" = "$(printf 'username=tigercosmos\npassword=fake-personal-token')" ]
[ "$(cd "$test_root/work-repo" && credential_fill https github.com '')" = "$(printf 'username=anchi-t2\npassword=fake-work-token')" ]
[ -z "$(credential_fill https gitlab.com t2-auto/proj.git)" ]
[ -z "$(credential_fill http github.com t2-auto/proj.git)" ]
# With forwarding off for gh, the helper asks the remote's own gh for the
# mapped account and refuses when that login is missing.
[ "$(CRED_FORWARD_DISABLED=gh credential_fill https github.com t2-auto/proj.git)" = "$(printf 'username=anchi-t2\npassword=local-token-anchi-t2')" ]
[ "$(CRED_FORWARD_DISABLED=all credential_fill https github.com cli/cli)" = "$(printf 'username=tigercosmos\npassword=local-token-tigercosmos')" ]
[ "$(CRED_FORWARD_DISABLED=claude credential_fill https github.com cli/cli)" = "$(printf 'username=tigercosmos\npassword=fake-personal-token')" ]
if CRED_FORWARD_DISABLED=gh CRED_FORWARD_GITHUB_ACCOUNT=nobody credential_fill https github.com cli/cli \
    >/dev/null 2>"$test_root/helper-local-missing.err"; then
    echo 'git credential helper unexpectedly answered without a local login' >&2
    exit 1
fi
grep -Fq 'no login for nobody' "$test_root/helper-local-missing.err"
[ "$(CRED_FORWARD_DISABLED=gh CRED_FORWARD_GITHUB_ACCOUNTS=$test_root/missing-map credential_fill https github.com cli/cli)" \
    = "$(printf 'username=x-access-token\npassword=local-token-default')" ]
if CRED_FORWARD_SOCKET=$test_root/nowhere.sock credential_fill https github.com cli/cli \
    >/dev/null 2>"$test_root/helper-unreachable.err"; then
    echo 'git credential helper unexpectedly answered without an agent' >&2
    exit 1
fi
grep -Fq 'devenv client off gh' "$test_root/helper-unreachable.err"
[ "$(CRED_FORWARD_SOCKET=$test_root/nowhere.sock CRED_FORWARD_FALLBACK=1 credential_fill https github.com t2-auto/proj.git)" = "$(printf 'username=anchi-t2\npassword=local-token-anchi-t2')" ]
[ -z "$(printf 'protocol=https\nhost=github.com\nusername=x\npassword=y\n\n' | "$helper" store)" ]
[ -z "$(printf 'protocol=https\nhost=github.com\n\n' | "$helper" erase)" ]
[ "$(CRED_FORWARD_GITHUB_ACCOUNTS=$test_root/missing-map credential_fill https github.com t2-auto/proj.git)" \
    = "$(printf 'username=x-access-token\npassword=fake-github-token')" ]
if CRED_FORWARD_GITHUB_ACCOUNTS=$test_root/bad-map credential_fill https github.com t2-auto/proj.git >/dev/null 2>&1; then
    echo "git credential helper unexpectedly accepted a malformed account map" >&2
    exit 1
fi
# git itself reaches the helper through the managed include.
git_home=$test_root/git-home
mkdir -p "$git_home/.config/cred-forward"
cp config/github-accounts "$git_home/.config/cred-forward/github-accounts"
printf '%s\n' '# managed' '[credential "https://github.com"]' '	helper =' "	helper = !$helper" '	useHttpPath = true' \
    >"$git_home/.config/cred-forward/gitconfig"
printf '%s\n' '[include]' '	path = ~/.config/cred-forward/gitconfig' >"$git_home/.gitconfig"
[ "$(printf 'url=https://github.com/t2-auto/proj.git\n\n' | HOME=$git_home git credential fill | grep '^password=')" = password=fake-work-token ]
[ "$(printf 'url=https://github.com/tigercosmos/devenv.git\n\n' | HOME=$git_home git credential fill | grep '^password=')" = password=fake-personal-token ]
unset CRED_FORWARD_GITHUB_ACCOUNTS

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
# The root test harness owns the output files around the sudo invocation.
# shellcheck disable=SC2024
if sudo -u remote env HOME=/home/remote /src/cred-forward/install/configure-sshd.sh \
    >"$test_root/admin-nonroot.out" 2>"$test_root/admin-nonroot.err"; then
    echo 'SSH daemon setup unexpectedly ran without root' >&2
    exit 1
fi
grep -Fq 'run this script with sudo' "$test_root/admin-nonroot.err"
install -d -m 0755 /etc/ssh/sshd_config.d

# A failed effective-policy check restores the exact previous file, including
# its mode, and must not publish a validated-policy marker.
cp -p /etc/ssh/sshd_config "$test_root/sshd_config.original"
sed '\|^[[:space:]]*Include[[:space:]]\+/etc/ssh/sshd_config.d/\*\.conf|d' \
    /etc/ssh/sshd_config >"$test_root/sshd_config.no-include"
install -m 0644 "$test_root/sshd_config.no-include" /etc/ssh/sshd_config
cat >/etc/ssh/sshd_config.d/10-cred-forward.conf <<'EOF'
# Managed by devenv cred-forward.
StreamLocalBindMask 0077
StreamLocalBindUnlink no
EOF
chmod 0600 /etc/ssh/sshd_config.d/10-cred-forward.conf
if /src/cred-forward/install/configure-sshd.sh \
    >"$test_root/admin-rollback.out" 2>"$test_root/admin-rollback.err"; then
    echo 'SSH daemon setup unexpectedly accepted an unloaded drop-in' >&2
    exit 1
fi
grep -Fq 'Include /etc/ssh/sshd_config.d/*.conf' "$test_root/admin-rollback.err"
grep -Eq '^StreamLocalBindMask[[:space:]]+0077$' \
    /etc/ssh/sshd_config.d/10-cred-forward.conf
[ "$(stat -c '%a' /etc/ssh/sshd_config.d/10-cred-forward.conf)" = 600 ]
[ ! -e /etc/cred-forward/sshd-policy ]
cp -p "$test_root/sshd_config.original" /etc/ssh/sshd_config
rm -f /etc/ssh/sshd_config.d/10-cred-forward.conf

printf '%s\n' '# administrator-owned file' \
    >/etc/ssh/sshd_config.d/10-cred-forward.conf
chmod 0644 /etc/ssh/sshd_config.d/10-cred-forward.conf
if /src/cred-forward/install/configure-sshd.sh \
    >"$test_root/admin-preserve.out" 2>"$test_root/admin-preserve.err"; then
    echo 'SSH daemon setup unexpectedly replaced an unrelated drop-in' >&2
    exit 1
fi
grep -Fq 'preserving existing' "$test_root/admin-preserve.err"
grep -Fqx '# administrator-owned file' \
    /etc/ssh/sshd_config.d/10-cred-forward.conf
rm -f /etc/ssh/sshd_config.d/10-cred-forward.conf
/src/cred-forward/install/configure-sshd.sh \
    >"$test_root/admin-install.log" 2>&1
grep -Eq '^StreamLocalBindMask[[:space:]]+0177$' \
    /etc/ssh/sshd_config.d/10-cred-forward.conf
grep -Eq '^StreamLocalBindUnlink[[:space:]]+yes$' \
    /etc/ssh/sshd_config.d/10-cred-forward.conf
grep -Eq '^StreamLocalBindMask[[:space:]]+0177$' \
    /etc/cred-forward/sshd-policy
grep -Eq '^StreamLocalBindUnlink[[:space:]]+yes$' \
    /etc/cred-forward/sshd-policy
[ "$(stat -c '%a' /etc/cred-forward/sshd-policy)" = 644 ]
/usr/sbin/sshd -T >"$test_root/sshd-effective"
grep -Eq '^streamlocalbindmask[[:space:]]+0177$' "$test_root/sshd-effective"
grep -Eq '^streamlocalbindunlink[[:space:]]+yes$' "$test_root/sshd-effective"
stat -c '%i:%Y' /etc/ssh/sshd_config.d/10-cred-forward.conf \
    >"$test_root/admin-before"
stat -c '%i:%Y' /etc/cred-forward/sshd-policy \
    >>"$test_root/admin-before"
sleep 1
/src/cred-forward/install/configure-sshd.sh \
    >"$test_root/admin-reinstall.log" 2>&1
stat -c '%i:%Y' /etc/ssh/sshd_config.d/10-cred-forward.conf \
    >"$test_root/admin-after"
stat -c '%i:%Y' /etc/cred-forward/sshd-policy \
    >>"$test_root/admin-after"
cmp "$test_root/admin-before" "$test_root/admin-after"

# RHEL-family systems can make the drop-in directory unreadable to users. The
# validated marker remains sufficient for the unprivileged installer check.
chmod 0700 /etc/ssh/sshd_config.d
sudo -u remote env HOME=/home/remote DEVENV_HOME=/src SHELL=/bin/bash \
    PATH=/usr/bin:/bin bash -c '
        . /src/lib/common.sh
        . /src/cred-forward/install/_configure.sh
        sshd_policy_is_configured
    '
chmod 0755 /etc/ssh/sshd_config.d
HOME=$client_home PATH=$client_path SHELL=/bin/bash DEVENV_HOME=/src \
    /src/cred-forward/install.sh >"$test_root/client-after-admin.log" 2>&1
grep -Fq 'SSH daemon policy supports safe credential socket replacement' \
    "$test_root/client-after-admin.log"
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
ssh "${ssh_forward_opts[@]}" remote@127.0.0.1 \
    CRED_FORWARD_SOCKET=/home/remote/.cache/cred.sock /tmp/cred-client github anchi-t2 \
    >"$test_root/forwarded-account-token"
[ "$(cat "$test_root/forwarded-account-token")" = fake-work-token ]

# The root test harness owns the output files around the sudo invocation.
# shellcheck disable=SC2024
if sudo -iu remote env CRED_FORWARD_SOCKET=/home/remote/.cache/cred.sock \
    /tmp/cred-client github \
    >"$test_root/post-session.out" 2>"$test_root/post-session.err"; then
    echo "cred-client unexpectedly worked through sudo after SSH forwarding ended" >&2
    exit 1
fi
# OpenSSH leaves the socket file behind; the client names it as stale.
grep -Fq 'stale credential socket' "$test_root/post-session.err"

kill "$agent_pid" "$sshd_pid"
wait "$agent_pid" || true
wait "$sshd_pid" || true
echo "Docker credential-forwarding tests passed"
