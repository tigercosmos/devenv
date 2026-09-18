#!/usr/bin/env bash
# lib/doctor.sh — the `devenv doctor` check. Sourced by scripts/devenv after
# lib/common.sh; do not execute it.
# DEVENV_CALLER_PATH must hold the PATH of the calling shell, captured before
# lib/common.sh rewrote it.

devenv_doctor() {
set +e
local rc=0
check_tool() {   # check_tool NAME VERSION-CMD...
    local name="$1"; shift
    if have "$name"; then
        ok "$name  $("$@" 2>&1 | head -1)  ($(command -v "$name"))"
    else
        fail "$name is not installed"; rc=1
    fi
}

log "dependencies"
check_tool gh gh --version
check_tool codex codex --version
if [ "$(command -v codex 2>/dev/null)" = "$LOCAL_BIN/codex" ]; then
    if [ -x "$LOCAL_BIN/codex-code-mode-host" ]; then ok "codex-code-mode-host  ($LOCAL_BIN/codex-code-mode-host)"
    else fail "codex-code-mode-host missing next to $LOCAL_BIN/codex (run: make deps)"; rc=1; fi
fi
check_tool claude claude --version
check_tool agent agent --version

CRED_FORWARD_ROLE=$(current_role)
CRED_FORWARD_WRAPPERS="$CRED_FORWARD_STATE_DIR/wrappers"
if [ "$CRED_FORWARD_ROLE" = server ]; then
    if [ -x "$LOCAL_BIN/cred-agent" ]; then ok "cred-agent  ($LOCAL_BIN/cred-agent)"
    else fail "cred-agent is missing (run: make cred-forward)"; rc=1; fi
    if [ -S "$HOME/.cache/cred-agent.sock" ]; then ok "cred-agent socket is available"
    else fail "cred-agent socket is unavailable (run: make cred-forward)"; rc=1; fi
    case "$(os)" in
        macos) cred_service="$HOME/Library/LaunchAgents/com.tigercosmos.cred-agent.plist" ;;
        linux) cred_service="$HOME/.config/systemd/user/cred-agent.service" ;;
    esac
    if [ -f "$cred_service" ]; then ok "cred-agent user service -> $cred_service"
    else fail "cred-agent user service is missing (run: make cred-forward)"; rc=1; fi
    link_hosts=$(config_lines "$CRED_FORWARD_LINKS" | awk '{ print $1 }' | paste -sd ' ' -)
    if [ -n "$link_hosts" ]; then
        if [ -x "$LOCAL_BIN/cred-forward-link" ]; then ok "cred-forward-link  ($LOCAL_BIN/cred-forward-link)"
        else fail "cred-forward-link is missing (run: make cred-forward)"; rc=1; fi
        case "$(os)" in
            macos)
                link_service="$HOME/Library/LaunchAgents/$CRED_FORWARD_LINK_LABEL.plist"
                link_log="$HOME/Library/Logs/cred-forward-link.log"
                ;;
            linux)
                link_service="$HOME/.config/systemd/user/cred-forward-link.service"
                link_log="journalctl --user -u cred-forward-link"
                ;;
        esac
        link_pid=$(link_service_pid || true)
        off_hosts=$(link_off_hosts)
        active_hosts=""
        for host in $link_hosts; do
            link_host_is_off "$host" "$off_hosts" || active_hosts="${active_hosts:+$active_hosts }$host"
        done
        if [ -f "$link_service" ]; then ok "cred-forward-link user service -> $link_service"
        else fail "cred-forward-link user service is missing (run: make cred-forward)"; rc=1; fi
        if [ -z "$active_hosts" ]; then warn "cred-forward-link is switched off (devenv server on)"
        elif [ -n "$link_pid" ]; then ok "cred-forward-link is running (pid $link_pid)"
        else fail "cred-forward-link is not running (see $link_log)"; rc=1; fi
        # The supervisor stays alive while a host retries, so check each
        # host's ssh child rather than the supervisor alone.
        for host in $link_hosts; do
            if [ -S "$(cred_forward_host_socket "$host")" ]; then ok "cred-agent socket for $host is available"
            else fail "cred-agent socket for $host is missing (run: make cred-forward)"; rc=1; fi
            if link_host_is_off "$host" "$off_hosts"; then warn "credential link to $host is switched off (devenv server on $host)"
            elif link_connected "$host"; then ok "credential link to $host is connected"
            else fail "credential link to $host is down (see $link_log)"; rc=1; fi
        done
        if [ -n "$(gh_pins)" ]; then print_gh_pins "GitHub login pinned: "
        else ok "no GitHub login pinned; remotes choose by repository owner"; fi
    else warn "no SSH hosts use credential forwarding (set CRED_FORWARD_HOSTS and run: make cred-forward)"; fi
elif [ "$CRED_FORWARD_ROLE" = client ]; then
    if [ -x "$LOCAL_BIN/cred-client" ]; then ok "cred-client  ($LOCAL_BIN/cred-client)"
    else fail "cred-client is missing (run: make cred-forward)"; rc=1; fi
    for tool in gh claude codex; do
        if [ -x "$CRED_FORWARD_WRAPPERS/$tool" ]; then ok "credential wrapper $tool -> $CRED_FORWARD_WRAPPERS/$tool"
        else fail "credential wrapper $tool is missing (run: make cred-forward)"; rc=1; fi
    done
    if [ -f "$HOME/.config/cred-forward/github-accounts" ]; then ok "gh account map -> $HOME/.config/cred-forward/github-accounts"
    else warn "no gh account map; the gh wrapper uses the active local login for every repository"; fi
    disabled=$(client_disabled_tools)
    if [ -n "$disabled" ]; then warn "forwarding is off for: $disabled (devenv client on)"
    else ok "forwarding is on for gh, claude, and codex"; fi
    if git_credentials_use_cred_forward; then
        ok "HTTPS git credentials for github.com use the forwarded login"
    else fail "HTTPS git credentials for github.com do not use cred-forward (run: make cred-forward)"; rc=1; fi
    if sshd_policy_is_configured; then
        ok "SSH daemon policy supports safe credential socket replacement"
    else
        warn "SSH daemon policy is pending (run: sudo $DEVENV_HOME/cred-forward/install/configure-sshd.sh)"
    fi
