<#
.SYNOPSIS
    Installs or upgrades the LRN CPU Monitor Windows service.

.DESCRIPTION
    Safe to re-run. On an upgrade it stops the service, replaces the binaries and
    restarts it, deliberately leaving an existing appsettings.json in place so a
    tuned threshold or connection string is never overwritten by the packaged
    defaults.

    The service is created to run as LocalSystem. That matters: a standard-user
    account can still read CPU usage for every process, but the executable path and
    command line come back empty for roughly 60% of them, which defeats the purpose
    of the log.

.PARAMETER InstallPath
    Destination directory for the binaries.

.PARAMETER ServiceName
    Windows service name.

.EXAMPLE
    .\Install-CpuMonitor.ps1

.EXAMPLE
    .\Install-CpuMonitor.ps1 -InstallPath "E:\LRN\CpuMonitor"
#>
[CmdletBinding()]
param(
    [string] $InstallPath = "D:\LRN\Release\CpuMonitor",
    [string] $ServiceName = "LRN - CPU Monitor"
)

$ErrorActionPreference = "Stop"

function Write-Step { param([string] $Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string] $Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Note { param([string] $Message) Write-Host "    $Message" -ForegroundColor Yellow }

# ---------------------------------------------------------------- preflight ----
Write-Step "Checking prerequisites"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This script must run from an elevated PowerShell session (Run as Administrator)."
}
Write-Ok "Running elevated as $($identity.Name)"

# Framework-dependent deployment, so the shared runtime has to be present.
$runtimes = & dotnet --list-runtimes 2>$null
if ($LASTEXITCODE -ne 0 -or -not $runtimes) {
    throw "The .NET runtime was not found. Install the .NET 8 Hosting Bundle or Runtime first."
}
if (-not ($runtimes | Where-Object { $_ -match '^Microsoft\.NETCore\.App 8\.' })) {
    throw "The .NET 8 runtime was not found. Installed runtimes:`n$($runtimes -join "`n")"
}
Write-Ok ".NET 8 runtime present"

$payload = Join-Path $PSScriptRoot "CpuMonitor"
if (-not (Test-Path $payload)) {
    throw "Payload folder not found at '$payload'. Unzip the whole package and run the script from its root."
}
$exeSource = Join-Path $payload "LRN.CpuMonitor.exe"
if (-not (Test-Path $exeSource)) {
    throw "LRN.CpuMonitor.exe is missing from '$payload'. The package is incomplete."
}
Write-Ok "Payload found ($((Get-ChildItem $payload -Recurse -File).Count) files)"

# ------------------------------------------------------------- stop service ----
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$isUpgrade = $null -ne $existing

if ($isUpgrade) {
    Write-Step "Existing service found - stopping it for upgrade"
    if ($existing.Status -ne 'Stopped') {
        Stop-Service -Name $ServiceName -Force
        # The process holds a lock on its own DLLs; wait for it to actually exit.
        $waited = 0
        while ((Get-Service -Name $ServiceName).Status -ne 'Stopped' -and $waited -lt 30) {
            Start-Sleep -Seconds 1; $waited++
        }
        if ((Get-Service -Name $ServiceName).Status -ne 'Stopped') {
            throw "Service did not stop within 30 seconds. Stop it manually and re-run."
        }
    }
    Write-Ok "Service stopped"
} else {
    Write-Step "No existing service - performing a fresh install"
}

# ---------------------------------------------------------------- copy files ----
# Pointing InstallPath at the payload folder is a reasonable way to run the service
# straight out of an unzipped directory, but copying a folder into itself fails, so
# that case skips the copy entirely and registers the service where it already sits.
$payloadResolved = (Resolve-Path $payload).ProviderPath.TrimEnd('\')
$installResolved = if (Test-Path $InstallPath) {
    (Resolve-Path $InstallPath).ProviderPath.TrimEnd('\')
} else {
    $InstallPath.TrimEnd('\')
}
$runInPlace = $payloadResolved -ieq $installResolved

if ($runInPlace) {
    Write-Step "Running in place from $installResolved"
    Write-Note "Install path is the payload folder, so no files are copied."
    Write-Note "The service loads binaries directly from here - do not move or delete this folder."
}
else {
    Write-Step "Copying binaries to $InstallPath"

    if (-not (Test-Path $InstallPath)) {
        New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
    }

    # Never clobber a tuned configuration on upgrade. Copy-Item -Exclude is
    # unreliable once -Recurse is involved, so the live config is set aside and
    # put back instead.
    $liveConfig = Join-Path $InstallPath "appsettings.json"
    $configBackup = Join-Path $InstallPath "appsettings.json.previous"
    $preserveConfig = Test-Path $liveConfig

    if ($preserveConfig) {
        Copy-Item $liveConfig $configBackup -Force
    }

    Copy-Item -Path (Join-Path $payload "*") -Destination $InstallPath -Recurse -Force

    if ($preserveConfig) {
        Copy-Item $configBackup $liveConfig -Force
        Write-Note "Existing appsettings.json kept; a copy is at appsettings.json.previous."
        Write-Note "Packaged defaults are in the zip if you want to compare."
    }
    else {
        Write-Ok "appsettings.json installed with packaged defaults - review the threshold before relying on it"
    }

    Write-Ok "Binaries copied"
}

# ------------------------------------------------------------ create service ----
$exeTarget = Join-Path $InstallPath "LRN.CpuMonitor.exe"

if (-not $isUpgrade) {
    Write-Step "Creating the service"

    New-Service -Name $ServiceName `
                -BinaryPathName "`"$exeTarget`"" `
                -DisplayName $ServiceName `
                -Description "Logs any process sustaining CPU above the configured threshold, with its path, PID, owner and launching process. Attributes SQL Server load to the calling application." `
                -StartupType Automatic | Out-Null
    Write-Ok "Service created as LocalSystem, start type Automatic"

    # Restart on crash rather than sitting dead until somebody notices.
    & sc.exe failure $ServiceName reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
    Write-Ok "Recovery configured: restart after 60s, three attempts, counter resets daily"
} else {
    Write-Step "Reusing the existing service registration"
    Write-Note "Service account and recovery settings were left as they are."
}

