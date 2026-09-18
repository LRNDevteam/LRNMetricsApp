<#
.SYNOPSIS
    Step 1, OPTION A (recommended) - create LRNDemoLab as a copy of CoveLRN on the
    SAME Azure SQL Managed Instance, using the instance's own automatic backups.

.DESCRIPTION
    Managed Instance already takes automatic backups of every database and keeps
    them for the retention period. A point-in-time restore to a NEW database name
    on the same instance copies CoveLRN without:

      * any storage account, container or SAS token,
      * any BACKUP statement running against the live database,
      * any .bacpac file sitting on someone's laptop.

    That last point is the reason to prefer this over the BACKUP TO URL route: the
    copy never leaves the instance, so there is no portable file of patient data to
    lose track of. The only thing holding PHI is LRNDemoLab itself, and step 2
    scrubs that.

    WHAT THIS IS NOT
    This does not work MI -> Azure SQL Database. Point-in-time restore targets the
    same instance (or another Managed Instance). If LRNDemoLab has to live on Azure
    SQL Database, use Demo_LRNDemo_01_CopyFromManagedInstance.ps1 (BACPAC) instead.

    >>>>>>>>>>>>>>>>>>>>>>>>>>  PHI WARNING  <<<<<<<<<<<<<<<<<<<<<<<<<<<<
    LRNDemoLab is a faithful copy of live Cove data the moment this finishes.
    Real names, dates of birth, subscriber and patient identifiers.
    Run step 2 immediately. Do not issue the LRNDemo credentials until it has
    been verified.
    >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

.NOTES
    Requires the Az.Sql module:

        Install-Module -Name Az.Sql -Scope CurrentUser -Repository PSGallery -Force
        Connect-AzAccount

    Needs SQL Managed Instance Contributor (or equivalent) on the instance.

.EXAMPLE
    # Report what it would do, contacting Azure only to read:
    .\Demo_LRNDemo_01a_CopyOnSameMI.ps1 -ResourceGroupName rg-lrn -InstanceName covemi -WhatIf

.EXAMPLE
    .\Demo_LRNDemo_01a_CopyOnSameMI.ps1 -ResourceGroupName rg-lrn -InstanceName covemi
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
    [Parameter(Mandatory = $true)] [string] $InstanceName,

    [string] $SourceDatabase = 'CoveLRN',
    [string] $TargetDatabase = 'LRNDemoLab',

    # Defaults to "as recent as the instance allows". Restore cannot use the last
    # few minutes, so the script steps back a safety margin rather than failing.
    [datetime] $PointInTime = [datetime]::UtcNow.AddMinutes(-15),

    [int] $TimeoutMinutes = 240
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Write-Warn($t) { Write-Host "  ! $t" -ForegroundColor Yellow }

Write-Step 'Preflight'

# Cheap argument guards first - a typo should surface before any Azure round trip.
# Every later step refuses a database whose name lacks "Demo"; the same rule here
# stops a mistyped name producing a copy of live patient data that nothing scrubs.
if ($TargetDatabase -notmatch 'Demo') {
    throw "Refusing to continue: -TargetDatabase '$TargetDatabase' does not contain 'Demo'. " +
          "Step 2 would refuse it too, leaving real patient data in a database nobody de-identifies."
}
if ($TargetDatabase -eq $SourceDatabase) {
    throw "Refusing to continue: source and target are the same database name."
}

if (-not (Get-Module -ListAvailable -Name Az.Sql)) {
    throw "The Az.Sql module is not installed. Run:`n" +
          "    Install-Module -Name Az.Sql -Scope CurrentUser -Repository PSGallery -Force`n" +
          "    Connect-AzAccount"
}
Import-Module Az.Sql -ErrorAction Stop

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) { throw "Not signed in to Azure. Run Connect-AzAccount first." }
Write-Host "  Subscription : $($context.Subscription.Name)"

# ── Confirm the source exists and read its earliest restore point ────────────
$source = Get-AzSqlInstanceDatabase -ResourceGroupName $ResourceGroupName `
                                    -InstanceName $InstanceName `
                                    -Name $SourceDatabase -ErrorAction Stop

