<#
.SYNOPSIS
    Stops and removes the LRN CPU Monitor Windows service.

.DESCRIPTION
    Removes the service registration. Binaries and logs are left on disk unless
    -RemoveFiles is given, so a breach history is never destroyed by accident.

.PARAMETER InstallPath
    Directory the service was installed to.

.PARAMETER ServiceName
    Windows service name.

.PARAMETER RemoveFiles
    Also delete the install directory. Logs go with it.

.EXAMPLE
    .\Uninstall-CpuMonitor.ps1

.EXAMPLE
    .\Uninstall-CpuMonitor.ps1 -RemoveFiles
#>
[CmdletBinding()]
param(
    [string] $InstallPath = "D:\LRN\Release\CpuMonitor",
    [string] $ServiceName = "LRN - CPU Monitor",
    [switch] $RemoveFiles
)

$ErrorActionPreference = "Stop"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This script must run from an elevated PowerShell session (Run as Administrator)."
}

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Host "Service '$ServiceName' is not installed." -ForegroundColor Yellow
} else {
    if ($service.Status -ne 'Stopped') {
        Write-Host "Stopping '$ServiceName'..." -ForegroundColor Cyan
        Stop-Service -Name $ServiceName -Force
        $waited = 0
        while ((Get-Service -Name $ServiceName).Status -ne 'Stopped' -and $waited -lt 30) {
            Start-Sleep -Seconds 1; $waited++
        }
    }

    & sc.exe delete $ServiceName | Out-Null
    Write-Host "Service removed." -ForegroundColor Green
}

if ($RemoveFiles) {
    if (Test-Path $InstallPath) {
        Remove-Item $InstallPath -Recurse -Force
        Write-Host "Deleted $InstallPath (including logs)." -ForegroundColor Green
    }
} elseif (Test-Path $InstallPath) {
    Write-Host "Binaries and logs left at $InstallPath. Re-run with -RemoveFiles to delete them." -ForegroundColor Yellow
}
