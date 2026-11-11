<#
.SYNOPSIS
  Shows which database every lab reaches, resolved the way LRN.ReportsApi does (LabConnectionResolver):
  Key Vault secret ConnectionStrings--Lab-{Id}, then the lab's ConnectionKey, then the built-in key
  (InHealthConn, CoveConnection, ...), then a secret whose name matches the lab. Prints server and
  database only - never a password.

.DESCRIPTION
  Read-only. Needs the Azure CLI signed in (az login) with "Key Vault Secrets User" on the vault.
  -TestConnection also opens each connection and checks the database name and the AR Workbench
  tables (dbo.ARWB_Claim). The last section prints what the running API actually loaded at its last
  start, from its log - the API reads the vault only at startup, so a changed secret needs a restart.

.EXAMPLE
  .\tools\Check-LabConnections.ps1
  .\tools\Check-LabConnections.ps1 -TestConnection
  .\tools\Check-LabConnections.ps1 -VaultName lrn-testapp-kv -AppSettings "C:\LRN-Files\ApplicationFolder\ReportWebApp\WWW\Test_LRNAnalystics\LRNApi\appsettings.json"
#>
param(
    [string]$VaultName = 'kv-lrnmetrics-prod',
    [string]$AppSettings = 'C:\LRN-Files\ApplicationFolder\ReportWebApp\WWW\Production_LRNAnalysitcs\LRNApi\appsettings.json',
    [string]$ApiLogFolder = 'C:\LRN-Files\ApplicationFolder\DenialWorkFlow\Logs\Api',
    [switch]$TestConnection
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) is not installed or not on PATH.' }

# Same as LabConnectionResolver.knownKey.
$knownKeys = @{
    PCRLABSOFAMERICA = 'PCRLOAConnStr'; PCRLOA = 'PCRLOAConnStr'; COVE = 'CoveConnection'
    INHEALTHDTR = 'InHealthConn'; INHEALTH = 'InHealthConn'; ELIXIR = 'ElixirConnection'
    VARIANTX = 'VariantXConnection'; ANALYZEPATHOLOGY = 'AnalyzePathologyConnStr'; WELLHEALTH = 'WellHealthConnStr'
    CERTUS = 'CertusConnection'; CERTUSLABORATORIES = 'CertusConnection'; BEECHTREE = 'BeechTreeConnStr'
    AUGUSTUSLABS = 'AugustusConnStr'; AUGUSTUS = 'AugustusConnStr'; NORTHWEST = 'NWLConnection'; NWL = 'NWLConnection'
    PCRDXAL = 'PCRALConnection'; PCRDXCO = 'PCRDxConnection'; PHILIFE = 'PhiLifeConnStr'; RISINGTIDES = 'RisingTidesConnStr'
}
function Normalize([string]$s) { (($s -replace '[^A-Za-z0-9]', '')).ToUpperInvariant() }

# appsettings.json allows // comments; strip whole-line ones before parsing.
$json = (Get-Content $AppSettings -Raw) -split "`n" | Where-Object { $_.Trim() -notmatch '^//' }
$labs = (($json -join "`n") | ConvertFrom-Json).LabConfig.LabsID | Where-Object { $_.Id -gt 0 -and ($null -eq $_.IsActive -or $_.IsActive) }

