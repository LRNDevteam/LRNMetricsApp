$ErrorActionPreference = 'Continue'
Write-Host "=== Perplexity locations ===" -ForegroundColor Cyan
$paths = @(
    "$env:LOCALAPPDATA\Perplexity",
    "$env:LOCALAPPDATA\Programs\Perplexity",
    "$env:APPDATA\Perplexity"
)
foreach ($p in $paths) {
    if (Test-Path $p) {
        $size = (Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        Write-Host ("FOUND {0}  {1:N2} GB" -f $p, ($size/1GB))
    }
}

Write-Host "`n=== Winget Perplexity ===" -ForegroundColor Cyan
winget list --name Perplexity

Write-Host "`n=== Uninstall registry ===" -ForegroundColor Cyan
$keys = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
Get-ItemProperty $keys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'Perplexity' } |
    Select-Object DisplayName, UninstallString, QuietUninstallString |
    Format-List

Write-Host "`n=== Windows users ===" -ForegroundColor Cyan
Get-ChildItem C:\Users -Directory | ForEach-Object { Write-Host $_.Name }
