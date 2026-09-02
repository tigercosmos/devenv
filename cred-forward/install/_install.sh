#!/bin/sh
set -eu

expected_os=$1
role=${2:-}

usage() {
    echo "usage: $0 agent|client|all" >&2
    exit 2
}

[ "$role" = agent ] || [ "$role" = client ] || [ "$role" = all ] || usage
[ "$(uname -s)" = "$expected_os" ] || {
    echo "cred-forward: this installer requires $expected_os" >&2
    exit 1
}
command -v go >/dev/null 2>&1 || {
    echo "cred-forward: Go is required" >&2
    exit 1
}

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
root=$(CDPATH='' cd -- "$script_dir/.." && pwd -P)
bin_dir=${CRED_FORWARD_BIN_DIR:-"$HOME/.local/bin"}
wrapper_dir=${CRED_FORWARD_WRAPPER_DIR:-"$HOME/.local/share/cred-forward/wrappers"}
state_dir="$HOME/.local/share/cred-forward/.install-state"
force=${FORCE:-0}
backup_dir=
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/cred-forward.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

ensure_dir() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        if [ ! -d "$1" ]; then
            echo "cred-forward: $1 exists and is not a directory" >&2
            exit 1
        fi
        return
    fi
    install -d -m "$2" "$1"
}

install_artifact() {
    source_path=$1
    destination=$2
    mode=$3
    backup_name=$4
    state_file="$state_dir/$backup_name.cksum"

    if [ -e "$destination" ] || [ -L "$destination" ]; then
        if [ ! -L "$destination" ] && [ -f "$destination" ] && cmp -s "$source_path" "$destination"; then
            record_install_state "$source_path" "$state_file"
            echo "already installed: $destination"
            return
        fi
        installer_owned=0
        if [ ! -L "$destination" ] && [ -f "$destination" ] && [ -f "$state_file" ]; then
            recorded_checksum=$(sed -n '1p' "$state_file")
            installed_checksum=$(artifact_checksum "$destination")
            if [ "$recorded_checksum" = "$installed_checksum" ]; then
                installer_owned=1
            fi
        fi
        if [ "$installer_owned" != 1 ]; then
            if [ "$force" != 1 ]; then
                echo "cred-forward: preserving existing $destination (set FORCE=1 to replace it)" >&2
                exit 1
            fi
            if [ -z "$backup_dir" ]; then
                backup_dir="$HOME/.local/share/cred-forward/.devenv-backup/$(date +%Y%m%d%H%M%S)-$$"
                ensure_dir "$backup_dir" 0700
            fi
            mv "$destination" "$backup_dir/$backup_name"
            echo "backed up existing $destination to $backup_dir/$backup_name"
        fi
    fi
    install -m "$mode" "$source_path" "$destination"
    record_install_state "$source_path" "$state_file"
    echo "installed: $destination"
}

artifact_checksum() {
    cksum <"$1" | awk '{ print $1 " " $2 }'
}

record_install_state() {
    state_value=$(artifact_checksum "$1")
    if [ -f "$2" ] && [ "$(sed -n '1p' "$2")" = "$state_value" ]; then
        return
    fi
    ensure_dir "$state_dir" 0700
    printf '%s\n' "$state_value" >"$build_dir/install-state"
    install -m 0600 "$build_dir/install-state" "$2"
}

case "$force" in
    0|1) ;;
    *)
        echo "cred-forward: FORCE must be 0 or 1" >&2
        exit 2
        ;;
esac

ensure_dir "$HOME/.cache" 0700
ensure_dir "$bin_dir" 0755
if [ "$role" = agent ] || [ "$role" = all ]; then
    (cd "$root" && CGO_ENABLED=0 go build -trimpath -o "$build_dir/cred-agent" ./cmd/cred-agent)
    install_artifact "$build_dir/cred-agent" "$bin_dir/cred-agent" 0755 bin-cred-agent
    install_artifact "$root/service/cred-agent-launch" "$bin_dir/cred-agent-launch" 0755 bin-cred-agent-launch
fi

if [ "$role" = client ] || [ "$role" = all ]; then
    (cd "$root" && CGO_ENABLED=0 go build -trimpath -o "$build_dir/cred-client" ./cmd/cred-client)
    install_artifact "$build_dir/cred-client" "$bin_dir/cred-client" 0755 bin-cred-client
    ensure_dir "$wrapper_dir" 0755
    install_artifact "$root/wrappers/_common.sh" "$wrapper_dir/_common.sh" 0644 wrapper-common
    install_artifact "$root/wrappers/gh" "$wrapper_dir/gh" 0755 wrapper-gh
    install_artifact "$root/wrappers/claude" "$wrapper_dir/claude" 0755 wrapper-claude
    install_artifact "$root/wrappers/codex" "$wrapper_dir/codex" 0755 wrapper-codex
    echo "add this directory before the real CLI directory in PATH:"
    echo "  export PATH=\"$wrapper_dir:\$PATH\""
fi
