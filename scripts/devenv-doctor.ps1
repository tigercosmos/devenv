# devenv-doctor.ps1 — report the state of the devenv environment on Windows.
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')
$rc = 0

function Check-Tool($name, [scriptblock]$version) {
    if (Have $name) { Ok "$name  $(& $version 2>&1 | Select-Object -First 1)  ($((Get-Command $name).Source))" }
    else { Fail "$name is not installed"; $script:rc = 1 }
}

Log 'dependencies'
Check-Tool gh     { gh --version }
Check-Tool codex  { codex --version }
if ((Have codex) -and ((Get-Command codex).Source -eq (Join-Path $script:LocalBin 'codex.exe'))) {
    $h = Join-Path $script:LocalBin 'codex-code-mode-host.exe'
    if (Test-Path $h) { Ok "codex-code-mode-host  ($h)" } else { Fail "codex-code-mode-host missing next to codex.exe (run: dependencies\install.ps1 codex)"; $script:rc = 1 }
}
Check-Tool claude { claude --version }
Check-Tool agent  { agent --version }

Log 'skills and tools'
if (Have codexmon) { Check-Tool codexmon { codexmon version } } else { Warn 'codexmon: not installed (needs Go on Windows)' }
Check-Tool code-cortex-mcp { code-cortex-mcp --version 2>&1 }   # NOT `version`: that starts the server
foreach ($s in 'codexmon', 'code-cortex') {
    $p = Join-Path $script:ClaudeSkills "$s\SKILL.md"
    if (Test-Path $p) { Ok "skill $s -> $(Split-Path $p)" } else { Fail "skill $s missing from $script:ClaudeSkills"; $rc = 1 }
}
Get-ChildItem (Join-Path $script:DevenvHome 'skills') -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') } | ForEach-Object {
    $dest = Join-Path $script:ClaudeSkills $_.Name
    if ((Test-Path $dest) -and (Get-Item $dest -Force).LinkType -and ((Get-Item $dest -Force).Target -contains $_.FullName)) { Ok "skill $($_.Name) -> $($_.FullName)" }
    elseif (Test-Path (Join-Path $dest 'SKILL.md')) { Warn "skill $($_.Name) is a local copy, not linked to $($_.FullName) (skills\install.ps1 -Force)" }
    else { Fail "skill $($_.Name) missing from $script:ClaudeSkills (run: skills\install.ps1)"; $script:rc = 1 }
}
foreach ($dir in @((Join-Path $HOME '.codex\skills'), (Join-Path $HOME '.agents\skills'), (Join-Path $HOME '.cursor\skills'))) {
    $missing = @(); $stale = @()
    Get-ChildItem $script:ClaudeSkills -Directory | ForEach-Object {
        $e = Join-Path $dir $_.Name
        if (-not (Test-Path $e)) { $missing += $_.Name }
        else { $i = Get-Item $e -Force; if (-not ($i.LinkType -and ($i.Target -contains $_.FullName))) { $stale += $_.Name } }
    }
    if (-not $missing -and -not $stale) { Ok "$dir has every skill" }
    if ($missing) { Warn "$dir is missing: $($missing -join ', ')  (run devenv-sync-skills.ps1)" }
    if ($stale) { Warn "$dir has a local copy, not a link, of: $($stale -join ', ')  (devenv-sync-skills.ps1 -Force)" }
}
foreach ($agent in @('claude', 'codex')) {
    if (-not (Have $agent)) { continue }
    try {
        & $agent mcp get code-cortex-mcp *> $null
        if ($LASTEXITCODE -eq 0) { Ok "$agent mcp: code-cortex-mcp registered" }
        else { Fail "$agent mcp: code-cortex-mcp not registered (run: make skills)"; $rc = 1 }
    } catch {
        Fail "$agent mcp: code-cortex-mcp not registered (run: make skills)"
        $rc = 1
    }
}

Log "shell ($PROFILE)"
if ((Test-Path $PROFILE) -and (Get-Content $PROFILE -Raw).Contains('# >>> devenv >>>')) { Ok 'devenv block present' }
else { Fail 'devenv block missing (run: shell\install.ps1)'; $rc = 1 }
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User') -split ';'
foreach ($d in @($script:LocalBin, (Join-Path $script:DevenvHome 'scripts'))) {
    if ($userPath -contains $d) { Ok "user PATH contains $d" } else { Fail "user PATH is missing $d"; $rc = 1 }
}

Write-Host ''
if ($rc -eq 0) { Ok 'all checks passed' } else { Fail 'some checks failed' }
exit $rc
