#!/usr/bin/env bash
# skills/install.sh — install the AI skills and tools:
#   * codexmon         https://github.com/tigercosmos/codexmon
#   * code-cortex-mcp  https://github.com/tigercosmos/code-cortex-mcp
#   * every skill kept in this repository (skills/<name>/SKILL.md)
# Binaries go to ~/.local/bin, skills to ~/.claude/skills (the repository's
# skills as symlinks, so `git pull` updates them), and every skill is linked
# into the other agents' skill directories (codex, cursor, ~/.agents).
#
#   bash skills/install.sh            # install what is missing
#   FORCE=1 bash skills/install.sh    # reinstall / upgrade
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

OS=$(os); ARCH=$(arch)

# ---- codexmon -------------------------------------------------------------
install_codexmon() {
    log "codexmon"
    if [ "$OS" = windows ]; then warn "codexmon supports macOS and Linux only; skipping"; return; fi
    if have codexmon && [ "$FORCE" != 1 ]; then
        ok "already installed: $(codexmon version 2>/dev/null | head -1)"
    else
        local tag ver goos asset
        tag=$(latest_tag tigercosmos/codexmon); ver="${tag#v}"
        [ -n "$ver" ] || die "could not resolve the latest codexmon release"
        case "$OS" in macos) goos=darwin ;; linux) goos=linux ;; esac
        asset="codexmon_${ver}_${goos}_${ARCH}.tar.gz"
        mktmp
        fetch "https://github.com/tigercosmos/codexmon/releases/download/${tag}/${asset}" "$TMPD/$asset"
        tar -xzf "$TMPD/$asset" -C "$TMPD" codexmon
        install_bin "$TMPD/codexmon" codexmon
        ok "$(codexmon version 2>/dev/null | head -1)"
    fi

    # Agent skill (the same file `make install` in the codexmon repo drops in place).
    local skill_dir="$CLAUDE_SKILLS/codexmon"
    if [ -f "$skill_dir/SKILL.md" ] && [ "$FORCE" != 1 ]; then
        ok "skill present: $skill_dir"
    else
        mkdir -p "$skill_dir"
        fetch "https://raw.githubusercontent.com/tigercosmos/codexmon/main/skills/codexmon/SKILL.md" "$skill_dir/SKILL.md"
        ok "installed skill -> $skill_dir"
    fi
}

# ---- code-cortex-mcp ------------------------------------------------------
install_code_cortex() {
    log "code-cortex-mcp"
    if have code-cortex-mcp && [ "$FORCE" != 1 ]; then
        ok "already installed: $(code-cortex-mcp --version 2>&1 | head -1)"
    elif have code-cortex-mcp; then
        # Self-update keeps the build the user has (release binary updates in place).
        code-cortex-mcp update || fetch_stdout https://raw.githubusercontent.com/tigercosmos/code-cortex-mcp/main/install.sh | bash -s -- --dir "$LOCAL_BIN"
        ok "$(code-cortex-mcp --version 2>&1 | head -1)"
    else
        # The official installer puts the binary in ~/.local/bin and configures
        # Claude Code, Codex, Cursor, and other MCP clients (server entry,
        # instruction files, pre-tool hooks).
        fetch_stdout https://raw.githubusercontent.com/tigercosmos/code-cortex-mcp/main/install.sh | bash -s -- --dir "$LOCAL_BIN"
        ok "$(code-cortex-mcp --version 2>&1 | head -1)"
    fi

    # The upstream configurator installs hooks and the shared skill. Run it
    # only when that shared setup is missing; an unconditional run can start
    # duplicate background indexers.
    if [ ! -f "$CLAUDE_SKILLS/code-cortex/SKILL.md" ]; then
        code-cortex-mcp install \
            || warn "code-cortex-mcp install failed; run it by hand to configure your agents"
    else
        ok "shared agent configuration present"
    fi

    # A fresh agent home can escape the upstream auto-detection. Register each
    # installed CLI explicitly and idempotently instead of rerunning the full
    # configurator.
    if have claude && ! claude mcp get code-cortex-mcp >/dev/null 2>&1; then
        claude mcp add --scope user code-cortex-mcp -- "$LOCAL_BIN/code-cortex-mcp" \
            >/dev/null \
            || warn "could not register code-cortex-mcp with Claude"
    fi
    if have codex && ! codex mcp get code-cortex-mcp >/dev/null 2>&1; then
        codex mcp add code-cortex-mcp -- "$LOCAL_BIN/code-cortex-mcp" \
            >/dev/null \
            || warn "could not register code-cortex-mcp with Codex"
    fi
    if [ -f "$CLAUDE_SKILLS/code-cortex/SKILL.md" ]; then
        ok "skill present: $CLAUDE_SKILLS/code-cortex"
    else
        warn "skill not found at $CLAUDE_SKILLS/code-cortex"
    fi
}

# ---- skills kept in this repository -------------------------------------
# ~/.claude/skills/<name> -> $DEVENV_HOME/skills/<name>. A directory that is
# already there and is not our link is left alone unless FORCE=1, in which
# case it is moved to ~/.claude/skills/.devenv-backup/ first, never deleted.
install_repo_skills() {
    log "repository skills ($DEVENV_HOME/skills)"
    mkdir -p "$CLAUDE_SKILLS"
    local src name dest current
    for src in "$DEVENV_HOME"/skills/*/; do
        src=${src%/}; name=$(basename "$src")
        [ -f "$src/SKILL.md" ] || continue
        dest="$CLAUDE_SKILLS/$name"
        if [ -L "$dest" ]; then
            current=$(readlink "$dest")
            if [ "$current" = "$src" ]; then ok "$name linked"; continue; fi
            if [ "$FORCE" != 1 ]; then
                warn "$name: $dest -> $current is not ours; FORCE=1 to relink"; continue
            fi
            rm -f "$dest"
        elif [ -e "$dest" ]; then
            if [ "$FORCE" != 1 ]; then
                warn "$name: $dest exists and is not a link; FORCE=1 to replace (the old copy is kept in .devenv-backup)"; continue
            fi
            local bak
            bak="$CLAUDE_SKILLS/.devenv-backup/$name-$(date +%Y%m%d%H%M%S)"
            mkdir -p "$(dirname "$bak")"; mv "$dest" "$bak"
            warn "$name: moved the previous copy to $bak"
        fi
        ln -s "$src" "$dest"
        ok "linked $dest -> $src"
    done
}

install_codexmon
install_code_cortex
install_repo_skills

log "sync skills to every agent"
"$DEVENV_HOME/scripts/devenv-sync-skills"
