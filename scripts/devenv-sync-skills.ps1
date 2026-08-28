# devenv-sync-skills.ps1 — link every skill under ~\.claude\skills into the
# other agents' skill directories (codex, ~\.agents, cursor). An entry that is
# not our link is left alone unless -Force (a real directory is backed up first).
[CmdletBinding()]
param([switch]$Force)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')
if (-not (Test-Path $script:ClaudeSkills)) { throw "$script:ClaudeSkills does not exist" }
foreach ($t in @((Join-Path $HOME '.codex\skills'), (Join-Path $HOME '.agents\skills'), (Join-Path $HOME '.cursor\skills'))) {
    Sync-Skills $t -Force:$Force
    Ok "$t up to date"
}
