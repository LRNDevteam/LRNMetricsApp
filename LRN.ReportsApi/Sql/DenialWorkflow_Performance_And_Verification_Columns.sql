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