Write-Host "Vault $VaultName - reading ConnectionStrings secrets..." -ForegroundColor Cyan
$secretNames = az keyvault secret list --vault-name $VaultName --query "[?starts_with(name,'ConnectionStrings--')].name" -o tsv
if ($LASTEXITCODE -ne 0) { throw "Could not list secrets in $VaultName (az login? Key Vault Secrets User role?)." }
$secretNames = @($secretNames | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$cache = @{}
function Get-Secret([string]$key) {
    $name = "ConnectionStrings--$key"
    $hit = $secretNames | Where-Object { $_ -ieq $name } | Select-Object -First 1
    if (-not $hit) { return $null }
    if (-not $cache.ContainsKey($hit)) {
        $s = az keyvault secret show --vault-name $VaultName --name $hit --query "{v:value,u:attributes.updated}" -o json | ConvertFrom-Json
        $cache[$hit] = $s
    }
    $cache[$hit]
}
function Describe([string]$cs) {
    try { $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder($cs); return @{ Server = $b.DataSource; Database = $b.InitialCatalog; User = $b.UserID; Trust = $b.TrustServerCertificate } }
    catch { return @{ Server = '(unreadable)'; Database = ''; User = ''; Trust = '' } }
}
function Resolve-Lab($lab) {
    $tries = @("Lab-$($lab.Id)")
    if ($lab.ConnectionKey) { $tries += $lab.ConnectionKey.Trim() }
    $k = $knownKeys[(Normalize $lab.Name)]; if ($k) { $tries += $k }
    foreach ($t in $tries) { $s = Get-Secret $t; if ($s -and $s.v) { return @{ Key = $t; Secret = $s; How = '' } } }
    $norm = Normalize $lab.Name
    foreach ($full in $secretNames) {
        $name = $full.Substring('ConnectionStrings--'.Length); $key = Normalize $name
        if ($key.Contains($norm) -or $norm.Contains(($key -replace 'CONNECTION', '' -replace 'CONNSTR', ''))) {
            return @{ Key = $name; Secret = (Get-Secret $name); How = ' (name match)' }
        }
    }
    return $null
}

$rows = @()
$master = Get-Secret 'DefaultConnection'
$all = @([pscustomobject]@{ Id = 0; Name = 'LRNMaster (DefaultConnection)' }) + @($labs)
foreach ($lab in $all) {
    $r = if ($lab.Id -eq 0) { if ($master) { @{ Key = 'DefaultConnection'; Secret = $master; How = '' } } } else { Resolve-Lab $lab }
    if (-not $r) { $rows += [pscustomobject]@{ LabId = $lab.Id; Lab = $lab.Name; Secret = '(none found)'; Server = ''; Database = ''; Login = ''; TrustCert = ''; Updated = ''; Test = '' }; continue }
    $d = Describe $r.Secret.v
    $test = ''
    if ($TestConnection) {
        try {
            $c = New-Object System.Data.SqlClient.SqlConnection($r.Secret.v); $c.Open()
            $cmd = $c.CreateCommand(); $cmd.CommandText = "SELECT DB_NAME(), CASE WHEN OBJECT_ID(N'dbo.ARWB_Claim', N'U') IS NULL THEN 0 ELSE 1 END"
            $rd = $cmd.ExecuteReader(); [void]$rd.Read()
            $test = "OK db=$($rd.GetString(0)) ARWB=" + $(if ($rd.GetInt32(1) -eq 1) { 'yes' } else { 'NO' })
            $c.Close()
        } catch { $test = 'FAIL: ' + ($_.Exception.Message -split "`n")[0] }
    }
    $rows += [pscustomobject]@{
        LabId = $lab.Id; Lab = $lab.Name; Secret = "$($r.Key)$($r.How)"; Server = $d.Server; Database = $d.Database
        Login = $d.User; TrustCert = $d.Trust; Updated = $r.Secret.u; Test = $test
    }
}
$rows | Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host

$local = $rows | Where-Object { $_.Server -match '^(ReportEngine|localhost|\.|\(local\))' }
if ($local) { Write-Host ("Labs still on a local SQL Server: " + (($local | ForEach-Object { $_.Lab }) -join ', ')) -ForegroundColor Yellow }

# What the API process actually loaded at its last start (it reads the vault once, at startup).
$root = Split-Path -Parent $AppSettings
$log = Get-ChildItem $ApiLogFolder -Filter 'api-*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3
if ($log) {
    $lines = $log | Sort-Object LastWriteTime | Select-String -Pattern 'KeyVault: |\) : database|\): database|Content root path' | ForEach-Object { $_.Line }
    # A start block is the lines before its "Content root path"; keep the last block of this API's folder.
    $block = @(); $last = @()
    foreach ($l in $lines) { $block += $l; if ($l -match 'Content root path: (.*)$') { if ($Matches[1].Trim() -ieq $root) { $last = $block }; $block = @() } }
    Write-Host "`nLast start of the API in $root (from its log):" -ForegroundColor Cyan
    if ($last) { $last | ForEach-Object { Write-Host "  $($_.Substring(0, [Math]::Min(220, $_.Length)))" } }
    else { Write-Host '  (no start found in the last 3 log files)' }
    Write-Host 'If a secret above was changed after that time, restart the API (recycle its app pool) to load it.' -ForegroundColor Yellow
}
