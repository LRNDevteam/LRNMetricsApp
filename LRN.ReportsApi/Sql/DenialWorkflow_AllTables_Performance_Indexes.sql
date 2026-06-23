/*
    Denial Workflow all-table performance indexes
    ------------------------------------------------------------
    Run this script inside EACH lab/customer database that stores the
    Denial Workflow tables. Do not run from master.

    Focus areas:
      - Dashboard summary and AR reviewer aging table
      - Claim level assignment page
      - Overall export/download query
      - Claim notes, documents, escalation, verification lookups

    Safe to re-run. Every index is created only if both an index and a
    statistic with the same name do not already exist.
*/

SET NOCOUNT ON;

IF DB_NAME() IN ('master', 'model', 'msdb', 'tempdb')
BEGIN
    THROW 51000, 'Run DenialWorkflow_AllTables_Performance_Indexes.sql in the lab/customer database, not a system database.', 1;
END;

DECLARE @sql nvarchar(max);
DECLARE @include nvarchar(max);
DECLARE @options nvarchar(max) = N' WITH (SORT_IN_TEMPDB = ON, DATA_COMPRESSION = PAGE)';

IF OBJECT_ID('tempdb..#DwfColumns') IS NOT NULL
    DROP TABLE #DwfColumns;

CREATE TABLE #DwfColumns
(
    TableName sysname NOT NULL,
    ColumnName sysname NOT NULL,
    PRIMARY KEY (TableName, ColumnName)
);

INSERT INTO #DwfColumns (TableName, ColumnName)
SELECT t.name, c.name
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.columns c ON c.object_id = t.object_id
WHERE s.name = 'dbo'
  AND t.name IN
  (
      'DenialTaskBoard',
      'DenialLineItem',
      'DenialClaimEscalations',
      'DenialClaimNotes',
      'DenialClaimDocuments',
      'DenialVerificationTask',
      'DenialClosedClaims',
      'DenialClosedClaimsHistory',
      'DenialInsight',
      'DenialTaskHistory'
  );

PRINT 'Starting Denial Workflow performance index setup for ' + DB_NAME();

/* Normalize DenialTaskBoard claim id fallback used by dashboard/export joins. */
IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialTaskBoard', 'ClaimID') IS NOT NULL
   AND COL_LENGTH('dbo.DenialTaskBoard', 'ClaimIDNormalized') IS NULL
BEGIN
    PRINT 'Adding dbo.DenialTaskBoard.ClaimIDNormalized computed column';
    ALTER TABLE dbo.DenialTaskBoard
    ADD ClaimIDNormalized AS
        CONVERT(nvarchar(100),
            CASE
                WHEN CHARINDEX('-', ClaimID) > 0 THEN LEFT(ClaimID, CHARINDEX('-', ClaimID) - 1)
                ELSE ClaimID
            END
        ) PERSISTED;

    INSERT INTO #DwfColumns (TableName, ColumnName)
    SELECT 'DenialTaskBoard', 'ClaimIDNormalized'
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM #DwfColumns
        WHERE TableName = 'DenialTaskBoard'
          AND ColumnName = 'ClaimIDNormalized'
    );
END;

/* DenialTaskBoard: primary assignment/dashboard/export access paths. */
IF EXISTS (SELECT 1 FROM #DwfColumns WHERE TableName = 'DenialTaskBoard' AND ColumnName IN ('LabId','ClaimUID','Status','AssignedTo','CreatedOn') GROUP BY TableName HAVING COUNT(*) = 5)
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialTaskBoard') AND name = 'IX_DTB_Lab_ClaimUID_Status_Assigned_Created')
   AND NOT EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID('dbo.DenialTaskBoard') AND name = 'IX_DTB_Lab_ClaimUID_Status_Assigned_Created')
