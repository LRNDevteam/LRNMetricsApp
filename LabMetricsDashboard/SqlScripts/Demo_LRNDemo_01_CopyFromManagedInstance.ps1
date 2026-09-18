<#
.SYNOPSIS
    Step 1 of 4 - copy CoveLRN from Azure SQL Managed Instance into the LRNDemoLab
    database on Azure SQL Database, via BACPAC.

.DESCRIPTION
    WHY THIS IS NOT A .SQL SCRIPT
    The on-prem demo pipeline (Demo_LRNLabDemo_01_CloneDatabase.sql) does this in
    T-SQL with BACKUP DATABASE ... TO DISK and RESTORE DATABASE. None of that is
    available here:

      * Azure SQL Database supports no BACKUP and no RESTORE at all.
      * A Managed Instance native backup cannot be restored into Azure SQL
        Database - they are different engines with different file formats.
      * CREATE DATABASE ... AS COPY OF works only within Azure SQL Database, so it
        cannot reach back to the Managed Instance either.

    The supported MI -> SQL Database path is a BACPAC: a logical export of schema
    plus data, produced by SqlPackage, then imported into the target. That is what
    this script drives.

    >>>>>>>>>>>>>>>>>>>>>>>>>>  PHI WARNING  <<<<<<<<<<<<<<<<<<<<<<<<<<<<
    The .bacpac this produces contains REAL PATIENT DATA - names, dates of
    birth, subscriber and patient identifiers - in a single portable file
    that anyone with the file has all of. So does LRNDemoLab itself, until
    step 2 has run against it.

    Consequently:
      * Write the .bacpac to an encrypted local path, never a shared drive,
        a sync folder (OneDrive/Dropbox) or a public blob container.
      * Run step 2 immediately afterwards. Do not stop for the day in between.
      * Delete the .bacpac when the import succeeds - use -RemoveBacpac, which
        is the default.
      * Do not issue the LRNDemo credentials until step 2 has been verified.
    >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

.NOTES
    Requires SqlPackage, which is NOT installed on the machine this script was
    written on. Install it first:

        dotnet tool install -g microsoft.sqlpackage

    Or download "SqlPackage for Windows" from Microsoft and put it on PATH.

.EXAMPLE
    # Validate everything and report, without touching anything:
    .\Demo_LRNDemo_01_CopyFromManagedInstance.ps1 -WhatIf

.EXAMPLE
    .\Demo_LRNDemo_01_CopyFromManagedInstance.ps1 `
        -SourceServer  'covemi.public.abc123.database.windows.net,3342' `
        -TargetServer  'lrndemo.database.windows.net' `
        -Confirm:$true
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    # Managed Instance holding the live Cove database. Public endpoint uses port 3342.
    [Parameter(Mandatory = $true)] [string] $SourceServer,
    [string] $SourceDatabase = 'CoveLRN',

    # Azure SQL Database logical server that will host the demo copy.
    [Parameter(Mandatory = $true)] [string] $TargetServer,
    [string] $TargetDatabase = 'LRNDemoLab',

    # Service objective for the demo database. S2 is enough to demo on and cheap
    # to leave running; raise it for the import if the lab is large, then scale back.
    [string] $TargetEdition        = 'Standard',
    [string] $TargetServiceObjective = 'S2',

    # Where the intermediate BACPAC lands. Keep it local and encrypted - see the
    # PHI warning above.
    [string] $WorkFolder = "$env:LOCALAPPDATA\LRNDemoLab",

    # Entra ID (Azure AD) interactive is the default: it avoids putting SQL
    # passwords on a command line, where they end up in PowerShell history.
    [ValidateSet('AzureAdInteractive', 'SqlAuth')]
    [string] $AuthMode = 'AzureAdInteractive',

    [string] $SourceUser,
    [string] $TargetUser,

    # Delete the BACPAC once the import succeeds. On by default: it is the single
    # most dangerous artefact this process creates.
    [bool] $RemoveBacpac = $true
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step($text) { Write-Host "`n=== $text ===" -ForegroundColor Cyan }
function Write-Warn($text) { Write-Host "  ! $text" -ForegroundColor Yellow }

# ── Preflight ────────────────────────────────────────────────────────────────
Write-Step 'Preflight'

# Argument guards run FIRST, before the tool check. They are free, and a typo in the
# target name should surface immediately rather than after someone has installed
# SqlPackage and waited for an export to start.
#
# Every later step refuses a database whose name lacks "Demo". Enforcing the same
# rule here means a mistyped name cannot begin a multi-gigabyte export of live
# patient data into a production-shaped name that nothing downstream will scrub.
if ($TargetDatabase -notmatch 'Demo') {
    throw "Refusing to continue: -TargetDatabase '$TargetDatabase' does not contain 'Demo'. " +
          "The de-identification script in step 2 will refuse it too, which would leave real " +
          "patient data sitting in a database nobody scrubs."
}
if ($TargetDatabase -eq $SourceDatabase -and $TargetServer -eq $SourceServer) {
    throw "Refusing to continue: source and target are the same database."
}

