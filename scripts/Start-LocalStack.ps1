<#
.SYNOPSIS
    Runs the local stack: LabMetricsDashboard and LRN.ReportsApi together.

.DESCRIPTION
    The dashboard calls LRN.ReportsApi for the Denial Workflow and the Report Control
    Board, so starting the dashboard alone leaves those screens empty - the symptom that
    made local testing look broken and sent everything to the deploy server instead.

    Both apps read secrets from their own gitignored appsettings.Local.json. Nothing in
    this script carries a credential.

.PARAMETER Api
    Start only LRN.ReportsApi.

.PARAMETER Dashboard
    Start only LabMetricsDashboard.

.PARAMETER NoBrowser
    Do not open a browser window.

.EXAMPLE
    .\scripts\Start-LocalStack.ps1
    Starts both, each in its own window, and opens the dashboard.

.EXAMPLE
    .\scripts\Start-LocalStack.ps1 -Api
    Starts just the API, for working on it with Swagger.
#>
[CmdletBinding()]
param(
    [switch] $Api,
    [switch] $Dashboard,
    [switch] $NoBrowser
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$dashboardProject = Join-Path $repoRoot 'LabMetricsDashboard\LabMetricsDashboard.csproj'
$apiProject = Join-Path $repoRoot 'LRN.ReportsApi\LRN.ReportsApi.csproj'

# Ports come from each project's Properties/launchSettings.json. Kept here only for the
# messages and the browser launch - the profiles remain the single source of truth.
$dashboardUrl = 'https://localhost:57996'
$apiUrl = 'http://localhost:62409'

# No switch means "everything", which is the normal case.
$startApi = $Api -or -not ($Api -or $Dashboard)
$startDashboard = $Dashboard -or -not ($Api -or $Dashboard)

function Assert-LocalSettings {
    param([string] $ProjectDirectory, [string] $AppName)

    $localSettings = Join-Path $ProjectDirectory 'appsettings.Local.json'
    if (-not (Test-Path $localSettings)) {
        throw "$AppName has no appsettings.Local.json. It holds the connection strings and the " +
              "JWT signing key, is gitignored, and without it the app starts but every page that " +
              "reads data fails. See docs/LOCAL_DEV.md."
    }
}

function Assert-LabConfigFolder {
    $dashboardDir = Split-Path -Parent $dashboardProject
    $settings = Get-Content (Join-Path $dashboardDir 'appsettings.Local.json') -Raw | ConvertFrom-Json
    $folder = $settings.LabConfig.LabConfigFolder

    if ([string]::IsNullOrWhiteSpace($folder)) {
        # Falls through to the tracked appsettings.json value, which is the deploy server's E: drive.
        Write-Warning ("LabConfig:LabConfigFolder is not overridden in appsettings.Local.json, so the " +
                       "dashboard will use the deploy path from appsettings.json. If that drive is not " +
                       "on this machine every lab is skipped and the lab picker comes up empty.")
        return
    }

    if (-not (Test-Path $folder)) {
        Write-Warning "LabConfig:LabConfigFolder '$folder' does not exist. Every lab will be skipped."
        return
    }

    $count = (Get-ChildItem -Path $folder -Filter '*.json' -ErrorAction SilentlyContinue).Count
    Write-Host "  Lab configs: $count file(s) in $folder" -ForegroundColor DarkGray
}

function Start-App {
    param([string] $Title, [string] $Project, [string] $Url)

    Write-Host "Starting $Title -> $Url" -ForegroundColor Cyan

    # A separate window per app: each keeps its own console log, and Ctrl+C in one does not
    # take the other down with it.
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoExit', '-Command',
        "`$host.UI.RawUI.WindowTitle = '$Title'; dotnet run --project '$Project'"
    ) | Out-Null
}

Write-Host ''
Write-Host 'LRN local stack' -ForegroundColor Green
Write-Host '---------------' -ForegroundColor Green

if ($startApi) {
    Assert-LocalSettings -ProjectDirectory (Split-Path -Parent $apiProject) -AppName 'LRN.ReportsApi'
}

if ($startDashboard) {
    Assert-LocalSettings -ProjectDirectory (Split-Path -Parent $dashboardProject) -AppName 'LabMetricsDashboard'
    Assert-LabConfigFolder
}

# The API first: the dashboard queries it as pages load, so a few seconds' head start
# saves a round of "the Report Board is empty, reload".
if ($startApi) {
    Start-App -Title 'LRN.ReportsApi' -Project $apiProject -Url $apiUrl
    if ($startDashboard) { Start-Sleep -Seconds 5 }
}

if ($startDashboard) {
    Start-App -Title 'LabMetricsDashboard' -Project $dashboardProject -Url $dashboardUrl
}

Write-Host ''
Write-Host 'Both apps compile before they serve, so the first request can take ~30s.' -ForegroundColor DarkGray
if ($startApi) { Write-Host "  API      $apiUrl  (Swagger at $apiUrl/swagger)" -ForegroundColor DarkGray }
if ($startDashboard) { Write-Host "  Dashboard $dashboardUrl" -ForegroundColor DarkGray }
Write-Host ''

if (-not $NoBrowser -and $startDashboard) {
    Start-Sleep -Seconds 20
    Start-Process $dashboardUrl
}
