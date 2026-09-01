# cred-forward

`cred-forward` lets remote command-line tools use credentials from a local
macOS or Linux machine. The remote machine receives a Unix-domain socket, not a
credential file.

This directory is a standalone macOS and Linux component. The top-level
`devenv` installer does not install it, and Windows is not supported.

The agent supports API credentials and existing CLI login credentials:

| Login | Local credential source | Remote use |
|---|---|---|
| GitHub CLI | `github` | `GH_TOKEN` |
| Claude API key | `anthropic` | `ANTHROPIC_API_KEY` |
| Claude subscription | `anthropicoauth` | `CLAUDE_CODE_OAUTH_TOKEN` |
| OpenAI API key | `openai` | Process-local Codex provider |
| Codex ChatGPT | `openaichatgpt`, `openaiaccount` | Command-backed Codex provider |

## Set up credential forwarding

### 1. Install and start the local agent

Run the matching installer from this directory:

```sh
./install/install-macos.sh agent
# or: ./install/install-linux.sh agent
```

Set credentials in the agent process only, then start the agent:

```sh
CRED_AGENT_GITHUB='github-token' \
CRED_AGENT_ANTHROPIC='anthropic-key' \
CRED_AGENT_OPENAI='openai-key' \
cred-agent
```

The default socket is `~/.cache/cred-agent.sock`. Set `CRED_AGENT_SOCKET` or
use `cred-agent -socket PATH` to change it.

Command helpers keep credential values out of the agent launch environment.
Each command must print one credential and an optional final newline:

```sh
export CRED_AGENT_GITHUB_COMMAND='my-secret-tool read github'
export CRED_AGENT_ANTHROPIC_COMMAND='my-secret-tool read anthropic'
export CRED_AGENT_OPENAI_COMMAND='my-secret-tool read openai'
cred-agent
```

Use the active GitHub CLI login without copying its token:

```sh
export CRED_AGENT_GITHUB_COMMAND='gh auth token'
```

The agent ignores standard variables such as `GH_TOKEN` by default. Set
`CRED_AGENT_INHERIT_ENV=1` to use standard GitHub, Anthropic, Claude, and
OpenAI variables as fallback sources. This option exposes all matching
variables through the forwarded socket.

Claude subscription forwarding needs a long-lived OAuth token. Run
`claude setup-token`, then store its output in a local secret provider. Set
`CRED_AGENT_ANTHROPIC_OAUTH` or its command helper to return that token:

```sh
export CRED_AGENT_ANTHROPIC_OAUTH_COMMAND='my-secret-tool read claude-oauth'
```

Codex ChatGPT forwarding reads the current access token and account identifier
from the local Codex credential store. These example commands use `jq`:

```sh
export CRED_AGENT_OPENAI_CHATGPT_COMMAND='jq -er .tokens.access_token "$HOME/.codex/auth.json"'
export CRED_AGENT_OPENAI_ACCOUNT_COMMAND='jq -er .tokens.account_id "$HOME/.codex/auth.json"'
```

The Codex access token expires. The local Codex CLI refreshes its credential
store during normal use. Restart local Codex if the remote wrapper gets a 401
response and the local token is stale.

The provider package uses small `Source` implementations and a registry.
Keychain, 1Password, or Secret Service providers can implement the same
interface later.

### 2. Configure the OpenSSH connection

Create `~/.cache` on the remote machine with mode `0700`:

```sh
install -d -m 0700 ~/.cache
```

Copy the relevant lines from [examples/ssh_config](examples/ssh_config) to the
local `~/.ssh/config`. Replace the host and remote user:

```sshconfig
Host my-dev-host
    HostName dev.example.com
    User my-user
    ForwardAgent yes
    ExitOnForwardFailure yes
    StreamLocalBindMask 0177
    StreamLocalBindUnlink yes
    RemoteForward /home/my-user/.cache/cred.sock ${HOME}/.cache/cred-agent.sock
```

Use an absolute path for the remote socket. OpenSSH expands `${HOME}` on the
local side, so do not use it for the remote path.

