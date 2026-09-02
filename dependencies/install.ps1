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
        winget install --id GitHub.cli -e --accept-source-agreements --accept-package-agreements --silent
        if ($LASTEXITCODE -ne 0 -and $Force) { winget upgrade --id GitHub.cli -e --silent }
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

function Install-Codex {
    Log 'codex (OpenAI Codex CLI)'
    if ((Have codex) -and -not $Force) { Ok "already installed: $(codex --version)"; return }
    $arch = if ((Get-Arch) -eq 'arm64') { 'aarch64' } else { 'x86_64' }
    $tmp = New-TempDir
    # codex-code-mode-host is a separate release asset that codex expects
    # next to itself (plugin management, "code mode").
    foreach ($name in 'codex', 'codex-code-mode-host') {
        $dir = Join-Path $tmp $name
        Fetch "https://github.com/openai/codex/releases/latest/download/$name-$arch-pc-windows-msvc.exe.zip" "$dir.zip"
        Expand-Archive "$dir.zip" -DestinationPath $dir -Force
        Install-Bin (Get-ChildItem $dir -Filter '*.exe' | Select-Object -First 1).FullName "$name.exe"
    }
    Remove-Item $tmp -Recurse -Force
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
