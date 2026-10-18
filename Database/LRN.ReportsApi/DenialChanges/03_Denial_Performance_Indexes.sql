/*
    Denial copy path - supporting indexes.

    Run against EACH LAB database (Certus_LRN, Augustus_LRN, NWL_LRN, ...), not LRNMaster.

    Why: raising the worker's command timeout stops "Execution Timeout Expired" but does not
    make the statements fast. Without these indexes every statement below scans the whole
    table, which is why the largest lab times out first while the smaller ones survive.

    Review before running. Each index costs write throughput on the bulk copies and space;
    check the estimated plans and existing indexes (see the "what already exists" query at
    the bottom) before applying to production, and create them during a maintenance window.
*/

/* ---------------------------------------------------------------------------
   1. PayerValidationReport - read one run's rows.
      Used by PayerValidationReportRepository.GetRunAsync (the "is this run in
      this lab?" aggregate) and GetDeniedRowsAsync (the actual copy).
      RunId leads because it is the selective predicate; PayStatus is the residual.
      A SELECT * still needs key lookups, so watch the plan: if the denied rows are
      most of the run, a scan is legitimately the cheaper plan and the timeout bump
      is the whole fix.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.PayerValidationReport', 'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = 'IX_PayerValidationReport_RunId_PayStatus'
                     AND object_id = OBJECT_ID('dbo.PayerValidationReport'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_PayerValidationReport_RunId_PayStatus
        ON dbo.PayerValidationReport (RunId, PayStatus);
END;
GO

/* ---------------------------------------------------------------------------
   2. DenialTaskBoard - the whole board for one lab. THIS IS THE ONE.
      Used by DenialTaskBoardRepository.GetExistingTasksAsync, which reads every task
      row the lab has ever accumulated - the statement in the Certus timeout stack.

      This index covers that query completely: the INCLUDE list is exactly the ten
      columns it now selects, so it is an index seek with no lookups back to the table.
      If you add a column to GetExistingTasksAsync, add it here too or the query drops
      back to a scan of the base table.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialTaskBoard', 'ClaimUID') IS NOT NULL
   AND COL_LENGTH('dbo.DenialTaskBoard', 'UniqueTrackId') IS NOT NULL
   AND COL_LENGTH('dbo.DenialTaskBoard', 'WorkFlowStatus') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = 'IX_DenialTaskBoard_LabId_Covering'
                     AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_LabId_Covering
        ON dbo.DenialTaskBoard (LabId)
        INCLUDE (TaskID, ClaimUID, CPTCode, DenialCode, UniqueTrackId,
                 Status, AssignedTo, WorkFlowStatus, DateOpened, DateCompleted);
END;
GO

/* ---------------------------------------------------------------------------
   3. DenialTaskBoard - the reconcile statements.
      ReconcileBeforeWriteAsync repeatedly matches on LabId + ClaimUID and on
      LabId + UniqueTrackId (the NOT EXISTS against #CurrentTaskKeys).
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialTaskBoard', 'ClaimUID') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = 'IX_DenialTaskBoard_LabId_ClaimUID'
                     AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_LabId_ClaimUID
        ON dbo.DenialTaskBoard (LabId, ClaimUID);
END;
GO

IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialTaskBoard', 'UniqueTrackId') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = 'IX_DenialTaskBoard_LabId_UniqueTrackId'
                     AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_LabId_UniqueTrackId
        ON dbo.DenialTaskBoard (LabId, UniqueTrackId);
END;
GO

/* ---------------------------------------------------------------------------
   4. DenialLineItem - the reconcile deletes and updates, all keyed
      on LabId + ClaimUID.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.DenialLineItem', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialLineItem', 'ClaimUID') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = 'IX_DenialLineItem_LabId_ClaimUID'
                     AND object_id = OBJECT_ID('dbo.DenialLineItem'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_DenialLineItem_LabId_ClaimUID
        ON dbo.DenialLineItem (LabId, ClaimUID);
END;
GO

/* ---------------------------------------------------------------------------
   Sizing the problem first - run these before deciding.
   --------------------------------------------------------------------------- */

-- How much does this lab actually carry?
-- SELECT COUNT(1) AS TaskBoardRows FROM dbo.DenialTaskBoard WHERE LabId = <LabId>;
-- SELECT COUNT(1) AS LineItemRows  FROM dbo.DenialLineItem  WHERE LabId = <LabId>;
-- SELECT COUNT(1) AS RunRows       FROM dbo.PayerValidationReport WHERE RunId = '<RunId>';

-- What already exists, so nothing above duplicates an index you have?
-- SELECT t.name AS TableName, i.name AS IndexName, i.type_desc,
--        STUFF((SELECT ', ' + c.name
--               FROM sys.index_columns ic
--               JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
--               WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
--               ORDER BY ic.key_ordinal
--               FOR XML PATH('')), 1, 2, '') AS KeyColumns
-- FROM sys.indexes i
-- JOIN sys.tables t ON t.object_id = i.object_id
-- WHERE t.name IN ('PayerValidationReport', 'DenialTaskBoard', 'DenialLineItem')
--   AND i.type > 0
-- ORDER BY t.name, i.name;
