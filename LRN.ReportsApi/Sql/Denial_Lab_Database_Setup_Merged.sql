/*
    Denial lab-database setup (merged)
    ------------------------------------------------------------
    Target database: each lab/customer database that stores Denial Workflow data.

    This script consolidates the non-destructive lab-scoped denial setup and
    migration files from this folder. It intentionally excludes the Northwest
    destructive clone/reset script and validation-only script; see
    Denial_Sql_Script_Inventory.md for the comparison and classification.

    Safe to re-run: sections use OBJECT_ID, COL_LENGTH, and sys.indexes guards.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() IN (N'master', N'model', N'msdb', N'tempdb')
BEGIN
    THROW 51001, 'Run this script in a lab/customer database, not a SQL Server system database.', 1;
END;
GO
/* ============================================================================
   Source: DenialWorkflow_Setup.sql
   ============================================================================ */
/* Run this once in each lab database before enabling LRN.ReportsApi workflow. */
IF OBJECT_ID('dbo.DenialStatusMaster','U') IS NULL
BEGIN
CREATE TABLE dbo.DenialStatusMaster(StatusId int IDENTITY(1,1) PRIMARY KEY, StatusName nvarchar(100) NOT NULL UNIQUE, IsClosedStatus bit NOT NULL DEFAULT(0), IsVerificationStatus bit NOT NULL DEFAULT(0), SortOrder int NOT NULL DEFAULT(100), IsActive bit NOT NULL DEFAULT(1));
END

IF COL_LENGTH('dbo.DenialStatusMaster','IsClosedStatus') IS NULL ALTER TABLE dbo.DenialStatusMaster ADD IsClosedStatus bit NOT NULL CONSTRAINT DF_DenialStatusMaster_IsClosedStatus DEFAULT(0);
IF COL_LENGTH('dbo.DenialStatusMaster','IsVerificationStatus') IS NULL ALTER TABLE dbo.DenialStatusMaster ADD IsVerificationStatus bit NOT NULL CONSTRAINT DF_DenialStatusMaster_IsVerificationStatus DEFAULT(0);
IF COL_LENGTH('dbo.DenialStatusMaster','SortOrder') IS NULL ALTER TABLE dbo.DenialStatusMaster ADD SortOrder int NOT NULL CONSTRAINT DF_DenialStatusMaster_SortOrder DEFAULT(100);
IF COL_LENGTH('dbo.DenialStatusMaster','IsActive') IS NULL ALTER TABLE dbo.DenialStatusMaster ADD IsActive bit NOT NULL CONSTRAINT DF_DenialStatusMaster_IsActive DEFAULT(1);
MERGE dbo.DenialStatusMaster AS t USING (VALUES
('Closed',1,0,10),('Completed',1,0,20),('Duplicate',0,1,30),('Verification Pending',0,1,40),('Pending Review',0,0,50),('In-Progress',0,0,60),('New',0,0,70)
) AS s(StatusName,IsClosedStatus,IsVerificationStatus,SortOrder) ON t.StatusName=s.StatusName
WHEN MATCHED THEN UPDATE SET IsClosedStatus=s.IsClosedStatus, IsVerificationStatus=s.IsVerificationStatus, SortOrder=s.SortOrder, IsActive=1
WHEN NOT MATCHED THEN INSERT(StatusName,IsClosedStatus,IsVerificationStatus,SortOrder) VALUES(s.StatusName,s.IsClosedStatus,s.IsVerificationStatus,s.SortOrder);

IF OBJECT_ID('dbo.DenialActionCategoryMaster','U') IS NULL
BEGIN
CREATE TABLE dbo.DenialActionCategoryMaster(ActionCategory nvarchar(255) NOT NULL PRIMARY KEY, Scope nvarchar(50) NOT NULL DEFAULT('CPTLevel'), IsActive bit NOT NULL DEFAULT(1), CreatedOn datetime2(0) NOT NULL DEFAULT(SYSDATETIME()));
END
MERGE dbo.DenialActionCategoryMaster AS t USING (VALUES('Rebill','ClaimLevel')) AS s(ActionCategory,Scope) ON t.ActionCategory=s.ActionCategory
WHEN MATCHED THEN UPDATE SET Scope=s.Scope, IsActive=1
WHEN NOT MATCHED THEN INSERT(ActionCategory,Scope) VALUES(s.ActionCategory,s.Scope);

IF OBJECT_ID('dbo.DenialTaskHistory','U') IS NULL
BEGIN
CREATE TABLE dbo.DenialTaskHistory(
 HistoryId bigint IDENTITY(1,1) PRIMARY KEY, TaskID nvarchar(100) NOT NULL, UniqueTrackId nvarchar(150) NOT NULL, LabId int NULL, RunId nvarchar(100) NULL,
 ActionType nvarchar(100) NOT NULL, OldStatus nvarchar(100) NULL, NewStatus nvarchar(100) NULL, OldAssignedTo nvarchar(255) NULL, NewAssignedTo nvarchar(255) NULL,
 Comments nvarchar(max) NULL, ActionBy nvarchar(255) NULL, ActionDate datetime2(0) NOT NULL DEFAULT(SYSDATETIME()), SnapshotJson nvarchar(max) NULL
);
CREATE INDEX IX_DenialTaskHistory_Lab_UID ON dbo.DenialTaskHistory(LabId, UniqueTrackId, HistoryId DESC);
END

IF OBJECT_ID('dbo.DenialVerificationTask','U') IS NULL
BEGIN
CREATE TABLE dbo.DenialVerificationTask(
 VerificationId bigint IDENTITY(1,1) PRIMARY KEY, TaskID nvarchar(100) NOT NULL, UniqueTrackId nvarchar(150) NOT NULL,
 ClaimID nvarchar(100) NULL, PatientId nvarchar(100) NULL, CPTCode nvarchar(50) NULL, DenialCode nvarchar(100) NULL, DenialDescription nvarchar(500) NULL,
 DenialClassification nvarchar(255) NULL, ActionCode nvarchar(100) NULL, RecommendedAction nvarchar(500) NULL, ActionCategory nvarchar(500) NULL, Task nvarchar(500) NULL, Priority nvarchar(100) NULL,
 InsuranceBalance decimal(18,2) NOT NULL DEFAULT(0), Status nvarchar(100) NULL, AssignedTo nvarchar(255) NULL, DateOpened date NULL, DueDate date NULL,
 ReviewerComments nvarchar(max) NULL, LabId int NULL, LabName nvarchar(255) NULL, OriginalRunId nvarchar(100) NULL, MissingDetectedRunId nvarchar(100) NULL, RunId nvarchar(100) NULL,
 VerificationStatus nvarchar(100) NOT NULL DEFAULT('Pending'), VerificationComments nvarchar(max) NULL, MovedOn datetime2(0) NOT NULL DEFAULT(SYSDATETIME()), VerifiedOn datetime2(0) NULL, VerifiedBy nvarchar(255) NULL
);
CREATE INDEX IX_DenialVerificationTask_Lab_Status_Assigned ON dbo.DenialVerificationTask(LabId, VerificationStatus, AssignedTo);
CREATE INDEX IX_DenialVerificationTask_Lab_UID ON dbo.DenialVerificationTask(LabId, UniqueTrackId);
END

IF COL_LENGTH('dbo.DenialTaskBoard','UniqueTrackId') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD UniqueTrackId nvarchar(150) NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','ReviewerComments') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD ReviewerComments nvarchar(max) NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','ReviewerUpdatedOn') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD ReviewerUpdatedOn datetime2(0) NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','ReviewerUpdatedBy') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD ReviewerUpdatedBy nvarchar(255) NULL;
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='IX_DenialTaskBoard_Lab_UID' AND object_id=OBJECT_ID('dbo.DenialTaskBoard')) CREATE INDEX IX_DenialTaskBoard_Lab_UID ON dbo.DenialTaskBoard(LabId, UniqueTrackId);
GO

/* ============================================================================
   Source: DenialTaskBoard_Update.sql
   ============================================================================ */
