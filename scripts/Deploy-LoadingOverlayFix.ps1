# Deploy and Verify Coding Summary Loading Overlay Fix
# Run this script on the production server after publishing

param(
	[Parameter(Mandatory=$false)]
	[string]$AppPoolName = "LRNMetricsApp",

	[Parameter(Mandatory=$false)]
	[string]$SitePath = "C:\inetpub\wwwroot\LRNMetrics"
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Coding Summary Loading Overlay - Deployment Verification" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 1. Check if file exists
$viewFile = Join-Path $SitePath "Views\Coding\Summary.cshtml"
if (Test-Path $viewFile) {
	Write-Host "[OK] View file found: $viewFile" -ForegroundColor Green

	# Check if new code is present
	$content = Get-Content $viewFile -Raw
	if ($content -match 'csTabLoadingOverlay\.classList\.add') {
		Write-Host "[OK] New JavaScript code detected (classList.add)" -ForegroundColor Green
	} else {
		Write-Host "[WARNING] Old JavaScript code detected (style.display)" -ForegroundColor Yellow
	}

	if ($content -match 'class="loading-card"') {
		Write-Host "[OK] New HTML structure detected" -ForegroundColor Green
	} else {
		Write-Host "[WARNING] Old HTML structure with inline styles detected" -ForegroundColor Yellow
	}

	if ($content -match '\[Coding Summary\] Script loaded at:') {
		Write-Host "[OK] Debug logging present" -ForegroundColor Green
	} else {
		Write-Host "[WARNING] Debug logging not found" -ForegroundColor Yellow
	}
} else {
	Write-Host "[ERROR] View file not found at: $viewFile" -ForegroundColor Red
	exit 1
}

Write-Host ""

# 2. Clear ASP.NET Temporary Files
Write-Host "Clearing ASP.NET temporary files..." -ForegroundColor Yellow
$tempPath = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\Temporary ASP.NET Files"
if (Test-Path $tempPath) {
	try {
		Get-ChildItem $tempPath -Recurse -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
		Write-Host "[OK] Temporary files cleared" -ForegroundColor Green
	} catch {
		Write-Host "[WARNING] Could not clear all temporary files (some may be in use)" -ForegroundColor Yellow
	}
} else {
	Write-Host "[SKIP] Temporary files path not found" -ForegroundColor Yellow
}

Write-Host ""

# 3. Recycle Application Pool
Write-Host "Recycling application pool: $AppPoolName..." -ForegroundColor Yellow
try {
	Import-Module WebAdministration -ErrorAction Stop
	if (Test-Path "IIS:\AppPools\$AppPoolName") {
		Restart-WebAppPool -Name $AppPoolName
		Write-Host "[OK] Application pool recycled" -ForegroundColor Green
		Start-Sleep -Seconds 3
	} else {
		Write-Host "[WARNING] Application pool '$AppPoolName' not found" -ForegroundColor Yellow
		Write-Host "Available pools:" -ForegroundColor Yellow
		Get-ChildItem "IIS:\AppPools" | Select-Object Name | Format-Table
	}
} catch {
	Write-Host "[WARNING] Could not recycle app pool: $($_.Exception.Message)" -ForegroundColor Yellow
	Write-Host "Try manually: Restart-WebAppPool -Name '$AppPoolName'" -ForegroundColor Yellow
}

Write-Host ""

# 4. Touch web.config to force recompilation
$webConfig = Join-Path $SitePath "web.config"
if (Test-Path $webConfig) {
	Write-Host "Touching web.config to force recompilation..." -ForegroundColor Yellow
	try {
		(Get-Item $webConfig).LastWriteTime = Get-Date
		Write-Host "[OK] web.config timestamp updated" -ForegroundColor Green
	} catch {
		Write-Host "[WARNING] Could not update web.config: $($_.Exception.Message)" -ForegroundColor Yellow
	}
} else {
	Write-Host "[WARNING] web.config not found at: $webConfig" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Deployment Steps Completed" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Green
Write-Host "1. Clear your browser cache (Ctrl+Shift+R)" -ForegroundColor White
Write-Host "2. Navigate to: https://lrnanalytics.com/lrnmetrics/Coding/Summary" -ForegroundColor White
Write-Host "3. Open browser console (F12)" -ForegroundColor White
Write-Host "4. Look for: '[Coding Summary] Script loaded at:'" -ForegroundColor White
Write-Host "5. Click a tab and verify loading overlay appears" -ForegroundColor White
Write-Host ""
Write-Host "Troubleshooting:" -ForegroundColor Yellow
Write-Host "- If still not working, check browser console for errors" -ForegroundColor White
Write-Host "- View page source (Ctrl+U) and search for 'csTabLoadingOverlay'" -ForegroundColor White
Write-Host "- Verify new HTML structure (without inline styles) is present" -ForegroundColor White
Write-Host "- Check Network tab to ensure Summary.cshtml is not cached" -ForegroundColor White
Write-Host ""

# 5. Generate verification URL
$verifyUrl = "https://lrnanalytics.com/lrnmetrics/Coding/Summary?_v=" + (Get-Date -Format "yyyyMMddHHmmss")
Write-Host "Cache-busting URL:" -ForegroundColor Cyan
Write-Host $verifyUrl -ForegroundColor White
Write-Host ""

Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
