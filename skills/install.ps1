# skills/install.ps1 — Windows (native) installer for the AI skills and tools.
#   powershell -ExecutionPolicy Bypass -File skills\install.ps1 [-Force]
[CmdletBinding()]
param([switch]$Force)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

function Get-CodeCortexVersion {
    $command = Get-Command code-cortex-mcp -ErrorAction Stop
    $savedPath = $env:Path
    try {
        # Test the executable in isolation so a second installation directory
        # on PATH cannot accidentally supply runtime DLLs that are absent here.
        $env:Path = "$env:WINDIR\System32;$env:WINDIR"
        $output = & $command.Source --version 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }
        $output | Select-Object -First 1
    } finally {
        $env:Path = $savedPath
    }
}

# Some upstream Windows releases were linked against the MSYS2 Clang runtime
# but shipped only the executable. Repair those releases without burdening a
# future self-contained release: the fallback runs only when --version fails.
function Install-CodeCortexRuntime($dest) {
    if (-not (Have tar)) { throw 'code-cortex-mcp needs tar to install its missing Windows runtime libraries' }
    $packages = @(
        @{
            File = 'mingw-w64-clang-x86_64-libc++-22.1.8-1-any.pkg.tar.zst'
            Hash = 'de0bd1b9d62f81b6ac06ea915af8da3fbd63e6705e1bb62ef3f553d1e5fbe4ef'
            Dll = 'libc++.dll'
        },
        @{
            File = 'mingw-w64-clang-x86_64-libunwind-22.1.8-1-any.pkg.tar.zst'
            Hash = '1427583ab43306045b06df71e4a31686d5848bddabba628ea1b8068f38dbd5fd'
            Dll = 'libunwind.dll'
        },
        @{
            File = 'mingw-w64-clang-x86_64-libwinpthread-14.0.0.r283.ga7cb47123-1-any.pkg.tar.zst'
            Hash = '7f15091be34a9e4f06950a911a98005a1b7fb9b3d8069ee344ec407fa613ba9c'
            Dll = 'libwinpthread-1.dll'
        },
        @{
            File = 'mingw-w64-clang-x86_64-zlib-1.3.2-2-any.pkg.tar.zst'
            Hash = '96d8db2f2bf24c0d4e82b899d50a3497d97536a8bd38ce275401d0f2b9580b5e'
            Dll = 'zlib1.dll'
        }
    )
    $tmp = New-TempDir
    try {
        foreach ($package in $packages) {
            $archive = Join-Path $tmp $package.File
            Fetch "https://repo.msys2.org/mingw/clang64/$($package.File.Replace('+', '%2B'))" $archive
            $actual = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $package.Hash) { throw "checksum mismatch for $($package.File)" }
            tar -xf $archive -C $tmp "clang64/bin/$($package.Dll)"
            if ($LASTEXITCODE -ne 0) { throw "could not extract $($package.Dll)" }
            Copy-Item (Join-Path $tmp "clang64\bin\$($package.Dll)") $dest -Force
        }
    } finally {
        Remove-Item $tmp -Recurse -Force
    }
    Ok "installed code-cortex-mcp Windows runtime -> $dest"
}

function Repair-CodeCortexRuntime {
    $version = Get-CodeCortexVersion
    if ($version) { return $version }
    $command = Get-Command code-cortex-mcp -ErrorAction Stop
    Warn 'code-cortex-mcp is missing its upstream Windows runtime; installing it'
    Install-CodeCortexRuntime (Split-Path $command.Source)
    $version = Get-CodeCortexVersion
    if (-not $version) { throw 'code-cortex-mcp still cannot run after installing its Windows runtime' }
    $version
}

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
    Ok "already installed: $(Repair-CodeCortexRuntime)"
} elseif (Have code-cortex-mcp) {
    Repair-CodeCortexRuntime | Out-Null
    code-cortex-mcp update -y
    if ($LASTEXITCODE -ne 0) { throw 'code-cortex-mcp update failed' }
    Ok "$(Repair-CodeCortexRuntime)"
} else {
    $tmp = New-TempDir
    try {
        Fetch 'https://raw.githubusercontent.com/tigercosmos/code-cortex-mcp/main/install.ps1' (Join-Path $tmp 'install.ps1')
        & (Join-Path $tmp 'install.ps1') --skip-config
        if ($LASTEXITCODE -ne 0) { throw 'code-cortex-mcp installer failed' }
    } finally {
        Remove-Item $tmp -Recurse -Force
    }
    Refresh-Path
    Ok "$(Repair-CodeCortexRuntime)"
}
# The upstream configurator installs hooks and the shared skill. Run it only
# when that shared setup is missing; an unconditional run can start duplicate
# background indexers.
if (-not (Test-Path (Join-Path $script:ClaudeSkills 'code-cortex\SKILL.md'))) {
    try {
        $runtimeSource = Split-Path (Get-Command code-cortex-mcp).Source
        code-cortex-mcp install -y
        if ($LASTEXITCODE -ne 0) {
            Warn 'code-cortex-mcp install failed; run it by hand to configure your agents'
        } else {
            # The configurator copies its executable into LocalBin but current
            # affected releases do not copy their adjacent runtime libraries.
            foreach ($dll in @('libc++.dll', 'libunwind.dll', 'libwinpthread-1.dll', 'zlib1.dll')) {
                $source = Join-Path $runtimeSource $dll
                if (Test-Path $source) { Copy-Item $source $script:LocalBin -Force }
            }
            Refresh-Path
            Repair-CodeCortexRuntime | Out-Null
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
        if (-not $Force) { Warn "${name}: $dest exists and is not our link; -Force to replace (the old copy is kept in .devenv-backup)"; return }
        if ($item.LinkType) { $item.Delete() }
        else {
            $bak = Join-Path $script:ClaudeSkills ".devenv-backup\$name-$(Get-Date -Format yyyyMMddHHmmss)"
            New-Item -ItemType Directory -Force -Path (Split-Path $bak) | Out-Null
            Move-Item $dest $bak; Warn "${name}: moved the previous copy to $bak"
        }
    }
    try { New-Item -ItemType SymbolicLink -Path $dest -Target $src | Out-Null }
    catch { New-Item -ItemType Junction -Path $dest -Target $src | Out-Null }
    Ok "linked $dest -> $src"
}

Log 'sync skills to every agent'
& (Join-Path $script:DevenvHome 'scripts\devenv-sync-skills.ps1') -Force:$Force