/*
Run this once in each lab database.
It creates the normalized claim id used by Denial Workflow joins:
DenialTaskBoard.ClaimID = 'CLM-10001'
DenialLineItem.VisitNumber = '10001'
*/
IF OBJECT_ID('dbo.DenialTaskBoard','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialTaskBoard','ClaimIDNormalized') IS NULL
    BEGIN
        ALTER TABLE dbo.DenialTaskBoard
        ADD ClaimIDNormalized AS CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL([ClaimID],''))), 'CLM-', '')) PERSISTED;
    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.indexes
        WHERE name = 'IX_DenialTaskBoard_ClaimIDNormalized'
          AND object_id = OBJECT_ID('dbo.DenialTaskBoard')
    )
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_ClaimIDNormalized
        ON dbo.DenialTaskBoard (ClaimIDNormalized);
    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.indexes
        WHERE name = 'IX_DenialTaskBoard_TaskView_ClaimIDNormalized'
          AND object_id = OBJECT_ID('dbo.DenialTaskBoard')
    )
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_TaskView_ClaimIDNormalized
        ON dbo.DenialTaskBoard (Status, AssignedTo, ClaimIDNormalized)
        INCLUDE (TaskID, UniqueTrackId, CPTCode, SLAStatus, DueDate, InsuranceBalance, DenialCode, DenialClassification, ActionCategory);
    END;
END;

IF OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL
   AND NOT EXISTS
   (
       SELECT 1
       FROM sys.indexes
       WHERE name = 'IX_DenialLineItem_VisitNumber_ClaimView'
         AND object_id = OBJECT_ID('dbo.DenialLineItem')
   )
BEGIN
    CREATE NONCLUSTERED INDEX IX_DenialLineItem_VisitNumber_ClaimView
    ON dbo.DenialLineItem (VisitNumber, DateOfService)
    INCLUDE (PayerNameNormalized, PanelName, PatientDOB, ClinicName, ReferringProvider, PatientID, SalesRepname, InsuranceBalance);
END;
GO

/* ============================================================================
   Source: DenialCodeMaster_CreateTable_Indexes.sql
   ============================================================================ */
