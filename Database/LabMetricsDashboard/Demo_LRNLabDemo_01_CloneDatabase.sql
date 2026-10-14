/* ============================================================================
   Demo lab step 1 of 3 - clone the PCR Labs of America database as LRNLabDemo.

   Backup + restore under a new name, rather than table-by-table copying: it brings
   the schema, data, indexes, stored procedures and snapshot tables across in one
   go, so the demo behaves identically to the real lab instead of "mostly".

   RE-RUNNABLE. Running it again refreshes the demo from a fresh backup and
   DISCARDS whatever the product team did in the demo. That is the point - it is
   the reset button - but it is destructive, so it refuses to run unless you set
   @IAmSureIWantToOverwriteTheDemo = 1 below.

   >>> AFTER THIS, RUN Demo_LRNLabDemo_02_Deidentify.sql. <<<
   The restored copy is a byte-for-byte clone of production and still holds real
   patient data until step 2 has run. Do not hand the demo account to anyone in
   between.

   EXPRESS EDITION
   Supported, with two consequences the script handles for you:
     * Backup compression is an Enterprise/Standard feature, so it is skipped
       automatically. Expect a full-size .bak - check you have the disk space.
     * Express caps a database at 10 GB of DATA (log excluded). The script
       measures the source first and refuses rather than failing halfway through
       a long restore.

   Run on the SQL Server instance that hosts the source database, as a login with
   dbcreator + the right to back it up.
   ============================================================================ */

SET NOCOUNT ON;

/* ── Settings - CHECK ALL FOUR BEFORE RUNNING ────────────────────────────── */
DECLARE @SourceDb      SYSNAME       = N'PCRLOA_LRN';   -- the live PCR database name
DECLARE @DemoDb        SYSNAME       = N'LRNLabDemo';   -- the demo database to (re)create
DECLARE @BackupFolder  NVARCHAR(400) = N'C:\LRN-Files\Deployments\DotNet\ServerDB-Backup\';
DECLARE @DataFolder    NVARCHAR(400) = NULL;  -- NULL = the instance's default data/log folders

DECLARE @IAmSureIWantToOverwriteTheDemo BIT = 0;   -- set to 1 to actually run

/* ── Everything below runs as one unit ───────────────────────────────────
   Wrapped in TRY/CATCH so the FIRST failure stops the run. Without this a failed
   BACKUP was followed by a RESTORE of a file that was never written, then an
   ALTER of a database that was never created - three misleading errors chasing
   one real one.                                                             */
