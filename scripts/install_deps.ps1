<#
.SYNOPSIS
    Prepares a Windows host to run the cluster inside WSL2.

.DESCRIPTION
    The cluster runs under rootless Podman in a WSL2 Linux distribution, where
    the Makefile and the bash scripts work unchanged. This script:

      1. installs WSL2 if it is missing (needs an elevated prompt and a reboot),
      2. forces cgroup v2 in the WSL2 kernel via %UserProfile%\.wslconfig, so
         Slurm can enforce job memory and CPU limits,
      3. installs the Linux distribution (default Ubuntu-24.04) if needed,
      4. enables systemd in the distribution (rootless Podman's API socket and
         cgroup delegation need it) and mounts Windows drives with Linux
         permissions (the SSH private key must not be world-readable),
      5. runs scripts/install_deps.sh inside the distribution.

    Ports published by the cluster (SSH 2222, Slurm-web 5011, ...) are reachable
    from Windows on localhost through WSL's localhost forwarding.

.PARAMETER Distro
    WSL distribution to use or install. Default: Ubuntu-24.04.

.PARAMETER Yes
    Do not prompt; passes -y to install_deps.sh and shuts WSL down when needed.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\install_deps.ps1
#>
[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu-24.04',
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
# Make wsl.exe print UTF-8 instead of UTF-16 so its output can be parsed.
$env:WSL_UTF8 = '1'

function Info($msg) { Write-Host "==> $msg" }
function Warn($msg) { Write-Warning $msg }
function Die($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

function Confirm-Step($question) {
    if ($Yes) { return $true }
    $answer = Read-Host "$question [y/N]"
    return $answer -match '^(y|yes)$'
}

function Invoke-Wsl {
    # Runs wsl.exe and returns its output as clean strings (no NULs or CRs).
    # Windows PowerShell turns redirected native stderr into errors, which
    # 'Stop' would make fatal; failures are reported through $WslExit instead.
    $ErrorActionPreference = 'Continue'
    $out = & wsl.exe @args 2>&1
    $script:WslExit = $LASTEXITCODE
    return @($out | ForEach-Object { "$_" -replace "`0", '' -replace "`r", '' } | Where-Object { $_ -ne '' })
}

$RepoRoot = Split-Path -Parent $PSScriptRoot

# --- 1. WSL2 itself ---------------------------------------------------------

if ([Environment]::OSVersion.Version.Build -lt 19041) {
    Die 'WSL2 needs Windows 10 version 2004 (build 19041) or later, or Windows 11.'
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Die 'wsl.exe not found; enable "Windows Subsystem for Linux" in Windows Features.'
}

Invoke-Wsl --status | Out-Null
if ($WslExit -ne 0) {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { Die 'WSL is not installed. Re-run this script from an elevated (Administrator) PowerShell.' }
    Info 'Installing WSL2'
    & wsl.exe --install --no-distribution
    if ($LASTEXITCODE -ne 0) { Die 'wsl --install failed; see https://learn.microsoft.com/windows/wsl/install' }
    Info 'WSL2 installed. Reboot Windows, then run this script again.'
    exit 0
}

Info 'Updating WSL'
& wsl.exe --update | Out-Null
& wsl.exe --set-default-version 2 | Out-Null

# --- 2. cgroup v2 in the WSL2 kernel ----------------------------------------

$NeedShutdown = $false
$wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
$cgroupLine = 'kernelCommandLine = cgroup_no_v1=all'
$text = if (Test-Path $wslConfig) { Get-Content -Raw $wslConfig } else { '' }

if ($text -match 'cgroup_no_v1=all') {
    Info "cgroup v2 already forced in $wslConfig"
} elseif ($text -match '(?m)^\s*kernelCommandLine\s*=') {
    Warn "$wslConfig already sets kernelCommandLine; add cgroup_no_v1=all to it yourself, then run: wsl --shutdown"
} else {
    Info "Forcing cgroup v2 in $wslConfig"
    if ($text -match '(?m)^\[wsl2\]\s*$') {
        $text = $text -replace '(?m)^\[wsl2\]\s*$', "[wsl2]`r`n$cgroupLine"
    } else {
        if ($text -and -not $text.EndsWith("`n")) { $text += "`r`n" }
        $text += "[wsl2]`r`n$cgroupLine`r`n"
    }
    Set-Content -Path $wslConfig -Value $text -NoNewline -Encoding ASCII
    $NeedShutdown = $true
}

# --- 3. Linux distribution --------------------------------------------------

$installed = Invoke-Wsl --list --quiet
if ($installed -notcontains $Distro) {
    Info "Installing $Distro. When it asks, create your Linux user, then type 'exit' to continue here."
    & wsl.exe --install --distribution $Distro
    if ($LASTEXITCODE -ne 0) { Die "could not install $Distro (list available ones with: wsl --list --online)" }
    $installed = Invoke-Wsl --list --quiet
    if ($installed -notcontains $Distro) { Die "$Distro is still not installed; run this script again after it finishes." }
}

$uid = (Invoke-Wsl --distribution $Distro --exec id -u) | Select-Object -First 1
if ($uid -eq '0') {
    Die "$Distro logs in as root. Create a normal user in it and make it the default (rootless Podman), then re-run."
}

# --- 4. systemd and drive permissions in the distribution --------------------

# Sets [boot] systemd=true and [automount] options in /etc/wsl.conf, keeping
# any other settings. Prints "changed" if the file was modified.
$wslConfScript = @'
import configparser, os
p = "/etc/wsl.conf"
c = configparser.ConfigParser()
c.optionxform = str
if os.path.exists(p):
    c.read(p)
want = {("boot", "systemd"): "true",
        ("automount", "options"): '"metadata,umask=22,fmask=11"'}
changed = False
for (section, key), value in want.items():
    if not c.has_section(section):
        c.add_section(section)
    if c.get(section, key, fallback=None) != value:
        c.set(section, key, value)
        changed = True
if changed:
    with open(p, "w") as f:
        c.write(f)
    print("changed")
'@
# Passed base64-encoded: piping into wsl.exe adds CRs, and Windows PowerShell
# mangles quotes in native arguments.
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($wslConfScript -replace "`r", ''))
$result = & wsl.exe --distribution $Distro --user root --exec python3 -c "import base64; exec(base64.b64decode('$encoded'))"
if ($LASTEXITCODE -ne 0) { Die "could not update /etc/wsl.conf in $Distro" }
$restartDistro = ("$result" -match 'changed')
if ($restartDistro) { Info "Enabled systemd and Linux file permissions in $Distro" }

if ($NeedShutdown) {
    if (Confirm-Step 'WSL must restart for the cgroup setting. This stops ALL running WSL distributions (and Docker Desktop). Continue?') {
        Info 'Shutting down WSL'
        & wsl.exe --shutdown
    } else {
        Die 'Run "wsl --shutdown" when convenient, then run this script again.'
    }
} elseif ($restartDistro) {
    Info "Restarting $Distro"
    & wsl.exe --terminate $Distro | Out-Null
}

# --- 5. Linux-side dependencies ---------------------------------------------

Info "Running scripts/install_deps.sh in $Distro (sudo may ask for your Linux password)"
$shArgs = @()
if ($Yes) { $shArgs += '-y' }
& wsl.exe --distribution $Distro --cd $RepoRoot --exec bash ./scripts/install_deps.sh @shArgs
if ($LASTEXITCODE -ne 0) { Die "install_deps.sh failed in $Distro" }

Write-Host ''
Info 'Windows setup complete. Work with the cluster from the distribution:'
Write-Host "    wsl -d $Distro --cd `"$RepoRoot`""
Write-Host '    make up && make test'
Info 'From Windows, Slurm-web is at http://localhost:5011 and SSH at: ssh -p 2222 hpcuser@localhost'