/* Denial Code Master - AR Manager only workflow master table */
IF OBJECT_ID('dbo.DenialCodeMaster', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialCodeMaster
    (
        DenialCode nvarchar(100) NOT NULL,
        DenialDescription nvarchar(1000) NULL,
        DenialClassification nvarchar(255) NULL,
        CoverageStatus nvarchar(255) NOT NULL,
        ICDComplianceStatus nvarchar(255) NOT NULL,
        DenialValidity nvarchar(255) NULL,
        ActionCode nvarchar(100) NULL,
        RecommendedAction nvarchar(1000) NULL,
        ActionCategory nvarchar(255) NULL,
        Task nvarchar(500) NULL,
        ShortCategory nvarchar(255) NULL,
        Priority nvarchar(100) NULL,
        SLADays nvarchar(100) NULL,
        NotesComments nvarchar(2000) NULL,
        CreatedOn datetime2 NOT NULL CONSTRAINT DF_DenialCodeMaster_CreatedOn DEFAULT SYSUTCDATETIME(),
        CreatedBy nvarchar(100) NULL,
        UpdatedOn datetime2 NULL,
        UpdatedBy nvarchar(100) NULL,
        CONSTRAINT PK_DenialCodeMaster PRIMARY KEY CLUSTERED (DenialCode, CoverageStatus, ICDComplianceStatus)
    );
END;
GO

IF OBJECT_ID('dbo.DenialCodeMaster', 'U') IS NOT NULL
   AND EXISTS (
       SELECT 1
       FROM sys.columns c
       JOIN sys.types t ON c.user_type_id = t.user_type_id
       WHERE c.object_id = OBJECT_ID('dbo.DenialCodeMaster')
         AND c.name = 'SLADays'
         AND t.name <> 'nvarchar'
   )
BEGIN
    ALTER TABLE dbo.DenialCodeMaster ALTER COLUMN SLADays nvarchar(100) NULL;
END;
GO

IF OBJECT_ID('dbo.DenialCodeMaster', 'U') IS NOT NULL
BEGIN
    UPDATE dbo.DenialCodeMaster
    SET CoverageStatus = N''
    WHERE CoverageStatus IS NULL;

    UPDATE dbo.DenialCodeMaster
    SET ICDComplianceStatus = N''
    WHERE ICDComplianceStatus IS NULL;

    ;WITH DuplicateKeys AS
    (
        SELECT *,
               ROW_NUMBER() OVER
               (
                   PARTITION BY DenialCode, CoverageStatus, ICDComplianceStatus
                   ORDER BY COALESCE(UpdatedOn, CreatedOn) DESC, CreatedOn DESC
               ) AS RowNumber
        FROM dbo.DenialCodeMaster
    )
    DELETE FROM DuplicateKeys
    WHERE RowNumber > 1;

    ALTER TABLE dbo.DenialCodeMaster ALTER COLUMN CoverageStatus nvarchar(255) NOT NULL;
    ALTER TABLE dbo.DenialCodeMaster ALTER COLUMN ICDComplianceStatus nvarchar(255) NOT NULL;
END;
GO

IF OBJECT_ID('dbo.DenialCodeMaster', 'U') IS NOT NULL
BEGIN
    DECLARE @ExistingPrimaryKey sysname;

    SELECT @ExistingPrimaryKey = kc.name
    FROM sys.key_constraints kc
    WHERE kc.parent_object_id = OBJECT_ID('dbo.DenialCodeMaster')
      AND kc.[type] = 'PK';

    IF @ExistingPrimaryKey IS NOT NULL
    BEGIN
        DECLARE @DropPrimaryKeySql nvarchar(max) = N'ALTER TABLE dbo.DenialCodeMaster DROP CONSTRAINT ' + QUOTENAME(@ExistingPrimaryKey) + N';';
        EXEC sp_executesql @DropPrimaryKeySql;
    END;

    IF NOT EXISTS (
        SELECT 1
        FROM sys.key_constraints kc
        JOIN sys.index_columns ic1 ON ic1.object_id = kc.parent_object_id AND ic1.index_id = kc.unique_index_id AND ic1.key_ordinal = 1
        JOIN sys.columns c1 ON c1.object_id = ic1.object_id AND c1.column_id = ic1.column_id
        JOIN sys.index_columns ic2 ON ic2.object_id = kc.parent_object_id AND ic2.index_id = kc.unique_index_id AND ic2.key_ordinal = 2
        JOIN sys.columns c2 ON c2.object_id = ic2.object_id AND c2.column_id = ic2.column_id
        JOIN sys.index_columns ic3 ON ic3.object_id = kc.parent_object_id AND ic3.index_id = kc.unique_index_id AND ic3.key_ordinal = 3
        JOIN sys.columns c3 ON c3.object_id = ic3.object_id AND c3.column_id = ic3.column_id
        WHERE kc.parent_object_id = OBJECT_ID('dbo.DenialCodeMaster')
          AND kc.[type] = 'PK'
          AND c1.name = 'DenialCode'
          AND c2.name = 'CoverageStatus'
          AND c3.name = 'ICDComplianceStatus'
    )
    BEGIN
        ALTER TABLE dbo.DenialCodeMaster
        ADD CONSTRAINT PK_DenialCodeMaster PRIMARY KEY CLUSTERED (DenialCode, CoverageStatus, ICDComplianceStatus);
    END;
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialCodeMaster_Classification' AND object_id = OBJECT_ID('dbo.DenialCodeMaster'))
    CREATE NONCLUSTERED INDEX IX_DenialCodeMaster_Classification
    ON dbo.DenialCodeMaster (DenialClassification, CoverageStatus)
    INCLUDE (ActionCode, ActionCategory, Priority, SLADays);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialCodeMaster_Action' AND object_id = OBJECT_ID('dbo.DenialCodeMaster'))
    CREATE NONCLUSTERED INDEX IX_DenialCodeMaster_Action
    ON dbo.DenialCodeMaster (ActionCode, ActionCategory)
    INCLUDE (DenialClassification, CoverageStatus, Task);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialCodeMaster_Lookups' AND object_id = OBJECT_ID('dbo.DenialCodeMaster'))
    CREATE NONCLUSTERED INDEX IX_DenialCodeMaster_Lookups
    ON dbo.DenialCodeMaster (DenialValidity, ICDComplianceStatus, Task)
    INCLUDE (DenialClassification, CoverageStatus, ActionCode, ActionCategory);
GO
GO

/* ============================================================================
   Source: DenialWorkflow_ClaimNotes_Documents.sql
   ============================================================================ */
IF OBJECT_ID('dbo.DenialClaimNotes','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialClaimNotes
    (
        NoteId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialClaimNotes PRIMARY KEY,
        LabId int NOT NULL,
        ClaimId nvarchar(150) NOT NULL,
        TaskId nvarchar(100) NULL,
        CptCode nvarchar(50) NULL,
        NoteLevel nvarchar(20) NOT NULL, -- Claim / Line
        NoteText nvarchar(max) NOT NULL,
        CreatedBy nvarchar(256) NOT NULL,
        CreatedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialClaimNotes_CreatedOn DEFAULT SYSUTCDATETIME(),
        IsDeleted bit NOT NULL CONSTRAINT DF_DenialClaimNotes_IsDeleted DEFAULT 0
    );

    CREATE INDEX IX_DenialClaimNotes_Claim ON dbo.DenialClaimNotes(LabId, ClaimId, NoteLevel, CreatedOn DESC);
    CREATE INDEX IX_DenialClaimNotes_Line ON dbo.DenialClaimNotes(LabId, ClaimId, TaskId, CptCode, CreatedOn DESC);
END;

IF OBJECT_ID('dbo.DenialClaimDocuments','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialClaimDocuments
    (
        DocumentId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialClaimDocuments PRIMARY KEY,
        LabId int NOT NULL,
        ClaimId nvarchar(150) NOT NULL,
        OriginalFileName nvarchar(260) NOT NULL,
        StoredFileName nvarchar(260) NOT NULL,
        ContentType nvarchar(150) NULL,
        FileSizeBytes bigint NOT NULL,
        FilePath nvarchar(1000) NOT NULL,
        Comment nvarchar(1000) NULL,
        UploadedBy nvarchar(256) NOT NULL,
        UploadedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialClaimDocuments_UploadedOn DEFAULT SYSUTCDATETIME(),
        IsDeleted bit NOT NULL CONSTRAINT DF_DenialClaimDocuments_IsDeleted DEFAULT 0
    );

    CREATE INDEX IX_DenialClaimDocuments_Claim ON dbo.DenialClaimDocuments(LabId, ClaimId, UploadedOn DESC);
END;
GO

/* ============================================================================
   Source: DenialWorkflow_MyWorklist_Escalations.sql
   ============================================================================ */
/* Run this in every lab-level denial database before using My Worklist escalation history. */
IF OBJECT_ID('dbo.DenialClaimEscalations','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialClaimEscalations
    (
        EscalationId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialClaimEscalations PRIMARY KEY,
        LabId int NOT NULL,
        ClaimId nvarchar(150) NOT NULL,
        TaskId nvarchar(100) NULL,
        CptCode nvarchar(50) NULL,
        EscalationLevel nvarchar(20) NOT NULL,
        EscalationReason nvarchar(300) NOT NULL,
        Comments nvarchar(max) NULL,
        Status nvarchar(50) NOT NULL CONSTRAINT DF_DenialClaimEscalations_Status DEFAULT 'Open',
        CreatedBy nvarchar(256) NOT NULL,
        CreatedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialClaimEscalations_CreatedOn DEFAULT SYSUTCDATETIME(),
        IsDeleted bit NOT NULL CONSTRAINT DF_DenialClaimEscalations_IsDeleted DEFAULT 0
    );
    CREATE INDEX IX_DenialClaimEscalations_Claim ON dbo.DenialClaimEscalations(LabId, ClaimId, EscalationLevel, CreatedOn DESC);
    CREATE INDEX IX_DenialClaimEscalations_Line ON dbo.DenialClaimEscalations(LabId, ClaimId, TaskId, CptCode, CreatedOn DESC);
END;
GO
GO

/* ============================================================================
   Source: DenialClosedClaimsHistory_Setup.sql
   ============================================================================ */
/*
Run this in each lab database that contains DenialTaskBoard and DenialLineItem.
It adds workflow status tracking, the closed-claims display table, and the
history table for closed-claim audit entries.
*/

IF OBJECT_ID('dbo.DenialTaskBoard','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialTaskBoard','WorkFlowStatus') IS NULL
        ALTER TABLE dbo.DenialTaskBoard ADD WorkFlowStatus nvarchar(100) NULL;
END;

IF OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialLineItem','AssignedTo') IS NULL
        ALTER TABLE dbo.DenialLineItem ADD AssignedTo nvarchar(255) NULL;

    IF COL_LENGTH('dbo.DenialLineItem','WorkFlowStatus') IS NULL
        ALTER TABLE dbo.DenialLineItem ADD WorkFlowStatus nvarchar(100) NULL;
END;

IF OBJECT_ID('dbo.DenialClosedClaims','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialClosedClaims
    (
        ClosedClaimId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialClosedClaims PRIMARY KEY,
        LabId int NOT NULL,
        ClaimId nvarchar(150) NOT NULL,
        PayerName nvarchar(256) NULL,
        PanelName nvarchar(256) NULL,
        PatientName nvarchar(255) NULL,
        PatientDOB date NULL,
        PatientId nvarchar(100) NULL,
        SubscriberId nvarchar(100) NULL,
        ClinicName nvarchar(256) NULL,
        SalesRepname nvarchar(256) NULL,
        ReferringProvider nvarchar(256) NULL,
        DateOfService date NULL,
        AssignedTo nvarchar(255) NULL,
        Status nvarchar(100) NOT NULL CONSTRAINT DF_DenialClosedClaims_Status DEFAULT 'Closed',
        WorkFlowStatus nvarchar(100) NOT NULL CONSTRAINT DF_DenialClosedClaims_WorkFlowStatus DEFAULT 'Closed Claim',
        TaskCount int NOT NULL CONSTRAINT DF_DenialClosedClaims_TaskCount DEFAULT 0,
        InsuranceBalance decimal(18,2) NOT NULL CONSTRAINT DF_DenialClosedClaims_InsuranceBalance DEFAULT 0,
        ClosedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialClosedClaims_ClosedOn DEFAULT SYSUTCDATETIME(),
        ClosedBy nvarchar(256) NULL,
        LastUpdatedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialClosedClaims_LastUpdatedOn DEFAULT SYSUTCDATETIME()
    );

    CREATE UNIQUE INDEX UX_DenialClosedClaims_Lab_Claim
        ON dbo.DenialClosedClaims(LabId, ClaimId);

    CREATE INDEX IX_DenialClosedClaims_Lab_ClosedOn
        ON dbo.DenialClosedClaims(LabId, ClosedOn DESC)
        INCLUDE(ClaimId, AssignedTo, WorkFlowStatus, InsuranceBalance);
END;

IF OBJECT_ID('dbo.DenialClosedClaimsHistory','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialClosedClaimsHistory
    (
        HistoryId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialClosedClaimsHistory PRIMARY KEY,
        ClosedClaimId bigint NULL,
        LabId int NOT NULL,
        ClaimId nvarchar(150) NOT NULL,
        ActionType nvarchar(100) NOT NULL,
        OldWorkFlowStatus nvarchar(100) NULL,
        NewWorkFlowStatus nvarchar(100) NULL,
        OldAssignedTo nvarchar(255) NULL,
        NewAssignedTo nvarchar(255) NULL,
        Comments nvarchar(max) NULL,
        ActionBy nvarchar(256) NULL,
        ActionDate datetime2(0) NOT NULL CONSTRAINT DF_DenialClosedClaimsHistory_ActionDate DEFAULT SYSUTCDATETIME()
    );

    CREATE INDEX IX_DenialClosedClaimsHistory_Lab_Claim
        ON dbo.DenialClosedClaimsHistory(LabId, ClaimId, ActionDate DESC);
END;
GO

/* ============================================================================
   Source: DenialWorkflow_StatusModel_ManagerReview_20260604.sql
   ============================================================================ */
/*
  Denial Workflow Manager Review status model migration
  Date: 2026-06-04

  Run this once per lab database before relying on the manager-review status fields.
  The script is idempotent and intentionally leaves unmapped/custom statuses for review.
*/

SET NOCOUNT ON;

IF OBJECT_ID('dbo.DenialTaskBoard','U') IS NULL
BEGIN
    RAISERROR('dbo.DenialTaskBoard was not found in this database.', 16, 1);
    RETURN;
END;

IF COL_LENGTH('dbo.DenialTaskBoard','ActionCompleted') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD ActionCompleted bit NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','ActualOutcome') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD ActualOutcome nvarchar(150) NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','DocumentationType') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD DocumentationType nvarchar(150) NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','FollowUpReason') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD FollowUpReason nvarchar(150) NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','ClosureReason') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD ClosureReason nvarchar(150) NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','SyncConfirmation') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD SyncConfirmation nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','ValidationStatus') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD ValidationStatus nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','ExpectedResponseDate') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD ExpectedResponseDate date NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','LastWorkflowUpdatedBy') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD LastWorkflowUpdatedBy nvarchar(255) NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','LastWorkflowUpdatedOn') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD LastWorkflowUpdatedOn datetime2(0) NULL;

IF OBJECT_ID('dbo.DenialClaimEscalations','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialClaimEscalations','EscalationScope') IS NULL ALTER TABLE dbo.DenialClaimEscalations ADD EscalationScope nvarchar(30) NULL;
    IF COL_LENGTH('dbo.DenialClaimEscalations','EscalationScopeValue') IS NULL ALTER TABLE dbo.DenialClaimEscalations ADD EscalationScopeValue nvarchar(150) NULL;
    IF COL_LENGTH('dbo.DenialClaimEscalations','EscalationScopeDisplay') IS NULL ALTER TABLE dbo.DenialClaimEscalations ADD EscalationScopeDisplay nvarchar(255) NULL;
    IF COL_LENGTH('dbo.DenialClaimEscalations','AffectedTaskIds') IS NULL ALTER TABLE dbo.DenialClaimEscalations ADD AffectedTaskIds nvarchar(max) NULL;
    IF COL_LENGTH('dbo.DenialClaimEscalations','RecommendedNextAction') IS NULL ALTER TABLE dbo.DenialClaimEscalations ADD RecommendedNextAction nvarchar(150) NULL;
END;

UPDATE dbo.DenialTaskBoard
SET Status = CASE LOWER(LTRIM(RTRIM(ISNULL(Status,''))))
    WHEN '' THEN 'Assigned'
    WHEN 'open' THEN 'Assigned'
    WHEN 'in progress' THEN 'Assigned'
    WHEN 'in-progress' THEN 'Assigned'
    WHEN 'pending review' THEN 'Assigned'
    WHEN 'pending payer' THEN 'Pending Payer Response'
    WHEN 'escalated' THEN 'Escalated to AR Manager'
    WHEN 'internal escalation' THEN 'Escalated to AR Manager'
    WHEN 'external escalation' THEN 'Escalated to AR Manager'
    WHEN 'completed' THEN 'Closed'
    WHEN 'required review' THEN 'Rework'
    ELSE Status
END,
WorkFlowStatus = CASE LOWER(LTRIM(RTRIM(ISNULL(WorkFlowStatus,''))))
    WHEN 'pending review' THEN 'Assigned'
    WHEN 'assigned to ar reviewer' THEN 'Assigned'
    WHEN 'internal escalation' THEN 'Escalated to AR Manager'
    WHEN 'external escalation' THEN 'Escalated to AR Manager'
    WHEN 'closed claim' THEN 'Closed'
    ELSE WorkFlowStatus
END,
LastWorkflowUpdatedOn = COALESCE(LastWorkflowUpdatedOn, SYSDATETIME())
WHERE LOWER(LTRIM(RTRIM(ISNULL(Status,'')))) IN ('','open','in progress','in-progress','pending review','pending payer','escalated','internal escalation','external escalation','completed','required review')
   OR LOWER(LTRIM(RTRIM(ISNULL(WorkFlowStatus,'')))) IN ('pending review','assigned to ar reviewer','internal escalation','external escalation','closed claim');

IF OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL AND COL_LENGTH('dbo.DenialLineItem','WorkFlowStatus') IS NOT NULL
BEGIN
    UPDATE dbo.DenialLineItem
    SET WorkFlowStatus = CASE LOWER(LTRIM(RTRIM(ISNULL(WorkFlowStatus,''))))
        WHEN 'pending review' THEN 'Assigned'
        WHEN 'assigned to ar reviewer' THEN 'Assigned'
        WHEN 'internal escalation' THEN 'Escalated to AR Manager'
        WHEN 'external escalation' THEN 'Escalated to AR Manager'
        WHEN 'closed claim' THEN 'Closed'
        ELSE WorkFlowStatus
    END
    WHERE LOWER(LTRIM(RTRIM(ISNULL(WorkFlowStatus,'')))) IN ('pending review','assigned to ar reviewer','internal escalation','external escalation','closed claim');
END;

IF OBJECT_ID('dbo.DenialStatusMaster','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialStatusMaster','StatusName') IS NOT NULL
    BEGIN
        DECLARE @StatusSeed table(StatusName nvarchar(100), SortOrder int);
        INSERT INTO @StatusSeed(StatusName, SortOrder) VALUES
        ('New',10),('Unassigned',20),('Assigned',30),('Payer Follow-up Required',40),
        ('Pending Payer Response',50),('Pending Documentation',60),('Write-Off Pending Approval',70),
        ('Escalated to AR Manager',80),('Rework',90),('Closed',100);

        INSERT INTO dbo.DenialStatusMaster(StatusName, SortOrder)
        SELECT s.StatusName, s.SortOrder
        FROM @StatusSeed s
        WHERE NOT EXISTS (SELECT 1 FROM dbo.DenialStatusMaster m WHERE m.StatusName = s.StatusName);
    END;
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialTaskBoard') AND name = 'IX_DenialTaskBoard_Status_AssignedTo')
    CREATE INDEX IX_DenialTaskBoard_Status_AssignedTo ON dbo.DenialTaskBoard(Status, AssignedTo) INCLUDE (LabId, ClaimID, TaskID, InsuranceBalance);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialTaskBoard') AND name = 'IX_DenialTaskBoard_ExpectedResponseDate')
    CREATE INDEX IX_DenialTaskBoard_ExpectedResponseDate ON dbo.DenialTaskBoard(ExpectedResponseDate) INCLUDE (Status, LabId, ClaimID, TaskID);

SELECT Status, COUNT_BIG(*) AS TaskCount
FROM dbo.DenialTaskBoard
WHERE ISNULL(Status,'') NOT IN
('New','Unassigned','Assigned','Payer Follow-up Required','Pending Payer Response','Pending Documentation','Write-Off Pending Approval','Escalated to AR Manager','Rework','Closed')
GROUP BY Status
ORDER BY TaskCount DESC;
GO

/* ============================================================================
   Source: DenialWorkflow_Performance_And_Verification_Columns.sql
   ============================================================================ */
/* Run this once in each lab DB before using Denial Workflow. */
IF OBJECT_ID('dbo.DenialVerificationTask') IS NULL
BEGIN
    SELECT TOP 0 * INTO dbo.DenialVerificationTask FROM dbo.DenialTaskBoard;
    ALTER TABLE dbo.DenialVerificationTask ADD VerificationId bigint IDENTITY(1,1) NOT NULL;
END
IF COL_LENGTH('dbo.DenialVerificationTask','VerificationStatus') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD VerificationStatus nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','VerificationComments') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD VerificationComments nvarchar(max) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','OriginalRunId') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD OriginalRunId nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','MissingDetectedRunId') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD MissingDetectedRunId nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','MovedOn') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD MovedOn datetime2(0) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','VerifiedBy') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD VerifiedBy nvarchar(255) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','VerifiedOn') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD VerifiedOn datetime2(0) NULL;

