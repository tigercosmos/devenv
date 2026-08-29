#!/usr/bin/env bash
# lib/common.sh — helpers shared by every devenv installer script.
# Source it; do not execute it.

DEVENV_HOME="${DEVENV_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOCAL_BIN="$HOME/.local/bin"
CLAUDE_SKILLS="$HOME/.claude/skills"
FORCE="${FORCE:-0}"          # FORCE=1 reinstalls / upgrades tools that are already present
export DEVENV_HOME LOCAL_BIN CLAUDE_SKILLS FORCE

# Tools installed by this repo land in ~/.local/bin; make them visible to the
# installers even before the shell profile has been configured.
case ":$PATH:" in *":$LOCAL_BIN:"*) ;; *) PATH="$LOCAL_BIN:$PATH" ;; esac
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
