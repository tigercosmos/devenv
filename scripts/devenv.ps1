# devenv.ps1 — manage the devenv environment on Windows.
#
#   devenv doctor              report what is installed and what is missing
#   devenv update [TOOL...]    pull this repository, upgrade every tool (or the named ones), re-sync
#   devenv sync-skills [-Force] link every skill into the other agents
#   devenv status              repository and role summary
#
# Credential forwarding (devenv client, devenv server, devenv gh) runs on
# macOS and Linux only; those subcommands report that here.
#
# Visual Studio also ships a devenv.exe. When both are on PATH, call this
# script as devenv.ps1 or put $DEVENV_HOME\scripts first.
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [switch]$Force,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

function Show-Usage {
    Get-Content $PSCommandPath | Select-Object -Skip 1 -First 9 | ForEach-Object { $_ -replace '^# ?', '' }
}

function Update-Devenv([string[]]$Tools) {
    Log 'devenv repository'
    if (Test-Path (Join-Path $script:DevenvHome '.git')) {
        $dirty = git -C $script:DevenvHome status --porcelain --untracked-files=no
        if ($dirty) { Warn "uncommitted changes in $script:DevenvHome; not pulling" }
        else {
            git -C $script:DevenvHome pull --ff-only
            if ($LASTEXITCODE -eq 0) { Ok 'repository is up to date' } else { Warn 'git pull failed; continuing with the current checkout' }
        }
    } else { Warn "$script:DevenvHome is not a git checkout; not pulling" }
    if ($Tools) {
        & (Join-Path $script:DevenvHome 'dependencies\install.ps1') -Force -Only $Tools
        return
    }
    & (Join-Path $script:DevenvHome 'dependencies\install.ps1') -Force
    & (Join-Path $script:DevenvHome 'skills\install.ps1') -Force
    & (Join-Path $script:DevenvHome 'shell\install.ps1')
    Warn 'cred-forward skipped (macOS and Linux only)'
}

function Sync-AllSkills {
    if (-not (Test-Path $script:ClaudeSkills)) { throw "$script:ClaudeSkills does not exist" }
    foreach ($t in @((Join-Path $HOME '.codex\skills'), (Join-Path $HOME '.agents\skills'), (Join-Path $HOME '.cursor\skills'))) {
        Sync-Skills $t -Force:$Force
        Ok "$t up to date"
    }
}

function Show-Status {
    $rev = try { git -C $script:DevenvHome log -1 --format='%h %s' 2>$null } catch { 'not a git checkout' }
    Log 'devenv'
    Ok "repository $script:DevenvHome ($rev)"
    Ok 'cred-forward role: not supported on Windows'
}

switch ($Command) {
    'doctor' {
        $ErrorActionPreference = 'Continue'
        . (Join-Path $script:DevenvHome 'lib\doctor.ps1')
        exit $rc
    }
    'update' { Update-Devenv $Rest }
    'sync-skills' { Sync-AllSkills }
    'status' { Show-Status }
    { $_ -in 'client', 'server', 'gh' } {
        Fail "devenv $Command is not supported on Windows; credential forwarding runs on macOS and Linux"
        exit 1
    }
    { $_ -in 'help', '-h', '--help' } { Show-Usage }
    default { Show-Usage; Fail "unknown command: $Command"; exit 1 }
}
