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

# cred_forward_github_owner URL-OR-SPEC
# Prints the repository owner for a github.com remote URL, an OWNER/REPO
# spec, or a HOST/OWNER/REPO spec. Fails for other hosts and other shapes.
cred_forward_github_owner() {
    cf_spec=$1
    case $cf_spec in
        *'
'*|'') return 1 ;;
        *://*)
            # ssh://git@github.com/owner/repo or https://github.com/owner/repo
            cf_spec=${cf_spec#*://}
            cf_spec=${cf_spec#*@}
            ;;
        *@*:*)
            # git@github.com:owner/repo
            cf_spec=${cf_spec#*@}
            cf_spec=$(printf '%s' "$cf_spec" | sed 's|:|/|')
            ;;
        */*/*) ;;
        */*) cf_spec=github.com/$cf_spec ;;
        *) return 1 ;;
    esac
    cf_host=${cf_spec%%/*}
    cf_host=${cf_host%:*}
    cf_rest=${cf_spec#*/}
    cf_owner=${cf_rest%%/*}
    cf_repo=${cf_rest#*/}
    [ "$cf_host" = github.com ] || return 1
    [ -n "$cf_owner" ] && [ "$cf_rest" != "$cf_owner" ] && [ -n "$cf_repo" ] || return 1
    case $cf_owner in
        -*|*[!A-Za-z0-9-]*) return 1 ;;
    esac
    printf '%s\n' "$cf_owner"
}

# cred_forward_github_map_owner FILE OWNER
# Prints the account that FILE maps OWNER to. Fails when neither the owner
# nor "*" is listed, or when the matching account is not a GitHub login.
cred_forward_github_map_owner() {
    cf_file=$1
    cf_wanted=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
    cf_default=
    cf_found=
    while IFS= read -r cf_line || [ -n "$cf_line" ]; do
        cf_line=${cf_line%}
        case $cf_line in ''|'#'*) continue ;; esac
        # The "*" fallback owner must not glob against the current directory.
        set -f
        # shellcheck disable=SC2086
        set -- $cf_line
        set +f
        [ $# -ge 2 ] || continue
        cf_owner=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
        if [ "$cf_owner" = '*' ]; then
            [ -n "$cf_default" ] || cf_default=$2
        elif [ "$cf_owner" = "$cf_wanted" ]; then
            cf_found=$2
            break
        fi
    done <"$cf_file"
    [ -n "$cf_found" ] || cf_found=$cf_default
    [ -n "$cf_found" ] || return 1
    if ! cred_forward_valid_login "$cf_found"; then
        echo "cred-forward: invalid account in $cf_file: $cf_found" >&2
        return 1
    fi
    printf '%s\n' "$cf_found"
}

# cred_forward_github_repo_owner
# Prints the owner of the github.com repository in the current directory,
# using the remotes in gh's order of preference and skipping other hosts.
cred_forward_github_repo_owner() {
    command -v git >/dev/null 2>&1 || return 1
    cf_remotes=$(git remote 2>/dev/null) || return 1
    for cf_remote in upstream github origin $cf_remotes; do
        cf_url=$(git config --get "remote.$cf_remote.url" 2>/dev/null) || continue
        cf_owner=$(cred_forward_github_owner "$cf_url") || continue
        printf '%s\n' "$cf_owner"
        return
    done
    return 1
}

