# cred-forward

`cred-forward` lets remote command-line tools use credentials from a local
macOS or Linux machine. The remote machine receives a Unix-domain socket, not a
credential file.

The top-level `devenv` installer installs and configures this component on
macOS and Linux. Windows is not supported.

The agent supports API credentials and existing CLI login credentials:

| Login | Local credential source | Remote use |
|---|---|---|
| GitHub CLI | `github` | `GH_TOKEN` |
| Claude API key | `anthropic` | `ANTHROPIC_API_KEY` |
| Claude subscription | `anthropicoauth` | `CLAUDE_CODE_OAUTH_TOKEN` |
| OpenAI API key | `openai` | Process-local Codex provider |
| Codex ChatGPT | `openaichatgpt`, `openaiaccount` | Command-backed Codex provider |

## Set up credential forwarding

### 1. Set up the local server

Run the top-level installer on the machine that stores the logins:

```sh
make install
```

On the first run, press Enter to select `server`. Enter the SSH host aliases that need
credential forwarding. The installer completes these tasks:

- Installs `cred-agent` and starts a user service.
- Uses the active `gh` login through `gh auth token`.
- Uses the local Codex ChatGPT cache in `~/.codex/auth.json`.
- Offers to store a Claude setup token in an owner-only local file.
- Adds a managed OpenSSH fragment under `~/.ssh/config.d`.
- Creates a missing remote `~/.cache` directory with mode `0700`. It preserves
  the permissions of an existing directory.

The macOS service is a LaunchAgent. The Linux service is a systemd user unit.
The default local socket is `~/.cache/cred-agent.sock`.

Use environment variables for an unattended server setup:

```sh
CRED_FORWARD_ROLE=server \
  CRED_FORWARD_HOSTS="sim0 sim4" \
  CRED_FORWARD_CLAUDE_SETUP=skip \
  make install
```

The installer saves the role and hosts. Later installs and `make update` reuse
both values.

If you decline the Claude setup prompt, later installs remember that choice.
Set `CRED_FORWARD_CLAUDE_SETUP=force` to prompt again. The setup token appears
in terminal output while `claude setup-token` runs. Clear terminal scrollback
after you store it.

Codex must use file-based credential storage for the built-in ChatGPT source.
If `~/.codex/auth.json` is unavailable, define a command provider in
`~/.config/cred-forward/agent.env`.

### 2. Set up each remote client

Clone this repository on the remote machine. Run:

```sh
make install
```

Select `client`. For an unattended install, run:

```sh
CRED_FORWARD_ROLE=client make install
```

The installer puts `cred-client` in `~/.local/bin`. It puts the wrappers in
`~/.local/share/cred-forward/wrappers` and activates them in the shell profile.
Open a new SSH connection after both installations finish.

### 3. Verify the connection

Use the normal commands after SSH connects:

```sh
gh auth status
claude
codex
```

The remote Codex credential store stays empty. Therefore,
`codex login status` can report `Not logged in` while the wrapped Codex command
uses the forwarded login.

## Custom credential providers

Command helpers keep credential values out of the agent launch environment.
Each command must print one credential and an optional final newline:

```sh
CRED_AGENT_GITHUB_COMMAND='my-secret-tool read github'
CRED_AGENT_ANTHROPIC_COMMAND='my-secret-tool read anthropic'
CRED_AGENT_OPENAI_COMMAND='my-secret-tool read openai'
```

Put these assignments in `~/.config/cred-forward/agent.env`. Restart the user
service after an edit.

The agent ignores standard variables such as `GH_TOKEN` by default. Set
`CRED_AGENT_INHERIT_ENV=1` to use standard GitHub, Anthropic, Claude, and
OpenAI variables as fallback sources. This option exposes all matching
variables through the forwarded socket.

Claude subscription forwarding needs a setup token. You can instead use a
local secret provider command:

```sh
CRED_AGENT_ANTHROPIC_OAUTH_COMMAND='my-secret-tool read claude-oauth'
```

You can also override the built-in Codex ChatGPT source:

```sh
CRED_AGENT_OPENAI_CHATGPT_COMMAND='my-secret-tool read codex-access-token'
CRED_AGENT_OPENAI_ACCOUNT_COMMAND='my-secret-tool read codex-account-id'
```

The Codex access token expires. The local Codex CLI refreshes its credential
store during normal use. Restart local Codex if the remote wrapper gets a 401
response and the local token is stale.

The provider package uses small `Source` implementations and a registry.
Keychain, 1Password, and Secret Service providers can implement the same
interface. The generated OpenSSH fragment has this form:

```sshconfig
Host my-dev-host
    RemoteForward /home/my-user/.cache/cred.sock /Users/local-user/.cache/cred-agent.sock
```

Use an absolute path for the remote socket. OpenSSH expands `${HOME}` on the
local side, so do not use it for the remote path.

The remote SSH server controls the mode and stale-file behavior for a remote
Unix socket. The `0700` parent directory restricts access to the remote account.
Configure `StreamLocalBindMask 0177` and `StreamLocalBindUnlink yes` in the
remote `sshd_config` when possible. These server settings provide reliable
permissions and stale-socket cleanup. Client-side options cannot enable them.

The generated client fragment does not set `ExitOnForwardFailure`. Therefore,
a stale remote socket cannot lock you out of SSH, Orca, or VS Code. During
initial host configuration, the server performs a best-effort cleanup when
remote `ss` or `lsof` confirms that no process listens on the socket. If every
SSH session is closed but `~/.cache/cred.sock` remains, remove that stale file
on the remote and reconnect. Until then, the wrappers report that the forwarded
socket is unavailable. See the OpenSSH
[`RemoteForward`](https://man.openbsd.org/ssh_config#RemoteForward) and remote
[`StreamLocalBindMask`](https://man.openbsd.org/sshd_config#StreamLocalBindMask)
documentation.

The credential forward does not need SSH-agent forwarding. Set
`CRED_FORWARD_SSH_AGENT=1` during server installation only when the remote
workflow must also use the local SSH agent. The installer then adds
`ForwardAgent yes` to its managed fragment.

OpenSSH, VS Code Remote SSH, and clients that use this OpenSSH host entry use
the same forward. No custom SSH command is required.

The installer backs up an existing SSH config before it adds the managed
`Include` line. OpenSSH, Orca, and VS Code Remote SSH use the same host entry.

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
- The setup uses `0700` socket directories. Remote administrators can also
  enforce a `0177` OpenSSH socket mask.
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
Leave `CRED_FORWARD_SSH_AGENT` unset unless the remote workflow needs it.

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