/* 2026-05-14: keep older DenialVerificationTask tables compatible with the current workflow UI. */
IF COL_LENGTH('dbo.DenialVerificationTask','TaskID') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD TaskID nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','UniqueTrackId') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD UniqueTrackId nvarchar(150) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','ClaimID') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD ClaimID nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','PatientId') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD PatientId nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','CPTCode') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD CPTCode nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','Units') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD Units int NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','Modifier') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD Modifier nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','DenialCode') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD DenialCode nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','DenialDescription') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD DenialDescription nvarchar(max) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','DenialClassification') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD DenialClassification nvarchar(250) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','ActionCode') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD ActionCode nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','RecommendedAction') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD RecommendedAction nvarchar(max) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','ActionCategory') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD ActionCategory nvarchar(250) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','Task') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD Task nvarchar(max) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','Priority') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD Priority nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','InsuranceBalance') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD InsuranceBalance decimal(18,2) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','IsCurrentDenial') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD IsCurrentDenial bit NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','SLADays') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD SLADays int NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','Status') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD Status nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','DateOpened') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD DateOpened datetime2(0) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','DueDate') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD DueDate datetime2(0) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','DateCompleted') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD DateCompleted datetime2(0) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','DaysRemaining') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD DaysRemaining int NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','SLAStatus') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD SLAStatus nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','AssignedTo') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD AssignedTo nvarchar(255) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','LabId') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD LabId int NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','LabName') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD LabName nvarchar(255) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','RunId') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD RunId nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','CreatedOn') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD CreatedOn datetime2(0) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','SalesRepname') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD SalesRepname nvarchar(255) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','ClinicName') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD ClinicName nvarchar(255) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','ReferringProvider') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD ReferringProvider nvarchar(255) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','PayerName') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD PayerName nvarchar(255) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','PayerNameNormalized') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD PayerNameNormalized nvarchar(255) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','PayerCode') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD PayerCode int NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','PayerType') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD PayerType nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','FirstBilledDate') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD FirstBilledDate datetime2(0) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','ChargeEnteredDate') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD ChargeEnteredDate datetime2(0) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','BillingProvider') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD BillingProvider nvarchar(255) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','PanelName') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD PanelName nvarchar(255) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','DateOfService') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD DateOfService datetime2(0) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','ReviewerComments') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD ReviewerComments nvarchar(max) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','ReviewerUpdatedOn') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD ReviewerUpdatedOn datetime2(0) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','ReviewerUpdatedBy') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD ReviewerUpdatedBy nvarchar(255) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','ICDCodes') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD ICDCodes nvarchar(max) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','CoverageStatus') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD CoverageStatus nvarchar(250) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','ICDComplianceStatus') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD ICDComplianceStatus nvarchar(250) NULL;
IF COL_LENGTH('dbo.DenialVerificationTask','DenialValidity') IS NULL ALTER TABLE dbo.DenialVerificationTask ADD DenialValidity nvarchar(max) NULL;