BEGIN
    SELECT @include = STRING_AGG(QUOTENAME(ColumnName), ', ')
    FROM #DwfColumns
    WHERE TableName = 'DenialTaskBoard'
      AND ColumnName IN ('TaskId','ClaimID','ClaimIDNormalized','UniqueTrackId','PatientName','PayerName','DenialCode','DenialClassification','ActionCategory','InsuranceBalance','DateOfService','DueDate','ModifiedOn')
      AND ColumnName NOT IN ('LabId','ClaimUID','Status','AssignedTo','CreatedOn');

    SET @sql = N'CREATE NONCLUSTERED INDEX IX_DTB_Lab_ClaimUID_Status_Assigned_Created ON dbo.DenialTaskBoard (LabId, ClaimUID, Status, AssignedTo, CreatedOn)'
        + CASE WHEN @include IS NULL THEN N'' ELSE N' INCLUDE (' + @include + N')' END
        + @options + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'Created IX_DTB_Lab_ClaimUID_Status_Assigned_Created';
END;

IF EXISTS (SELECT 1 FROM #DwfColumns WHERE TableName = 'DenialTaskBoard' AND ColumnName IN ('LabId','Status','AssignedTo','CreatedOn','ClaimUID') GROUP BY TableName HAVING COUNT(*) = 5)
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialTaskBoard') AND name = 'IX_DTB_Lab_Status_Assigned_Created_ClaimUID')
   AND NOT EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID('dbo.DenialTaskBoard') AND name = 'IX_DTB_Lab_Status_Assigned_Created_ClaimUID')
BEGIN
    SELECT @include = STRING_AGG(QUOTENAME(ColumnName), ', ')
    FROM #DwfColumns
    WHERE TableName = 'DenialTaskBoard'
      AND ColumnName IN ('TaskId','ClaimID','ClaimIDNormalized','UniqueTrackId','DenialClassification','ActionCategory','DenialCode','PayerName','InsuranceBalance','DateOfService','DueDate')
      AND ColumnName NOT IN ('LabId','Status','AssignedTo','CreatedOn','ClaimUID');

    SET @sql = N'CREATE NONCLUSTERED INDEX IX_DTB_Lab_Status_Assigned_Created_ClaimUID ON dbo.DenialTaskBoard (LabId, Status, AssignedTo, CreatedOn, ClaimUID)'
        + CASE WHEN @include IS NULL THEN N'' ELSE N' INCLUDE (' + @include + N')' END
        + @options + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'Created IX_DTB_Lab_Status_Assigned_Created_ClaimUID';
END;

IF EXISTS (SELECT 1 FROM #DwfColumns WHERE TableName = 'DenialTaskBoard' AND ColumnName IN ('LabId','ClaimIDNormalized') GROUP BY TableName HAVING COUNT(*) = 2)
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialTaskBoard') AND name = 'IX_DTB_Lab_ClaimIDNormalized')
   AND NOT EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID('dbo.DenialTaskBoard') AND name = 'IX_DTB_Lab_ClaimIDNormalized')
BEGIN
    SELECT @include = STRING_AGG(QUOTENAME(ColumnName), ', ')
    FROM #DwfColumns
    WHERE TableName = 'DenialTaskBoard'
      AND ColumnName IN ('TaskId','ClaimID','ClaimUID','Status','AssignedTo','CreatedOn','DenialClassification','ActionCategory','InsuranceBalance')
      AND ColumnName NOT IN ('LabId','ClaimIDNormalized');

    SET @sql = N'CREATE NONCLUSTERED INDEX IX_DTB_Lab_ClaimIDNormalized ON dbo.DenialTaskBoard (LabId, ClaimIDNormalized)'
        + CASE WHEN @include IS NULL THEN N'' ELSE N' INCLUDE (' + @include + N')' END
        + @options + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'Created IX_DTB_Lab_ClaimIDNormalized';
END;

IF EXISTS (SELECT 1 FROM #DwfColumns WHERE TableName = 'DenialTaskBoard' AND ColumnName IN ('LabId','DenialClassification','ActionCategory') GROUP BY TableName HAVING COUNT(*) = 3)
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialTaskBoard') AND name = 'IX_DTB_Lab_DenialClass_Action')
   AND NOT EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID('dbo.DenialTaskBoard') AND name = 'IX_DTB_Lab_DenialClass_Action')
