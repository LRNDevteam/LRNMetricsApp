# =====================================================================
# InHealthDTR Database Fix Deployment Script
# =====================================================================
# This script deploys the database changes to fix the column mismatch
# issue for InHealthDTR lab data imports.
# =====================================================================

param(
	[Parameter(Mandatory=$true)]
	[string]$ServerName,

	[Parameter(Mandatory=$true)]
	[string]$DatabaseName,

	[Parameter(Mandatory=$false)]
	[string]$Username,

	[Parameter(Mandatory=$false)]
	[string]$Password,

	[Parameter(Mandatory=$false)]
	[switch]$UseWindowsAuth = $true
)

$ErrorActionPreference = "Stop"
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "InHealthDTR Database Fix Deployment" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "Server: $ServerName" -ForegroundColor White
Write-Host "Database: $DatabaseName" -ForegroundColor White
Write-Host "Auth: $(if($UseWindowsAuth){'Windows Authentication'}else{'SQL Authentication'})" -ForegroundColor White
Write-Host ""

# Build connection string
if ($UseWindowsAuth) {
	$connectionString = "Server=$ServerName;Database=$DatabaseName;Integrated Security=True;TrustServerCertificate=True;"
} else {
	if ([string]::IsNullOrEmpty($Username) -or [string]::IsNullOrEmpty($Password)) {
		Write-Host "ERROR: Username and Password required for SQL Authentication" -ForegroundColor Red
		exit 1
	}
	$connectionString = "Server=$ServerName;Database=$DatabaseName;User Id=$Username;Password=$Password;TrustServerCertificate=True;"
}

function Execute-SqlScript {
	param(
		[string]$ScriptPath,
		[string]$ConnectionString
	)

	$scriptName = Split-Path -Leaf $ScriptPath
	Write-Host "Executing: $scriptName..." -ForegroundColor Yellow

	try {
		$sqlContent = Get-Content $ScriptPath -Raw

		$connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
		$connection.Open()

		$command = $connection.CreateCommand()
		$command.CommandText = $sqlContent
		$command.CommandTimeout = 300  # 5 minutes

		$result = $command.ExecuteNonQuery()

		$connection.Close()

		Write-Host "  ✓ $scriptName completed successfully" -ForegroundColor Green
		return $true
	}
	catch {
		Write-Host "  ✗ $scriptName FAILED" -ForegroundColor Red
		Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
		return $false
	}
}

# Script execution order
$scripts = @(
	"02_InHealthDTR_Alter_ClaimLevelData_AddFields.sql",
	"03_InHealthDTR_Alter_LineLevelData_AddFields.sql",
	"04_InHealthDTR_Recreate_ClaimLevelDataTVP_And_UpdateSP.sql",
	"05_InHealthDTR_Recreate_LineLevelDataTVP_And_UpdateSP.sql"
)

Write-Host ""
Write-Host "Deployment Steps:" -ForegroundColor Cyan
Write-Host "  1. Add missing columns to ClaimLevelData table" -ForegroundColor White
Write-Host "  2. Add missing columns to LineLevelData table" -ForegroundColor White
Write-Host "  3. Recreate ClaimLevel TVP and stored procedure" -ForegroundColor White
Write-Host "  4. Recreate LineLevel TVP and stored procedure" -ForegroundColor White
Write-Host ""

$proceed = Read-Host "Proceed with deployment? (Y/N)"
if ($proceed -ne 'Y' -and $proceed -ne 'y') {
	Write-Host "Deployment cancelled." -ForegroundColor Yellow
	exit 0
}

Write-Host ""
Write-Host "Starting deployment..." -ForegroundColor Cyan
Write-Host ""

$allSuccess = $true

foreach ($script in $scripts) {
	$fullPath = Join-Path $scriptPath $script

	if (-not (Test-Path $fullPath)) {
		Write-Host "ERROR: Script not found: $fullPath" -ForegroundColor Red
		$allSuccess = $false
		break
	}

	$success = Execute-SqlScript -ScriptPath $fullPath -ConnectionString $connectionString

	if (-not $success) {
		$allSuccess = $false
		break
	}

	Start-Sleep -Milliseconds 500
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan

if ($allSuccess) {
	Write-Host "Deployment completed successfully!" -ForegroundColor Green
	Write-Host ""
	Write-Host "Next steps:" -ForegroundColor Cyan
	Write-Host "  1. Verify TVP column counts using the verification queries in 00_README_FIX_INSTRUCTIONS.sql" -ForegroundColor White
	Write-Host "  2. Test InHealthDTR CSV file import" -ForegroundColor White
	Write-Host "  3. Monitor application logs for any errors" -ForegroundColor White
} else {
	Write-Host "Deployment FAILED!" -ForegroundColor Red
	Write-Host "Please check the error messages above and fix any issues before retrying." -ForegroundColor Yellow
	exit 1
}

Write-Host "=============================================" -ForegroundColor Cyan
