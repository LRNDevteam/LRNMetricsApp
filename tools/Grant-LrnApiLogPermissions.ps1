[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AppPoolName,

    [string]$LogFolder = 'C:\LRN-Files\ApplicationFolder\DenialWorkFlow\Logs'
)

$ErrorActionPreference = 'Stop'
$identity = "IIS AppPool\$AppPoolName"

New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null

& icacls.exe $LogFolder /grant "${identity}:(OI)(CI)(M)" /T /C
if ($LASTEXITCODE -ne 0) {
    throw "icacls failed with exit code $LASTEXITCODE. Run this script from an elevated PowerShell session."
}

Write-Host "Granted Modify permission on '$LogFolder' to '$identity'."
