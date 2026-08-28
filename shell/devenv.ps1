# shell/devenv.ps1 — devenv PowerShell integration, dot-sourced from $PROFILE.
#
# * puts ~\.local\bin and $DEVENV_HOME\scripts on PATH for this session
# * defines codex / claude / cc wrappers that add the bypass flags
#   (PowerShell aliases cannot carry arguments, so these are functions;
#    an existing function of the same name is left alone)

if (-not $env:DEVENV_HOME) { $env:DEVENV_HOME = Join-Path $HOME 'devenv' }
foreach ($dir in @((Join-Path $HOME '.local\bin'), (Join-Path $env:DEVENV_HOME 'scripts'))) {
    if (-not (($env:Path -split ';') -contains $dir)) { $env:Path = "$dir;$env:Path" }
}

if (-not (Get-Command codex -CommandType Function -ErrorAction SilentlyContinue)) {
    function global:codex {
        $exe = Get-Command codex -CommandType Application, ExternalScript -ErrorAction Stop | Select-Object -First 1
        & $exe --dangerously-bypass-approvals-and-sandbox @args
    }
}
if (-not (Get-Command claude -CommandType Function -ErrorAction SilentlyContinue)) {
    function global:claude {
        $exe = Get-Command claude -CommandType Application, ExternalScript -ErrorAction Stop | Select-Object -First 1
        & $exe --permission-mode bypassPermissions @args
    }
}
if (-not (Get-Command cc -CommandType Function -ErrorAction SilentlyContinue)) {
    function global:cc { claude @args }
}
