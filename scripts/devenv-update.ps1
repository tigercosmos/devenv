# devenv-update.ps1 — upgrade every tool devenv manages, then re-sync skills
# and re-check the PowerShell profile.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')
& (Join-Path $script:DevenvHome 'dependencies\install.ps1') -Force
& (Join-Path $script:DevenvHome 'skills\install.ps1') -Force
& (Join-Path $script:DevenvHome 'shell\install.ps1')