Write-Host "  Source       : $SourceDatabase on $InstanceName"
Write-Host "  Status       : $($source.Status)"

# Restoring to a name that already exists fails. Say so now rather than after a
# multi-hour wait - and say it as the refresh instruction it actually is.
$existing = Get-AzSqlInstanceDatabase -ResourceGroupName $ResourceGroupName `
                                      -InstanceName $InstanceName `
                                      -Name $TargetDatabase -ErrorAction SilentlyContinue
if ($existing) {
    throw "$TargetDatabase already exists on $InstanceName. Point-in-time restore will not " +
          "overwrite it. To refresh the demo, drop it first:`n" +
          "    Remove-AzSqlInstanceDatabase -ResourceGroupName $ResourceGroupName " +
          "-InstanceName $InstanceName -Name $TargetDatabase`n" +
          "then re-run this, followed by steps 2 and 3."
}

# The earliest point the instance can still restore from. Asking for anything
# before it fails with an error that does not explain itself well.
$earliest = $source.EarliestRestorePoint
if ($earliest) {
    Write-Host "  Restore window: $earliest (UTC) .. now"
    if ($PointInTime -lt $earliest) {
        throw "-PointInTime $PointInTime is before the earliest restore point $earliest. " +
              "Pick a later time, or extend the instance's backup retention."
    }
}

Write-Host "  Target       : $TargetDatabase"
Write-Host "  Point in time: $($PointInTime.ToString('u'))"
Write-Warn 'The restored copy contains real patient data until step 2 has run.'

if (-not $PSCmdlet.ShouldProcess("$SourceDatabase -> $TargetDatabase on $InstanceName",
                                 'Restore a copy of a database containing PHI')) {
    Write-Host "`nDry run only - nothing was restored." -ForegroundColor Green
    return
}

# ── Restore ──────────────────────────────────────────────────────────────────
Write-Step "Restoring $SourceDatabase to $TargetDatabase"
Write-Host '  This runs on the instance and takes roughly as long as the database is large.'
Write-Host '  It does not read the live database directly, so Cove is unaffected.'

$started = Get-Date

Restore-AzSqlInstanceDatabase -FromPointInTimeBackup `
    -ResourceGroupName $ResourceGroupName `
    -InstanceName $InstanceName `
    -Name $SourceDatabase `
    -PointInTime $PointInTime `
    -TargetInstanceDatabaseName $TargetDatabase `
    -ErrorAction Stop | Out-Null

# The cmdlet returns when the control-plane operation is accepted, so poll until
# the database is actually online rather than reporting success too early.
Write-Step 'Waiting for the copy to come online'
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)

do {
    Start-Sleep -Seconds 30
    $db = Get-AzSqlInstanceDatabase -ResourceGroupName $ResourceGroupName `
                                    -InstanceName $InstanceName `
                                    -Name $TargetDatabase -ErrorAction SilentlyContinue
    $status = if ($db) { $db.Status } else { 'Creating' }
    Write-Host ("  {0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $status)

    if ((Get-Date) -gt $deadline) {
        throw "Gave up waiting after $TimeoutMinutes minutes. The restore may still be running - " +
              "check the instance in the portal before starting again."
    }
} while ($status -ne 'Online')

Write-Host ("  Online after {0:hh\:mm\:ss}" -f ((Get-Date) - $started)) -ForegroundColor Green

Write-Step 'Done - and NOT yet safe to demo'
Write-Host @"
  $TargetDatabase is a faithful copy of live Cove data. It still contains real
  patient names, dates of birth and identifiers.

  Next, connected to ${TargetDatabase}:

    2. Demo_LRNDemo_02_Deidentify.sql          @Apply = 0 first, read the list
    3. Demo_LRNDemo_03_RestampLabIdentity.sql  @Apply = 0 first
    4. Demo_LRNDemo_04_RegisterLab.sql         against LRNMaster, not this database

  Do not issue the LRNDemo credentials until step 2 has been verified.
"@ -ForegroundColor Yellow
