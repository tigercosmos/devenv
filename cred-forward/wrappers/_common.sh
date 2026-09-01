#!/bin/sh

cred_forward_client() {
    if [ -n "${CRED_FORWARD_CLIENT:-}" ]; then
        if [ ! -x "$CRED_FORWARD_CLIENT" ]; then
            echo "cred-forward: CRED_FORWARD_CLIENT is not executable: $CRED_FORWARD_CLIENT" >&2
            return 1
        fi
        printf '%s\n' "$CRED_FORWARD_CLIENT"
        return
    fi
    if command -v cred-client >/dev/null 2>&1; then
        command -v cred-client
        return
    fi
    if [ -x "$HOME/.local/bin/cred-client" ]; then
        printf '%s\n' "$HOME/.local/bin/cred-client"
        return
    fi
    echo "cred-forward: cred-client is not installed or is not on PATH" >&2
    return 1
}

cred_forward_real() {
    cf_tool=$1
    cf_override=$2
    cf_wrapper_dir=$3
    if [ -n "$cf_override" ]; then
        if [ ! -x "$cf_override" ]; then
            echo "cred-forward: real $cf_tool is not executable: $cf_override" >&2
            return 1
        fi
        printf '%s\n' "$cf_override"
        return
    fi

    cf_old_ifs=$IFS
    IFS=:
    for cf_directory in $PATH; do
        [ -n "$cf_directory" ] || cf_directory=.
        cf_candidate=$cf_directory/$cf_tool
        if [ ! -x "$cf_candidate" ] || [ -d "$cf_candidate" ]; then
            continue
        fi
        cf_resolved=$(cred_forward_resolve_path "$cf_candidate") || continue
        cf_candidate_dir=$(dirname -- "$cf_resolved")
        if [ "$cf_candidate_dir" != "$cf_wrapper_dir" ]; then
            IFS=$cf_old_ifs
            printf '%s\n' "$cf_resolved"
            return
        fi
    done
    IFS=$cf_old_ifs
    echo "cred-forward: real $cf_tool was not found after the wrapper directory" >&2
    return 1
}

cred_forward_resolve_path() {
    cf_path=$1
    while [ -L "$cf_path" ]; do
        cf_link_dir=$(CDPATH='' cd -- "$(dirname -- "$cf_path")" 2>/dev/null && pwd -P) || return 1
        cf_link=$(readlink "$cf_path") || return 1
        case $cf_link in
            /*) cf_path=$cf_link ;;
            *) cf_path=$cf_link_dir/$cf_link ;;
        esac
    done
    cf_path_dir=$(CDPATH='' cd -- "$(dirname -- "$cf_path")" 2>/dev/null && pwd -P) || return 1
    printf '%s/%s\n' "$cf_path_dir" "$(basename -- "$cf_path")"
}

cred_forward_toml_string() {
    case $1 in
        *'
'*)
            echo "cred-forward: path contains a newline" >&2
            return 1
            ;;
    esac
    escaped=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '"%s"\n' "$escaped"
}

cred_forward_shell_word() {
    case $1 in
        *'
'*)
            echo "cred-forward: path contains a newline" >&2
            return 1
            ;;
    esac
    cf_escaped=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
    printf "'%s'\n" "$cf_escaped"
}

cred_forward_json_string() {
    case $1 in
        *'
'*|*'	'*|*''*)
            echo "cred-forward: command contains an unsupported control character" >&2
            return 1
            ;;
    esac
    cf_escaped=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '"%s"\n' "$cf_escaped"
}
