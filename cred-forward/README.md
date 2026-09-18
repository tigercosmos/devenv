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
- Records each host and its remote socket path in
  `~/.config/cred-forward/links`.
- Creates a missing remote `~/.cache` directory with mode `0700`. It preserves
  the permissions of an existing directory.
- Installs `cred-forward-link` and starts a second user service that keeps
  one SSH connection per host. That connection owns the remote socket.

The macOS services are LaunchAgents. The Linux services are systemd user
units. The default local socket is `~/.cache/cred-agent.sock`.

The link service authenticates without a prompt. Use an SSH key without a
passphrase for the forwarded hosts, or load the key into the SSH agent that
the user service manager exposes. On macOS, `launchd` provides
`SSH_AUTH_SOCK` to LaunchAgents. The link log is
`~/Library/Logs/cred-forward-link.log` on macOS and
`journalctl --user -u cred-forward-link` on Linux.

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
`~/.local/share/cred-forward/wrappers` and activates them in the shell profiles.
It seeds `~/.config/cred-forward/github-accounts` once; see
[Multiple GitHub accounts](#multiple-github-accounts).
The user-level installation never runs `sudo`.

The remote SSH daemon requires two settings for secure socket permissions and
stale-socket replacement. If the settings are absent, `make install` prints
this separate administrator command:

```sh
sudo ~/devenv/cred-forward/install/configure-sshd.sh
```

The script writes `/etc/ssh/sshd_config.d/10-cred-forward.conf`, validates the
effective SSH configuration, and records the result in
`/etc/cred-forward/sshd-policy`. On Linux, it reloads an active SSH service. On
macOS, new connections load the policy without interrupting existing sessions.
It preserves unrelated files at either path. Run the printed script path when
the repository is not in `~/devenv`.

The link service connects as soon as the server installation finishes. An
open SSH session does not need to reconnect.

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

## Multiple GitHub accounts

The local `gh` can hold several logins (`gh auth login` once per account). The
agent serves each of them: `cred-client github` returns the active login and
`cred-client github ACCOUNT` returns the login for one account through
`gh auth token --user ACCOUNT`.

The remote `gh` wrapper picks the account from the repository owner. The map
lives in `~/.config/cred-forward/github-accounts` on the client:

```text
t2-auto anchi-t2
tigercosmos tigercosmos
* tigercosmos
```

Each line pairs an owner with a local `gh` login. Owners match
case-insensitively and `*` is the fallback. The wrapper finds the owner in
this order:

1. `--repo`/`-R` or `GH_REPO`, as `OWNER/REPO`, `HOST/OWNER/REPO`, or a URL.
2. The repository operand of a `gh repo` command, such as
   `gh repo clone t2-auto/project`. Other positional arguments and option
   values are never treated as repositories.
3. The first github.com remote of the current directory, checking
   `upstream`, `github`, and `origin` before the others.
4. The `*` fallback.

Only `github.com` owners are recognised. Without the map file, or when a
line matches nothing, the wrapper uses the active local login as before.
`CRED_FORWARD_GITHUB_ACCOUNT=login` forces one account for a single command
and `CRED_FORWARD_GITHUB_ACCOUNTS=path` selects another map file.

The installer seeds the map from `config/github-accounts` and never replaces
it afterwards, not even with `FORCE=1`. Edit the file directly.

### HTTPS git pushes

The client installer also routes git's own HTTPS credentials for
`github.com` through the same map. It installs
`git-credential-cred-forward` next to the wrappers, writes a managed
`~/.config/cred-forward/gitconfig`, and adds one `include.path` line to the
global git config. The include sits after any helper that
`gh auth setup-git` configured, so it takes precedence. The original global
config is copied to `~/.local/share/cred-forward/.devenv-backup/` first.

The helper answers `get` only. It reads the repository owner from the
request path, so `git push` in a `t2-auto` repository uses `anchi-t2` and
every other repository uses the fallback. `store` and `erase` do nothing;
no credential is written to disk. Other hosts and plain HTTP fall through
to the next helper.

SSH remotes bypass credential helpers. Their account is decided by the SSH
key that the remote machine offers.

`CRED_AGENT_GITHUB_TOKEN_<NAME>` and `CRED_AGENT_GITHUB_COMMAND_<NAME>`
override the local login for one account, where `<NAME>` is the account in
upper case with hyphens replaced by underscores, for example
`CRED_AGENT_GITHUB_COMMAND_ANCHI_T2`. Named logins always come from
`github.com`.

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

The agent reuses a `gh auth token` result for one minute per account.
Parallel git and `gh` commands on the remote otherwise start one `gh` process
per request. A switched `gh` login takes effect within that minute.
Environment and command overrides are not cached.

The provider package uses small `Source` implementations and a registry.
Keychain, 1Password, and Secret Service providers can implement the same
interface.

### The link service

OpenSSH binds the remote socket path per SSH session. With
`StreamLocalBindUnlink yes`, each new session takes the path from the
previous one, and OpenSSH leaves the socket file behind when a session ends.
If every login carried the forward, the path would belong to the most recent
login, including a short `ssh host command`, and would die when that login
ended. Sessions that were still open would then fail immediately or wait for
the client timeout on every credential request.

`cred-forward-link` is therefore the only process that asks for the forward.
It runs as a user service, reads `~/.config/cred-forward/links`, and opens
one `ssh -N` connection per line with the `RemoteForward` option on its own
command line, together with `ExitOnForwardFailure` and server-alive checks.
It reconnects with backoff when a connection drops. `~/.ssh/config` never
carries the forward, so interactive logins, VS Code Remote SSH, `scp`, and git
over SSH use the host entry unchanged. The links file has this form:

```
# Managed by devenv cred-forward.
my-dev-host /home/my-user/.cache/cred.sock
```

Before the first connection, the installer runs a short remote command that
creates `~/.cache` with mode `0700` and removes a leftover socket file. The
link runs the same command again before a retry that follows a failed
connection. Only the link binds that path, so the file is always safe to
remove.

Use an absolute path for the remote socket. OpenSSH expands `${HOME}` on the
local side, so do not use it for the remote path.

The remote SSH server controls the mode and stale-file behavior for a remote
Unix socket. The `0700` parent directory restricts access to the remote account.
The administrator script sets `StreamLocalBindMask 0177` and
`StreamLocalBindUnlink yes`. These settings provide reliable permissions and
stale-socket replacement. Client-side options cannot enable them. See the
OpenSSH
[`RemoteForward`](https://man.openbsd.org/ssh_config#RemoteForward) and remote
[`StreamLocalBindMask`](https://man.openbsd.org/sshd_config#StreamLocalBindMask)
documentation.

The credential forward does not need SSH-agent forwarding. Set
`CRED_FORWARD_SSH_AGENT=1` during server installation only when the remote
workflow must also use the local SSH agent. The installer then writes a
managed fragment under `~/.ssh/config.d` with `ForwardAgent yes` for each
host and backs up an existing SSH config before it adds the `Include` line.
Without that setting, the installer removes its managed fragment.

## Wrapper behavior

The `gh` wrapper sets `GH_TOKEN` for the real child process. The git
credential helper prints the login to git on stdout and stores nothing. The
Claude wrapper
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
- Each connection logs its timestamp, service name, account, status, and
  local peer process ID. An invalid request uses `service=-`; a request for
  the default login uses `account=-`.
- For a forwarded request, the peer process ID identifies the local SSH
  process. It does not identify the remote process that made the request.
- The macOS agent writes audit records to
  `~/Library/Logs/cred-agent.log`. The agent rotates the file at 1 MiB and
  keeps one previous file at `~/Library/Logs/cred-agent.log.1`.
- The Linux user service writes audit records to the systemd journal. Use
  `journalctl --user -u cred-agent` to read the records.
- The local agent sets its socket mode to `0600`.
- The setup uses `0700` socket directories. Remote administrators can also
  enforce a `0177` OpenSSH socket mask.
- The protocol accepts six fixed service names, an optional GitHub login
  name for the `github` service, and limits all frame sizes.
- The remote wrappers do not write credential files. Codex and Claude API-key
  helpers fetch credentials only when the tool needs them.
- The `gh` token and Claude subscription token exist in the target process
  environment. Child commands from those tools can inherit these values.
- OpenSSH removes the remote listener when the SSH transport closes. A stale
  socket file cannot reach the local agent; `cred-client` reports it as
  stale.

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

A request may name one account: `CRED/1 GET github anchi-t2\n`. The account
uses the GitHub login syntax: up to 39 letters, digits, or hyphens.

Errors contain a fixed code such as `unavailable`. Provider errors and command
output never cross the socket.
