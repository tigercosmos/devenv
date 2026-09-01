# devenv-update.ps1 — upgrade every Windows tool devenv manages, then re-sync
# skills and report that cred-forward is not supported.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')
& (Join-Path $script:DevenvHome 'dependencies\install.ps1') -Force
& (Join-Path $script:DevenvHome 'skills\install.ps1') -Force
& (Join-Path $script:DevenvHome 'shell\install.ps1')
Warn 'cred-forward skipped (macOS and Linux only)'