BEGIN
    SELECT @include = STRING_AGG(QUOTENAME(ColumnName), ', ')
    FROM #DwfColumns
    WHERE TableName = 'DenialTaskBoard'
      AND ColumnName IN ('ClaimUID','ClaimID','ClaimIDNormalized','Status','AssignedTo','InsuranceBalance','DenialCode','PayerName','CreatedOn')
      AND ColumnName NOT IN ('LabId','DenialClassification','ActionCategory');

    SET @sql = N'CREATE NONCLUSTERED INDEX IX_DTB_Lab_DenialClass_Action ON dbo.DenialTaskBoard (LabId, DenialClassification, ActionCategory)'
        + CASE WHEN @include IS NULL THEN N'' ELSE N' INCLUDE (' + @include + N')' END
        + @options + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'Created IX_DTB_Lab_DenialClass_Action';
END;

IF EXISTS (SELECT 1 FROM #DwfColumns WHERE TableName = 'DenialTaskBoard' AND ColumnName IN ('LabId','AssignedTo','DueDate') GROUP BY TableName HAVING COUNT(*) = 3)
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialTaskBoard') AND name = 'IX_DTB_Lab_Assigned_DueDate')
   AND NOT EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID('dbo.DenialTaskBoard') AND name = 'IX_DTB_Lab_Assigned_DueDate')
BEGIN
    SELECT @include = STRING_AGG(QUOTENAME(ColumnName), ', ')
    FROM #DwfColumns
    WHERE TableName = 'DenialTaskBoard'
      AND ColumnName IN ('ClaimUID','ClaimID','Status','TaskId','CreatedOn','InsuranceBalance','DenialClassification','ActionCategory')
      AND ColumnName NOT IN ('LabId','AssignedTo','DueDate');

    SET @sql = N'CREATE NONCLUSTERED INDEX IX_DTB_Lab_Assigned_DueDate ON dbo.DenialTaskBoard (LabId, AssignedTo, DueDate)'
        + CASE WHEN @include IS NULL THEN N'' ELSE N' INCLUDE (' + @include + N')' END
        + @options + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'Created IX_DTB_Lab_Assigned_DueDate';
END;

/* DenialLineItem: claim UID joins, AR aging buckets, and filter/export lookups. */
IF EXISTS (SELECT 1 FROM #DwfColumns WHERE TableName = 'DenialLineItem' AND ColumnName IN ('LabId','ClaimUID','DateOfService') GROUP BY TableName HAVING COUNT(*) = 3)
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialLineItem') AND name = 'IX_DLI_Lab_ClaimUID_DOS')
   AND NOT EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID('dbo.DenialLineItem') AND name = 'IX_DLI_Lab_ClaimUID_DOS')
BEGIN
    SELECT @include = STRING_AGG(QUOTENAME(ColumnName), ', ')
    FROM #DwfColumns
    WHERE TableName = 'DenialLineItem'
      AND ColumnName IN ('VisitNumber','PatientName','PayerName','PanelName','ClinicName','ReferringProvider','PatientID','SalesRepname','InsuranceBalance','DenialClassification','ActionCategory','DenialCode','DenialCodeNormalized','PatientDOB')
      AND ColumnName NOT IN ('LabId','ClaimUID','DateOfService');

    SET @sql = N'CREATE NONCLUSTERED INDEX IX_DLI_Lab_ClaimUID_DOS ON dbo.DenialLineItem (LabId, ClaimUID, DateOfService DESC)'
        + CASE WHEN @include IS NULL THEN N'' ELSE N' INCLUDE (' + @include + N')' END
        + @options + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'Created IX_DLI_Lab_ClaimUID_DOS';
END;

IF EXISTS (SELECT 1 FROM #DwfColumns WHERE TableName = 'DenialLineItem' AND ColumnName IN ('LabId','DateOfService','ClaimUID') GROUP BY TableName HAVING COUNT(*) = 3)
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialLineItem') AND name = 'IX_DLI_Lab_DOS_ClaimUID')
   AND NOT EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID('dbo.DenialLineItem') AND name = 'IX_DLI_Lab_DOS_ClaimUID')
