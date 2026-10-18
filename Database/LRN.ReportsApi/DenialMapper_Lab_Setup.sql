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
