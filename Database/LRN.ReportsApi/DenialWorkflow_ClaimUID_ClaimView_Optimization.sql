/*
Run this once in EACH LAB database that contains DenialLineItem / DenialTaskBoard.

Purpose:
  Optimizes Claim Assignment / Claim View after switching distinct claim grouping
  from VisitNumber to ClaimUID.

Safe to re-run:
  - Creates indexes only when they do not already exist.
  - Uses dynamic INCLUDE column lists so labs with slightly different schemas still work.

Notes:
  - If ClaimUID exists, this script indexes ClaimUID for claim list counts, page loads,
    assignment, and click-to-expand line task loading.
  - If ClaimUID does not exist, the script falls back to existing VisitNumber / ClaimIDNormalized
    indexes and creates missing fallback indexes.
*/

SET NOCOUNT ON;

DECLARE @schema sysname = N'dbo';
DECLARE @sql nvarchar(max);

--------------------------------------------------------------------------------
-- Helper temp table for existing columns.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#ColumnList') IS NOT NULL DROP TABLE #ColumnList;
CREATE TABLE #ColumnList
(
    TableName sysname NOT NULL,
    ColumnName sysname NOT NULL,
    PRIMARY KEY (TableName, ColumnName)
);

INSERT INTO #ColumnList(TableName, ColumnName)
SELECT
    t.name,
    c.name
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.columns c ON c.object_id = t.object_id
WHERE s.name = @schema
  AND t.name IN (N'DenialLineItem', N'DenialTaskBoard', N'DenialClaimEscalations');

