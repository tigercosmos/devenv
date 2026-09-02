#!/usr/bin/env bash
# Configure the SSH daemon policy required by cred-forward clients.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# The source path is resolved from this script.
# shellcheck disable=SC1091
. "$script_dir/../../lib/common.sh"
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

drop_in=/etc/ssh/sshd_config.d/10-cred-forward.conf
state_dir=/etc/cred-forward
state_file="$state_dir/sshd-policy"
marker='Managed by devenv cred-forward.'
content="# $marker
StreamLocalBindMask 0177
StreamLocalBindUnlink yes"
tmp=""
backup=""
installed_new=0
changed=0
effective=""
complete=0

cleanup() {
    local status=$?
    trap - EXIT
    set +e
    if [ "$status" -ne 0 ] && [ "$complete" != 1 ] && [ "$changed" = 1 ]; then
        restore_previous_config \
            || warn "could not restore the previous SSH daemon configuration"
    fi
    [ -z "$tmp" ] || rm -f "$tmp"
    [ -z "$backup" ] || rm -f "$backup"
    exit "$status"
}
trap cleanup EXIT

has_required_policy() {
    local file="$1"
    [ -r "$file" ] \
        && grep -Eq '^[[:space:]]*StreamLocalBindMask[[:space:]]+0177([[:space:]]|$)' "$file" \
        && grep -Eq '^[[:space:]]*StreamLocalBindUnlink[[:space:]]+yes([[:space:]]|$)' "$file"
}

require_safe_drop_in() {
    local owner mode
    if [ -L "$drop_in" ] || [ ! -f "$drop_in" ]; then
        die "$drop_in must be a regular file, not a symbolic link"
    fi
    case "$(uname -s)" in
        Darwin) read -r owner mode < <(stat -f '%u %Lp' "$drop_in") ;;
        Linux) read -r owner mode < <(stat -c '%u %a' "$drop_in") ;;
    esac
    if [ "$owner" != 0 ] || (( (8#$mode & 8#022) != 0 )); then
        die "$drop_in must be root-owned and not writable by group or other"
    fi
}

restore_previous_config() {
    if [ -n "$backup" ]; then
        cp -p "$backup" "$drop_in"
    elif [ "$installed_new" = 1 ]; then
        rm -f "$drop_in"
    fi
}

reload_sshd() {
    case "$(os)" in
        linux)
            if have systemctl && systemctl is-active ssh.service >/dev/null 2>&1; then
                systemctl reload ssh.service
            elif have systemctl && systemctl is-active sshd.service >/dev/null 2>&1; then
                systemctl reload sshd.service
            elif have service && service ssh status >/dev/null 2>&1; then
                service ssh reload
            elif have service && service sshd status >/dev/null 2>&1; then
                service sshd reload
            else
                warn "no active SSH service was found; the next sshd start will use the policy"
            fi
            ;;
        macos)
            ok "macOS sshd will use the policy for new connections; no restart is required"
            ;;
    esac
}

[ "$(id -u)" -eq 0 ] || die "run this script with sudo: sudo $0"
case "$(os)" in
    linux|macos) ;;
    *) die "cred-forward SSH daemon setup supports macOS and Linux only" ;;
esac

sshd_bin=$(command -v sshd 2>/dev/null || true)
[ -n "$sshd_bin" ] || die "sshd is not installed"

tmp=$(mktemp)
printf '%s\n' "$content" >"$tmp"
chmod 0644 "$tmp"

if [ -e "$state_file" ]; then
    if [ -L "$state_file" ] || [ ! -f "$state_file" ]; then
        die "$state_file must be a regular file, not a symbolic link"
    fi
    if ! grep -qF "$marker" "$state_file" 2>/dev/null; then
        die "preserving existing $state_file; move it before configuring cred-forward"
    fi
fi

if [ -e "$drop_in" ]; then
    require_safe_drop_in
    if cmp -s "$tmp" "$drop_in" || has_required_policy "$drop_in"; then
        ok "SSH daemon policy is already configured: $drop_in"
    elif grep -qF "$marker" "$drop_in" 2>/dev/null; then
        backup=$(mktemp)
        cp -p "$drop_in" "$backup"
        install -m 0644 "$tmp" "$drop_in"
        changed=1
        ok "updated $drop_in"
    else
        die "preserving existing $drop_in; configure the two StreamLocalBind settings manually"
    fi
else
    install -d -m 0755 "$(dirname "$drop_in")"
    install -m 0644 "$tmp" "$drop_in"
    installed_new=1
    changed=1
    ok "installed $drop_in"
fi

if ! "$sshd_bin" -t; then
    die "sshd rejected the configuration; restored the previous state"
fi
if ! effective=$("$sshd_bin" -T 2>/dev/null); then
    die "sshd could not report its effective configuration"
fi
if ! grep -Eq '^streamlocalbindmask[[:space:]]+0177$' <<<"$effective" \
    || ! grep -Eq '^streamlocalbindunlink[[:space:]]+yes$' <<<"$effective"; then
    die "sshd does not make the policy effective; ensure sshd_config contains: Include /etc/ssh/sshd_config.d/*.conf"
fi

if [ "$changed" = 1 ]; then
    reload_sshd
fi
install -d -m 0755 "$state_dir"
if ! cmp -s "$tmp" "$state_file"; then
    install -m 0644 "$tmp" "$state_file"
fi
complete=1
ok "SSH daemon accepts safe cred-forward socket replacement"
