SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF OBJECT_ID('dbo.DenialMapperPushAudit','U') IS NULL
CREATE TABLE dbo.DenialMapperPushAudit
(
    PushAuditId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialMapperPushAudit PRIMARY KEY,
    SourceLabId int NOT NULL,
    TargetLabId int NOT NULL,
    PushedByUserId nvarchar(100) NOT NULL,
    PushStatus nvarchar(50) NOT NULL,
    TotalCompared int NOT NULL CONSTRAINT DF_DMPA_TotalCompared DEFAULT 0,
    TotalDifferences int NOT NULL CONSTRAINT DF_DMPA_TotalDifferences DEFAULT 0,
    TotalAssignedOpenTasksAffected int NOT NULL CONSTRAINT DF_DMPA_OpenTasks DEFAULT 0,
    CreatedOn datetime2 NOT NULL CONSTRAINT DF_DMPA_CreatedOn DEFAULT SYSUTCDATETIME(),
    ConfirmedOn datetime2 NULL, ConfirmedByUserId nvarchar(100) NULL,
    CancelledOn datetime2 NULL, CancelledByUserId nvarchar(100) NULL,
    AcknowledgedOn datetime2 NULL, AcknowledgedByUserId nvarchar(100) NULL,
    FailureMessage nvarchar(2000) NULL
);

IF OBJECT_ID('dbo.DenialMapperPushAuditDetail','U') IS NULL
CREATE TABLE dbo.DenialMapperPushAuditDetail
(
    PushAuditDetailId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialMapperPushAuditDetail PRIMARY KEY,
    PushAuditId bigint NOT NULL, TargetLabId int NOT NULL,
    DenialCode nvarchar(100) NOT NULL, ICDComplianceStatus nvarchar(255) NULL, CoverageStatus nvarchar(255) NULL,
    ExistingActionCode nvarchar(255) NULL, NewActionCode nvarchar(255) NULL,
    ExistingActionCategory nvarchar(500) NULL, NewActionCategory nvarchar(500) NULL,
    ExistingTask nvarchar(500) NULL, NewTask nvarchar(500) NULL,
    ExistingShortCategory nvarchar(1000) NULL, NewShortCategory nvarchar(1000) NULL,
    ExistingDenialClassification nvarchar(255) NULL, NewDenialClassification nvarchar(255) NULL,
    DifferenceType nvarchar(255) NOT NULL,
    IsAssignedToOpenTask bit NOT NULL CONSTRAINT DF_DMPAD_Open DEFAULT 0,
    OpenAssignedTaskCount int NOT NULL CONSTRAINT DF_DMPAD_OpenCount DEFAULT 0,
    CreatedOn datetime2 NOT NULL CONSTRAINT DF_DMPAD_CreatedOn DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_DenialMapperPushAuditDetail_Audit FOREIGN KEY(PushAuditId) REFERENCES dbo.DenialMapperPushAudit(PushAuditId)
);

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='IX_DenialMapperPushAudit_Status_TargetLab' AND object_id=OBJECT_ID('dbo.DenialMapperPushAudit'))
 CREATE INDEX IX_DenialMapperPushAudit_Status_TargetLab ON dbo.DenialMapperPushAudit(TargetLabId,PushStatus,CreatedOn DESC);
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='IX_DenialMapperPushAuditDetail_PushAuditId' AND object_id=OBJECT_ID('dbo.DenialMapperPushAuditDetail'))
 CREATE INDEX IX_DenialMapperPushAuditDetail_PushAuditId ON dbo.DenialMapperPushAuditDetail(PushAuditId);
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='IX_DenialMapperPushAuditDetail_Code_Key' AND object_id=OBJECT_ID('dbo.DenialMapperPushAuditDetail'))
 CREATE INDEX IX_DenialMapperPushAuditDetail_Code_Key ON dbo.DenialMapperPushAuditDetail(TargetLabId,DenialCode,ICDComplianceStatus,CoverageStatus);

COMMIT;
