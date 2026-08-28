# devenv-sync-skills.ps1 — link every skill under ~\.claude\skills into the
# other agents' skill directories (codex, ~\.agents, cursor). Existing entries are never touched.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')
if (-not (Test-Path $script:ClaudeSkills)) { throw "$script:ClaudeSkills does not exist" }
foreach ($t in @((Join-Path $HOME '.codex\skills'), (Join-Path $HOME '.agents\skills'), (Join-Path $HOME '.cursor\skills'))) {
    Sync-Skills $t
    Ok "$t up to date"
}
