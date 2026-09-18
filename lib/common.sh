#!/usr/bin/env bash
# lib/common.sh — helpers shared by every devenv installer script.
# Source it; do not execute it.

DEVENV_HOME="${DEVENV_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOCAL_BIN="$HOME/.local/bin"
CLAUDE_SKILLS="$HOME/.claude/skills"
FORCE="${FORCE:-0}"          # FORCE=1 reinstalls / upgrades tools that are already present
export DEVENV_HOME LOCAL_BIN CLAUDE_SKILLS FORCE

# Installers must call real tools, not credential wrappers that require an SSH
# connection. Remove the wrapper directory, then put ~/.local/bin first.
CRED_FORWARD_WRAPPERS="$HOME/.local/share/cred-forward/wrappers"
IFS=: read -r -a _devenv_path_parts <<<"$PATH"
_devenv_clean_path=""
for _devenv_path_part in "${_devenv_path_parts[@]}"; do
    [ "$_devenv_path_part" = "$CRED_FORWARD_WRAPPERS" ] && continue
    _devenv_clean_path="${_devenv_clean_path:+$_devenv_clean_path:}$_devenv_path_part"
done
case "$_devenv_clean_path:" in
    "$LOCAL_BIN:"*) PATH="$_devenv_clean_path" ;;
    :) PATH="$LOCAL_BIN" ;;
    *) PATH="$LOCAL_BIN:$_devenv_clean_path" ;;
esac
unset CRED_FORWARD_WRAPPERS _devenv_clean_path _devenv_path_part _devenv_path_parts
export PATH

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_RESET=$'\033[0m'
else
    C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_RESET=''
fi

log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail() { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { fail "$@"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# os: macos | linux | windows
os() {
    case "$(uname -s)" in
        Darwin)               echo macos ;;
        Linux)                echo linux ;;
        MINGW*|MSYS*|CYGWIN*) echo windows ;;
        *) die "unsupported OS: $(uname -s)" ;;
    esac
}

# arch: arm64 | amd64
arch() {
    case "$(uname -m)" in
        arm64|aarch64) echo arm64 ;;
        x86_64|amd64)  echo amd64 ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac
}

# fetch URL DEST — download with curl or wget.
fetch() {
    if have curl; then
        curl -fsSL "$1" -o "$2"
    elif have wget; then
        wget -q -O "$2" "$1"
    else
        die "curl or wget is required"
    fi
}

# fetch_stdout URL — download to stdout.
fetch_stdout() {
    if have curl; then
        curl -fsSL "$1"
    elif have wget; then
        wget -q -O - "$1"
    else
        die "curl or wget is required"
    fi
}

# latest_tag OWNER/REPO — tag_name of the latest GitHub release.
latest_tag() {
    local tags
    # sed reads the whole body; a `head -1` here would close the pipe early
    # and make curl fail with exit 23 under pipefail.
    tags=$(fetch_stdout "https://api.github.com/repos/$1/releases/latest" \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
    printf '%s\n' "${tags%%$'\n'*}"
}

# mktmp — create a scratch directory in $TMPD, removed when the script exits.
# (Not `$(...)`-style: a trap set inside a command substitution fires when that
# subshell exits, which would delete the directory before it is used.)
TMPD=""
mktmp() {
    TMPD=$(mktemp -d)
    trap 'rm -rf "$TMPD"' EXIT
}

ensure_local_bin() { mkdir -p "$LOCAL_BIN"; }

# install_bin SRC NAME — copy an executable into ~/.local/bin.
install_bin() {
    ensure_local_bin
    install -m 0755 "$1" "$LOCAL_BIN/$2"
    ok "installed $2 -> $LOCAL_BIN/$2"
}

# ---------------------------------------------------------------------------
# User service helpers (shared by cred-forward/install and scripts/devenv-doctor)
# macOS and Linux only; cred-forward does not run on Windows.
# ---------------------------------------------------------------------------

# macos_service_pid LABEL — pid of a running LaunchAgent, or nothing.
macos_service_pid() {
    launchctl print "gui/$(id -u)/$1" 2>/dev/null \
        | awk '$1 == "pid" && $2 == "=" { print $3; exit }'
}

# linux_service_pid UNIT — MainPID of an active systemd user unit; fails when
# the unit is not running.
linux_service_pid() {
    local pid
    pid=$(systemctl --user show --property MainPID --value "$1" 2>/dev/null) \
        || return 1
    case "$pid" in
        ''|0|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$pid"
}

# config_lines FILE — the lines of a cred-forward config or state file,
# without comments and blank lines; nothing for a missing file.
config_lines() {
    [ -f "$1" ] || return 0
    sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$1"
}
# cred_forward_links FILE — the "HOST REMOTE-SOCKET" lines of a links file.
cred_forward_links() { config_lines "$1"; }

# ---------------------------------------------------------------------------
# cred-forward state (shared by cred-forward/install, scripts/devenv, and
# lib/doctor.sh). The writers live in cred-forward/install/_configure.sh.
# ---------------------------------------------------------------------------

CRED_FORWARD_STATE_DIR="$HOME/.local/share/cred-forward"
CRED_FORWARD_ROLE_FILE="$CRED_FORWARD_STATE_DIR/role"
# shellcheck disable=SC2034  # read by the installer and the link service tests
CRED_FORWARD_LINKS="$HOME/.config/cred-forward/links"
CRED_FORWARD_LINK_OFF="$CRED_FORWARD_STATE_DIR/link-off"
CRED_FORWARD_GH_PIN="$HOME/.config/cred-forward/gh-account"
CRED_FORWARD_CLIENT_DISABLED="$CRED_FORWARD_STATE_DIR/disabled"
CRED_FORWARD_LINK_LABEL=com.tigercosmos.cred-forward-link
CRED_FORWARD_SSHD_STATE=/etc/cred-forward/sshd-policy
CRED_FORWARD_TOOLS="gh claude codex"
# shellcheck disable=SC2034  # read by the installer and scripts/devenv
CRED_FORWARD_CLAUDE_SECRET="$CRED_FORWARD_STATE_DIR/secrets/claude-oauth"

# file_date FILE — the modification date of FILE as YYYY-MM-DD HH:MM.
file_date() {
    case "$(os)" in
        macos) stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$1" ;;
        *) date -r "$1" '+%Y-%m-%d %H:%M' ;;
    esac
}

