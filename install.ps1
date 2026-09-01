# install.ps1 — Windows (native) equivalent of `make install`.
#   powershell -ExecutionPolicy Bypass -File install.ps1 [-Force]
[CmdletBinding()]
param([switch]$Force)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
& (Join-Path $PSScriptRoot 'dependencies\install.ps1') -Force:$Force
& (Join-Path $PSScriptRoot 'skills\install.ps1') -Force:$Force
& (Join-Path $PSScriptRoot 'shell\install.ps1')
Warn 'cred-forward skipped (macOS and Linux only)'
& (Join-Path $PSScriptRoot 'scripts\devenv-doctor.ps1')
