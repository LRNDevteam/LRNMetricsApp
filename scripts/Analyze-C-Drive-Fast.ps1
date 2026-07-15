# Analyze-C-Drive-Fast.ps1 — quick scan of known large locations (no full C:\ walk)
$ErrorActionPreference = 'SilentlyContinue'

function SizeGB([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $sum = (Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum
    if ($null -eq $sum) { $sum = 0 }
    [math]::Round($sum / 1GB, 2)
}

$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
Write-Host "`nC: Total $([math]::Round($disk.Size/1GB,2)) GB | Free $([math]::Round($disk.FreeSpace/1GB,2)) GB`n" -ForegroundColor Cyan

$checks = [ordered]@{
    'Windows\WinSxS'                    = 'C:\Windows\WinSxS'
    'Windows\SoftwareDistribution'      = 'C:\Windows\SoftwareDistribution'
    'Windows\Installer'                 = 'C:\Windows\Installer'
    'Program Files'                     = 'C:\Program Files'
    'Program Files (x86)'               = 'C:\Program Files (x86)'
    'ProgramData'                       = 'C:\ProgramData'
    'Users (all)'                       = 'C:\Users'
    'SQL Server (PF)'                   = 'C:\Program Files\Microsoft SQL Server'
    'SQL Server (PF x86)'               = 'C:\Program Files (x86)\Microsoft SQL Server'
    'Downloads'                         = "$env:USERPROFILE\Downloads"
    'Desktop'                           = "$env:USERPROFILE\Desktop"
    'AppData\Local'                     = "$env:LOCALAPPDATA"
    'AppData\Local\Temp'                = "$env:LOCALAPPDATA\Temp"
    'AppData\Local\Docker'              = "$env:LOCALAPPDATA\Docker"
    'AppData\Local\Packages'            = "$env:LOCALAPPDATA\Packages"
    'Visual Studio cache'               = "$env:LOCALAPPDATA\Microsoft\VisualStudio"
    'Cursor (Roaming)'                  = "$env:APPDATA\Cursor"
    'Cursor projects cache'             = "$env:USERPROFILE\.cursor"
    'NuGet packages'                    = "$env:USERPROFILE\.nuget\packages"
    'npm cache'                         = "$env:LOCALAPPDATA\npm-cache"
    'pagefile.sys'                      = 'C:\pagefile.sys'
    'hiberfil.sys'                      = 'C:\hiberfil.sys'
}

$results = foreach ($label in $checks.Keys) {
    $p = $checks[$label]
    if (Test-Path $p) {
        $item = Get-Item $p -Force
        $gb = if ($item.PSIsContainer) { SizeGB $p } else { [math]::Round($item.Length/1GB,2) }
        [PSCustomObject]@{ Location = $label; Path = $p; SizeGB = $gb }
    }
}
$results | Sort-Object SizeGB -Descending | Format-Table -AutoSize

Write-Host "`nBiggest wins on dev PCs (usually):" -ForegroundColor Yellow
Write-Host "  1. Settings > Storage > Temporary files > Previous Windows installation"
Write-Host "  2. DISM component cleanup (Extended bat step 4)"
Write-Host "  3. Move SQL data/logs to E: if on C:"
Write-Host "  4. Docker: docker system prune -a"
Write-Host "  5. Uninstall unused VS workloads / old SDKs"
Write-Host "  6. Move Downloads & large files to E:\LRN-Data"
Write-Host ""
Read-Host "Press Enter"