# cred_forward_github_account FILE ARGS...
# Prints the gh login for this invocation, or nothing to use the active
# login. The owner comes from --repo/-R or GH_REPO first, then from the
# repository operand of a "gh repo" command, then from the repository in
# the current directory. FILE maps the owner, or "*", to the login.
cred_forward_github_account() {
    cf_map=$1
    shift
    if [ -n "${CRED_FORWARD_GITHUB_ACCOUNT:-}" ]; then
        printf '%s\n' "$CRED_FORWARD_GITHUB_ACCOUNT"
        return
    fi
    [ -f "$cf_map" ] || return 0
    cf_explicit=${GH_REPO:-}
    cf_operand=
    cf_command=
    cf_take_repo=0
    cf_options_done=0
    for cf_arg in "$@"; do
        if [ "$cf_take_repo" = 1 ]; then
            cf_explicit=$cf_arg
            cf_take_repo=0
            continue
        fi
        if [ "$cf_options_done" != 1 ]; then
            case $cf_arg in
                -R|--repo) cf_take_repo=1; continue ;;
                --repo=*) cf_explicit=${cf_arg#--repo=}; continue ;;
                -R=*) cf_explicit=${cf_arg#-R=}; continue ;;
                -R?*) cf_explicit=${cf_arg#-R}; continue ;;
                --) cf_options_done=1; continue ;;
                # Other options may take a value; the operand scan below only
                # trusts the well-known "gh repo SUBCOMMAND REPOSITORY" shape.
                -*) continue ;;
            esac
        fi
        case $cf_command in
            '') cf_command=$cf_arg ;;
            repo) cf_command=repo/$cf_arg ;;
            repo/*)
                # A value of an unknown option (--branch main) never looks
                # like a repository, so the first operand that does is it.
                [ -n "$cf_operand" ] || ! cred_forward_github_owner "$cf_arg" >/dev/null || cf_operand=$cf_arg
                ;;
        esac
    done
    cf_owner=
    if [ -n "$cf_explicit" ]; then
        cf_owner=$(cred_forward_github_owner "$cf_explicit") || cf_owner=
    fi
    if [ -z "$cf_owner" ] && [ -n "$cf_operand" ]; then
        cf_owner=$(cred_forward_github_owner "$cf_operand") || cf_owner=
    fi
    cred_forward_github_resolve_account "$cf_map" "$cf_owner"
}

# cred_forward_github_resolve_account FILE OWNER
# Maps OWNER through FILE. An empty OWNER falls back to the repository in
# the current directory, then to the "*" entry.
cred_forward_github_resolve_account() {
    cf_map=$1
    cf_owner=$2
    [ -n "$cf_owner" ] || cf_owner=$(cred_forward_github_repo_owner) || cf_owner=
    cred_forward_github_map_owner "$cf_map" "${cf_owner:-*}"
}

# cred_forward_valid_login NAME
# True when NAME has the GitHub login syntax the agent accepts: up to 39
# letters, digits, and hyphens, without a leading hyphen.
cred_forward_valid_login() {
    case $1 in
        ''|-*|*[!A-Za-z0-9-]*) return 1 ;;
    esac
    [ ${#1} -le 39 ]
}

# cred_forward_disabled TOOL
# True when forwarding is switched off for TOOL. `devenv client off --once`
# sets CRED_FORWARD_DISABLED for one command; `devenv client off` lists the
# tools in the disabled file so every open shell sees the change at once.
# "all" in either place covers every tool. This runs on every wrapper call,
# so the file is read by the shell itself, without forking.
cred_forward_disabled() {
    cf_tool=$1
    cf_list=${CRED_FORWARD_DISABLED:-}
    if [ -z "$cf_list" ]; then
        cf_file=${CRED_FORWARD_STATE_DIR:-"$HOME/.local/share/cred-forward"}/disabled
        [ -f "$cf_file" ] || return 1
        while IFS= read -r cf_line || [ -n "$cf_line" ]; do
            cf_line=${cf_line%%#*}
            cf_list="$cf_list ${cf_line%}"
        done <"$cf_file"
    fi
    case " $cf_list " in
        *' all '*|*" $cf_tool "*) return 0 ;;
    esac
    return 1
}

# cred_forward_read_tty SECONDS
# Reads one line from the terminal, giving up after SECONDS. POSIX read has
# no timeout, so bash does the waiting when it is installed.
cred_forward_read_tty() {
    if command -v bash >/dev/null 2>&1; then
        bash -c 'IFS= read -r -t "$1" cf_answer </dev/tty || exit 0; printf "%s" "$cf_answer"' _ "$1"
    else
        IFS= read -r cf_answer </dev/tty || cf_answer=
        printf '%s' "$cf_answer"
    fi
}

# cred_forward_local_or_die TOOL STATUS REAL ARGS...
# After cred-client failed with STATUS: run the real tool with its local
# login when the fallback allows it, exit with STATUS otherwise.
cred_forward_local_or_die() {
    cred_forward_fallback "$1" "$2"
    shift 2
    exec "$@"
}

# cred_forward_fallback TOOL STATUS
# Decides what to do after cred-client exited with STATUS. Returns 0 when the
# caller should run the real TOOL with its local login: only when no agent
# answered (exit 3) and either CRED_FORWARD_FALLBACK=1 or a person at the
# terminal said yes. Any other outcome exits with STATUS, so a command run by
# a script or an AI agent fails instead of silently using another account.
cred_forward_fallback() {
    cf_tool=$1
    cf_status=$2
    [ "$cf_status" = 3 ] || exit "$cf_status"
    cf_hint="run 'devenv client off $cf_tool' to use the local login, or CRED_FORWARD_FALLBACK=1 for one command"
    case ${CRED_FORWARD_FALLBACK:-} in
        1|yes) return 0 ;;
        0|no)
            echo "cred-forward: the credential agent is unreachable; $cf_hint" >&2
            exit "$cf_status"
            ;;
    esac
    if [ -t 2 ] && { : </dev/tty; } 2>/dev/null; then
        printf 'cred-forward: the credential agent is unreachable.\nUse the local %s login for this command? [y/N] (10s) ' "$cf_tool" >/dev/tty
        cf_answer=$(cred_forward_read_tty 10)
        printf '\n' >/dev/tty
        case $cf_answer in
            y|Y|yes|YES|Yes) return 0 ;;
        esac
        echo "cred-forward: not using the local login; $cf_hint" >&2
        exit "$cf_status"
    fi
    echo "cred-forward: the credential agent is unreachable and no terminal is attached; $cf_hint" >&2
    exit "$cf_status"
}
