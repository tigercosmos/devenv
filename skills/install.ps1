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
# The upstream configurator installs hooks and the shared skill. Run it only
# when that shared setup is missing; an unconditional run can start duplicate
# background indexers.
if (-not (Test-Path (Join-Path $script:ClaudeSkills 'code-cortex\SKILL.md'))) {
    try {
        code-cortex-mcp install
        if ($LASTEXITCODE -ne 0) {
            Warn 'code-cortex-mcp install failed; run it by hand to configure your agents'
        }
    } catch {
        Warn 'code-cortex-mcp install failed; run it by hand to configure your agents'
    }
} else {
    Ok 'shared agent configuration present'
}

# A fresh agent home can escape the upstream auto-detection. Register each
# installed CLI explicitly and idempotently instead of rerunning the complete
# configurator.
foreach ($agent in @('claude', 'codex')) {
    if (-not (Have $agent)) { continue }
    $registered = $false
    try {
        & $agent mcp get code-cortex-mcp *> $null
        $registered = ($LASTEXITCODE -eq 0)
    } catch {}
    if (-not $registered) {
        try {
            if ($agent -eq 'claude') {
                & $agent mcp add --scope user code-cortex-mcp -- (Join-Path $script:LocalBin 'code-cortex-mcp') *> $null
            } else {
                & $agent mcp add code-cortex-mcp -- (Join-Path $script:LocalBin 'code-cortex-mcp') *> $null
            }
            if ($LASTEXITCODE -ne 0) { Warn "could not register code-cortex-mcp with $agent" }
        } catch {
            Warn "could not register code-cortex-mcp with $agent"
        }
    }
}
if (Test-Path (Join-Path $script:ClaudeSkills 'code-cortex\SKILL.md')) {
    Ok "skill present: $(Join-Path $script:ClaudeSkills 'code-cortex')"
} else {
    Warn "skill not found at $(Join-Path $script:ClaudeSkills 'code-cortex')"
}

# ---- skills kept in this repository -------------------------------------
# ~\.claude\skills\<name> -> $DevenvHome\skills\<name> (symlink, or a junction
# when symlinks need elevation). An existing directory that is not our link is
# left alone unless -Force, which moves it to .devenv-backup first.
Log "repository skills ($(Join-Path $script:DevenvHome 'skills'))"
New-Item -ItemType Directory -Force -Path $script:ClaudeSkills | Out-Null
Get-ChildItem (Join-Path $script:DevenvHome 'skills') -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') } | ForEach-Object {
    $name = $_.Name; $src = $_.FullName; $dest = Join-Path $script:ClaudeSkills $name
    if (Test-Path $dest) {
        $item = Get-Item $dest -Force
        if ($item.LinkType -and ($item.Target -contains $src)) { Ok "$name linked"; return }
        if (-not $Force) { Warn "$name: $dest exists and is not our link; -Force to replace (the old copy is kept in .devenv-backup)"; return }
        if ($item.LinkType) { $item.Delete() }
        else {
            $bak = Join-Path $script:ClaudeSkills ".devenv-backup\$name-$(Get-Date -Format yyyyMMddHHmmss)"
            New-Item -ItemType Directory -Force -Path (Split-Path $bak) | Out-Null
            Move-Item $dest $bak; Warn "$name: moved the previous copy to $bak"
        }
    }
    try { New-Item -ItemType SymbolicLink -Path $dest -Target $src | Out-Null }
    catch { New-Item -ItemType Junction -Path $dest -Target $src | Out-Null }
    Ok "linked $dest -> $src"
}

Log 'sync skills to every agent'
& (Join-Path $script:DevenvHome 'scripts\devenv-sync-skills.ps1') -Force:$Force
