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