BEGIN
    SELECT @include = STRING_AGG(QUOTENAME(ColumnName), ', ')
    FROM #DwfColumns
    WHERE TableName = 'DenialLineItem'
      AND ColumnName IN ('VisitNumber','PayerName','PanelName','InsuranceBalance','DenialClassification','ActionCategory','DenialCodeNormalized')
      AND ColumnName NOT IN ('LabId','DateOfService','ClaimUID');

    SET @sql = N'CREATE NONCLUSTERED INDEX IX_DLI_Lab_DOS_ClaimUID ON dbo.DenialLineItem (LabId, DateOfService DESC, ClaimUID)'
        + CASE WHEN @include IS NULL THEN N'' ELSE N' INCLUDE (' + @include + N')' END
        + @options + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'Created IX_DLI_Lab_DOS_ClaimUID';
END;

IF EXISTS (SELECT 1 FROM #DwfColumns WHERE TableName = 'DenialLineItem' AND ColumnName IN ('LabId','VisitNumber','DateOfService') GROUP BY TableName HAVING COUNT(*) = 3)
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialLineItem') AND name = 'IX_DLI_Lab_VisitNumber_DOS')
   AND NOT EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID('dbo.DenialLineItem') AND name = 'IX_DLI_Lab_VisitNumber_DOS')
BEGIN
    SELECT @include = STRING_AGG(QUOTENAME(ColumnName), ', ')
    FROM #DwfColumns
    WHERE TableName = 'DenialLineItem'
      AND ColumnName IN ('ClaimUID','PayerName','PanelName','InsuranceBalance','DenialClassification','ActionCategory','DenialCodeNormalized')
      AND ColumnName NOT IN ('LabId','VisitNumber','DateOfService');

    SET @sql = N'CREATE NONCLUSTERED INDEX IX_DLI_Lab_VisitNumber_DOS ON dbo.DenialLineItem (LabId, VisitNumber, DateOfService DESC)'
        + CASE WHEN @include IS NULL THEN N'' ELSE N' INCLUDE (' + @include + N')' END
        + @options + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'Created IX_DLI_Lab_VisitNumber_DOS';
END;

IF EXISTS (SELECT 1 FROM #DwfColumns WHERE TableName = 'DenialLineItem' AND ColumnName IN ('LabId','DenialClassification','ActionCategory') GROUP BY TableName HAVING COUNT(*) = 3)
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialLineItem') AND name = 'IX_DLI_Lab_DenialClass_Action')
   AND NOT EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID('dbo.DenialLineItem') AND name = 'IX_DLI_Lab_DenialClass_Action')
BEGIN
    SELECT @include = STRING_AGG(QUOTENAME(ColumnName), ', ')
    FROM #DwfColumns
    WHERE TableName = 'DenialLineItem'
      AND ColumnName IN ('ClaimUID','VisitNumber','DateOfService','InsuranceBalance','PayerName','DenialCodeNormalized')
      AND ColumnName NOT IN ('LabId','DenialClassification','ActionCategory');

    SET @sql = N'CREATE NONCLUSTERED INDEX IX_DLI_Lab_DenialClass_Action ON dbo.DenialLineItem (LabId, DenialClassification, ActionCategory)'
        + CASE WHEN @include IS NULL THEN N'' ELSE N' INCLUDE (' + @include + N')' END
        + @options + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'Created IX_DLI_Lab_DenialClass_Action';
END;

/* Escalations. */
IF EXISTS (SELECT 1 FROM #DwfColumns WHERE TableName = 'DenialClaimEscalations' AND ColumnName IN ('LabId','ClaimId','IsDeleted','Status') GROUP BY TableName HAVING COUNT(*) = 4)
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialClaimEscalations') AND name = 'IX_DCE_Lab_Claim_Deleted_Status')
   AND NOT EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID('dbo.DenialClaimEscalations') AND name = 'IX_DCE_Lab_Claim_Deleted_Status')
