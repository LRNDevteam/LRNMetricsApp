<#
.SYNOPSIS
    Creates the LRN configuration values as real secrets in kv-lrnmetrics-prod.

.DESCRIPTION
    Two sources, because they are not equally trustworthy:

      -SourceJson <path>   Read an appsettings.Local.json that is KNOWN to work. Preferred for the
                           connection strings and the JWT signing key - these are the exact values
                           the apps run on today, so there is nothing to get wrong.

      (default)            Read the vault's own TAGS. Needed for the few settings that exist only
                           there (DenialWorkflowAuth--Issuer / --Audience / --TokenMinutes and the
                           ExternalApiClients pair).

    Tags are resource metadata, not vault contents: readable by anyone with Reader on the vault,
    exposed in `az resource show`, ARM exports, Resource Graph and cost exports, capped at 256
    characters, and invisible to AddAzureKeyVault, which only reads the secrets collection.

    Values reach `az` through a temp file rather than --value, so they never appear in a process
    command line, shell history or transcript. The temp file is overwritten and deleted after.

    This script NEVER deletes tags. Verify the secrets, confirm the apps run, then remove them.

.PARAMETER VaultName
    Key Vault name. Defaults to kv-lrnmetrics-prod.

.PARAMETER SourceJson
    Path to an appsettings-style JSON file. Only the ConnectionStrings, DenialWorkflowAuth and
    ExternalApiClients sections are read; "//" comment keys and everything else are ignored.

.PARAMETER SkipExisting
    Leave a secret alone if it already exists. Use this on a second pass so a tag never overwrites
    a value you already loaded from known-good JSON.

.PARAMETER KeepDoubledBackslashes
    Tag mode only. By default a literal '\\' collapses to '\', because the tags were written with
    one extra level of escaping - 'Server=ReportEngine\\SQLEXPRESS' has to become
    'Server=ReportEngine\SQLEXPRESS' or every SQLEXPRESS lab fails to connect. A value that already
    has a single backslash is left untouched either way, so this is safe if the tags turn out to be
    correct. JSON mode never rewrites anything.

.EXAMPLE
    # Pass 1 - the values that matter, from a file proven to work
    ./KeyVault-MigrateTagsToSecrets.ps1 -SourceJson .\appsettings.Local.json -WhatIf
    ./KeyVault-MigrateTagsToSecrets.ps1 -SourceJson .\appsettings.Local.json

    # Pass 2 - fill in whatever only exists as a tag, without touching pass 1
    ./KeyVault-MigrateTagsToSecrets.ps1 -SkipExisting -WhatIf
    ./KeyVault-MigrateTagsToSecrets.ps1 -SkipExisting

.NOTES
    Needs Azure CLI and `az login`; easiest in Azure Cloud Shell, which has both.
    The signed-in account needs the DATA-plane role 'Key Vault Secrets Officer' on the vault.
    The vault has enableRbacAuthorization=true, so subscription Owner alone returns 403.

    -WhatIf with -SourceJson runs entirely offline - no CLI, no login - so you can check exactly
    which names and value lengths would be created before touching anything.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $VaultName = 'kv-lrnmetrics-prod',
    [string] $SourceJson,
    [switch] $SkipExisting,
    [switch] $KeepDoubledBackslashes
)

$ErrorActionPreference = 'Stop'

# Only these sections are configuration the apps read. Anything else in the file stays local.
$AllowedSections = @('ConnectionStrings', 'DenialWorkflowAuth', 'ExternalApiClients')

function Test-AzAvailable {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI ('az') is not on PATH. Run this from Azure Cloud Shell, or install the CLI and 'az login' first."
    }
}

# appsettings nesting -> flat config keys with '--' where configuration uses ':'.
function ConvertTo-SecretMap {
    param($Node, [string]$Prefix, [hashtable]$Acc)

    foreach ($prop in $Node.PSObject.Properties) {
        if ($prop.Name.StartsWith('//')) { continue }   # "//Comment" keys are documentation

        $key = if ($Prefix) { "$Prefix--$($prop.Name)" } else { $prop.Name }
        $value = $prop.Value

        if ($null -eq $value) { continue }

        if ($value -is [System.Management.Automation.PSCustomObject]) {
            ConvertTo-SecretMap -Node $value -Prefix $key -Acc $Acc
        }
        elseif ($value -is [System.Object[]]) {
            for ($i = 0; $i -lt $value.Count; $i++) {
                $item = $value[$i]
                if ($item -is [System.Management.Automation.PSCustomObject]) {
                    ConvertTo-SecretMap -Node $item -Prefix "$key--$i" -Acc $Acc
                } else {
                    $Acc["$key--$i"] = [string]$item
                }
            }
        }
        else {
            $Acc[$key] = [string]$value
        }
    }
}

# ── Gather the values ────────────────────────────────────────────────────────
$map = @{}
$mode = ''