BEGIN TRY

    DECLARE @sql        NVARCHAR(MAX);
    DECLARE @BackupFile NVARCHAR(500);
    DECLARE @Msg        NVARCHAR(1000);

    /* ── Guards ─────────────────────────────────────────────────────────── */
    IF DB_ID(@SourceDb) IS NULL
    BEGIN
        SET @Msg = N'Source database "' + @SourceDb + N'" was not found on this instance. Check @SourceDb.';
        THROW 51001, @Msg, 1;
    END

    /* Never let a typo point the demo name at a real lab's database. */
    IF @DemoDb = @SourceDb OR @DemoDb NOT LIKE N'%Demo%'
        THROW 51002, N'@DemoDb must differ from @SourceDb and must contain "Demo". Refusing to continue.', 1;

    IF DB_ID(@DemoDb) IS NOT NULL AND @IAmSureIWantToOverwriteTheDemo = 0
    BEGIN
        PRINT N'"' + @DemoDb + N'" already exists.';
        PRINT N'This script would DROP it and restore a fresh copy of "' + @SourceDb + N'",';
        PRINT N'discarding every change the demo users have made.';
        PRINT N'Set @IAmSureIWantToOverwriteTheDemo = 1 if that is what you want.';
        RETURN;
    END

    /* Normalise the folder so a missing trailing slash does not silently build
       a path like "...Backupmydb.bak". */
    IF RIGHT(@BackupFolder, 1) <> N'\' SET @BackupFolder = @BackupFolder + N'\';

    /* Does the backup folder actually exist, from the SERVICE ACCOUNT's point of
       view? This is the usual cause of "Operating system error 3 / 5" later on,
       and it is much cheaper to find out now.

       xp_fileexist wants the folder WITHOUT a trailing backslash, and needs rights
       a dbcreator-only login may not have - so a failed check only warns. The real
       BACKUP below is still the authority. */
    DECLARE @FileExists INT, @IsDirectory INT, @ParentExists INT, @FolderProbe NVARCHAR(400);
    DECLARE @CanProbeFiles BIT = 1;

    SET @FolderProbe = LEFT(@BackupFolder, LEN(@BackupFolder) - 1);   -- drop the trailing '\'

    BEGIN TRY
        EXEC master.dbo.xp_fileexist @FolderProbe, @FileExists OUTPUT, @IsDirectory OUTPUT, @ParentExists OUTPUT;
    END TRY
    BEGIN CATCH
        SET @CanProbeFiles = 0;
        PRINT N'(Could not check the backup folder - xp_fileexist is not available to this login. Continuing.)';
    END CATCH

    IF @CanProbeFiles = 1 AND @IsDirectory <> 1
    BEGIN
        SET @Msg = N'Backup folder "' + @FolderProbe + N'" is not visible to the SQL Server service account. '
                 + N'Create it on the SQL Server host and grant that account write access '
                 + N'(it is NOT your own Windows account that needs the permission).';
        THROW 51003, @Msg, 1;
    END

    /* ── Edition checks ─────────────────────────────────────────────────
       EngineEdition: 2 = Standard, 3 = Enterprise/Developer, 4 = Express, 8 = Managed Instance.
       Compression is unavailable on Express and Web; asking for it there fails the
       whole BACKUP with Msg 1844 rather than degrading gracefully.              */
    DECLARE @EngineEdition INT    = CAST(SERVERPROPERTY('EngineEdition') AS INT);
    DECLARE @EditionName NVARCHAR(200) = CAST(SERVERPROPERTY('Edition') AS NVARCHAR(200));
    DECLARE @UseCompression BIT =
        CASE WHEN @EngineEdition IN (2, 3, 8) AND @EditionName NOT LIKE N'%Web%' THEN 1 ELSE 0 END;

    IF @UseCompression = 0
        PRINT N'Edition "' + @EditionName + N'" does not support backup compression - writing an uncompressed backup.';

    /* Express caps DATA files at 10 GB per database. Restoring past that fails
       partway through, which on a large lab is a long wait for a dead end. */
    IF @EngineEdition = 4
    BEGIN
        DECLARE @DataMb DECIMAL(18,1) =
            (SELECT SUM(CAST(size AS BIGINT)) * 8.0 / 1024
             FROM sys.master_files
             WHERE database_id = DB_ID(@SourceDb) AND type = 0);   -- type 0 = rows; log does not count

        PRINT N'Source data size: ' + CAST(CAST(@DataMb AS DECIMAL(18,1)) AS NVARCHAR(20)) + N' MB (Express limit: 10240 MB).';

        IF @DataMb > 10240
        BEGIN
            SET @Msg = N'"' + @SourceDb + N'" holds ' + CAST(CAST(@DataMb AS DECIMAL(18,1)) AS NVARCHAR(20))
                     + N' MB of data, over the 10240 MB Express limit. The restore would fail partway. '
                     + N'Either clone onto a Developer/Standard instance (Developer edition is free and '
                     + N'has no size cap), or build the demo from a trimmed subset instead of a full clone.';
            THROW 51004, @Msg, 1;
        END
    END

    SET @BackupFile = @BackupFolder + @SourceDb + N'_ForDemoClone_'
                    + CONVERT(NVARCHAR(20), GETDATE(), 112) + N'.bak';

    /* ── 1. Back up the source ───────────────────────────────────────────
       COPY_ONLY so this does not disturb the real backup chain for PCR.     */
    PRINT N'Backing up ' + @SourceDb + N' to ' + @BackupFile + N' ...';

    SET @sql = N'BACKUP DATABASE ' + QUOTENAME(@SourceDb) + N'
                 TO DISK = @File
                 WITH COPY_ONLY, INIT, STATS = 10'
             + CASE WHEN @UseCompression = 1 THEN N', COMPRESSION' ELSE N'' END + N';';
    EXEC sp_executesql @sql, N'@File NVARCHAR(500)', @File = @BackupFile;

    /* Belt and braces: a few BACKUP failures do not surface as catchable errors,
       so confirm the file is really there before trying to restore from it. */
    IF @CanProbeFiles = 1
    BEGIN
        EXEC master.dbo.xp_fileexist @BackupFile, @FileExists OUTPUT, @IsDirectory OUTPUT, @ParentExists OUTPUT;
        IF @FileExists <> 1
        BEGIN
            SET @Msg = N'The backup did not produce a file at "' + @BackupFile + N'". Stopping before the restore. '
                     + N'Check the messages above for the real cause.';
            THROW 51005, @Msg, 1;
        END
    END

    /* ── 2. Work out where the restored files go ─────────────────────────
       Logical file names differ per database, so read them from the backup rather
       than assuming; otherwise the MOVE clauses below are guesswork.          */
    IF @DataFolder IS NULL
        SELECT @DataFolder = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(400));

    IF @DataFolder IS NULL
        THROW 51006, N'Could not resolve a default data folder. Set @DataFolder explicitly.', 1;

    IF RIGHT(@DataFolder, 1) <> N'\' SET @DataFolder = @DataFolder + N'\';

    CREATE TABLE #FileList (
        LogicalName NVARCHAR(128), PhysicalName NVARCHAR(260), [Type] CHAR(1), FileGroupName NVARCHAR(128),
        Size NUMERIC(20,0), MaxSize NUMERIC(20,0), FileId BIGINT, CreateLSN NUMERIC(25,0), DropLSN NUMERIC(25,0),
        UniqueId UNIQUEIDENTIFIER, ReadOnlyLSN NUMERIC(25,0), ReadWriteLSN NUMERIC(25,0), BackupSizeInBytes BIGINT,
        SourceBlockSize INT, FileGroupId INT, LogGroupGUID UNIQUEIDENTIFIER, DifferentialBaseLSN NUMERIC(25,0),
        DifferentialBaseGUID UNIQUEIDENTIFIER, IsReadOnly BIT, IsPresent BIT, TDEThumbprint VARBINARY(32),
        SnapshotUrl NVARCHAR(360)
    );

    INSERT INTO #FileList EXEC (N'RESTORE FILELISTONLY FROM DISK = ''' + @BackupFile + N'''');

    DECLARE @Move NVARCHAR(MAX) = N'';
    SELECT @Move = @Move + N', MOVE ' + QUOTENAME(LogicalName, '''')
                 + N' TO ' + QUOTENAME(
                       @DataFolder + @DemoDb + N'_' + CAST(FileId AS NVARCHAR(10))
                       + CASE WHEN [Type] = 'L' THEN N'.ldf' ELSE N'.mdf' END, '''')
    FROM #FileList
    WHERE IsPresent = 1;

    DROP TABLE #FileList;

    /* ── 3. Drop any previous demo copy, then restore ────────────────────
       SINGLE_USER first: an open demo session would otherwise block the drop.  */
    IF DB_ID(@DemoDb) IS NOT NULL
    BEGIN
        PRINT N'Dropping the existing ' + @DemoDb + N' ...';
        SET @sql = N'ALTER DATABASE ' + QUOTENAME(@DemoDb) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
                     DROP DATABASE ' + QUOTENAME(@DemoDb) + N';';
        EXEC sp_executesql @sql;
    END

    PRINT N'Restoring ' + @DemoDb + N' ...';
    SET @sql = N'RESTORE DATABASE ' + QUOTENAME(@DemoDb) + N'
                 FROM DISK = ''' + @BackupFile + N'''
                 WITH RECOVERY, STATS = 10' + @Move + N';';
    EXEC sp_executesql @sql;

    IF DB_ID(@DemoDb) IS NULL
    BEGIN
        SET @Msg = N'The restore did not produce a database called "' + @DemoDb + N'". Check the messages above.';
        THROW 51007, @Msg, 1;
    END

    /* ── 4. Leave the copy clearly marked ────────────────────────────────
       MULTI_USER so the app can connect; the description is there for anyone who
       finds the database later and wonders what it is.                        */
    SET @sql = N'ALTER DATABASE ' + QUOTENAME(@DemoDb) + N' SET MULTI_USER;';
    EXEC sp_executesql @sql;

    SET @sql = N'USE ' + QUOTENAME(@DemoDb) + N';
                 IF NOT EXISTS (SELECT 1 FROM sys.extended_properties WHERE class = 0 AND name = N''LRN_Purpose'')
                     EXEC sys.sp_addextendedproperty @name = N''LRN_Purpose'',
                          @value = N''Demo/training clone of ' + @SourceDb + N'. De-identified by Demo_LRNLabDemo_02_Deidentify.sql. Not a client database.'';';
    EXEC sp_executesql @sql;

    PRINT N'';
    PRINT N'Clone complete: ' + @DemoDb + N' restored from ' + @SourceDb + N'.';
    PRINT N'*** THIS COPY STILL CONTAINS REAL PATIENT DATA. ***';
    PRINT N'*** Run Demo_LRNLabDemo_02_Deidentify.sql against ' + @DemoDb + N' before anyone uses it. ***';
    PRINT N'Backup file left at ' + @BackupFile + N' - delete it once the restore is verified.';

END TRY
BEGIN CATCH
    IF OBJECT_ID('tempdb..#FileList') IS NOT NULL DROP TABLE #FileList;

    PRINT N'';
    PRINT N'=== CLONE ABORTED - nothing further was attempted. ===';
    PRINT ERROR_MESSAGE();
    THROW;
END CATCH
GO