BEGIN
    SELECT @include = STRING_AGG(QUOTENAME(ColumnName), ', ')
    FROM #DwfColumns
    WHERE TableName = 'DenialClaimEscalations'
      AND ColumnName IN ('EscalationId','TaskId','CptCode','EscalatedBy','EscalatedTo','EscalationReason','CreatedOn','UpdatedOn','Response')
      AND ColumnName NOT IN ('LabId','ClaimId','IsDeleted','Status');

    SET @sql = N'CREATE NONCLUSTERED INDEX IX_DCE_Lab_Claim_Deleted_Status ON dbo.DenialClaimEscalations (LabId, ClaimId, IsDeleted, Status)'
        + CASE WHEN @include IS NULL THEN N'' ELSE N' INCLUDE (' + @include + N')' END
        + @options + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'Created IX_DCE_Lab_Claim_Deleted_Status';
END;

IF EXISTS (SELECT 1 FROM #DwfColumns WHERE TableName = 'DenialClaimEscalations' AND ColumnName IN ('LabId','EscalatedTo','IsDeleted','Status') GROUP BY TableName HAVING COUNT(*) = 4)
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialClaimEscalations') AND name = 'IX_DCE_Lab_EscalatedTo_Status')
   AND NOT EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID('dbo.DenialClaimEscalations') AND name = 'IX_DCE_Lab_EscalatedTo_Status')
BEGIN
    SELECT @include = STRING_AGG(QUOTENAME(ColumnName), ', ')
    FROM #DwfColumns
    WHERE TableName = 'DenialClaimEscalations'
      AND ColumnName IN ('EscalationId','ClaimId','TaskId','CptCode','EscalatedBy','CreatedOn','EscalationReason')
      AND ColumnName NOT IN ('LabId','EscalatedTo','IsDeleted','Status');

    SET @sql = N'CREATE NONCLUSTERED INDEX IX_DCE_Lab_EscalatedTo_Status ON dbo.DenialClaimEscalations (LabId, EscalatedTo, IsDeleted, Status)'
        + CASE WHEN @include IS NULL THEN N'' ELSE N' INCLUDE (' + @include + N')' END
        + @options + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'Created IX_DCE_Lab_EscalatedTo_Status';
END;

/* Notes and documents. */
IF EXISTS (SELECT 1 FROM #DwfColumns WHERE TableName = 'DenialClaimNotes' AND ColumnName IN ('LabId','ClaimId','IsDeleted','CreatedOn') GROUP BY TableName HAVING COUNT(*) = 4)
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialClaimNotes') AND name = 'IX_DCN_Lab_Claim_Deleted_Created')
   AND NOT EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID('dbo.DenialClaimNotes') AND name = 'IX_DCN_Lab_Claim_Deleted_Created')
BEGIN
    SELECT @include = STRING_AGG(QUOTENAME(ColumnName), ', ')
    FROM #DwfColumns
    WHERE TableName = 'DenialClaimNotes'
      AND ColumnName IN ('NoteId','TaskId','CptCode','NoteLevel','Status','CreatedBy','UpdatedOn')
      AND ColumnName NOT IN ('LabId','ClaimId','IsDeleted','CreatedOn');

    SET @sql = N'CREATE NONCLUSTERED INDEX IX_DCN_Lab_Claim_Deleted_Created ON dbo.DenialClaimNotes (LabId, ClaimId, IsDeleted, CreatedOn DESC)'
        + CASE WHEN @include IS NULL THEN N'' ELSE N' INCLUDE (' + @include + N')' END
        + @options + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'Created IX_DCN_Lab_Claim_Deleted_Created';
END;

IF EXISTS (SELECT 1 FROM #DwfColumns WHERE TableName = 'DenialClaimDocuments' AND ColumnName IN ('LabId','ClaimId','IsDeleted','UploadedOn') GROUP BY TableName HAVING COUNT(*) = 4)
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialClaimDocuments') AND name = 'IX_DCD_Lab_Claim_Deleted_Uploaded')
   AND NOT EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID('dbo.DenialClaimDocuments') AND name = 'IX_DCD_Lab_Claim_Deleted_Uploaded')
