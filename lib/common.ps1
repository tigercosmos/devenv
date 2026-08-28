# lib/common.ps1 — helpers shared by every devenv PowerShell installer. Dot-source it.
$script:DevenvHome = if ($env:DEVENV_HOME) { $env:DEVENV_HOME } else { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
$script:LocalBin = Join-Path $HOME '.local\bin'
$script:ClaudeSkills = Join-Path $HOME '.claude\skills'
$env:DEVENV_HOME = $script:DevenvHome

function Log($msg)  { Write-Host "==> $msg" -ForegroundColor Blue }
function Ok($msg)   { Write-Host "  + $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "  x $msg" -ForegroundColor Red }
function Have($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Get-Arch {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'ARM64' { 'arm64' }
        default { 'amd64' }
    }
}

function Fetch($url, $dest) { Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing }

function Get-LatestTag($repo) {
    (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name
}

function New-TempDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $d | Out-Null
    $d
}

function Install-Bin($src, $name) {
    New-Item -ItemType Directory -Force -Path $script:LocalBin | Out-Null
    Copy-Item $src (Join-Path $script:LocalBin $name) -Force
    Ok "installed $name -> $(Join-Path $script:LocalBin $name)"
}

# Re-read PATH from the registry so tools installed a moment ago are callable.
function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$script:LocalBin;$user;$machine"
}

# Add DIR to the user's persistent PATH (idempotent).
function Add-UserPath($dir) {
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($user -split ';' | Where-Object { $_ })
    if ($parts -contains $dir) { Ok "PATH already contains $dir"; return }
    [Environment]::SetEnvironmentVariable('Path', (@($dir) + $parts) -join ';', 'User')
    Ok "added $dir to the user PATH"
    Refresh-Path
}

# Link every skill under ~/.claude/skills into another agent's skills directory.
# An entry that is not our link is left alone unless -Force, which relinks it
# (a real directory is moved to <target>\.devenv-backup first, never deleted).
function Sync-Skills($target, [switch]$Force) {
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Get-ChildItem $script:ClaudeSkills -Directory | ForEach-Object {
        $src = $_.FullName; $dest = Join-Path $target $_.Name
        if (Test-Path $dest) {
            $item = Get-Item $dest -Force
            if ($item.LinkType -and ($item.Target -contains $src)) { return }
            if (-not $Force) { Warn "$dest is not a link to $src; -Force to relink"; return }
            if ($item.LinkType) { $item.Delete() }
            else {
                $bak = Join-Path $target ".devenv-backup\$($_.Name)-$(Get-Date -Format yyyyMMddHHmmss)"
                New-Item -ItemType Directory -Force -Path (Split-Path $bak) | Out-Null
                Move-Item $dest $bak; Warn "moved $dest to $bak"
            }
        }
        try {
            New-Item -ItemType SymbolicLink -Path $dest -Target $src | Out-Null
        } catch {
            New-Item -ItemType Junction -Path $dest -Target $src | Out-Null
        }
        Ok "linked $dest -> $src"
    }
}
