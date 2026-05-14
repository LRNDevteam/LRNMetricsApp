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
