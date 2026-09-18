# devenv-update.ps1 — kept for existing habits; the command is `devenv update`.
& (Join-Path $PSScriptRoot 'devenv.ps1') update @args
exit $LASTEXITCODE