BEGIN
    SELECT @include = STRING_AGG(QUOTENAME(ColumnName), ', ')
    FROM #DwfColumns
    WHERE TableName = 'DenialClaimDocuments'
      AND ColumnName IN ('DocumentId','TaskId','CptCode','FileName','ContentType','UploadedBy')
      AND ColumnName NOT IN ('LabId','ClaimId','IsDeleted','UploadedOn');

    SET @sql = N'CREATE NONCLUSTERED INDEX IX_DCD_Lab_Claim_Deleted_Uploaded ON dbo.DenialClaimDocuments (LabId, ClaimId, IsDeleted, UploadedOn DESC)'
        + CASE WHEN @include IS NULL THEN N'' ELSE N' INCLUDE (' + @include + N')' END
        + @options + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'Created IX_DCD_Lab_Claim_Deleted_Uploaded';
END;

/* Verification and closed-claim queues. */
IF EXISTS (SELECT 1 FROM #DwfColumns WHERE TableName = 'DenialVerificationTask' AND ColumnName IN ('LabId','VerificationStatus','AssignedTo') GROUP BY TableName HAVING COUNT(*) = 3)
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialVerificationTask') AND name = 'IX_DVT_Lab_VerificationStatus_Assigned')
   AND NOT EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID('dbo.DenialVerificationTask') AND name = 'IX_DVT_Lab_VerificationStatus_Assigned')
BEGIN
    SELECT @include = STRING_AGG(QUOTENAME(ColumnName), ', ')
    FROM #DwfColumns
    WHERE TableName = 'DenialVerificationTask'
      AND ColumnName IN ('TaskId','ClaimUID','ClaimId','Status','MovedOn','CreatedOn','UpdatedOn','CptCode','PayerName')
      AND ColumnName NOT IN ('LabId','VerificationStatus','AssignedTo');

    SET @sql = N'CREATE NONCLUSTERED INDEX IX_DVT_Lab_VerificationStatus_Assigned ON dbo.DenialVerificationTask (LabId, VerificationStatus, AssignedTo)'
        + CASE WHEN @include IS NULL THEN N'' ELSE N' INCLUDE (' + @include + N')' END
        + @options + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'Created IX_DVT_Lab_VerificationStatus_Assigned';
END;

IF EXISTS (SELECT 1 FROM #DwfColumns WHERE TableName = 'DenialClosedClaims' AND ColumnName IN ('LabId','ClaimId') GROUP BY TableName HAVING COUNT(*) = 2)
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialClosedClaims') AND name = 'IX_DCC_Lab_Claim')
   AND NOT EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID('dbo.DenialClosedClaims') AND name = 'IX_DCC_Lab_Claim')
BEGIN
    SELECT @include = STRING_AGG(QUOTENAME(ColumnName), ', ')
    FROM #DwfColumns
    WHERE TableName = 'DenialClosedClaims'
      AND ColumnName IN ('TaskId','CptCode','AssignedTo','ClosedBy','ClosedOn','Status','Reason','CreatedOn')
      AND ColumnName NOT IN ('LabId','ClaimId');

    SET @sql = N'CREATE NONCLUSTERED INDEX IX_DCC_Lab_Claim ON dbo.DenialClosedClaims (LabId, ClaimId)'
        + CASE WHEN @include IS NULL THEN N'' ELSE N' INCLUDE (' + @include + N')' END
        + @options + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'Created IX_DCC_Lab_Claim';
END;

IF EXISTS (SELECT 1 FROM #DwfColumns WHERE TableName = 'DenialClosedClaimsHistory' AND ColumnName IN ('LabId','ClaimId') GROUP BY TableName HAVING COUNT(*) = 2)
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialClosedClaimsHistory') AND name = 'IX_DCCH_Lab_Claim')
   AND NOT EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID('dbo.DenialClosedClaimsHistory') AND name = 'IX_DCCH_Lab_Claim')
