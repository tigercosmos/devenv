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
Check-Tool claude { claude --version }
Check-Tool agent  { agent --version }

Log 'skills and tools'
if (Have codexmon) { Check-Tool codexmon { codexmon version } } else { Warn 'codexmon: not installed (needs Go on Windows)' }
Check-Tool code-cortex-mcp { code-cortex-mcp --version 2>&1 }   # NOT `version`: that starts the server
foreach ($s in 'codexmon', 'code-cortex') {
    $p = Join-Path $script:ClaudeSkills "$s\SKILL.md"
    if (Test-Path $p) { Ok "skill $s -> $(Split-Path $p)" } else { Fail "skill $s missing from $script:ClaudeSkills"; $rc = 1 }
}
foreach ($dir in @((Join-Path $HOME '.codex\skills'), (Join-Path $HOME '.agents\skills'), (Join-Path $HOME '.cursor\skills'))) {
    $missing = Get-ChildItem $script:ClaudeSkills -Directory | Where-Object { -not (Test-Path (Join-Path $dir $_.Name)) } | ForEach-Object Name
    if ($missing) { Warn "$dir is missing: $($missing -join ', ')  (run devenv-sync-skills.ps1)" } else { Ok "$dir has every skill" }
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