# current_role — server, client, or nothing when cred-forward is not installed.
current_role() { sed -n '1p' "$CRED_FORWARD_ROLE_FILE" 2>/dev/null || true; }

# cred_forward_host_socket HOST — the local socket the agent opens for one link.
cred_forward_host_socket() { printf '%s/.cache/cred-agent-%s.sock\n' "$HOME" "$1"; }

# link_off_hosts — the switched-off hosts as one space-separated line; "*"
# means every host.
link_off_hosts() { config_lines "$CRED_FORWARD_LINK_OFF" | paste -sd ' ' -; }

# in_list WORD LIST — true when the space-separated LIST contains WORD.
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# link_host_is_off HOST OFF — true when OFF (from link_off_hosts) covers HOST.
link_host_is_off() { in_list '*' "$2" || in_list "$1" "$2"; }

# link_connected HOST — true when the link service holds the SSH link to HOST.
link_connected() { pgrep -f "^ssh -N -n .* $1\$" >/dev/null 2>&1; }

# gh_pins — the "HOST ACCOUNT" pin lines, without comments.
gh_pins() { config_lines "$CRED_FORWARD_GH_PIN"; }

# client_disabled_tools — the tools whose forwarding is off, space-separated,
# with the "all" shorthand expanded.
client_disabled_tools() {
    local list
    list=$(config_lines "$CRED_FORWARD_CLIENT_DISABLED" | paste -sd ' ' -)
    if in_list all "$list"; then printf '%s\n' "$CRED_FORWARD_TOOLS"; else printf '%s\n' "$list"; fi
}

link_service_pid() {
    case "$(os)" in
        macos) macos_service_pid "$CRED_FORWARD_LINK_LABEL" ;;
        linux) linux_service_pid cred-forward-link.service ;;
    esac
}

# print_gh_pins [PREFIX] — one ok line per pin, or one saying there is none.
print_gh_pins() {
    local prefix="${1:-}" pins host acct
    pins=$(gh_pins)
    if [ -z "$pins" ]; then
        ok "${prefix}none; remotes choose the login by repository owner"
        return
    fi
    while read -r host acct; do
        if [ "$host" = '*' ]; then ok "${prefix}every host -> $acct"; else ok "${prefix}$host -> $acct"; fi
    done <<<"$pins"
}

# print_link_hosts HOSTS OFF — one line per configured host: off, connected,
# or not connected.
print_link_hosts() {
    local host
    for host in $1; do
        if link_host_is_off "$host" "$2"; then warn "$host: off (devenv server on $host)"
        elif link_connected "$host"; then ok "$host: on, connected"
        else warn "$host: on, not connected"; fi
    done
}

# sshd_policy_is_configured — the client's SSH daemon has the socket policy.
sshd_policy_is_configured() {
    [ -r "$CRED_FORWARD_SSHD_STATE" ] \
        && grep -Eq '^[[:space:]]*StreamLocalBindMask[[:space:]]+0177([[:space:]]|$)' \
            "$CRED_FORWARD_SSHD_STATE" \
        && grep -Eq '^[[:space:]]*StreamLocalBindUnlink[[:space:]]+yes([[:space:]]|$)' \
            "$CRED_FORWARD_SSHD_STATE"
}

