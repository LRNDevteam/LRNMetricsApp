/*
================================================================================================
    Reset one lab so the master file processor treats its next run as a first run.
    File: Reset_LabForFreshRun.sql        Database: LRNMaster (plus the lab's own database)

    READ THIS FIRST
    ---------------
    You probably do not need this script. The Report Audit Log screen has a "Re-run Master
    Processor" button that queues a re-run per lab, keeps the history, and records who asked.
    That path destroys nothing: it takes a NEW RunID and leaves the previous run's logs intact.

    Use this script only for a genuine start-from-zero - a new environment, a restored database,
    or a lab whose history is being deliberately discarded. It DELETES audit history.

    HOW TO RUN
    ----------
    Set @LabId and @LabName below, then run with @WhatIf = 1 first. That prints what would go and
    changes nothing. Set @WhatIf = 0 only once the counts look right.
================================================================================================
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE LRNMaster;
GO

DECLARE @LabId    INT           = 4,          -- <<< Cove
        @LabName  VARCHAR(120)  = 'Cove',     -- <<< must match dbo.LRN_Run_Log.LabName
        @WhatIf   BIT           = 1;          -- <<< 1 = preview only, 0 = actually delete

------------------------------------------------------------------------------------------------
-- The runs in scope. Every child table below is keyed on RunID, so the set is collected once and
-- every delete works from it.
--
-- Matched on LabName: that column has been on dbo.LRN_Run_Log since the beginning, while LabId
-- was added later and is still NULL on older rows. Matching on LabId would silently miss exactly
-- the history this script is meant to clear. Check the count below before applying - if two labs
-- share a name, this is where you would see it.
------------------------------------------------------------------------------------------------
DECLARE @Runs TABLE (RunID VARCHAR(30) PRIMARY KEY);

INSERT INTO @Runs (RunID)
SELECT RunID
FROM   dbo.LRN_Run_Log
WHERE  LabName = @LabName;

SELECT CONCAT('Runs in scope for ', @LabName, ' (LabId ', @LabId, '): ', COUNT(*)) AS Scope FROM @Runs;

------------------------------------------------------------------------------------------------
-- What would go. Always printed, whether previewing or not.
------------------------------------------------------------------------------------------------
SELECT 'dbo.LRN_Error_Log'                     AS TableName, COUNT(*) AS RowsAffected FROM dbo.LRN_Error_Log                     WHERE RunID IN (SELECT RunID FROM @Runs)
UNION ALL SELECT 'dbo.LRN_Step_Log',            COUNT(*) FROM dbo.LRN_Step_Log            WHERE RunID IN (SELECT RunID FROM @Runs)
UNION ALL SELECT 'dbo.ReportRunIdInfoLog',      COUNT(*) FROM dbo.ReportRunIdInfoLog      WHERE RunId IN (SELECT RunID FROM @Runs)
UNION ALL SELECT 'dbo.ReportsWorkflowTracker',  COUNT(*) FROM dbo.ReportsWorkflowTracker  WHERE RunId IN (SELECT RunID FROM @Runs)
UNION ALL SELECT 'dbo.LRN_Run_Log',             COUNT(*) FROM dbo.LRN_Run_Log             WHERE RunID IN (SELECT RunID FROM @Runs)
UNION ALL SELECT 'dbo.BillingFrequencyFileStatus', COUNT(*) FROM dbo.BillingFrequencyFileStatus WHERE LabId = @LabId
UNION ALL SELECT 'dbo.MasterFileProcessorRerunRequest', COUNT(*) FROM dbo.MasterFileProcessorRerunRequest WHERE LabId = @LabId;

IF @WhatIf = 1
BEGIN
    PRINT '';
    PRINT 'WhatIf = 1. Nothing was deleted. Set @WhatIf = 0 to apply.';
    RETURN;
END

------------------------------------------------------------------------------------------------
-- Children before parents, all in one transaction: a half-cleared lab - step logs gone but run
-- rows still present - reads as a run that produced no steps, which is worse than not starting.
------------------------------------------------------------------------------------------------
BEGIN TRANSACTION;

    DELETE FROM dbo.LRN_Error_Log            WHERE RunID IN (SELECT RunID FROM @Runs);
    DELETE FROM dbo.LRN_Step_Log             WHERE RunID IN (SELECT RunID FROM @Runs);
    DELETE FROM dbo.ReportRunIdInfoLog       WHERE RunId IN (SELECT RunID FROM @Runs);
    DELETE FROM dbo.ReportsWorkflowTracker   WHERE RunId IN (SELECT RunID FROM @Runs);
    DELETE FROM dbo.LRN_Run_Log              WHERE RunID IN (SELECT RunID FROM @Runs);

    -- THE one row that actually makes the next run happen. Everything above is history; this is
    -- the gate. While a PROCESSED row survives for the lab's current SharePoint file, the worker
    -- finds the file, sees the unchanged ETag and skips - however empty the rest of the tables are.
    DELETE FROM dbo.BillingFrequencyFileStatus WHERE LabId = @LabId;

    -- Re-run requests for this lab. A Claimed row left by a worker that was stopped mid-run would
    -- otherwise block every future request for the lab.
    DELETE FROM dbo.MasterFileProcessorRerunRequest WHERE LabId = @LabId;

COMMIT TRANSACTION;

PRINT 'LRNMaster cleared. Now run the lab-database section below against the lab''s own database.';
GO

/*
================================================================================================
    NOT TOUCHED, ON PURPOSE
    -----------------------
    dbo.LrnFileStatus
        Belongs to the upstream automation, not to this worker, which only ever reads it. Deleting
        rows here does not give you a fresh run - it removes the record of the run whose data is
        sitting in the source tables, and the gate then refuses to start because no row says the
        source is Completed.

    dbo.LRN_RunIdSequence
        The per-lab RunID counter. Leave it alone. Resetting it re-issues RunIDs that the reports,
        the workflow tracker and any archived output already use, and the next run then collides
        with history that was not deleted.

    dbo.ReportTypeMaster, dbo.LabRegistry, dbo.Labs, dbo.LabInsuranceMaster
        Reference data. Clearing any of these breaks every lab, not just this one.
================================================================================================
*/