fi

log "skills and tools"
if [ "$(os)" = windows ]; then
    if have codexmon; then
        check_tool codexmon codexmon version
    else
        warn "codexmon: not available for Windows"
    fi
else
    check_tool codexmon codexmon version
fi
check_tool code-cortex-mcp code-cortex-mcp --version   # NOT `version`: that starts the server
for s in codexmon code-cortex; do
    if [ -f "$CLAUDE_SKILLS/$s/SKILL.md" ]; then ok "skill $s -> $CLAUDE_SKILLS/$s"
    else fail "skill $s missing from $CLAUDE_SKILLS"; rc=1; fi
done
for d in "$DEVENV_HOME"/skills/*/; do
    d=${d%/}; s=$(basename "$d"); [ -f "$d/SKILL.md" ] || continue
    if [ "$(readlink "$CLAUDE_SKILLS/$s" 2>/dev/null)" = "$d" ]; then ok "skill $s -> $d"
    elif [ -f "$CLAUDE_SKILLS/$s/SKILL.md" ]; then warn "skill $s is a local copy, not linked to $d (FORCE=1 make skills)"
    else fail "skill $s missing from $CLAUDE_SKILLS (run: make skills)"; rc=1; fi
done
for agent_dir in "$HOME/.codex/skills" "$HOME/.agents/skills" "$HOME/.cursor/skills"; do
    missing=(); stale=()
    for d in "$CLAUDE_SKILLS"/*/; do
        d=${d%/}; [ -d "$d" ] || continue; n=$(basename "$d"); e="$agent_dir/$n"
        if [ ! -e "$e" ]; then missing+=("$n")
        elif [ "$(readlink "$e" 2>/dev/null)" != "$d" ] && [ "$(readlink -f "$e")" != "$(readlink -f "$d")" ]; then stale+=("$n"); fi
    done
    if [ ${#missing[@]} -eq 0 ] && [ ${#stale[@]} -eq 0 ]; then ok "$agent_dir has every skill"; fi
    [ ${#missing[@]} -gt 0 ] && warn "$agent_dir is missing: ${missing[*]}  (run: devenv sync-skills)"
    [ ${#stale[@]} -gt 0 ] && warn "$agent_dir has a local copy, not a link, of: ${stale[*]}  (FORCE=1 devenv sync-skills)"
done
if have claude; then
    if claude mcp get code-cortex-mcp >/dev/null 2>&1; then ok "claude mcp: code-cortex-mcp registered"
    else fail "claude mcp: code-cortex-mcp not registered (run: make skills)"; rc=1; fi
fi
if have codex; then
    if codex mcp get code-cortex-mcp >/dev/null 2>&1; then ok "codex mcp: code-cortex-mcp registered"
    else fail "codex mcp: code-cortex-mcp not registered (run: make skills)"; rc=1; fi
fi

PROFILE=$(profile_file)
LOGIN_PROFILE=$(additional_login_profile)
log "shell ($PROFILE)"
if grep -qF '# >>> devenv >>>' "$PROFILE" 2>/dev/null; then ok "devenv block present"
else fail "devenv block missing (run: make shell)"; rc=1; fi
check_aliases "$PROFILE" || rc=1
for d in "$LOCAL_BIN" "$DEVENV_HOME/scripts"; do
    case ":$DEVENV_CALLER_PATH:" in
        *":$d:"*) ok "PATH contains $d" ;;
        *) warn "PATH of this shell lacks $d (open a new terminal after make install)" ;;
    esac
done
if [ "$CRED_FORWARD_ROLE" = client ]; then
    for tool in gh claude codex; do
        resolved=$(profile_executable "$PROFILE" "$tool") || resolved=""
        if [ "$resolved" = "$CRED_FORWARD_WRAPPERS/$tool" ]; then
            ok "$tool resolves to its credential wrapper in the profile"
        else
            fail "$tool does not resolve to its credential wrapper in $PROFILE"
            rc=1
        fi
    done
    case ":$DEVENV_CALLER_PATH:" in
        *":$CRED_FORWARD_WRAPPERS:"*) ok "PATH contains $CRED_FORWARD_WRAPPERS" ;;
        *) warn "PATH of this shell lacks $CRED_FORWARD_WRAPPERS (open a new terminal after make install)" ;;
    esac
    if [ -n "$LOGIN_PROFILE" ] && [ "$LOGIN_PROFILE" != "$PROFILE" ]; then
        for tool in gh claude codex; do
            resolved=$(profile_executable "$LOGIN_PROFILE" "$tool") || resolved=""
            if [ "$resolved" = "$CRED_FORWARD_WRAPPERS/$tool" ]; then
                ok "$tool resolves to its credential wrapper in the login profile"
            else
                fail "$tool does not resolve to its credential wrapper in $LOGIN_PROFILE"
                rc=1
            fi
        done
    fi
fi

echo
if [ "$rc" -eq 0 ]; then
    ok "all checks passed"
else
    fail "some checks failed"
fi
set -e
return $rc
}