# ---------------------------------------------------------------------------
# Shell profile helpers (shared by shell/install.sh and scripts/devenv-doctor)
# ---------------------------------------------------------------------------

# profile_file — the login file this platform's shell reads:
#   macOS: ~/.zprofile (zsh)   Linux: ~/.bashrc (bash)
# DEVENV_PROFILE overrides the choice.
profile_file() {
    if [ -n "${DEVENV_PROFILE:-}" ]; then echo "$DEVENV_PROFILE"; return; fi
    case "$(os)" in
        macos) case "${SHELL:-}" in */bash) echo "$HOME/.bash_profile" ;; *) echo "$HOME/.zprofile" ;; esac ;;
        linux) case "${SHELL:-}" in */zsh)  echo "$HOME/.zshrc"        ;; *) echo "$HOME/.bashrc"   ;; esac ;;
        *)     echo "$HOME/.bashrc" ;;
    esac
}

# additional_login_profile — a second profile that can change PATH after it
# sources the primary profile. Stock Linux ~/.profile files do this for Bash.
additional_login_profile() {
    [ -z "${DEVENV_PROFILE:-}" ] || return 0
    if [ "$(os)" = linux ]; then
        case "${SHELL:-}" in
            */zsh) ;;
            *) echo "$HOME/.profile" ;;
        esac
    fi
}

# profile_shell FILE — which shell interprets FILE (zsh|bash).
profile_shell() {
    case "$1" in *zsh*|*zprofile*) echo zsh ;; *) echo bash ;; esac
}

# Required aliases: name|flag[|flag...] — the alias body must contain at least
# one of the flags. Alternatives exist because a flag can have more than one
# accepted spelling (e.g. claude's --dangerously-skip-permissions is the older
# name for --permission-mode bypassPermissions).
REQUIRED_ALIASES='codex|--dangerously-bypass-approvals-and-sandbox
claude|--permission-mode bypassPermissions|--dangerously-skip-permissions
cc|--permission-mode bypassPermissions|--dangerously-skip-permissions'

# eval_in_profile FILE CMD — run CMD in a clean *interactive* shell of the kind
# that reads FILE, after sourcing FILE. Interactive matters: a stock Ubuntu
# ~/.bashrc returns early for non-interactive shells, before any alias.
eval_in_profile() {
    local file="$1" cmd="$2"
    if [ "$(profile_shell "$file")" = zsh ] && have zsh; then
        zsh -f -i -c "source '$file' >/dev/null 2>&1; $cmd" 2>/dev/null
    else
        bash --noprofile --norc -i -c "source '$file' >/dev/null 2>&1; $cmd" 2>/dev/null
    fi
}

# profile_executable FILE NAME — resolve the external command in a clean shell,
# bypassing aliases and functions that may use the same name.
profile_executable() {
    local file="$1" name="$2"
    case "$name" in *[!A-Za-z0-9._-]*|'') return 2 ;; esac
    if [ "$(profile_shell "$file")" = zsh ] && have zsh; then
        eval_in_profile "$file" "whence -p -- '$name'"
    else
        eval_in_profile "$file" "type -P -- '$name'"
    fi
}

# alias_matches DEF FLAGS — true when DEF contains any of the '|'-separated
# FLAGS. IFS is set locally so the caller's field splitting is untouched.
alias_matches() {
    local def="$1" flags="$2" flag
    local IFS='|'
    for flag in $flags; do
        [ -n "$flag" ] || continue
        [[ "$def" == *"$flag"* ]] && return 0
    done
    return 1
}

# check_aliases FILE — source FILE in a clean shell and verify the required
# aliases resolve. Prints one ok/fail line per alias; returns 1 on any miss.
check_aliases() {
    local file="$1" rc=0 name flags def
    [ -f "$file" ] || { fail "$file does not exist"; return 1; }
    while IFS='|' read -r name flags; do
        [ -n "$name" ] || continue
        def=$(eval_in_profile "$file" "alias $name")
        if [ -n "$def" ] && alias_matches "$def" "$flags"; then
            ok "alias $name -> ${def#*=}"
        else
            case "$flags" in
                *'|'*) fail "alias $name is missing one of: ${flags//|/, } in $file" ;;
                *)     fail "alias $name is missing '$flags' in $file" ;;
            esac
            rc=1
        fi
    done <<< "$REQUIRED_ALIASES"
    return $rc
}

# git_credentials_use_cred_forward — the last github.com helper in the global
# git config is the cred-forward helper.
git_credentials_use_cred_forward() {
    have git || return 1
    [ "$(git config --global --includes --get-all credential.https://github.com.helper 2>/dev/null | sed -n '$p')" \
        = "!$HOME/.local/share/cred-forward/wrappers/git-credential-cred-forward" ]
}
