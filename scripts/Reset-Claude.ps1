$ErrorActionPreference = 'Continue'
Write-Host '=== Reset Claude desktop app ===' -ForegroundColor Cyan

# Stop Claude processes
Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match 'Claude' -or $_.ProcessName -match 'Claude'
} | ForEach-Object {
    Write-Host ("Stopping {0} ({1})" -f $_.ProcessName, $_.Id)
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2

$pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $pkg) {
    $pkg = Get-AppxPackage | Where-Object { $_.Name -match 'Claude' -or $_.PackageFullName -match 'Claude' } | Select-Object -First 1
}

if ($pkg) {
    Write-Host ("Package: {0}" -f $pkg.PackageFullName)
    Write-Host 'Calling Reset-AppxPackage...'
    try {
        Reset-AppxPackage -Package $pkg.PackageFullName
        Write-Host 'Reset-AppxPackage completed.' -ForegroundColor Green
    } catch {
        Write-Host ("Reset-AppxPackage failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host 'Falling back to clearing LocalState/TempState/AC caches...'
    }
} else {
    Write-Host 'Appx package not found via Get-AppxPackage - clearing Packages folder data.' -ForegroundColor Yellow
}

# Manual clear of user data folders (works even if Reset cmdlet unavailable)
$pkgRoot = Join-Path $env:LOCALAPPDATA 'Packages'
$claudeDirs = Get-ChildItem -LiteralPath $pkgRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'Claude' }

foreach ($dir in $claudeDirs) {
    Write-Host ("Claude package folder: {0}" -f $dir.FullName)
    $before = (Get-ChildItem -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum
    if ($null -eq $before) { $before = 0 }
    Write-Host ("Size before: {0:N2} GB" -f ($before / 1GB))

    $subClear = @(
        'LocalCache',
        'LocalState',
        'TempState',
        'AC',
        'AppData',
        'Settings'
    )
    foreach ($sub in $subClear) {
        $full = Join-Path $dir.FullName $sub
        if (Test-Path -LiteralPath $full) {
            Write-Host ("  Clearing {0}..." -f $sub)
            Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $after = (Get-ChildItem -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum
    if ($null -eq $after) { $after = 0 }
    Write-Host ("Size after:  {0:N2} GB" -f ($after / 1GB))
    Write-Host ("Freed:       {0:N2} GB" -f (($before - $after) / 1GB)) -ForegroundColor Green
}

$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
Write-Host ("C: Free now: {0:N2} GB" -f ($disk.FreeSpace / 1GB)) -ForegroundColor Cyan
Write-Host 'Done. Reopen Claude and sign in again if prompted.'
