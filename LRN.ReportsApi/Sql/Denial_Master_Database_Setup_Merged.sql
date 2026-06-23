/*
    Denial master-database setup (merged)
    ------------------------------------------------------------
    Target database: LRNMaster / configured ReportsApi DefaultConnection.

    This script consolidates the master-scoped denial mapper objects from the
    historical files in this folder. It is safe to re-run; table/index creation
    is guarded by OBJECT_ID/sys.indexes checks in the source sections.

    Do not run this in a lab/customer database.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() IN (N'master', N'model', N'msdb', N'tempdb')
BEGIN
    THROW 51000, 'Run this script in LRNMaster, not a SQL Server system database.', 1;
END;
GO
/* ============================================================================
   Source: DenialMapper_Setup.sql
   ============================================================================ */
SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF OBJECT_ID('dbo.DenialMapperSuperMaster','U') IS NULL
CREATE TABLE dbo.DenialMapperSuperMaster(
 Id bigint IDENTITY PRIMARY KEY, DenialCode nvarchar(50) NOT NULL, DenialDescription nvarchar(500) NULL,
 DenialClassification nvarchar(100) NULL, CoverageStatus nvarchar(100) NULL, ICDComplianceStatus nvarchar(100) NULL,
 DenialValidity nvarchar(100) NULL, ActionCode nvarchar(100) NOT NULL, ActionCategory nvarchar(100) NOT NULL,
 Task nvarchar(300) NOT NULL, RecommendedAction nvarchar(1000) NOT NULL, SLA nvarchar(50) NOT NULL, Priority nvarchar(50) NOT NULL,
 IsActive bit NOT NULL CONSTRAINT DF_DMSM_Active DEFAULT 1, CreatedBy nvarchar(200) NOT NULL, CreatedOn datetime2 NOT NULL CONSTRAINT DF_DMSM_Created DEFAULT SYSUTCDATETIME(),
 ModifiedBy nvarchar(200) NOT NULL, ModifiedOn datetime2 NOT NULL CONSTRAINT DF_DMSM_Modified DEFAULT SYSUTCDATETIME()
);
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='UX_DenialMapperSuperMaster_Key')
 CREATE UNIQUE INDEX UX_DenialMapperSuperMaster_Key ON dbo.DenialMapperSuperMaster(DenialCode,DenialClassification,CoverageStatus,ICDComplianceStatus) WHERE IsActive=1;

IF OBJECT_ID('dbo.DenialMapperAuditLog','U') IS NULL
CREATE TABLE dbo.DenialMapperAuditLog(
 Id bigint IDENTITY PRIMARY KEY, EventType nvarchar(100) NOT NULL, LabId int NULL, SuperMasterId bigint NULL, DenialCode nvarchar(50) NULL,
 FieldName nvarchar(100) NULL, FromValue nvarchar(max) NULL, ToValue nvarchar(max) NULL, PerformedBy nvarchar(200) NOT NULL,
 PerformedRole nvarchar(100) NOT NULL, PerformedOn datetime2 NOT NULL DEFAULT SYSUTCDATETIME(), Remarks nvarchar(1000) NULL
);
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='IX_DenialMapperAuditLog_LabDate')
 CREATE INDEX IX_DenialMapperAuditLog_LabDate ON dbo.DenialMapperAuditLog(LabId,PerformedOn DESC);

COMMIT;
GO

/* ============================================================================
   Source: DenialMapper_PushAudit_Setup.sql
   ============================================================================ */
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
GO

/* ============================================================================
   Current application compatibility: mapper push audit columns
   ============================================================================ */
IF OBJECT_ID('dbo.DenialMapperPushAudit','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialMapperPushAudit','AcknowledgedOn') IS NULL
        ALTER TABLE dbo.DenialMapperPushAudit ADD AcknowledgedOn datetime2 NULL;

    IF COL_LENGTH('dbo.DenialMapperPushAudit','AcknowledgedByUserId') IS NULL
        ALTER TABLE dbo.DenialMapperPushAudit ADD AcknowledgedByUserId nvarchar(100) NULL;

    IF COL_LENGTH('dbo.DenialMapperPushAudit','FailureMessage') IS NULL
        ALTER TABLE dbo.DenialMapperPushAudit ADD FailureMessage nvarchar(2000) NULL;
END;
GO

PRINT 'Denial master-database setup completed for ' + DB_NAME();
GO

