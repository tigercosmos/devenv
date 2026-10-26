# dependencies/install.ps1 — Windows (native) installer for gh, codex, claude,
# and the cursor agent. Run from PowerShell:
#   powershell -ExecutionPolicy Bypass -File dependencies\install.ps1 [-Force] [-Only gh,codex]
[CmdletBinding()]
param(
    [switch]$Force,
    [string[]]$Only = @('gh', 'codex', 'claude', 'cursor')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

function Install-Gh {
    Log 'gh (GitHub CLI)'
    if ((Have gh) -and -not $Force) { Ok "already installed: $((gh --version)[0])"; return }
    if (Have winget) {
        if (Have gh) { winget upgrade --id GitHub.cli -e --silent }
        else { winget install --id GitHub.cli -e --accept-source-agreements --accept-package-agreements --silent }
    } else {
        # Fall back to the release zip in ~\.local\bin
        $tag = Get-LatestTag 'cli/cli'; $ver = $tag.TrimStart('v')
        $asset = "gh_${ver}_windows_$(Get-Arch).zip"
        $tmp = New-TempDir
        Fetch "https://github.com/cli/cli/releases/download/$tag/$asset" (Join-Path $tmp $asset)
        Expand-Archive (Join-Path $tmp $asset) -DestinationPath $tmp -Force
        Install-Bin (Join-Path $tmp 'bin\gh.exe') 'gh.exe'
        Remove-Item $tmp -Recurse -Force
    }
    Refresh-Path
    Ok "$((gh --version)[0])"
}

# Codex now runs only from its "package" layout (codex.exe plus rg.exe, the
# sandbox helpers, and codex-resources); a bare release binary refuses to
# start with "this CLI has no complete local package". The official installer
# puts the package under %LOCALAPPDATA%\Programs\OpenAI\Codex and adds its
# bin to the user PATH.
function Invoke-CodexInstaller {
    $tmp = New-TempDir
    $script = Join-Path $tmp 'install.ps1'
    Fetch 'https://github.com/openai/codex/releases/latest/download/install.ps1' $script
    # A separate process keeps the installer's StrictMode out of this session.
    $env:CODEX_NON_INTERACTIVE = '1'
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $script
        if ($LASTEXITCODE -ne 0) { throw "the Codex installer exited with $LASTEXITCODE" }
    } finally {
        Remove-Item Env:CODEX_NON_INTERACTIVE -ErrorAction SilentlyContinue
        Remove-Item $tmp -Recurse -Force
    }
}

function Install-Codex {
    Log 'codex (OpenAI Codex CLI)'
    # An earlier devenv copied bare binaries into ~\.local\bin, where they
    # shadow the packaged install; they are devenv's own copies, so drop them.
    $legacy = (Have codex) -and ((Get-Command codex).Source -eq (Join-Path $script:LocalBin 'codex.exe'))
    if ((Have codex) -and -not $legacy -and -not $Force) { Ok "already installed: $(codex --version)"; return }
    if ($legacy) {
        Warn "$(Join-Path $script:LocalBin 'codex.exe') is a bare binary without its package; reinstalling"
        foreach ($name in 'codex.exe', 'codex-code-mode-host.exe', 'codex-command-runner.exe', 'codex-windows-sandbox-setup.exe') {
            Remove-Item (Join-Path $script:LocalBin $name) -Force -ErrorAction SilentlyContinue
        }
    }
    Invoke-CodexInstaller
    Refresh-Path
    Ok "$(codex --version)"
}

function Install-Claude {
    Log 'claude (Claude Code)'
    if ((Have claude) -and -not $Force) { Ok "already installed: $(claude --version)"; return }
    if (Have claude) {
        claude update
    } else {
        # Native installer -> ~\.local\bin\claude.exe
        Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
    }
    Refresh-Path
    Ok "$(claude --version)"
}

function Install-Cursor {
    Log 'agent (Cursor CLI)'
    if ((Have agent) -and -not $Force) { Ok "already installed: $(agent --version)"; return }
    Invoke-RestMethod 'https://cursor.com/install?win32=true' | Invoke-Expression
    Refresh-Path
    Ok "$(agent --version)"
}

foreach ($t in $Only) {
    switch ($t) {
        'gh'     { Install-Gh }
        'codex'  { Install-Codex }
        'claude' { Install-Claude }
        { $_ -in 'cursor', 'agent' } { Install-Cursor }
        default  { throw "unknown tool: $t (expected gh, codex, claude, cursor)" }
    }
}