IF OBJECT_ID('dbo.DenialTaskHistory') IS NULL
BEGIN
    CREATE TABLE dbo.DenialTaskHistory(
        HistoryId bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
        TaskID nvarchar(100) NULL,
        UniqueTrackId nvarchar(150) NULL,
        LabId int NULL,
        RunId nvarchar(100) NULL,
        ActionType nvarchar(100) NULL,
        OldStatus nvarchar(100) NULL,
        NewStatus nvarchar(100) NULL,
        OldAssignedTo nvarchar(255) NULL,
        NewAssignedTo nvarchar(255) NULL,
        Comments nvarchar(max) NULL,
        ActionBy nvarchar(255) NULL,
        ActionDate datetime2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
        SnapshotJson nvarchar(max) NULL
    );
END

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DenialTaskBoard_Workflow_Page' AND object_id=OBJECT_ID('dbo.DenialTaskBoard'))
    CREATE INDEX IX_DenialTaskBoard_Workflow_Page ON dbo.DenialTaskBoard(LabId, Status, AssignedTo, DueDate, TaskID) INCLUDE(ClaimID,CPTCode,DenialCode,PayerName,RunId,InsuranceBalance);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DenialTaskBoard_Workflow_Search' AND object_id=OBJECT_ID('dbo.DenialTaskBoard'))
    CREATE INDEX IX_DenialTaskBoard_Workflow_Search ON dbo.DenialTaskBoard(LabId, DenialCode, PayerName, RunId) INCLUDE(TaskID,ClaimID,AssignedTo,Status,InsuranceBalance);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DenialInsight_Workflow_Page' AND object_id=OBJECT_ID('dbo.DenialInsight'))
    CREATE INDEX IX_DenialInsight_Workflow_Page ON dbo.DenialInsight(LabId, DenialCodes, HighImpactInsurance, RunId) INCLUDE(InsuranceBalance,ImpactPercentage,NoOfDenialCount,NoOfClaimsCount);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DenialVerificationTask_Workflow_Page' AND object_id=OBJECT_ID('dbo.DenialVerificationTask'))
    CREATE INDEX IX_DenialVerificationTask_Workflow_Page ON dbo.DenialVerificationTask(LabId, VerificationStatus, AssignedTo, MovedOn, TaskID) INCLUDE(ClaimID,CPTCode,DenialCode,PayerName,RunId,InsuranceBalance);
GO

/* ============================================================================
   Source: DenialCodeActionChangeVerification_Setup.sql
   ============================================================================ */
/*
Run this once in each lab database that uses Denial Workflow.
It is also applied defensively by the Reports API before import/review operations.
*/

