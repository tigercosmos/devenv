# install.ps1 — Windows (native) equivalent of `make install`.
#   powershell -ExecutionPolicy Bypass -File install.ps1 [-Force]
[CmdletBinding()]
param([switch]$Force)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'dependencies\install.ps1') -Force:$Force
& (Join-Path $PSScriptRoot 'skills\install.ps1') -Force:$Force
& (Join-Path $PSScriptRoot 'shell\install.ps1')
& (Join-Path $PSScriptRoot 'scripts\devenv-doctor.ps1')
