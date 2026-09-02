# shell/devenv.ps1 — devenv PowerShell integration, dot-sourced from $PROFILE.
#
# * puts credential wrappers, ~\.local\bin, and $DEVENV_HOME\scripts on PATH
# * defines codex / claude / cc wrappers that add the bypass flags
#   (PowerShell aliases cannot carry arguments, so these are functions;
#    an existing function of the same name is left alone)

if (-not $env:DEVENV_HOME) { $env:DEVENV_HOME = Join-Path $HOME 'devenv' }
$pathDirs = @((Join-Path $HOME '.local\bin'), (Join-Path $env:DEVENV_HOME 'scripts'))
$credWrappers = Join-Path $HOME '.local\share\cred-forward\wrappers'
$credRoleFile = Join-Path $HOME '.local\share\cred-forward\role'
$credRole = if (Test-Path $credRoleFile) { "$(Get-Content $credRoleFile -First 1)".Trim() } else { '' }
if (($credRole -eq 'client') -and (Test-Path $credWrappers -PathType Container)) {
    $pathDirs = @($credWrappers) + $pathDirs
}
$remainingPathDirs = @($env:Path -split ';' | Where-Object { $_ -and ($_ -notin $pathDirs) })
$env:Path = (@($pathDirs) + $remainingPathDirs) -join ';'

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