IF OBJECT_ID('dbo.DenialCodeActionChangeBatch','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialCodeActionChangeBatch
    (
        BatchId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialCodeActionChangeBatch PRIMARY KEY,
        SourceFileName nvarchar(500) NOT NULL,
        UploadedBy nvarchar(100) NOT NULL,
        UploadedOn datetime2(0) NOT NULL CONSTRAINT DF_DCACB_UploadedOn DEFAULT SYSUTCDATETIME(),
        TotalAffectedClaims int NOT NULL CONSTRAINT DF_DCACB_TotalAffectedClaims DEFAULT 0,
        TotalAffectedTasks int NOT NULL CONSTRAINT DF_DCACB_TotalAffectedTasks DEFAULT 0,
        PendingCount int NOT NULL CONSTRAINT DF_DCACB_PendingCount DEFAULT 0,
        ConfirmedCount int NOT NULL CONSTRAINT DF_DCACB_ConfirmedCount DEFAULT 0,
        IgnoredCount int NOT NULL CONSTRAINT DF_DCACB_IgnoredCount DEFAULT 0,
        Status nvarchar(50) NOT NULL CONSTRAINT DF_DCACB_Status DEFAULT 'Pending'
    );
END;

IF OBJECT_ID('dbo.DenialCodeActionChangeVerification','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialCodeActionChangeVerification
    (
        VerificationId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialCodeActionChangeVerification PRIMARY KEY,
        BatchId bigint NOT NULL,
        ClaimID nvarchar(100) NOT NULL,
        TaskID nvarchar(100) NULL,
        PatientId nvarchar(100) NULL,
        CPTCode nvarchar(100) NULL,
        Units int NULL,
        Modifier nvarchar(100) NULL,
        PayerName nvarchar(255) NULL,
        AssignedTo nvarchar(100) NULL,
        ClaimStatus nvarchar(100) NULL,
        DenialCode nvarchar(100) NOT NULL,
        DenialDescription nvarchar(1000) NULL,
        DenialClassification nvarchar(255) NULL,
        ICDComplianceStatus nvarchar(255) NULL,
        CoverageStatus nvarchar(255) NULL,
        ActionCode nvarchar(100) NULL,
        ActionCategory nvarchar(500) NULL,
        RecommendedAction nvarchar(1000) NULL,
        Task nvarchar(500) NULL,
        Priority nvarchar(100) NULL,
        InsuranceBalance decimal(18,2) NULL,
        SLADays int NULL,
        Status nvarchar(100) NULL,
        DateOpened date NULL,
        DueDate date NULL,
        SLAStatus nvarchar(100) NULL,
        FirstBilledDate date NULL,
        ChargeEnteredDate date NULL,
        DenialValidity nvarchar(255) NULL,
        OldActionCode nvarchar(100) NULL,
        NewActionCode nvarchar(100) NULL,
        OldActionCategory nvarchar(500) NULL,
        NewActionCategory nvarchar(500) NULL,
        OldTask nvarchar(500) NULL,
        NewTask nvarchar(500) NULL,
        OldShortCategory nvarchar(255) NULL,
        NewShortCategory nvarchar(255) NULL,
        VerificationStatus nvarchar(50) NOT NULL CONSTRAINT DF_DCACV_VerificationStatus DEFAULT 'Pending',
        VerifiedBy nvarchar(100) NULL,
        VerifiedOn datetime2(0) NULL,
        CreatedOn datetime2(0) NOT NULL CONSTRAINT DF_DCACV_CreatedOn DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_DCACV_Batch FOREIGN KEY (BatchId) REFERENCES dbo.DenialCodeActionChangeBatch(BatchId)
    );
END;

IF COL_LENGTH('dbo.DenialTaskBoard','ShortCategory') IS NULL
    ALTER TABLE dbo.DenialTaskBoard ADD ShortCategory nvarchar(255) NULL;

IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','CPTCode') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD CPTCode nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','Units') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD Units int NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','Modifier') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD Modifier nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','DenialDescription') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD DenialDescription nvarchar(1000) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','DenialClassification') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD DenialClassification nvarchar(255) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','ActionCode') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD ActionCode nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','ActionCategory') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD ActionCategory nvarchar(500) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','RecommendedAction') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD RecommendedAction nvarchar(1000) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','Task') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD Task nvarchar(500) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','Priority') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD Priority nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','InsuranceBalance') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD InsuranceBalance decimal(18,2) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','SLADays') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD SLADays int NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','Status') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD Status nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','DateOpened') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD DateOpened date NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','DueDate') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD DueDate date NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','SLAStatus') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD SLAStatus nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','FirstBilledDate') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD FirstBilledDate date NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','ChargeEnteredDate') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD ChargeEnteredDate date NULL;
IF COL_LENGTH('dbo.DenialCodeActionChangeVerification','DenialValidity') IS NULL ALTER TABLE dbo.DenialCodeActionChangeVerification ADD DenialValidity nvarchar(255) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DCACV_Batch_Status' AND object_id=OBJECT_ID('dbo.DenialCodeActionChangeVerification'))
    CREATE INDEX IX_DCACV_Batch_Status ON dbo.DenialCodeActionChangeVerification(BatchId, VerificationStatus);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DCACV_Denial_Key' AND object_id=OBJECT_ID('dbo.DenialCodeActionChangeVerification'))
    CREATE INDEX IX_DCACV_Denial_Key ON dbo.DenialCodeActionChangeVerification(DenialCode, ICDComplianceStatus, CoverageStatus);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DCACV_Claim_Task' AND object_id=OBJECT_ID('dbo.DenialCodeActionChangeVerification'))
    CREATE INDEX IX_DCACV_Claim_Task ON dbo.DenialCodeActionChangeVerification(ClaimID, TaskID);
GO

IF OBJECT_ID('dbo.DenialTaskBoard','U') IS NOT NULL
   AND OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL
   AND OBJECT_ID('dbo.DenialCodeActionChangeVerification','U') IS NOT NULL
BEGIN
    UPDATE v
    SET CPTCode = COALESCE(NULLIF(v.CPTCode, ''), NULLIF(t.CPTCode, ''), NULLIF(line.CPTCode, '')),
        Units = COALESCE(v.Units, TRY_CONVERT(int, t.Units), TRY_CONVERT(int, line.Units)),
        Modifier = COALESCE(NULLIF(v.Modifier, ''), NULLIF(t.Modifier, ''), NULLIF(line.Modifier, '')),
        PayerName = COALESCE(NULLIF(v.PayerName, ''), NULLIF(t.PayerName, ''), NULLIF(line.PayerName, '')),
        DenialDescription = COALESCE(NULLIF(v.DenialDescription, ''), NULLIF(t.DenialDescription, ''), NULLIF(line.DenialDescription, '')),
        DenialClassification = COALESCE(NULLIF(v.DenialClassification, ''), NULLIF(t.DenialClassification, ''), NULLIF(line.DenialClassification, '')),
        ActionCode = COALESCE(NULLIF(v.ActionCode, ''), NULLIF(t.ActionCode, ''), NULLIF(line.ActionCode, '')),
        ActionCategory = COALESCE(NULLIF(v.ActionCategory, ''), NULLIF(t.ActionCategory, ''), NULLIF(line.ActionCategory, '')),
        RecommendedAction = COALESCE(NULLIF(v.RecommendedAction, ''), NULLIF(t.RecommendedAction, ''), NULLIF(line.RecommendedAction, '')),
        Task = COALESCE(NULLIF(v.Task, ''), NULLIF(t.Task, ''), NULLIF(line.TaskGuidance, '')),
        Priority = COALESCE(NULLIF(v.Priority, ''), NULLIF(t.Priority, ''), NULLIF(line.Priority, '')),
        InsuranceBalance = COALESCE(v.InsuranceBalance, TRY_CONVERT(decimal(18,2), t.InsuranceBalance), TRY_CONVERT(decimal(18,2), line.InsuranceBalance)),
        SLADays = COALESCE(v.SLADays, TRY_CONVERT(int, t.SLADays), TRY_CONVERT(int, line.SLADays)),
        Status = COALESCE(NULLIF(v.Status, ''), NULLIF(t.Status, ''), NULLIF(line.TaskStatus, '')),
        DateOpened = COALESCE(v.DateOpened, t.DateOpened, line.DateOfService),
        DueDate = COALESCE(v.DueDate, t.DueDate),
        SLAStatus = COALESCE(NULLIF(v.SLAStatus, ''), NULLIF(t.SLAStatus, '')),
        FirstBilledDate = COALESCE(v.FirstBilledDate, t.FirstBilledDate, line.FirstBilledDate),
        ChargeEnteredDate = COALESCE(v.ChargeEnteredDate, t.ChargeEnteredDate, line.ChargeEnteredDate),
        DenialValidity = COALESCE(NULLIF(v.DenialValidity, ''), NULLIF(t.DenialValidity, ''), NULLIF(line.DenialValidity, ''))
    FROM dbo.DenialCodeActionChangeVerification v
    LEFT JOIN dbo.DenialTaskBoard t
        ON t.TaskID = v.TaskID
       AND CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(t.ClaimID, ''))), 'CLM-', '')) =
           CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(v.ClaimID, ''))), 'CLM-', ''))
    OUTER APPLY
    (
        SELECT TOP (1)
            l.CPTCode, l.Units, l.Modifier, l.PayerName, l.DenialDescription, l.DenialClassification,
            l.ActionCode, l.ActionCategory, l.RecommendedAction, l.TaskGuidance, l.Priority,
            l.InsuranceBalance, l.SLADays, l.TaskStatus, l.DateOfService, l.FirstBilledDate,
            l.ChargeEnteredDate, l.DenialValidity
        FROM dbo.DenialLineItem l
        WHERE CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber, ''))), 'CLM-', '')) =
              CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(v.ClaimID, ''))), 'CLM-', ''))
          AND (
                UPPER(LTRIM(RTRIM(ISNULL(l.DenialCodeNormalized, '')))) = UPPER(v.DenialCode)
             OR UPPER(LTRIM(RTRIM(ISNULL(l.DenialCodeOriginal, '')))) = UPPER(v.DenialCode)
             OR NULLIF(LTRIM(RTRIM(ISNULL(l.DenialCodeNormalized, ''))), '') IS NULL
          )
        ORDER BY
            CASE WHEN UPPER(LTRIM(RTRIM(ISNULL(l.DenialCodeNormalized, '')))) = UPPER(v.DenialCode)
                   OR UPPER(LTRIM(RTRIM(ISNULL(l.DenialCodeOriginal, '')))) = UPPER(v.DenialCode) THEN 0 ELSE 1 END,
            l.DateOfService DESC
    ) line
    WHERE v.CPTCode IS NULL
       OR v.Units IS NULL
       OR v.Modifier IS NULL
       OR v.DenialDescription IS NULL
       OR v.DenialClassification IS NULL
       OR v.ActionCode IS NULL
       OR v.ActionCategory IS NULL
       OR v.RecommendedAction IS NULL
       OR v.Task IS NULL
       OR v.Priority IS NULL
       OR v.InsuranceBalance IS NULL
       OR v.SLADays IS NULL
       OR v.Status IS NULL
       OR v.DateOpened IS NULL
       OR v.FirstBilledDate IS NULL
       OR v.ChargeEnteredDate IS NULL
       OR v.DenialValidity IS NULL;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_DenialActionChange_RecountBatch
    @BatchId bigint
