# devenv-doctor.ps1 — kept for existing habits; the command is `devenv doctor`.
& (Join-Path $PSScriptRoot 'devenv.ps1') doctor @args
exit $LASTEXITCODE