/*
================================================================================================
    THE LAB'S OWN DATABASE  (e.g. CoveLRN)
    Run this part separately, connected to the lab database named by LabDbConnectionKey.
================================================================================================

USE CoveLRN;   -- <<< the lab database
GO

-- Preview first.
SELECT 'dbo.LineLevelData'       AS TableName, COUNT(*) AS Rows FROM dbo.LineLevelData
UNION ALL SELECT 'dbo.ClaimLevelData',  COUNT(*) FROM dbo.ClaimLevelData
UNION ALL SELECT 'dbo.LIMSMaster',      COUNT(*) FROM dbo.LIMSMaster
UNION ALL SELECT 'dbo.LineClaimFileLogs', COUNT(*) FROM dbo.LineClaimFileLogs
UNION ALL SELECT 'dbo.LrnSourceRunMarker', COUNT(*) FROM dbo.LrnSourceRunMarker;

BEGIN TRANSACTION;

    -- The second gate, and the one people forget. For a LabDatabase-sourced lab this marker says
    -- "we have already taken upstream RunID X". While it is present the processor skips the lab
    -- even with every LRNMaster table empty.
    DELETE FROM dbo.LrnSourceRunMarker;

    -- Audit trail of past loads. Safe to keep if you only want the next run to happen; delete it
    -- only when the point is to discard history.
    DELETE FROM dbo.LineClaimFileLogs;

    -- The data tables themselves need no action for a re-run: the loader truncates each of them
    -- before every load. Clear them only to leave the lab visibly empty in the meantime.
    -- TRUNCATE TABLE dbo.LineLevelData;
    -- TRUNCATE TABLE dbo.ClaimLevelData;
    -- TRUNCATE TABLE dbo.LIMSMaster;

COMMIT TRANSACTION;
GO
================================================================================================
*/