# Written without the null-conditional operator (?.) on purpose: that is PowerShell 7
# syntax and fails to PARSE on Windows PowerShell 5.1, which is still the default
# shell on the machines this gets run from - the script would die before its first line.
$sqlPackageCmd = Get-Command sqlpackage -ErrorAction SilentlyContinue
$sqlPackage = if ($sqlPackageCmd) { $sqlPackageCmd.Source } else { $null }

if (-not $sqlPackage) {
    throw "SqlPackage was not found on PATH. Install it with:`n" +
          "    dotnet tool install -g microsoft.sqlpackage`n" +
          "then reopen the shell so PATH picks it up."
}
Write-Host "  SqlPackage : $sqlPackage"

New-Item -ItemType Directory -Force -Path $WorkFolder | Out-Null
$bacpac = Join-Path $WorkFolder "$SourceDatabase`_$(Get-Date -Format yyyyMMdd_HHmmss).bacpac"

Write-Host "  Source     : $SourceDatabase on $SourceServer"
Write-Host "  Target     : $TargetDatabase on $TargetServer ($TargetEdition / $TargetServiceObjective)"
Write-Host "  BACPAC     : $bacpac"
Write-Warn 'This BACPAC will contain real patient data until step 2 has run.'

# Shared SqlPackage auth arguments.
function Get-AuthArgs([string] $user) {
    if ($AuthMode -eq 'AzureAdInteractive') {
        # Prompts once per connection in a browser. No secret on the command line.
        return @('/ua:True')
    }
    if (-not $user) { throw "SqlAuth was selected but no user was supplied for this connection." }
    return @("/SourceUser:$user")   # SqlPackage prompts for the password
}

if (-not $PSCmdlet.ShouldProcess("$SourceDatabase -> $TargetDatabase", 'Export and import a database containing PHI')) {
    Write-Host "`nDry run only - nothing was exported or imported." -ForegroundColor Green
    return
}

# ── Export ───────────────────────────────────────────────────────────────────
Write-Step "Export $SourceDatabase to BACPAC"
Write-Host '  This reads the live database. It is a logical export, not a backup:'
Write-Host '  expect it to take considerably longer than a .bak on a large lab.'

$exportArgs = @(
    '/Action:Export'
    "/SourceServerName:$SourceServer"
    "/SourceDatabaseName:$SourceDatabase"
    "/TargetFile:$bacpac"
    '/p:VerifyExtraction=True'
    # A long-running export against a live instance will otherwise die on a
    # transient Azure disconnect and lose the whole run.
    '/SourceTimeout:0'
)
if ($AuthMode -eq 'AzureAdInteractive') { $exportArgs += '/ua:True' }
elseif ($SourceUser) { $exportArgs += "/SourceUser:$SourceUser" }

& $sqlPackage @exportArgs
if ($LASTEXITCODE -ne 0) { throw "SqlPackage export failed with exit code $LASTEXITCODE. Nothing was imported." }

$sizeMb = [math]::Round((Get-Item $bacpac).Length / 1MB, 1)
Write-Host "  Exported $sizeMb MB" -ForegroundColor Green

# ── Import ───────────────────────────────────────────────────────────────────
Write-Step "Import BACPAC into $TargetDatabase"
Write-Warn "If $TargetDatabase already exists the import FAILS by design - SqlPackage will not"
Write-Warn "overwrite. Drop it first if you are refreshing the demo."

$importArgs = @(
    '/Action:Import'
    "/SourceFile:$bacpac"
    "/TargetServerName:$TargetServer"
    "/TargetDatabaseName:$TargetDatabase"
    "/p:DatabaseEdition=$TargetEdition"
    "/p:DatabaseServiceObjective=$TargetServiceObjective"
    '/TargetTimeout:0'
)
if ($AuthMode -eq 'AzureAdInteractive') { $importArgs += '/ua:True' }
elseif ($TargetUser) { $importArgs += "/TargetUser:$TargetUser" }

& $sqlPackage @importArgs
if ($LASTEXITCODE -ne 0) {
    throw "SqlPackage import failed with exit code $LASTEXITCODE. " +
          "The BACPAC is still at $bacpac and still contains PHI - delete it if you are abandoning this run."
}

Write-Host "  Imported into $TargetDatabase" -ForegroundColor Green

# ── Clean up the PHI-bearing artefact ────────────────────────────────────────
if ($RemoveBacpac) {
    Remove-Item $bacpac -Force
    Write-Host "  Deleted the BACPAC." -ForegroundColor Green
} else {
    Write-Warn "BACPAC KEPT at $bacpac - it contains real patient data. Delete it when you are done."
}

Write-Step 'Done - and NOT yet safe to demo'
Write-Host @"
  $TargetDatabase is currently a byte-faithful copy of live Cove data.
  It still contains real patient names, dates of birth and identifiers.

  Next, connected DIRECTLY to $TargetDatabase (Azure SQL Database cannot
  switch database context, so there is no USE statement in these):

    2. Demo_LRNDemo_02_Deidentify.sql          @Apply = 0 first, read the list
    3. Demo_LRNDemo_03_RestampLabIdentity.sql  @Apply = 0 first
    4. Demo_LRNDemo_04_RegisterLab.sql         against LRNMaster, not this database

  Do not issue the LRNDemo credentials until step 2 has been verified.
"@ -ForegroundColor Yellow