# ------------------------------------------------------------- start service ----
Write-Step "Starting the service"
Start-Service -Name $ServiceName

$waited = 0
while ((Get-Service -Name $ServiceName).Status -ne 'Running' -and $waited -lt 30) {
    Start-Sleep -Seconds 1; $waited++
}

$final = Get-Service -Name $ServiceName
if ($final.Status -ne 'Running') {
    throw "Service failed to reach Running state (currently '$($final.Status)'). Check $InstallPath\Logs\cpu-monitor-*.txt"
}
Write-Ok "Service is running"

# -------------------------------------------------------------- verification ----
Write-Step "Verification"

$config = (& sc.exe qc $ServiceName) -join "`n"
$account = ([regex]::Match($config, 'SERVICE_START_NAME\s*:\s*(.+)')).Groups[1].Value.Trim()

Write-Host "    Service name   : $ServiceName"
Write-Host "    Status         : $($final.Status)"
Write-Host "    Runs as        : $account"
Write-Host "    Install path   : $InstallPath"
Write-Host "    Config         : $InstallPath\appsettings.json"
Write-Host "    Breach log     : $InstallPath\Logs\cpu-breaches-<date>.txt"
Write-Host "    Full log       : $InstallPath\Logs\cpu-monitor-<date>.txt"
Write-Host "    JSON breaches  : $InstallPath\Logs\cpu-breaches.jsonl"

if ($account -notmatch 'LocalSystem') {
    Write-Note "Not running as LocalSystem. CPU detection still works for every account, but the"
    Write-Note "executable path and command line will be unavailable for most processes."
}

Write-Step "Done"
Write-Host "    Tail the breach log with:" -ForegroundColor Gray
Write-Host "      Get-Content '$InstallPath\Logs\cpu-breaches-*.txt' -Wait -Tail 20" -ForegroundColor Gray
