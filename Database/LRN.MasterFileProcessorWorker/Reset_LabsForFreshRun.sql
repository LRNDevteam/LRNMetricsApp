/*
================================================================================================
    Reset a SET of labs so the master file processor treats the next run of each as a first run.
    File: Reset_LabsForFreshRun.sql        Database: LRNMaster (plus each lab's own database)

    The multi-lab form of Reset_LabForFreshRun.sql. Same rules, same tables.

    READ THIS FIRST
    ---------------
    For a normal re-run you do not need this script: the Report Audit Log "Re-run Master Processor"
    button queues one per lab and destroys nothing. Use this only for a genuine start-from-zero
    (new environment, restored databases, history deliberately discarded). It DELETES audit history.

    HOW TO RUN
    ----------
    1. STOP the master file processor service(s) first (a run in progress would be cut off from
       its own log rows). The script refuses while any listed lab has a Claimed re-run request,
       unless @Force = 1.
    2. Connect to LRNMaster. Fill @Labs below: LabId, LabName (exactly as in dbo.LRN_Run_Log.LabName)
       and the lab database name.
    3. Run with @WhatIf = 1. Check the per-lab counts. Then set @WhatIf = 0 and run again.
    4. Lab databases on the SAME server as LRNMaster are cleared by this script. For any lab
       database on another server (e.g. ReportEngine\SQLEXPRESS) the output says so: run PART 2
       at the bottom of this file there, once per lab database.
    5. Start the service. The next poll picks each lab up as a first run.
================================================================================================
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @WhatIf         BIT = 1,   -- <<< 1 = preview only, 0 = actually delete
        @ClearLabData   BIT = 0,   -- <<< 1 = also TRUNCATE LineLevelData / ClaimLevelData / LIMSMaster
                                   --     (not needed for a re-run: the loader truncates them itself)
        @ClearSnapshots BIT = 0,   -- <<< 1 = also delete the labs' ReportSnapshotRun/File rows
                                   --     (the Parquet files in blob storage are NOT deleted)
        @ClearUploads   BIT = 0,   -- <<< 1 = also delete the labs' AR Workbench master file uploads
        @Force          BIT = 0;   -- <<< 1 = run even if a re-run request is Claimed (service running)

DECLARE @Labs TABLE
(
    LabId       INT           NOT NULL PRIMARY KEY,
    LabName     VARCHAR(120)  NOT NULL,     -- must match dbo.LRN_Run_Log.LabName
    LabDatabase SYSNAME       NULL          -- the lab's own database; NULL = skip the lab-database part
);

INSERT INTO @Labs (LabId, LabName, LabDatabase) VALUES
--  (LabId, 'LabName',          'LabDatabase')     <<< EXAMPLES - replace with your labs
    (4,     'Cove',             'CoveLRN'),
    (16,    'Elixir',           'Elixir_LRN');

------------------------------------------------------------------------------------------------
-- Checks
------------------------------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM @Labs)
BEGIN
    RAISERROR('No labs listed in @Labs.', 16, 1);
    RETURN;
END

-- A LabName that matches no run and a LabId that has no file status usually means a typo: the
-- delete would then quietly do nothing for that lab. Shown, not refused (a never-run lab is valid).
SELECT  l.LabId, l.LabName, l.LabDatabase,
        (SELECT COUNT(*) FROM dbo.LRN_Run_Log r WHERE r.LabName = l.LabName)                AS RunsFound,
        (SELECT COUNT(*) FROM dbo.BillingFrequencyFileStatus b WHERE b.LabId = l.LabId)    AS FileStatusRows,
        CASE WHEN l.LabDatabase IS NULL           THEN 'skipped (no LabDatabase)'
             WHEN DB_ID(l.LabDatabase) IS NULL    THEN 'NOT on this server - run PART 2 there'
             ELSE 'cleared by this script' END                                            AS LabDatabasePart
FROM    @Labs l
ORDER BY l.LabId;

IF @Force = 0 AND EXISTS (SELECT 1 FROM dbo.MasterFileProcessorRerunRequest q
                          JOIN @Labs l ON l.LabId = q.LabId
                          WHERE q.Status = 'Claimed')
BEGIN
    SELECT q.* FROM dbo.MasterFileProcessorRerunRequest q JOIN @Labs l ON l.LabId = q.LabId WHERE q.Status = 'Claimed';
    RAISERROR('A listed lab has a Claimed re-run request: the processor may be running it. Stop the service, or set @Force = 1 if the claim is a leftover.', 16, 1);
    RETURN;
END

------------------------------------------------------------------------------------------------
-- The runs in scope. Matched on LabName, as LabId is NULL on older dbo.LRN_Run_Log rows.
------------------------------------------------------------------------------------------------
DECLARE @Runs TABLE (RunID VARCHAR(30) PRIMARY KEY, LabId INT NOT NULL);

INSERT INTO @Runs (RunID, LabId)
SELECT r.RunID, l.LabId
FROM   dbo.LRN_Run_Log r
JOIN   @Labs l ON l.LabName = r.LabName;

------------------------------------------------------------------------------------------------
-- What would go, per lab. Always printed.
------------------------------------------------------------------------------------------------
DECLARE @HasUploads BIT = CASE WHEN OBJECT_ID('dbo.MasterFileUpload', 'U') IS NOT NULL THEN 1 ELSE 0 END,
        @HasSnaps   BIT = CASE WHEN OBJECT_ID('dbo.ReportSnapshotRun', 'U') IS NOT NULL THEN 1 ELSE 0 END;

SELECT  l.LabId, l.LabName,
        (SELECT COUNT(*) FROM @Runs x WHERE x.LabId = l.LabId)                                                          AS LRN_Run_Log,
        (SELECT COUNT(*) FROM dbo.LRN_Step_Log s          JOIN @Runs x ON x.RunID = s.RunID WHERE x.LabId = l.LabId)   AS LRN_Step_Log,
        (SELECT COUNT(*) FROM dbo.LRN_Error_Log e         JOIN @Runs x ON x.RunID = e.RunID WHERE x.LabId = l.LabId)   AS LRN_Error_Log,
        (SELECT COUNT(*) FROM dbo.ReportRunIdInfoLog i    JOIN @Runs x ON x.RunID = i.RunId WHERE x.LabId = l.LabId)   AS ReportRunIdInfoLog,
        (SELECT COUNT(*) FROM dbo.ReportsWorkflowTracker w JOIN @Runs x ON x.RunID = w.RunId WHERE x.LabId = l.LabId)  AS ReportsWorkflowTracker,
        (SELECT COUNT(*) FROM dbo.BillingFrequencyFileStatus b WHERE b.LabId = l.LabId)                                AS BillingFrequencyFileStatus,
        (SELECT COUNT(*) FROM dbo.MasterFileProcessorRerunRequest q WHERE q.LabId = l.LabId)                          AS RerunRequests
FROM    @Labs l
ORDER BY l.LabId;

IF @WhatIf = 1
BEGIN
    PRINT '';
    PRINT 'WhatIf = 1. Nothing was deleted. Set @WhatIf = 0 to apply.';
    RETURN;
END

------------------------------------------------------------------------------------------------
-- LRNMaster. Children before parents, one transaction for every listed lab: a half-cleared lab
-- (step logs gone, run rows still there) reads as a run that produced no steps.
------------------------------------------------------------------------------------------------
BEGIN TRANSACTION;

    DELETE e FROM dbo.LRN_Error_Log           e JOIN @Runs x ON x.RunID = e.RunID;
    DELETE s FROM dbo.LRN_Step_Log            s JOIN @Runs x ON x.RunID = s.RunID;
    DELETE i FROM dbo.ReportRunIdInfoLog      i JOIN @Runs x ON x.RunID = i.RunId;
    DELETE w FROM dbo.ReportsWorkflowTracker  w JOIN @Runs x ON x.RunID = w.RunId;
    DELETE r FROM dbo.LRN_Run_Log             r JOIN @Runs x ON x.RunID = r.RunID;

    -- THE gate. While a PROCESSED row survives for the lab's current SharePoint file, the worker
    -- sees the unchanged ETag and skips, however empty everything else is.
    DELETE b FROM dbo.BillingFrequencyFileStatus b JOIN @Labs l ON l.LabId = b.LabId;

    -- Re-run requests. A Claimed row left by a stopped worker would block every future request.
    DELETE q FROM dbo.MasterFileProcessorRerunRequest q JOIN @Labs l ON l.LabId = q.LabId;

    -- Optional. A missing table only fails when its statement runs, so the guards are enough.
    -- Uploads: their requests are gone above, so the FK allows it.
    IF @ClearUploads = 1 AND @HasUploads = 1
        DELETE u FROM dbo.MasterFileUpload u JOIN @Labs l ON l.LabId = u.LabId;

    -- Snapshot rows (ReportSnapshotFile goes with them: ON DELETE CASCADE). Blob files stay.
    IF @ClearSnapshots = 1 AND @HasSnaps = 1
        DELETE s FROM dbo.ReportSnapshotRun s JOIN @Labs l ON l.LabId = s.LabId;

COMMIT TRANSACTION;

PRINT 'LRNMaster cleared for ' + CAST((SELECT COUNT(*) FROM @Labs) AS VARCHAR(10)) + ' lab(s).';

------------------------------------------------------------------------------------------------
-- Lab databases on this server. Same statements as PART 2, run in each database in turn.
-- Each database is its own transaction; a failure stops the script and names the database.
------------------------------------------------------------------------------------------------
DECLARE @LabSql NVARCHAR(MAX) = N'
SET XACT_ABORT ON;
BEGIN TRANSACTION;
    -- The second gate: "already took upstream RunID X". Present = the lab is skipped.
    IF OBJECT_ID(''dbo.LrnSourceRunMarker'', ''U'') IS NOT NULL DELETE FROM dbo.LrnSourceRunMarker;
    -- Audit trail of past loads.
    IF OBJECT_ID(''dbo.LineClaimFileLogs'', ''U'') IS NOT NULL DELETE FROM dbo.LineClaimFileLogs;
    IF @ClearLabData = 1
    BEGIN
        IF OBJECT_ID(''dbo.LineLevelData'',  ''U'') IS NOT NULL TRUNCATE TABLE dbo.LineLevelData;
        IF OBJECT_ID(''dbo.ClaimLevelData'', ''U'') IS NOT NULL TRUNCATE TABLE dbo.ClaimLevelData;
        IF OBJECT_ID(''dbo.LIMSMaster'',     ''U'') IS NOT NULL TRUNCATE TABLE dbo.LIMSMaster;
    END
COMMIT TRANSACTION;';

DECLARE @Db SYSNAME, @Exec NVARCHAR(400);

DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT LabDatabase FROM @Labs WHERE LabDatabase IS NOT NULL AND DB_ID(LabDatabase) IS NOT NULL;
OPEN dbs;
FETCH NEXT FROM dbs INTO @Db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Exec = QUOTENAME(@Db) + N'.sys.sp_executesql';
    PRINT 'Clearing lab database ' + @Db + ' ...';
    EXEC @Exec @LabSql, N'@ClearLabData BIT', @ClearLabData = @ClearLabData;
    FETCH NEXT FROM dbs INTO @Db;
END
CLOSE dbs;
DEALLOCATE dbs;

-- What is left to do by hand.
SELECT LabId, LabName, LabDatabase, 'Run PART 2 of this file in this database, on its own server' AS ToDo
FROM   @Labs
WHERE  LabDatabase IS NOT NULL AND DB_ID(LabDatabase) IS NULL;

PRINT 'Done. Start the master file processor service: the next poll runs each lab as a first run.';
GO

/*
================================================================================================
    NOT TOUCHED, ON PURPOSE  (as in Reset_LabForFreshRun.sql)
    -----------------------
    dbo.LrnFileStatus            upstream automation's table; the worker only reads it.
    dbo.LRN_RunIdSequence        per-lab RunID counter; resetting it re-issues RunIDs already used.
    dbo.ReportTypeMaster, dbo.LabRegistry, dbo.Labs, dbo.LabInsuranceMaster   reference data.
    dbo.ARWB_* (lab database)    AR Workbench workflow state (assignments, follow-ups, QA, CIP).
                                 The next load's AR Workbench sync refreshes the claims and keeps it.
================================================================================================
*/

