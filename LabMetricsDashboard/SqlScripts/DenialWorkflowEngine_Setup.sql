/*
Denial Workflow Engine setup script
Run this script in every LAB database that contains DenialTaskBoard, DenialInsight, and DenialLineItem.
*/
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.DenialStatusMaster', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialStatusMaster
    (
        StatusId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialStatusMaster PRIMARY KEY,
        StatusName nvarchar(100) NOT NULL CONSTRAINT UQ_DenialStatusMaster_StatusName UNIQUE,
        IsClosedStatus bit NOT NULL CONSTRAINT DF_DenialStatusMaster_IsClosedStatus DEFAULT(0),
        IsVerificationStatus bit NOT NULL CONSTRAINT DF_DenialStatusMaster_IsVerificationStatus DEFAULT(0),
        SortOrder int NOT NULL CONSTRAINT DF_DenialStatusMaster_SortOrder DEFAULT(100),
        IsActive bit NOT NULL CONSTRAINT DF_DenialStatusMaster_IsActive DEFAULT(1),
        CreatedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialStatusMaster_CreatedOn DEFAULT(SYSUTCDATETIME())
    );
END;
GO

MERGE dbo.DenialStatusMaster AS t
USING (VALUES
    (N'Closed', 1, 0, 10),
    (N'Completed', 1, 0, 20),
    (N'Duplicate', 0, 1, 30),
    (N'Verification Pending', 0, 1, 40),
    (N'Pending Review', 0, 0, 50),
    (N'In-Progress', 0, 0, 60),
    (N'New', 0, 0, 70)
) AS s(StatusName, IsClosedStatus, IsVerificationStatus, SortOrder)
ON t.StatusName = s.StatusName
WHEN MATCHED THEN UPDATE SET IsClosedStatus = s.IsClosedStatus, IsVerificationStatus = s.IsVerificationStatus, SortOrder = s.SortOrder, IsActive = 1
WHEN NOT MATCHED THEN INSERT (StatusName, IsClosedStatus, IsVerificationStatus, SortOrder, IsActive) VALUES (s.StatusName, s.IsClosedStatus, s.IsVerificationStatus, s.SortOrder, 1);
GO