BEGIN
    SELECT @include = STRING_AGG(QUOTENAME(ColumnName), ', ')
    FROM #DwfColumns
    WHERE TableName = 'DenialClosedClaimsHistory'
      AND ColumnName IN ('TaskId','CptCode','AssignedTo','ClosedBy','ClosedOn','Status','Reason','ActionDate','CreatedOn')
      AND ColumnName NOT IN ('LabId','ClaimId');

    SET @sql = N'CREATE NONCLUSTERED INDEX IX_DCCH_Lab_Claim ON dbo.DenialClosedClaimsHistory (LabId, ClaimId)'
        + CASE WHEN @include IS NULL THEN N'' ELSE N' INCLUDE (' + @include + N')' END
        + @options + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'Created IX_DCCH_Lab_Claim';
END;

/* DenialInsight and task history. */
IF EXISTS (SELECT 1 FROM #DwfColumns WHERE TableName = 'DenialInsight' AND ColumnName IN ('LabId','InsuranceBalance') GROUP BY TableName HAVING COUNT(*) = 2)
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialInsight') AND name = 'IX_DI_Lab_InsuranceBalance')
   AND NOT EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID('dbo.DenialInsight') AND name = 'IX_DI_Lab_InsuranceBalance')
BEGIN
    SELECT @include = STRING_AGG(QUOTENAME(ColumnName), ', ')
    FROM #DwfColumns
    WHERE TableName = 'DenialInsight'
      AND ColumnName IN ('RunId','VisitNumber','ClaimUID','DenialCodes','HighImpactInsurance','PatientName','PayerName','PanelName','DateOfService')
      AND ColumnName NOT IN ('LabId','InsuranceBalance');

    SET @sql = N'CREATE NONCLUSTERED INDEX IX_DI_Lab_InsuranceBalance ON dbo.DenialInsight (LabId, InsuranceBalance DESC)'
        + CASE WHEN @include IS NULL THEN N'' ELSE N' INCLUDE (' + @include + N')' END
        + @options + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'Created IX_DI_Lab_InsuranceBalance';
END;

IF EXISTS (SELECT 1 FROM #DwfColumns WHERE TableName = 'DenialTaskHistory' AND ColumnName IN ('LabId','ClaimId') GROUP BY TableName HAVING COUNT(*) = 2)
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialTaskHistory') AND name = 'IX_DTH_Lab_Claim')
   AND NOT EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID('dbo.DenialTaskHistory') AND name = 'IX_DTH_Lab_Claim')
BEGIN
    SELECT @include = STRING_AGG(QUOTENAME(ColumnName), ', ')
    FROM #DwfColumns
    WHERE TableName = 'DenialTaskHistory'
      AND ColumnName IN ('TaskId','CptCode','AssignedTo','Status','Action','CreatedOn','UpdatedOn','CreatedBy')
      AND ColumnName NOT IN ('LabId','ClaimId');

    SET @sql = N'CREATE NONCLUSTERED INDEX IX_DTH_Lab_Claim ON dbo.DenialTaskHistory (LabId, ClaimId)'
        + CASE WHEN @include IS NULL THEN N'' ELSE N' INCLUDE (' + @include + N')' END
        + @options + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'Created IX_DTH_Lab_Claim';
END;

/* Refresh statistics for the tables that exist. */
DECLARE @tableName sysname;
DECLARE table_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT DISTINCT TableName
FROM #DwfColumns
ORDER BY TableName;

OPEN table_cursor;
FETCH NEXT FROM table_cursor INTO @tableName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'UPDATE STATISTICS dbo.' + QUOTENAME(@tableName) + N' WITH RESAMPLE;';
    EXEC sys.sp_executesql @sql;
    PRINT 'Updated statistics for dbo.' + @tableName;

    FETCH NEXT FROM table_cursor INTO @tableName;
END;

CLOSE table_cursor;
DEALLOCATE table_cursor;

PRINT 'Completed Denial Workflow performance index setup for ' + DB_NAME();
