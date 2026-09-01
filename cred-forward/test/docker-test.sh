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
            test "${10}" = 'model_providers.cred_forward.auth.command="/src/dist/linux-amd64/cred-client"'
            test "${12}" = 'model_providers.cred_forward.auth.args=["openaichatgpt"]'
        else
            test -z "${OPENAI_API_KEY:-}"
            test "${8}" = 'model_providers.cred_forward.auth.command="/src/dist/linux-amd64/cred-client"'
            test "${10}" = 'model_providers.cred_forward.auth.args=["openai"]'
        fi
        ;;
esac
printf 'wrapper-ok:%s\n' "$(basename "$0")"
EOF
    chmod +x "$test_root/real/$tool"
done
export CRED_FORWARD_SOCKET=$local_socket
export CRED_FORWARD_CLIENT=/src/dist/linux-amd64/cred-client
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