IF OBJECT_ID(N'dbo.DenialActionCategoryMaster', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialActionCategoryMaster
    (
        ActionCategoryId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialActionCategoryMaster PRIMARY KEY,
        ActionCategory nvarchar(255) NOT NULL CONSTRAINT UQ_DenialActionCategoryMaster_ActionCategory UNIQUE,
        ActionScope nvarchar(50) NOT NULL CONSTRAINT DF_DenialActionCategoryMaster_ActionScope DEFAULT(N'CPTLevel'),
        IsActive bit NOT NULL CONSTRAINT DF_DenialActionCategoryMaster_IsActive DEFAULT(1),
        CreatedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialActionCategoryMaster_CreatedOn DEFAULT(SYSUTCDATETIME())
    );
END;
GO

MERGE dbo.DenialActionCategoryMaster AS t
USING (VALUES (N'Rebill', N'ClaimLevel')) AS s(ActionCategory, ActionScope)
ON t.ActionCategory = s.ActionCategory
WHEN MATCHED THEN UPDATE SET ActionScope = s.ActionScope, IsActive = 1
WHEN NOT MATCHED THEN INSERT (ActionCategory, ActionScope, IsActive) VALUES (s.ActionCategory, s.ActionScope, 1);
GO

IF OBJECT_ID(N'dbo.DenialTaskHistory', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialTaskHistory
    (
        HistoryId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialTaskHistory PRIMARY KEY,
        TaskID nvarchar(100) NULL,
        UniqueTrackId nvarchar(150) NULL,
        ActionType nvarchar(100) NOT NULL,
        OldStatus nvarchar(100) NULL,
        NewStatus nvarchar(100) NULL,
        OldAssignedTo nvarchar(255) NULL,
        NewAssignedTo nvarchar(255) NULL,
        Comments nvarchar(max) NULL,
        ActionBy nvarchar(255) NULL,
        ActionDate datetime2(0) NOT NULL CONSTRAINT DF_DenialTaskHistory_ActionDate DEFAULT(SYSUTCDATETIME()),
        RunId nvarchar(100) NULL,
        SnapshotJson nvarchar(max) NULL,
        LabId int NULL,
        LabName nvarchar(255) NULL
    );
END;
GO

IF OBJECT_ID(N'dbo.DenialVerificationTask', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialVerificationTask
    (
        VerificationId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialVerificationTask PRIMARY KEY,
        TaskID nvarchar(100) NULL,
        UniqueTrackId nvarchar(150) NULL,
        ClaimID nvarchar(100) NULL,
        PatientId nvarchar(100) NULL,
        CPTCode nvarchar(50) NULL,
        DenialCode nvarchar(100) NULL,
        DenialDescription nvarchar(500) NULL,
        ActionCategory nvarchar(500) NULL,
        RecommendedAction nvarchar(500) NULL,
        Task nvarchar(500) NULL,
        Priority nvarchar(100) NULL,
        InsuranceBalance decimal(18,2) NOT NULL CONSTRAINT DF_DenialVerificationTask_InsuranceBalance DEFAULT(0),
        Status nvarchar(100) NULL,
        DateOpened date NULL,
        DueDate date NULL,
        DateCompleted date NULL,
        DaysRemaining int NULL,
        SLAStatus nvarchar(100) NULL,
        AssignedTo nvarchar(255) NULL,
        LabId int NULL,
        LabName nvarchar(255) NULL,
        RunId nvarchar(100) NULL,
        CreatedOn datetime2(0) NULL,
        PayerName nvarchar(255) NULL,
        PayerNameNormalized nvarchar(255) NULL,
        ReviewerComments nvarchar(max) NULL,
        ReviewerUpdatedOn datetime2(0) NULL,
        ReviewerUpdatedBy nvarchar(255) NULL,
        VerificationStatus nvarchar(100) NOT NULL CONSTRAINT DF_DenialVerificationTask_VerificationStatus DEFAULT(N'Verification Pending'),
        VerificationComments nvarchar(max) NULL,
        OriginalRunId nvarchar(100) NULL,
        MissingDetectedRunId nvarchar(100) NULL,
        MovedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialVerificationTask_MovedOn DEFAULT(SYSUTCDATETIME()),
        VerifiedBy nvarchar(255) NULL,
        VerifiedOn datetime2(0) NULL
    );
END;
GO

IF OBJECT_ID(N'dbo.DenialTaskBoard', N'U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialTaskBoard', 'ReviewerComments') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD ReviewerComments nvarchar(max) NULL;
    IF COL_LENGTH('dbo.DenialTaskBoard', 'ReviewerUpdatedOn') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD ReviewerUpdatedOn datetime2(0) NULL;
    IF COL_LENGTH('dbo.DenialTaskBoard', 'ReviewerUpdatedBy') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD ReviewerUpdatedBy nvarchar(255) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DenialTaskBoard_Workflow_Active' AND object_id = OBJECT_ID(N'dbo.DenialTaskBoard'))
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_Workflow_Active ON dbo.DenialTaskBoard (LabId, Status, AssignedTo, UniqueTrackId) INCLUDE (TaskID, RunId, ClaimID, CPTCode, DenialCode, DueDate);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DenialTaskBoard_Workflow_ClaimAction' AND object_id = OBJECT_ID(N'dbo.DenialTaskBoard'))
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_Workflow_ClaimAction ON dbo.DenialTaskBoard (LabId, ClaimID, ActionCategory) INCLUDE (TaskID, Status, AssignedTo);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DenialVerificationTask_Workflow' AND object_id = OBJECT_ID(N'dbo.DenialVerificationTask'))
    CREATE NONCLUSTERED INDEX IX_DenialVerificationTask_Workflow ON dbo.DenialVerificationTask (LabId, VerificationStatus, AssignedTo, UniqueTrackId) INCLUDE (TaskID, RunId, MovedOn);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DenialTaskHistory_Workflow' AND object_id = OBJECT_ID(N'dbo.DenialTaskHistory'))
    CREATE NONCLUSTERED INDEX IX_DenialTaskHistory_Workflow ON dbo.DenialTaskHistory (LabId, TaskID, UniqueTrackId, ActionDate) INCLUDE (ActionType, RunId);
GO
