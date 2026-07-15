# Analyze-C-Drive.ps1 — find what's using space on C:
$ErrorActionPreference = 'SilentlyContinue'

function Get-FolderSizeGB([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $sum = (Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { $sum = 0 }
    return [math]::Round($sum / 1GB, 2)
}

Write-Host ""
Write-Host "=== C: DRIVE SPACE ===" -ForegroundColor Cyan
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$freeGB  = [math]::Round($disk.FreeSpace / 1GB, 2)
$totalGB = [math]::Round($disk.Size / 1GB, 2)
$usedGB  = [math]::Round(($disk.Size - $disk.FreeSpace) / 1GB, 2)
Write-Host "Total: $totalGB GB | Used: $usedGB GB | Free: $freeGB GB"
Write-Host ""

Write-Host "=== TOP-LEVEL C:\ FOLDERS ===" -ForegroundColor Cyan
Get-ChildItem C:\ -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $gb = if ($_.PSIsContainer) { Get-FolderSizeGB $_.FullName } else { [math]::Round($_.Length / 1GB, 2) }
    [PSCustomObject]@{ Folder = $_.FullName; SizeGB = $gb }
} | Sort-Object SizeGB -Descending | Format-Table -AutoSize

Write-Host "=== COMMON LARGE LOCATIONS ===" -ForegroundColor Cyan
$targets = @(
    "$env:USERPROFILE\Downloads",
    "$env:USERPROFILE\Desktop",
    "$env:LOCALAPPDATA\Temp",
    "$env:LOCALAPPDATA\Microsoft\VisualStudio",
    "$env:LOCALAPPDATA\Packages",
    "$env:LOCALAPPDATA\Docker",
    "$env:USERPROFILE\.cursor",
    "$env:USERPROFILE\.nuget\packages",
    "$env:APPDATA\Cursor",
    "C:\Windows\SoftwareDistribution",
    "C:\Windows\Temp",
    "C:\Windows\WinSxS",
    "C:\Program Files\Microsoft SQL Server",
    "C:\Program Files (x86)\Microsoft SQL Server"
)
$targets | ForEach-Object {
    $gb = Get-FolderSizeGB $_
    if ($null -ne $gb) { [PSCustomObject]@{ Path = $_; SizeGB = $gb } }
} | Sort-Object SizeGB -Descending | Format-Table -AutoSize

Write-Host "=== LARGEST IN AppData\Local ===" -ForegroundColor Cyan
Get-ChildItem "$env:LOCALAPPDATA" -Force -ErrorAction SilentlyContinue | ForEach-Object {
    [PSCustomObject]@{ Folder = $_.Name; SizeGB = (Get-FolderSizeGB $_.FullName) }
} | Sort-Object SizeGB -Descending | Select-Object -First 20 | Format-Table -AutoSize

Write-Host "Done." -ForegroundColor Green
Read-Host "Press Enter to close"
