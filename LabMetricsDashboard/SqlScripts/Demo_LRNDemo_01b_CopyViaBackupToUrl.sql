/* ============================================================================
   Step 1, OPTION B - create LRNDemoLab from CoveLRN on Azure SQL Managed
   Instance, using COPY_ONLY backup to blob storage and restore from it.

   >>> THIS IS ALL T-SQL. Run it from SSMS connected to the Managed Instance. <<<

   WHEN TO USE THIS INSTEAD OF OPTION A
   Option A (Demo_LRNDemo_01a_CopyOnSameMI.ps1) restores from the instance's own
   automatic backups and needs no storage account at all. Prefer it. Use this
   script when you specifically need:

     * a copy onto a DIFFERENT Managed Instance, or
     * a backup file you keep deliberately (a fixed demo baseline to re-restore).

   NOT SQL SERVER EXPRESS
   "Express" does not enter into this. CoveLRN lives on a Managed Instance, which
   is a different engine: it backs up to URL (blob), never to a local disk path,
   and it does not expose the file system. A local Express instance cannot restore
   an MI backup either - the paths this script writes are blob URLs, not folders.

   WHY COPY_ONLY IS NOT OPTIONAL
   Managed Instance runs its own automatic backup chain. A normal full backup
   would take ownership of that chain and break the instance's own point-in-time
   restore for CoveLRN. MI therefore only permits COPY_ONLY native backups, and
   this script uses one. Do not remove it.

   >>>>>>>>>>>>>>>>>>>>>>>>>>>  PHI WARNING  <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
   The .bak this writes to blob storage contains REAL PATIENT DATA - names,
   dates of birth, subscriber and patient identifiers - in one portable file.
   So does LRNDemoLab, until step 2 has run.

     * Use a PRIVATE container. No anonymous access, no broad SAS.
     * Delete the blob once the restore succeeds - step 4 at the bottom.
     * Run step 2 immediately afterwards.
     * Do not issue the LRNDemo credentials until step 2 is verified.
   >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
   ============================================================================ */

SET NOCOUNT ON;
GO

/* ════════════════════════════════════════════════════════════════════════════
   BEFORE YOU RUN ANY OF THIS - create the container and a SAS token.

   In Azure PowerShell (once; the SAS is what SQL authenticates with):

     $ctx = New-AzStorageContext -StorageAccountName 'lrnbackups' -UseConnectedAccount
     New-AzStorageContainer -Name 'midemo' -Context $ctx -Permission Off

     # Read/Write/Delete/List are all required - MI writes the blob, reads it
     # back, and lists the container. A read-only SAS fails the BACKUP.
     $sas = New-AzStorageContainerSASToken -Name 'midemo' -Context $ctx `
              -Permission rwdl -ExpiryTime (Get-Date).AddHours(12)

     # Strip the leading '?' before pasting into @Sas below - CREATE CREDENTIAL
     # rejects it, with an error that does not mention the '?'.
     $sas.TrimStart('?')

   ════════════════════════════════════════════════════════════════════════════ */

/* ── Settings ────────────────────────────────────────────────────────────── */
DECLARE @SourceDb   SYSNAME        = N'CoveLRN';
DECLARE @DemoDb     SYSNAME        = N'LRNDemoLab';
DECLARE @Container  NVARCHAR(400)  = N'https://lrnbackups.blob.core.windows.net/midemo';
DECLARE @Sas        NVARCHAR(MAX)  = N'<paste the SAS here, WITHOUT the leading ?>';

/* Safety switch. Leave at 0 to validate and print the statements without
   running them; set to 1 only once the printed plan looks right. */
DECLARE @Apply      BIT = 0;

/* ── Guards ──────────────────────────────────────────────────────────────── */
IF DB_ID(@SourceDb) IS NULL
BEGIN
    DECLARE @NoSrc NVARCHAR(300) = N'Source database "' + @SourceDb + N'" is not on this instance.';
    THROW 51001, @NoSrc, 1;
END

/* Same rule every later step enforces: a target without "Demo" in its name would
   be refused by the de-identify script, which is exactly how a copy of live
   patient data ends up sitting somewhere nobody scrubs. */
IF @DemoDb = @SourceDb OR @DemoDb NOT LIKE N'%Demo%'
    THROW 51002, N'@DemoDb must differ from @SourceDb and must contain "Demo". Refusing to continue.', 1;

IF @Sas LIKE N'?%'
    THROW 51003, N'Remove the leading "?" from @Sas - CREATE CREDENTIAL rejects it.', 1;

IF @Sas LIKE N'%<paste%'
    THROW 51004, N'Set @Sas to a real SAS token first.', 1;

IF DB_ID(@DemoDb) IS NOT NULL
    THROW 51005, N'The demo database already exists. DROP it first, then re-run - that is the refresh path.', 1;

/* This must be a Managed Instance. EngineEdition 8 = Managed Instance.
   On a box instance the URL syntax below is valid but the guidance is not. */
