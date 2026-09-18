# devenv-sync-skills.ps1 — kept for existing habits; the command is `devenv sync-skills`.
[CmdletBinding()]
param([switch]$Force)
& (Join-Path $PSScriptRoot 'devenv.ps1') sync-skills -Force:$Force
exit $LASTEXITCODE