/*
================================================================================================
    PART 2 - A LAB DATABASE ON ANOTHER SERVER  (e.g. ReportEngine\SQLEXPRESS)
    Connect to that server, select the lab database, uncomment and run. Once per lab database.
================================================================================================

SET XACT_ABORT ON;
DECLARE @ClearLabData BIT = 0;   -- <<< same meaning as above

-- Preview.
SELECT 'dbo.LrnSourceRunMarker' AS TableName, COUNT(*) AS Rows FROM dbo.LrnSourceRunMarker
UNION ALL SELECT 'dbo.LineClaimFileLogs', COUNT(*) FROM dbo.LineClaimFileLogs
UNION ALL SELECT 'dbo.LineLevelData',     COUNT(*) FROM dbo.LineLevelData
UNION ALL SELECT 'dbo.ClaimLevelData',    COUNT(*) FROM dbo.ClaimLevelData
UNION ALL SELECT 'dbo.LIMSMaster',        COUNT(*) FROM dbo.LIMSMaster;

BEGIN TRANSACTION;
    IF OBJECT_ID('dbo.LrnSourceRunMarker', 'U') IS NOT NULL DELETE FROM dbo.LrnSourceRunMarker;
    IF OBJECT_ID('dbo.LineClaimFileLogs', 'U') IS NOT NULL DELETE FROM dbo.LineClaimFileLogs;
    IF @ClearLabData = 1
    BEGIN
        TRUNCATE TABLE dbo.LineLevelData;
        TRUNCATE TABLE dbo.ClaimLevelData;
        IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL TRUNCATE TABLE dbo.LIMSMaster;
    END
COMMIT TRANSACTION;

================================================================================================
*/
