# shell/install.ps1 — wire shell\devenv.ps1 into the PowerShell $PROFILE,
# add ~\.local\bin and devenv\scripts to the persistent user PATH, and verify
# the codex / claude / cc wrappers resolve.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

# The documented bootstrap uses a process-scoped Bypass so this installer can
# start on a default Windows client. The login profile still needs a persistent
# policy that permits local scripts after that bootstrap process exits.
$policies = Get-ExecutionPolicy -List
$normalPolicy = @('MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine') |
    ForEach-Object { ($policies | Where-Object Scope -eq $_).ExecutionPolicy } |
    Where-Object { $_ -ne 'Undefined' } |
    Select-Object -First 1
if (-not $normalPolicy) { $normalPolicy = 'Restricted' }
if ($normalPolicy -in @('Restricted', 'AllSigned')) {
    throw "PowerShell execution policy $normalPolicy will block the devenv profile. Run: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
}

# Keep the shared shell-profile contract explicit. Windows has no second one.
$additionalLoginProfile = Get-AdditionalLoginProfile
if ($additionalLoginProfile) { throw 'unexpected additional PowerShell profile' }

$begin = '# >>> devenv >>>'
$end = '# <<< devenv <<<'
$block = @(
    $begin,
    "`$env:DEVENV_HOME = '$($script:DevenvHome)'",
    '. (Join-Path $env:DEVENV_HOME ''shell\devenv.ps1'')',
    $end
) -join "`r`n"

Log "PowerShell profile: $PROFILE"
New-Item -ItemType Directory -Force -Path (Split-Path $PROFILE) | Out-Null
if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE | Out-Null }
$content = Get-Content $PROFILE -Raw
if ($null -eq $content) { $content = '' }
if ($content.Contains($begin)) {
    $pattern = [regex]::Escape($begin) + '[\s\S]*?' + [regex]::Escape($end)
    if (($content -match $pattern) -and ($Matches[0] -eq $block)) {
        Ok 'devenv block already present'
    } else {
        Set-Content $PROFILE ([regex]::Replace($content, $pattern, $block))
        Ok 'devenv block updated'
    }
} else {
    Add-Content $PROFILE "`r`n$block`r`n"
    Ok 'devenv block appended'
}

Log 'persistent user PATH'
Add-UserPath $script:LocalBin
Add-UserPath (Join-Path $script:DevenvHome 'scripts')

Log 'verify wrappers (loading the profile in a fresh PowerShell)'
$check = @'
. $PROFILE
$rc = 0
foreach ($pair in @(@('codex','--dangerously-bypass-approvals-and-sandbox'), @('claude','--permission-mode bypassPermissions'), @('cc','--permission-mode bypassPermissions'))) {
    $name, $flag = $pair
    $f = Get-Command $name -CommandType Function -ErrorAction SilentlyContinue
    $body = if ($f) { $f.Definition } else { '' }
    if ($name -eq 'cc' -and $f) { $body += (Get-Command claude -CommandType Function -ErrorAction SilentlyContinue).Definition }
    if ($body -like "*$flag*") { Write-Host "  + function $name carries $flag" -ForegroundColor Green }
    else { Write-Host "  x function $name is missing $flag" -ForegroundColor Red; $rc = 1 }
}
exit $rc
'@
$tmp = New-TempDir
try {
    $checkScript = Join-Path $tmp 'check-wrappers.ps1'
    Set-Content -LiteralPath $checkScript -Value $check -Encoding UTF8
    & (Get-Process -Id $PID).Path -NoLogo -NoProfile -ExecutionPolicy Bypass -File $checkScript
    if ($LASTEXITCODE -ne 0) { throw 'wrapper check failed — see above' }
} finally {
    Remove-Item $tmp -Recurse -Force
}

Write-Host ''
Write-Host "Open a new terminal, or run:  . `$PROFILE"