--------------------------------------------------------------------------------
-- DenialLineItem: ClaimUID claim grouping and claim page projection.
--------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.DenialLineItem', N'U') IS NOT NULL
BEGIN
    DECLARE @lineIncludes nvarchar(max) = N'';

    SELECT @lineIncludes = STRING_AGG(QUOTENAME(ColumnName), N', ')
    FROM #ColumnList
    WHERE TableName = N'DenialLineItem'
      AND ColumnName IN
      (
          N'VisitNumber', N'AccessionNo', N'AccessionNumber', N'PayerName', N'PayerNameNormalized',
          N'PanelName', N'PatientName', N'PatientDOB', N'PatientID', N'SubscriberId',
          N'ClinicName', N'SalesRepname', N'ReferringProvider', N'InsuranceBalance',
          N'DenialCodeNormalized', N'DenialClassification', N'ActionCategory',
          N'AssignedTo', N'WorkFlowStatus'
      );

    -- Keep shared INCLUDE list conservative so fallback VisitNumber indexes do not
    -- duplicate key columns in INCLUDE.
    SET @lineIncludes = NULLIF(REPLACE(REPLACE(ISNULL(@lineIncludes, N''), N'[VisitNumber], ', N''), N', [VisitNumber]', N''), N'');

    IF EXISTS (SELECT 1 FROM #ColumnList WHERE TableName=N'DenialLineItem' AND ColumnName=N'ClaimUID')
       AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.DenialLineItem') AND name = N'IX_DWF_LineItem_ClaimUID_ClaimView')
    BEGIN
        SET @sql = N'CREATE NONCLUSTERED INDEX IX_DWF_LineItem_ClaimUID_ClaimView
ON dbo.DenialLineItem (ClaimUID, DateOfService DESC)' +
CASE WHEN NULLIF(@lineIncludes, N'') IS NULL THEN N'' ELSE N'
INCLUDE (' + @lineIncludes + N')' END + N'
WITH (SORT_IN_TEMPDB = ON, DATA_COMPRESSION = PAGE);';

        EXEC sys.sp_executesql @sql;
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.DenialLineItem') AND name = N'IX_DWF_LineItem_VisitNumber_ClaimView_Fallback')
    BEGIN
        SET @sql = N'CREATE NONCLUSTERED INDEX IX_DWF_LineItem_VisitNumber_ClaimView_Fallback
ON dbo.DenialLineItem (VisitNumber, DateOfService DESC)' +
CASE WHEN NULLIF(@lineIncludes, N'') IS NULL THEN N'' ELSE N'
INCLUDE (' + @lineIncludes + N')' END + N'
WITH (SORT_IN_TEMPDB = ON, DATA_COMPRESSION = PAGE);';

        EXEC sys.sp_executesql @sql;
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.DenialLineItem') AND name = N'IX_DWF_LineItem_DOS_ClaimUID_Page')
       AND EXISTS (SELECT 1 FROM #ColumnList WHERE TableName=N'DenialLineItem' AND ColumnName=N'ClaimUID')
    BEGIN
        SET @sql = N'CREATE NONCLUSTERED INDEX IX_DWF_LineItem_DOS_ClaimUID_Page
ON dbo.DenialLineItem (DateOfService DESC, ClaimUID)' +
CASE WHEN NULLIF(@lineIncludes, N'') IS NULL THEN N'' ELSE N'
INCLUDE (' + @lineIncludes + N')' END + N'
WITH (SORT_IN_TEMPDB = ON, DATA_COMPRESSION = PAGE);';

        EXEC sys.sp_executesql @sql;
    END;
END;

--------------------------------------------------------------------------------
-- DenialTaskBoard: ClaimUID joins for status aggregate, assignment, and drill-down.
--------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.DenialTaskBoard', N'U') IS NOT NULL
BEGIN
    DECLARE @taskIncludes nvarchar(max) = N'';

    SELECT @taskIncludes = STRING_AGG(QUOTENAME(ColumnName), N', ')
    FROM #ColumnList
    WHERE TableName = N'DenialTaskBoard'
      AND ColumnName IN
      (
          N'TaskID', N'UniqueTrackId', N'ClaimID', N'ClaimIDNormalized', N'PatientId',
          N'CPTCode', N'Units', N'Modifier', N'DenialCode', N'DenialDescription',
          N'DenialClassification', N'ActionCode', N'RecommendedAction', N'ActionCategory',
          N'Task', N'Priority', N'InsuranceBalance', N'IsCurrentDenial', N'SLADays',
          N'Status', N'WorkFlowStatus', N'DateOpened', N'DueDate', N'DateCompleted',
          N'DaysRemaining', N'SLAStatus', N'AssignedTo', N'LabId', N'LabName', N'RunId',
          N'CreatedOn', N'SalesRepname', N'ClinicName', N'ReferringProvider', N'PayerName',
          N'PayerCode', N'PayerType', N'FirstBilledDate', N'ChargeEnteredDate',
          N'BillingProvider', N'PanelName', N'DateOfService', N'ReviewerComments',
          N'ReviewerUpdatedOn', N'ReviewerUpdatedBy', N'ICDCodes', N'CoverageStatus',
          N'ICDComplianceStatus', N'DenialValidity'
      );

    -- Keep shared INCLUDE list conservative so each index does not duplicate its key columns.
    SET @taskIncludes = ISNULL(@taskIncludes, N'');
    SET @taskIncludes = REPLACE(REPLACE(@taskIncludes, N'[TaskID], ', N''), N', [TaskID]', N'');
    SET @taskIncludes = REPLACE(REPLACE(@taskIncludes, N'[CPTCode], ', N''), N', [CPTCode]', N'');
    SET @taskIncludes = REPLACE(REPLACE(@taskIncludes, N'[ClaimIDNormalized], ', N''), N', [ClaimIDNormalized]', N'');
    SET @taskIncludes = NULLIF(@taskIncludes, N'');

    IF EXISTS (SELECT 1 FROM #ColumnList WHERE TableName=N'DenialTaskBoard' AND ColumnName=N'ClaimUID')
       AND EXISTS (
           SELECT 1
           FROM sys.indexes i
           JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
           WHERE i.object_id = OBJECT_ID(N'dbo.DenialTaskBoard')
             AND i.name = N'IX_DWF_TaskBoard_ClaimUID_StatusAgg'
             AND ic.is_included_column = 0
           GROUP BY i.object_id, i.index_id
           HAVING COUNT(1) > 1
       )
    BEGIN
        DROP INDEX IX_DWF_TaskBoard_ClaimUID_StatusAgg ON dbo.DenialTaskBoard;
    END;

    IF EXISTS (SELECT 1 FROM #ColumnList WHERE TableName=N'DenialTaskBoard' AND ColumnName=N'ClaimUID')
       AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.DenialTaskBoard') AND name = N'IX_DWF_TaskBoard_ClaimUID_StatusAgg')
    BEGIN
        SET @sql = N'CREATE NONCLUSTERED INDEX IX_DWF_TaskBoard_ClaimUID_StatusAgg
ON dbo.DenialTaskBoard (ClaimUID)' +
CASE WHEN NULLIF(@taskIncludes, N'') IS NULL THEN N'' ELSE N'
INCLUDE (' + @taskIncludes + N')' END + N'
WITH (SORT_IN_TEMPDB = ON, DATA_COMPRESSION = PAGE);';

        EXEC sys.sp_executesql @sql;
    END;

    IF EXISTS (SELECT 1 FROM #ColumnList WHERE TableName=N'DenialTaskBoard' AND ColumnName=N'ClaimUID')
       AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.DenialTaskBoard') AND name = N'IX_DWF_TaskBoard_ClaimUID_Drill')
    BEGIN
        SET @sql = N'CREATE NONCLUSTERED INDEX IX_DWF_TaskBoard_ClaimUID_Drill
ON dbo.DenialTaskBoard (ClaimUID, CPTCode, TaskID)' +
CASE WHEN NULLIF(@taskIncludes, N'') IS NULL THEN N'' ELSE N'
INCLUDE (' + @taskIncludes + N')' END + N'
WITH (SORT_IN_TEMPDB = ON, DATA_COMPRESSION = PAGE);';

        EXEC sys.sp_executesql @sql;
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.DenialTaskBoard') AND name = N'IX_DWF_TaskBoard_ClaimIDNormalized_StatusAgg')
       AND EXISTS (SELECT 1 FROM #ColumnList WHERE TableName=N'DenialTaskBoard' AND ColumnName=N'ClaimIDNormalized')
    BEGIN
        SET @sql = N'CREATE NONCLUSTERED INDEX IX_DWF_TaskBoard_ClaimIDNormalized_StatusAgg
ON dbo.DenialTaskBoard (ClaimIDNormalized, Status, AssignedTo, CreatedOn)' +
CASE WHEN NULLIF(@taskIncludes, N'') IS NULL THEN N'' ELSE N'
INCLUDE (' + @taskIncludes + N')' END + N'
WITH (SORT_IN_TEMPDB = ON, DATA_COMPRESSION = PAGE);';

        EXEC sys.sp_executesql @sql;
    END;
END;

--------------------------------------------------------------------------------
-- DenialClaimEscalations: status checks by LabId + ClaimId.
--------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.DenialClaimEscalations', N'U') IS NOT NULL
BEGIN
    DECLARE @escIncludes nvarchar(max) = N'';

    SELECT @escIncludes = STRING_AGG(QUOTENAME(ColumnName), N', ')
    FROM #ColumnList
    WHERE TableName = N'DenialClaimEscalations'
      AND ColumnName IN
      (
          N'EscalationId', N'EscalationLevel', N'EscalationReason', N'Comments',
          N'Status', N'EscalatedTo', N'EscalatedToRole', N'NextFollowUpDate',
          N'CreatedBy', N'CreatedOn'
      );

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.DenialClaimEscalations') AND name = N'IX_DWF_Escalations_Lab_Claim_Active')
    BEGIN
        SET @sql = N'CREATE NONCLUSTERED INDEX IX_DWF_Escalations_Lab_Claim_Active
ON dbo.DenialClaimEscalations (LabId, ClaimId, IsDeleted)' +
CASE WHEN NULLIF(@escIncludes, N'') IS NULL THEN N'' ELSE N'
INCLUDE (' + @escIncludes + N')' END + N'
WITH (SORT_IN_TEMPDB = ON, DATA_COMPRESSION = PAGE);';

        EXEC sys.sp_executesql @sql;
    END;
END;

--------------------------------------------------------------------------------
-- Refresh stats so SQL Server uses the new indexes immediately.
--------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.DenialLineItem', N'U') IS NOT NULL
    UPDATE STATISTICS dbo.DenialLineItem;

IF OBJECT_ID(N'dbo.DenialTaskBoard', N'U') IS NOT NULL
    UPDATE STATISTICS dbo.DenialTaskBoard;

IF OBJECT_ID(N'dbo.DenialClaimEscalations', N'U') IS NOT NULL
    UPDATE STATISTICS dbo.DenialClaimEscalations;

DROP TABLE #ColumnList;

PRINT 'Denial Workflow ClaimUID claim-view optimization completed.';
GO
