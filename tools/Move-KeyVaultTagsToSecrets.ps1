<#
.SYNOPSIS
  One-time move of configuration values that were stored as Key Vault TAGS into Key Vault SECRETS.

.DESCRIPTION
  The apps (LRN.ReportsApi, LabMetricsDashboard, the workers) read Key Vault SECRETS only. Values in the
  vault's Tags are never loaded - and tags are plain text to anyone with Reader on the resource group,
  so they must not hold passwords at all. This script:

    1. compares every tag with the secret of the same name and shows New / Differs / Same
       (connection strings as server + database, other values hidden - nothing secret is printed);
    2. with -Apply, writes each New / Differs value as a new secret version
       (connection strings get a doubled '\\' in the server name collapsed to one '\');
    3. with -RemoveTags, deletes all tags from the vault - only after every tag matches its secret.

  Without -Apply it changes nothing. Needs `az login` with "Key Vault Secrets Officer" on the vault
  (and "Contributor" or "Tag Contributor" on it for -RemoveTags). Restart the apps afterwards: they read
  the vault only at startup.

.EXAMPLE
  .\tools\Move-KeyVaultTagsToSecrets.ps1 -VaultName kv-lrnmetrics-prod                       # preview
  .\tools\Move-KeyVaultTagsToSecrets.ps1 -VaultName kv-lrnmetrics-prod -Apply                # copy tags to secrets
  .\tools\Move-KeyVaultTagsToSecrets.ps1 -VaultName kv-lrnmetrics-prod -Apply -RemoveTags    # copy, verify, remove tags
#>
param(
    [Parameter(Mandatory)] [string]$VaultName,
    [switch]$Apply,
    [switch]$RemoveTags
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) is not installed or not on PATH.' }

function Invoke-Az([string[]]$azArgs) {
    $out = & az @azArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($out -join "`n")
}

$vaultJson = Invoke-Az @('keyvault', 'show', '--name', $VaultName, '-o', 'json')
if (-not $vaultJson) { throw "Could not read vault $VaultName (az login? the right subscription?)." }
$vault = $vaultJson | ConvertFrom-Json
$tags = $vault.tags.PSObject.Properties | Where-Object { $_.Name -ne '' }
if (-not $tags) { Write-Host "$VaultName has no tags - nothing to move." -ForegroundColor Green; return }

function Fix-Value([string]$name, [string]$value) {
    if ($name -notlike 'ConnectionStrings--*') { return $value }
    # "ReportEngine\\SQLEXPRESS" (escaped twice somewhere on the way into the tag) -> "ReportEngine\SQLEXPRESS".
    return [regex]::Replace($value, '\\{2,}', '\')
}
function Describe([string]$name, [string]$value) {
    if ($null -eq $value) { return '(none)' }
    if ($name -notlike 'ConnectionStrings--*') { return "(hidden, $($value.Length) chars)" }
    try { $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder($value); return "$($b.DataSource) / $($b.InitialCatalog)" }
    catch { return '(unreadable connection string)' }
}
function Get-SecretValue([string]$name) {
    $json = Invoke-Az @('keyvault', 'secret', 'show', '--vault-name', $VaultName, '--name', $name, '--query', 'value', '-o', 'json')
    if ($null -eq $json) { return $null }
    return ($json | ConvertFrom-Json)
}

$plan = foreach ($t in $tags) {
    $wanted = Fix-Value $t.Name ([string]$t.Value)
    $current = Get-SecretValue $t.Name
    [pscustomobject]@{
        Name = $t.Name; Wanted = $wanted
        Status = if ($null -eq $current) { 'New' } elseif ($current -ceq $wanted) { 'Same' } else { 'Differs' }
        Secret = Describe $t.Name $current
        Tag = Describe $t.Name $wanted
    }
}
$plan | Sort-Object Status, Name | Format-Table Status, Name, Secret, Tag -AutoSize -Wrap | Out-String -Width 250 | Write-Host

$todo = @($plan | Where-Object { $_.Status -ne 'Same' })
if (-not $Apply) {
    Write-Host "$($todo.Count) secret(s) would be written. Nothing changed - run again with -Apply." -ForegroundColor Yellow
    return
}

foreach ($p in $todo) {
    # Through a temp file, so the value never appears on a command line or in the process list.
    $tmp = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($tmp, $p.Wanted, (New-Object Text.UTF8Encoding $false))
        $ok = Invoke-Az @('keyvault', 'secret', 'set', '--vault-name', $VaultName, '--name', $p.Name, '--file', $tmp, '--encoding', 'utf-8', '-o', 'none')
        if ($null -eq $ok) { throw "Writing secret $($p.Name) failed (Key Vault Secrets Officer role?)." }
        Write-Host "  set   $($p.Name)  ->  $($p.Tag)" -ForegroundColor Green
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

# Every tag must now match its secret before the tags can go.
$mismatch = @($plan | Where-Object { (Get-SecretValue $_.Name) -cne $_.Wanted } | ForEach-Object Name)
if ($mismatch) { throw "These secrets do not match their tags after writing; tags left in place: $($mismatch -join ', ')" }
Write-Host "All $($plan.Count) tag value(s) are now secrets." -ForegroundColor Green

if ($RemoveTags) {
    $ok = Invoke-Az @('tag', 'delete', '--resource-id', $vault.id, '--yes', '-o', 'none')
    if ($null -eq $ok) { throw "Removing the tags from $VaultName failed (Tag Contributor role?). Remove them in the portal: the vault > Tags." }
    Write-Host "Tags removed from $VaultName." -ForegroundColor Green
} else {
    Write-Host "Tags still hold these values in plain text - run again with -Apply -RemoveTags, or delete them in the portal." -ForegroundColor Yellow
}
Write-Host 'Restart the apps (recycle the app pools, restart the services): they read the vault only at startup.' -ForegroundColor Yellow