AS
BEGIN
    SET NOCOUNT ON;
    IF @BatchId IS NULL RETURN;

    UPDATE b
    SET PendingCount = counts.PendingCount,
        ConfirmedCount = counts.ConfirmedCount,
        IgnoredCount = counts.IgnoredCount,
        Status = CASE WHEN counts.PendingCount = 0 THEN 'Completed' ELSE 'Pending' END
    FROM dbo.DenialCodeActionChangeBatch b
    CROSS APPLY
    (
        SELECT
            SUM(CASE WHEN v.VerificationStatus = 'Pending' THEN 1 ELSE 0 END) AS PendingCount,
            SUM(CASE WHEN v.VerificationStatus = 'Confirmed' THEN 1 ELSE 0 END) AS ConfirmedCount,
            SUM(CASE WHEN v.VerificationStatus IN ('Ignored', 'Skipped') THEN 1 ELSE 0 END) AS IgnoredCount
        FROM dbo.DenialCodeActionChangeVerification v
        WHERE v.BatchId = b.BatchId
    ) counts
    WHERE b.BatchId = @BatchId;
END;
GO
GO

/* ============================================================================
   Source: DenialMapper_Lab_Setup.sql
   ============================================================================ */
-- Optional deployment script for each configured lab database.
-- The push API also creates these tables automatically before the first push.
SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF OBJECT_ID('dbo.DenialMapperLabMaster','U') IS NULL
CREATE TABLE dbo.DenialMapperLabMaster(
 Id bigint IDENTITY PRIMARY KEY, LabId int NOT NULL, SuperMasterId bigint NOT NULL, DenialCode nvarchar(50) NOT NULL,
 DenialDescription nvarchar(500) NULL, DenialClassification nvarchar(100) NULL, CoverageStatus nvarchar(100) NULL,
 ICDComplianceStatus nvarchar(100) NULL, DenialValidity nvarchar(100) NULL, ActionCode nvarchar(100) NOT NULL,
 ActionCategory nvarchar(100) NOT NULL, Task nvarchar(300) NOT NULL, RecommendedAction nvarchar(1000) NOT NULL,
 SLA nvarchar(50) NOT NULL, Priority nvarchar(50) NOT NULL, IsActive bit NOT NULL DEFAULT 1,
 PushedBy nvarchar(200) NOT NULL, PushedOn datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),
 CreatedBy nvarchar(200) NOT NULL, CreatedOn datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),
 ModifiedBy nvarchar(200) NOT NULL, ModifiedOn datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),
 CONSTRAINT UQ_DenialMapperLabMaster_Super UNIQUE(SuperMasterId)
);

IF OBJECT_ID('dbo.DenialMapperLabOverride','U') IS NULL
CREATE TABLE dbo.DenialMapperLabOverride(
 Id bigint IDENTITY PRIMARY KEY, LabId int NOT NULL, SuperMasterId bigint NOT NULL, ActionCode nvarchar(100) NOT NULL,
 ActionCategory nvarchar(100) NOT NULL, Task nvarchar(300) NOT NULL, RecommendedAction nvarchar(1000) NOT NULL,
 IsActive bit NOT NULL DEFAULT 1, CreatedBy nvarchar(200) NOT NULL, CreatedOn datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),
 ModifiedBy nvarchar(200) NOT NULL, ModifiedOn datetime2 NOT NULL DEFAULT SYSUTCDATETIME()
);

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='UX_DenialMapperLabOverride_Active')
 CREATE UNIQUE INDEX UX_DenialMapperLabOverride_Active ON dbo.DenialMapperLabOverride(SuperMasterId) WHERE IsActive=1;

COMMIT;
GO

/* ============================================================================
   Source: DenialWorkflow_ClaimUID_ClaimView_Optimization.sql
   ============================================================================ */
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
GO

/* ============================================================================
   Source: DenialWorkflow_AllTables_Performance_Indexes.sql
   ============================================================================ */
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
GO

/* ============================================================================
   Source: DenialWorkflow_ClaimStatus_Precedence_RoleFilters.sql
   ============================================================================ */
/*
Denial workflow claim-status precedence and role-filter support.

Validation scenarios:
A. Closed, Closed, Closed -> ClaimStatus = Closed, Queue = Closed.
B. All old unassigned/no assigned user -> ClaimStatus = Unassigned, Queue = Unassigned.
C. Assigned, Assigned -> ClaimStatus = Assigned, Queue = Assigned.
D. Assigned + Pending Payer Response + Closed -> ClaimStatus = Pending Payer Response, Queue = Pending Payer Response.
E. Pending Documentation + Pending Payer Response + Assigned + Closed -> ClaimStatus = Pending Documentation, Queue = Pending Documentation.
F. Any Write Off Approval Pending with documentation/payer/closed -> ClaimStatus = Write Off Approval Pending, Queue = Write-Off Approval.
G. Any internal escalation/escalated to AR manager -> ClaimStatus = Escalated to AR Manager, Queue = Internal Escalation.
H. Verify role queue/filter visibility in the React config for AR Reviewer, AR Manager, Account Manager, and Client Manager.
*/

IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL
AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_TaskBoard_Lab_Claim_Status_Assigned' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_DWF_TaskBoard_Lab_Claim_Status_Assigned
    ON dbo.DenialTaskBoard(LabId, ClaimIDNormalized, Status, AssignedTo)
    INCLUDE(TaskID, ClaimID, CreatedOn, ReviewerUpdatedOn, WorkFlowStatus);
END;

IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL
AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_TaskBoard_Lab_Status_WorkFlowStatus' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_DWF_TaskBoard_Lab_Status_WorkFlowStatus
    ON dbo.DenialTaskBoard(LabId, Status, WorkFlowStatus)
    INCLUDE(ClaimIDNormalized, ClaimID, AssignedTo, CreatedOn);
END;

IF OBJECT_ID('dbo.DenialClaimEscalations', 'U') IS NOT NULL
AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_Escalations_Lab_Claim_Status_Role' AND object_id = OBJECT_ID('dbo.DenialClaimEscalations'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_DWF_Escalations_Lab_Claim_Status_Role
    ON dbo.DenialClaimEscalations(LabId, ClaimId, Status, EscalatedToRole)
    INCLUDE(IsDeleted, EscalatedTo, NextFollowUpDate, EscalationReason, CreatedOn);
