# skills/install.ps1 — Windows (native) installer for the AI skills and tools.
#   powershell -ExecutionPolicy Bypass -File skills\install.ps1 [-Force]
[CmdletBinding()]
param([switch]$Force)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

# ---- codexmon (no Windows release; build with Go when available) ----------
Log 'codexmon'
if ((Have codexmon) -and -not $Force) {
    Ok "already installed: $(codexmon version)"
} elseif (Have go) {
    $env:GOBIN = $script:LocalBin
    go install github.com/tigercosmos/codexmon/cmd/codexmon@latest
    Refresh-Path
    Ok "$(codexmon version)"
} else {
    Warn 'codexmon ships prebuilt binaries for macOS/Linux only; install Go (winget install GoLang.Go) and rerun to build it'
}
$skill = Join-Path $script:ClaudeSkills 'codexmon'
if ((Test-Path (Join-Path $skill 'SKILL.md')) -and -not $Force) {
    Ok "skill present: $skill"
} else {
    New-Item -ItemType Directory -Force -Path $skill | Out-Null
    Fetch 'https://raw.githubusercontent.com/tigercosmos/codexmon/main/skills/codexmon/SKILL.md' (Join-Path $skill 'SKILL.md')
    Ok "installed skill -> $skill"
}

# ---- code-cortex-mcp ------------------------------------------------------
Log 'code-cortex-mcp'
if ((Have code-cortex-mcp) -and -not $Force) {
    Ok "already installed: $(code-cortex-mcp --version 2>&1)"
} elseif (Have code-cortex-mcp) {
    code-cortex-mcp update
    Ok "$(code-cortex-mcp --version 2>&1)"
} else {
    $tmp = New-TempDir
    Fetch 'https://raw.githubusercontent.com/tigercosmos/code-cortex-mcp/main/install.ps1' (Join-Path $tmp 'install.ps1')
    & (Join-Path $tmp 'install.ps1')
    Remove-Item $tmp -Recurse -Force
    Refresh-Path
    Ok "$(code-cortex-mcp --version 2>&1)"
}
if (-not (Test-Path (Join-Path $script:ClaudeSkills 'code-cortex\SKILL.md'))) {
    code-cortex-mcp install
}
if (Test-Path (Join-Path $script:ClaudeSkills 'code-cortex\SKILL.md')) {
    Ok "skill present: $(Join-Path $script:ClaudeSkills 'code-cortex')"
} else {
    Warn "skill not found at $(Join-Path $script:ClaudeSkills 'code-cortex')"
}

Log 'sync skills to every agent'
& (Join-Path $script:DevenvHome 'scripts\devenv-sync-skills.ps1')