IF CAST(SERVERPROPERTY('EngineEdition') AS INT) <> 8
    THROW 51006, N'This is not an Azure SQL Managed Instance. BACKUP TO URL guidance here does not apply.', 1;

DECLARE @Stamp   NVARCHAR(20)  = FORMAT(SYSUTCDATETIME(), N'yyyyMMdd_HHmmss');
DECLARE @BakUrl  NVARCHAR(600) = @Container + N'/' + @SourceDb + N'_ForDemo_' + @Stamp + N'.bak';
DECLARE @Sql     NVARCHAR(MAX);

PRINT N'Source    : ' + @SourceDb;
PRINT N'Target    : ' + @DemoDb;
PRINT N'Backup to : ' + @BakUrl;
PRINT N'';

/* ── 1. Credential for the container ─────────────────────────────────────────
   The credential NAME must equal the container URL exactly - no trailing slash.
   SQL matches it by prefix against the URL in BACKUP/RESTORE; a mismatch shows
   up as a generic "Cannot open backup device" that gives no hint of the cause. */
IF EXISTS (SELECT 1 FROM sys.credentials WHERE name = @Container)
BEGIN
    PRINT N'-- Dropping and recreating the credential (the SAS may have expired).';
    SET @Sql = N'DROP CREDENTIAL ' + QUOTENAME(@Container) + N';';
    IF @Apply = 1 EXEC sys.sp_executesql @Sql; ELSE PRINT @Sql;
END

SET @Sql = N'CREATE CREDENTIAL ' + QUOTENAME(@Container) + N'
    WITH IDENTITY = ''SHARED ACCESS SIGNATURE'', SECRET = ''' + REPLACE(@Sas, N'''', N'''''') + N''';';

IF @Apply = 1
BEGIN
    EXEC sys.sp_executesql @Sql;
    PRINT N'Credential created for ' + @Container;
END
ELSE
    PRINT N'-- CREATE CREDENTIAL [' + @Container + N'] WITH IDENTITY = ''SHARED ACCESS SIGNATURE'', SECRET = ''<redacted>'';';

/* ── 2. COPY_ONLY backup ─────────────────────────────────────────────────────
   COMPRESSION is supported on Managed Instance and roughly halves both the blob
   and the transfer time. STATS gives progress on what is otherwise a long silent
   operation. */
SET @Sql = N'BACKUP DATABASE ' + QUOTENAME(@SourceDb) + N'
    TO URL = ''' + @BakUrl + N'''
    WITH COPY_ONLY, COMPRESSION, STATS = 5;';

PRINT N'';
IF @Apply = 1
BEGIN
    PRINT N'Backing up (this reads the live database; Cove stays online)...';
    EXEC sys.sp_executesql @Sql;
END
ELSE
    PRINT @Sql;

/* ── 3. Restore under the demo name ──────────────────────────────────────────
   No WITH MOVE: Managed Instance manages its own file layout, so the logical
   files land wherever the instance puts them. That is the one place this is
   SIMPLER than the on-prem version of the same script. */
SET @Sql = N'RESTORE DATABASE ' + QUOTENAME(@DemoDb) + N'
    FROM URL = ''' + @BakUrl + N'''
    WITH STATS = 5;';

PRINT N'';
IF @Apply = 1
BEGIN
    PRINT N'Restoring as ' + @DemoDb + N'...';
    EXEC sys.sp_executesql @Sql;
    PRINT N'Restore complete.';
END
ELSE
    PRINT @Sql;

/* ── 4. Delete the blob ──────────────────────────────────────────────────────
   Not done here, because T-SQL cannot delete a blob. Do it now, by hand - it is
   the single most dangerous artefact this process creates:

     Remove-AzStorageBlob -Container 'midemo' -Context $ctx `
         -Blob '<the .bak named above>'

   Or drop the whole container if it was created only for this.
   Keep it ONLY if you deliberately want a fixed demo baseline to re-restore -
   and if you do, it is a file of live patient data and belongs under the same
   controls as the production database. */

PRINT N'';
IF @Apply = 0
    PRINT N'@Apply = 0 - nothing was run. Review the statements above, then set @Apply = 1.';
ELSE
BEGIN
    PRINT N'>>> ' + @DemoDb + N' now holds REAL patient data. It is NOT safe to demo yet. <<<';
    PRINT N'Next, connected to ' + @DemoDb + N':';
    PRINT N'  2. Demo_LRNDemo_02_Deidentify.sql          (@Apply = 0 first, read the column list)';
    PRINT N'  3. Demo_LRNDemo_03_RestampLabIdentity.sql  (@Apply = 0 first)';
    PRINT N'  4. Demo_LRNDemo_04_RegisterLab.sql         (against LRNMaster)';
    PRINT N'Then delete the .bak blob, and only then issue the LRNDemo credentials.';
END
GO