END;

IF OBJECT_ID('dbo.DenialClaimNotes', 'U') IS NOT NULL
AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_Notes_Lab_Claim_Followup' AND object_id = OBJECT_ID('dbo.DenialClaimNotes'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_DWF_Notes_Lab_Claim_Followup
    ON dbo.DenialClaimNotes(LabId, ClaimId, NextFollowUpDate)
    INCLUDE(IsDeleted, NoteLevel, Status, CreatedOn);
END;
GO

/* ============================================================================
   Source: DenialWorkflow_Modern_UI_Index_Verification.sql
   ============================================================================ */
/*
  Denial Workflow modern UI support indexes.
  These are additive and guarded so the script can be run safely more than once.
*/

IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_Lab_WorkFlow_Assigned_Claim' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
        CREATE INDEX IX_DenialTaskBoard_Lab_WorkFlow_Assigned_Claim
        ON dbo.DenialTaskBoard(LabId, WorkFlowStatus, AssignedTo, ClaimID)
        INCLUDE(Status, PayerName, PatientName, DateOfService, CreatedOn, InsuranceBalance);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_Lab_Claim' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
        CREATE INDEX IX_DenialTaskBoard_Lab_Claim
        ON dbo.DenialTaskBoard(LabId, ClaimID)
        INCLUDE(TaskID, CPTCode, DenialCode, DenialClassification, ActionCategory, Status, InsuranceBalance);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_Lab_CreatedOn' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
        CREATE INDEX IX_DenialTaskBoard_Lab_CreatedOn
        ON dbo.DenialTaskBoard(LabId, CreatedOn)
        INCLUDE(ClaimID, WorkFlowStatus, AssignedTo, InsuranceBalance);
END

IF OBJECT_ID('dbo.DenialLineItem', 'U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialLineItem_Lab_Visit_DOS' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
       AND COL_LENGTH('dbo.DenialLineItem', 'LabId') IS NOT NULL
       AND COL_LENGTH('dbo.DenialLineItem', 'VisitNumber') IS NOT NULL
       AND COL_LENGTH('dbo.DenialLineItem', 'DateOfService') IS NOT NULL
       AND COL_LENGTH('dbo.DenialLineItem', 'PayerName') IS NOT NULL
       AND COL_LENGTH('dbo.DenialLineItem', 'DenialClassification') IS NOT NULL
       AND COL_LENGTH('dbo.DenialLineItem', 'PanelName') IS NOT NULL
       AND COL_LENGTH('dbo.DenialLineItem', 'BilledAmount') IS NOT NULL
       AND COL_LENGTH('dbo.DenialLineItem', 'InsuranceBalance') IS NOT NULL
        CREATE INDEX IX_DenialLineItem_Lab_Visit_DOS
        ON dbo.DenialLineItem(LabId, VisitNumber, DateOfService)
        INCLUDE(PayerName, DenialClassification, PanelName, BilledAmount, InsuranceBalance);
END

IF OBJECT_ID('dbo.DenialClaimEscalations', 'U') IS NOT NULL
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialClaimEscalations_Lab_Status_Claim_CreatedOn' AND object_id = OBJECT_ID('dbo.DenialClaimEscalations'))
        CREATE INDEX IX_DenialClaimEscalations_Lab_Status_Claim_CreatedOn
        ON dbo.DenialClaimEscalations(LabId, Status, ClaimId, CreatedOn);

IF OBJECT_ID('dbo.DenialTaskHistory', 'U') IS NOT NULL
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskHistory_Lab_Track_ActionDate' AND object_id = OBJECT_ID('dbo.DenialTaskHistory'))
        CREATE INDEX IX_DenialTaskHistory_Lab_Track_ActionDate
        ON dbo.DenialTaskHistory(LabId, UniqueTrackId, ActionDate DESC);

IF OBJECT_ID('dbo.DenialClaimNotes', 'U') IS NOT NULL
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialClaimNotes_Lab_Claim_CreatedOn' AND object_id = OBJECT_ID('dbo.DenialClaimNotes'))
        CREATE INDEX IX_DenialClaimNotes_Lab_Claim_CreatedOn
        ON dbo.DenialClaimNotes(LabId, ClaimId, CreatedOn DESC);

IF OBJECT_ID('dbo.DenialClaimDocuments', 'U') IS NOT NULL
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialClaimDocuments_Lab_Claim_UploadedOn' AND object_id = OBJECT_ID('dbo.DenialClaimDocuments'))
        CREATE INDEX IX_DenialClaimDocuments_Lab_Claim_UploadedOn
        ON dbo.DenialClaimDocuments(LabId, ClaimId, UploadedOn DESC);
GO

/* ============================================================================
   Current application compatibility: claim support and mapper lab columns
   ============================================================================ */
IF OBJECT_ID('dbo.DenialClaimNotes','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialClaimNotes','Status') IS NULL
        ALTER TABLE dbo.DenialClaimNotes ADD Status nvarchar(50) NULL;

    IF COL_LENGTH('dbo.DenialClaimNotes','NextFollowUpDate') IS NULL
        ALTER TABLE dbo.DenialClaimNotes ADD NextFollowUpDate date NULL;
END;

IF OBJECT_ID('dbo.DenialClaimEscalations','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialClaimEscalations','EscalatedTo') IS NULL
        ALTER TABLE dbo.DenialClaimEscalations ADD EscalatedTo nvarchar(256) NULL;

    IF COL_LENGTH('dbo.DenialClaimEscalations','EscalatedToRole') IS NULL
        ALTER TABLE dbo.DenialClaimEscalations ADD EscalatedToRole nvarchar(100) NULL;

    IF COL_LENGTH('dbo.DenialClaimEscalations','NextFollowUpDate') IS NULL
        ALTER TABLE dbo.DenialClaimEscalations ADD NextFollowUpDate date NULL;
END;

IF OBJECT_ID('dbo.DenialMapperLabMaster','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialMapperLabMaster','LabId') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD LabId int NULL;
    IF COL_LENGTH('dbo.DenialMapperLabMaster','DenialCode') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD DenialCode nvarchar(50) NULL;
    IF COL_LENGTH('dbo.DenialMapperLabMaster','DenialDescription') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD DenialDescription nvarchar(500) NULL;
    IF COL_LENGTH('dbo.DenialMapperLabMaster','DenialClassification') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD DenialClassification nvarchar(100) NULL;
    IF COL_LENGTH('dbo.DenialMapperLabMaster','CoverageStatus') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD CoverageStatus nvarchar(100) NULL;
    IF COL_LENGTH('dbo.DenialMapperLabMaster','ICDComplianceStatus') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD ICDComplianceStatus nvarchar(100) NULL;
    IF COL_LENGTH('dbo.DenialMapperLabMaster','DenialValidity') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD DenialValidity nvarchar(100) NULL;
    IF COL_LENGTH('dbo.DenialMapperLabMaster','ActionCode') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD ActionCode nvarchar(100) NULL;
    IF COL_LENGTH('dbo.DenialMapperLabMaster','ActionCategory') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD ActionCategory nvarchar(100) NULL;
    IF COL_LENGTH('dbo.DenialMapperLabMaster','Task') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD Task nvarchar(300) NULL;
    IF COL_LENGTH('dbo.DenialMapperLabMaster','RecommendedAction') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD RecommendedAction nvarchar(1000) NULL;
    IF COL_LENGTH('dbo.DenialMapperLabMaster','SLA') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD SLA nvarchar(50) NULL;
    IF COL_LENGTH('dbo.DenialMapperLabMaster','Priority') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD Priority nvarchar(50) NULL;
END;

IF OBJECT_ID('dbo.DenialMapperLabOverride','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialMapperLabOverride','LabId') IS NULL
        ALTER TABLE dbo.DenialMapperLabOverride ADD LabId int NULL;
END;
GO

PRINT 'Denial lab-database setup completed for ' + DB_NAME();
GO

