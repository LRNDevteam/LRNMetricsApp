$ErrorActionPreference = 'Continue'
Write-Host ''
Write-Host '=== 1) Remove Perplexity ===' -ForegroundColor Cyan

Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -match 'Perplexity' -or ($_.Path -and $_.Path -like '*Perplexity*')
} | ForEach-Object {
    Write-Host ("Stopping: {0} ({1})" -f $_.ProcessName, $_.Id)
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1

$keys = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$uninst = Get-ItemProperty $keys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'Perplexity' } |
    Select-Object -First 1

if ($null -ne $uninst) {
    Write-Host ("Found uninstall entry: {0}" -f $uninst.DisplayName)
    $cmd = $uninst.QuietUninstallString
    if (-not $cmd) { $cmd = $uninst.UninstallString }
    if ($cmd) {
        Write-Host ("Running uninstall: {0}" -f $cmd)
        try {
            if ($cmd -match '^"([^"]+)"\s*(.*)$') {
                $args = $Matches[2]
                if ($args -notmatch '/S') { $args = ($args + ' /S').Trim() }
                Start-Process -FilePath $Matches[1] -ArgumentList $args -Wait -NoNewWindow -ErrorAction SilentlyContinue
            } else {
                Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ($cmd + ' /S') -Wait -NoNewWindow -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Host ("Uninstall failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
} else {
    Write-Host 'No registry uninstall entry - removing folders.'
}

$perpPaths = @(
    (Join-Path $env:LOCALAPPDATA 'Perplexity'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Perplexity'),
    (Join-Path $env:APPDATA 'Perplexity'),
    (Join-Path $env:LOCALAPPDATA 'perplexity-updater'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Perplexity.lnk'),
    (Join-Path $env:USERPROFILE 'Desktop\Perplexity.lnk')
)
foreach ($p in $perpPaths) {
    if (Test-Path -LiteralPath $p) {
        Write-Host ("Deleting: {0}" -f $p)
        Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $p) {
            Write-Host '  WARNING: still exists (file in use?)' -ForegroundColor Yellow
        } else {
            Write-Host '  Removed OK' -ForegroundColor Green
        }
    }
}

Write-Host ''
Write-Host '=== 2) Clear Chrome cache for ALL user profiles ===' -ForegroundColor Cyan

$chromeProcs = Get-Process chrome -ErrorAction SilentlyContinue
if ($chromeProcs) {
    Write-Host 'Closing Chrome processes...'
    $chromeProcs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Get-DirBytes([string]$Dir) {
    $sum = (Get-ChildItem -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0L }
    return [int64]$sum
}

$userRoots = Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') }

$totalFreed = [int64]0
foreach ($user in $userRoots) {
    $chromeBase = Join-Path $user.FullName 'AppData\Local\Google\Chrome\User Data'
    if (-not (Test-Path -LiteralPath $chromeBase)) {
        Write-Host ("No Chrome for user: {0}" -f $user.Name)
        continue
    }
    Write-Host ("User: {0}" -f $user.Name) -ForegroundColor Yellow

    $shared = @('ShaderCache', 'GrShaderCache')
    foreach ($s in $shared) {
        $full = Join-Path $chromeBase $s
        if (Test-Path -LiteralPath $full) {
            $before = Get-DirBytes $full
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $full)) {
                $totalFreed += $before
                Write-Host ("  Cleared shared {0} ({1:N0} MB)" -f $s, ($before / 1MB))
            }
        }
    }

    $profiles = @('Default')
    $profiles += @(Get-ChildItem -LiteralPath $chromeBase -Directory -Filter 'Profile *' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })

    $cacheDirs = @(
        'Cache',
        'Code Cache',
        'GPUCache',
        'ShaderCache',
        'Service Worker\CacheStorage',
        'Service Worker\ScriptCache'
    )

    foreach ($prof in $profiles) {
        foreach ($c in $cacheDirs) {
            $full = Join-Path (Join-Path $chromeBase $prof) $c
            if (Test-Path -LiteralPath $full) {
                $before = Get-DirBytes $full
                Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path -LiteralPath $full)) {
                    $totalFreed += $before
                    Write-Host ("  Cleared {0}\{1} ({2:N0} MB)" -f $prof, $c, ($before / 1MB))
                } else {
                    Write-Host ("  Partial/locked: {0}\{1}" -f $prof, $c) -ForegroundColor Yellow
                }
            }
        }
    }
}

Write-Host ''
Write-Host '=== Done ===' -ForegroundColor Green
Write-Host ("Chrome cache freed (approx): {0:N2} GB" -f ($totalFreed / 1GB))
$perpLeft = Join-Path $env:LOCALAPPDATA 'Perplexity'
if (Test-Path -LiteralPath $perpLeft) {
    Write-Host 'Perplexity folder: STILL PRESENT' -ForegroundColor Yellow
} else {
    Write-Host 'Perplexity folder: GONE' -ForegroundColor Green
}
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
Write-Host ("C: Free now: {0:N2} GB" -f ($disk.FreeSpace / 1GB))