if ($SourceJson) {
    $mode = "JSON ($SourceJson)"
    if (-not (Test-Path $SourceJson)) { throw "Source file not found: $SourceJson" }

    $json = Get-Content $SourceJson -Raw | ConvertFrom-Json
    foreach ($section in $AllowedSections) {
        $node = $json.PSObject.Properties | Where-Object { $_.Name -eq $section }
        if ($node) { ConvertTo-SecretMap -Node $node.Value -Prefix $section -Acc $map }
    }
    Write-Host "Read $($map.Count) value(s) from $SourceJson" -ForegroundColor Cyan
}
else {
    $mode = "vault tags"
    Test-AzAvailable
    Write-Host "Reading tags from vault '$VaultName'..." -ForegroundColor Cyan

    $tagsJson = az keyvault show --name $VaultName --query tags -o json
    if ($LASTEXITCODE -ne 0) { throw "Could not read vault '$VaultName'. Check the name, your subscription context, and that you are logged in." }

    $tags = $tagsJson | ConvertFrom-Json
    if ($null -eq $tags) { Write-Host "No tags on the vault - nothing to migrate."; return }

    foreach ($t in $tags.PSObject.Properties) {
        if ($t.Name -notlike '*--*') { continue }   # ordinary tags (Environment, Owner) stay put
        $map[$t.Name] = [string]$t.Value
    }
    Write-Host "Found $($map.Count) configuration tag(s)." -ForegroundColor Cyan
}

if ($map.Count -eq 0) { Write-Host "Nothing to create."; return }

# ── Existing secrets, so -SkipExisting means something ───────────────────────
$existing = @()
if (-not $WhatIfPreference -or -not $SourceJson) {
    Test-AzAvailable
    $listed = az keyvault secret list --vault-name $VaultName --query "[].name" -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and $listed) { $existing = @($listed | ConvertFrom-Json) }
}

Write-Host ""
$created = 0; $skipped = 0; $failed = 0; $unescaped = @()
$tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("kvmig-" + [Guid]::NewGuid().ToString('N') + ".txt")

try {
    foreach ($name in ($map.Keys | Sort-Object)) {
        $value = $map[$name]

        # Key Vault secret names allow only alphanumerics and dashes.
        if ($name -notmatch '^[0-9a-zA-Z-]+$') {
            Write-Warning "SKIP  $name - not a legal secret name (letters, digits and '-' only)."
            $skipped++; continue
        }
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Warning "SKIP  $name - empty value."
            $skipped++; continue
        }
        if ($SkipExisting -and $existing -contains $name) {
            Write-Host "EXISTS $name - left alone" -ForegroundColor DarkGray
            $skipped++; continue
        }

        # Tag mode only: undo the extra escaping. A single backslash is already correct and
        # will not match, so this cannot damage a well-formed value.
        if (-not $SourceJson -and -not $KeepDoubledBackslashes -and $value.Contains('\\')) {
            $value = $value.Replace('\\', '\')
            $unescaped += $name
        }

        # Length only - never the value.
        if ($PSCmdlet.ShouldProcess($name, "Create secret in $VaultName ($($value.Length) chars)")) {
            Test-AzAvailable
            # WriteAllText, not Out-File: no trailing newline, which would corrupt the secret.
            [System.IO.File]::WriteAllText($tempFile, $value, (New-Object System.Text.UTF8Encoding($false)))

            az keyvault secret set --vault-name $VaultName --name $name --file $tempFile --encoding utf-8 --output none
            if ($LASTEXITCODE -eq 0) {
                Write-Host "OK    $name" -ForegroundColor Green
                $created++
            } else {
                Write-Warning "FAIL  $name - see the az error above."
                $failed++
            }
        } else {
            Write-Host "WHATIF $name ($($value.Length) chars)" -ForegroundColor Yellow
        }
    }
}
finally {
    if (Test-Path $tempFile) {
        [System.IO.File]::WriteAllText($tempFile, (' ' * 4096))   # overwrite before deleting
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "Source: $mode"
Write-Host "Created: $created   Skipped: $skipped   Failed: $failed"

if ($unescaped.Count -gt 0) {
    Write-Host ""
    Write-Host "Collapsed a doubled backslash in $($unescaped.Count) value(s):" -ForegroundColor Yellow
    $unescaped | ForEach-Object { Write-Host "  $_" }
}

if ($failed -eq 0 -and $created -gt 0) {
    Write-Host ""
    Write-Host "Next:" -ForegroundColor Cyan
    Write-Host "  1. az keyvault secret list --vault-name $VaultName -o table"
    Write-Host "  2. Recycle the app pool. Startup now fails with a named error if the vault is"
    Write-Host "     missing anything required, so a clean start means it read what it needed."
    Write-Host "  3. Only then strip the credential tags, and rotate everything that sat in one."
}
