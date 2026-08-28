#!/usr/bin/env bash
# dependencies/install.sh — install gh, codex, claude, and the cursor agent
# into the user's home (~/.local/bin, or the platform package manager).
#
#   bash dependencies/install.sh            # install what is missing
#   FORCE=1 bash dependencies/install.sh    # reinstall / upgrade everything
#   bash dependencies/install.sh gh codex   # only the named tools
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

OS=$(os); ARCH=$(arch)

# ---- gh -------------------------------------------------------------------
gh_from_release() {
    local ver asset
    ver=$(latest_tag cli/cli); ver="${ver#v}"
    [ -n "$ver" ] || die "could not resolve the latest gh release"
    mktmp
    case "$OS" in
        macos)
            asset="gh_${ver}_macOS_${ARCH}.zip"
            fetch "https://github.com/cli/cli/releases/download/v${ver}/${asset}" "$TMPD/$asset"
            unzip -q "$TMPD/$asset" -d "$TMPD" ;;
        linux)
            asset="gh_${ver}_linux_${ARCH}.tar.gz"
            fetch "https://github.com/cli/cli/releases/download/v${ver}/${asset}" "$TMPD/$asset"
            tar -xzf "$TMPD/$asset" -C "$TMPD" ;;
        *) die "gh: use dependencies/install.ps1 on Windows" ;;
    esac
    install_bin "$TMPD"/gh_*/bin/gh gh
}

install_gh() {
    log "gh (GitHub CLI)"
    if have gh && [ "$FORCE" != 1 ]; then ok "already installed: $(gh --version | head -1)"; return; fi
    if [ "$OS" = macos ] && have brew; then
        if brew list gh >/dev/null 2>&1; then brew upgrade gh || true; else brew install gh; fi
    else
        gh_from_release
    fi
    ok "$(gh --version | head -1)"
}

# ---- codex ----------------------------------------------------------------
codex_from_release() {
    local triple
    case "$ARCH" in arm64) triple=aarch64 ;; amd64) triple=x86_64 ;; esac
    case "$OS" in
        macos) triple="${triple}-apple-darwin" ;;
        linux) triple="${triple}-unknown-linux-musl" ;;
        *) die "codex: use dependencies/install.ps1 on Windows" ;;
    esac
    mktmp
    # The release ships helper binaries as separate assets. codex looks for
    # codex-code-mode-host next to itself (plugin management, "code mode");
    # without it `codex` reports the executable as missing.
    local name
    for name in codex codex-code-mode-host; do
        fetch "https://github.com/openai/codex/releases/latest/download/${name}-${triple}.tar.gz" "$TMPD/$name.tar.gz"
        tar -xzf "$TMPD/$name.tar.gz" -C "$TMPD"
        install_bin "$TMPD/${name}-${triple}" "$name"
    done
}

install_codex() {
    log "codex (OpenAI Codex CLI)"
    if have codex && [ "$FORCE" != 1 ]; then
        ok "already installed: $(codex --version 2>/dev/null | head -1)"
        # A release install from an earlier devenv lacks the helper; add it.
        if [ "$(command -v codex)" = "$LOCAL_BIN/codex" ] && [ ! -x "$LOCAL_BIN/codex-code-mode-host" ]; then
            warn "codex-code-mode-host is missing next to $LOCAL_BIN/codex; installing"
            codex_from_release
        fi
        return
    fi
    if have npm; then
        npm install -g @openai/codex@latest
    elif [ "$OS" = macos ] && have brew; then
        if brew list codex >/dev/null 2>&1; then brew upgrade codex || true; else brew install codex; fi
    else
        codex_from_release
    fi
    ok "$(codex --version 2>/dev/null | head -1)"
}

# ---- claude ---------------------------------------------------------------
install_claude() {
    log "claude (Claude Code)"
    if have claude && [ "$FORCE" != 1 ]; then ok "already installed: $(claude --version 2>/dev/null | head -1)"; return; fi
    if have claude; then
        claude update || fetch_stdout https://claude.ai/install.sh | bash
    else
        # Native installer: binary -> ~/.local/bin/claude, versions -> ~/.local/share/claude
        fetch_stdout https://claude.ai/install.sh | bash
    fi
    ok "$(claude --version 2>/dev/null | head -1)"
}

# ---- cursor agent ---------------------------------------------------------
install_cursor() {
    log "agent (Cursor CLI)"
    if have agent && have cursor-agent && [ "$FORCE" != 1 ]; then
        ok "already installed: $(agent --version 2>/dev/null | head -1)"; return
    fi
    # Official installer: ~/.local/share/cursor-agent + symlinks ~/.local/bin/{agent,cursor-agent}
    fetch_stdout https://cursor.com/install | bash
    ok "$(agent --version 2>/dev/null | head -1)"
}

# ---------------------------------------------------------------------------
[ "$OS" = windows ] && die "on Windows run: powershell -ExecutionPolicy Bypass -File dependencies/install.ps1"
have curl || have wget || die "curl or wget is required"

tools=("$@"); [ ${#tools[@]} -gt 0 ] || tools=(gh codex claude cursor)
for t in "${tools[@]}"; do
    case "$t" in
        gh)     install_gh ;;
        codex)  install_codex ;;
        claude) install_claude ;;
        cursor|agent) install_cursor ;;
        *) die "unknown tool: $t (expected gh, codex, claude, cursor)" ;;
    esac
done