`StreamLocalBindMask 0177` creates an owner-only socket on systems that honor
Unix socket modes. `StreamLocalBindUnlink yes` removes a stale socket before a
new connection. `ExitOnForwardFailure yes` stops the connection if OpenSSH
cannot create the forward. See the OpenSSH
[`RemoteForward`](https://man.openbsd.org/ssh_config#RemoteForward) and
[`StreamLocalBindMask`](https://man.openbsd.org/ssh_config#StreamLocalBindMask)
documentation.

The credential forward does not use SSH agent forwarding. `ForwardAgent yes`
is included for development workflows that also need the local SSH agent.

OpenSSH, VS Code Remote SSH, and clients that use this OpenSSH host entry use
the same forward. No custom SSH command is required.

### 3. Install the remote client and wrappers

Clone or copy this directory to the remote machine. Run:

```sh
./install/install-linux.sh client
# or: ./install/install-macos.sh client
```

The installer puts `cred-client` in `~/.local/bin`. It puts wrappers in
`~/.local/share/cred-forward/wrappers`. Add the wrapper directory before the
directory that contains the real tools:

```sh
export PATH="$HOME/.local/share/cred-forward/wrappers:$PATH"
```

The installer upgrades files that it installed before. It does not replace an
unknown file at the same path. Set `FORCE=1` to replace that file and save the
original under `~/.local/share/cred-forward/.devenv-backup`.

Add that line to the remote shell startup file used by OpenSSH and VS Code.
The installer does not edit a shell or SSH configuration file.

Test each service after an SSH connection starts:

```sh
cred-client github
cred-client anthropic
cred-client openai
```

Each command writes only the requested credential to standard output. Errors
go to standard error. `CRED_FORWARD_SOCKET` changes the default remote socket
from `~/.cache/cred.sock`.

Then use the normal commands:

```sh
gh auth status
claude
codex
```

Set `CRED_FORWARD_REAL_GH`, `CRED_FORWARD_REAL_CLAUDE`, or
`CRED_FORWARD_REAL_CODEX` if automatic real-binary discovery is unsuitable.

## Wrapper behavior

The `gh` wrapper sets `GH_TOKEN` for the real child process. The Claude wrapper
prefers a subscription OAuth token. For an API key, it uses Claude's
`apiKeyHelper` setting to call `cred-client` when Claude needs the key.

For ChatGPT login, the Codex wrapper uses a command-backed provider. Codex calls
`cred-client` again when it refreshes the bearer token. The wrapper forwards
the account identifier in a request header. It does not create `auth.json`.

For OpenAI API keys, the Codex wrapper uses a command-backed provider. Codex
calls `cred-client` when it needs the key and uses the OpenAI Responses API.

Official Codex documentation states that normal API-key login caches the key in
`auth.json` or an operating-system store. It also documents `env_key` for a
custom provider. See [Codex authentication](https://developers.openai.com/codex/auth)
and the [Codex configuration reference](https://developers.openai.com/codex/config-reference).

API-key use receives OpenAI Platform billing and features. ChatGPT login uses
the existing Codex subscription login.

## Security model and limitations

- The agent and client never log credential values.
- The local agent sets its socket mode to `0600`.
- The setup uses `0700` socket directories and a `0177` OpenSSH socket mask.
- The protocol accepts six fixed service names and limits all frame sizes.
- The remote wrappers do not write credential files. Codex and Claude API-key
  helpers fetch credentials only when the tool needs them.
- The `gh` token and Claude subscription token exist in the target process
  environment. Child commands from those tools can inherit these values.
- OpenSSH removes the remote listener when the SSH transport closes. A stale
  socket file cannot reach the local agent.

The forwarded socket is an active credential capability. Remote root can bypass
file permissions and use the socket while the SSH connection exists. A process
that uses the same remote account can also use it during that time. OpenSSH
documents the same limitation for forwarded agent sockets.

Root can also inspect a target command's environment while that command runs.
End forwarded `gh`, `claude`, and `codex` processes when the SSH transport ends.
Do not detach these commands into `tmux`, `screen`, or a background service.

After the SSH transport closes, the socket has no path to the local agent.
Running `sudo -iu my-user` after disconnect cannot retrieve a credential. This
design cannot undo a credential that remote root copied while forwarding was
active. Revoke credentials if the remote root account is not trusted.

`ForwardAgent yes` separately exposes the local SSH agent during the connection.
Remove that line if the remote workflow does not need SSH agent forwarding.

## Build and test

Build static binaries for macOS and Linux on AMD64 and ARM64:

```sh
make build
```

Run unit tests:

```sh
make test
```

Run the complete Linux test in Docker:

```sh
make docker-test
```

The Docker test runs protocol tests, checks wrapper behavior, builds all four
targets, and opens a real OpenSSH Unix-socket forward. It also confirms that the
client cannot retrieve a credential after the SSH connection closes.

## Protocol

One Unix-socket connection carries one request. Version 1 uses a bounded line
request and a length-framed response:

```text
CRED/1 GET github\n
CRED/1 OK 12\n
token-value
```

Errors contain a fixed code such as `unavailable`. Provider errors and command
output never cross the socket.
