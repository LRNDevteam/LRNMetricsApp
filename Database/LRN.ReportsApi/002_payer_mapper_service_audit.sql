/* =====================================================================
   Payer Policy Mapper - service run audit (idempotent)
   One row per worker run (scheduled hourly / manual trigger from the
   Payer Service Audit page / rules-change / nightly rescan). The rows a
   run updated are the dbo.PayerMatchAudit rows carrying that RunId.
   ===================================================================== */
SET NOCOUNT ON;
GO

-- 1. Run header table -----------------------------------------------------
IF OBJECT_ID('dbo.PayerMapperRun', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PayerMapperRun (
        RunId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_PayerMapperRun PRIMARY KEY
                       CONSTRAINT DF_PayerMapperRun_RunId DEFAULT (NEWID()),
        TriggerType    NVARCHAR(20)  NOT NULL,   -- Scheduled / Manual / RulesChange / NightlyRescan
        RequestedBy    NVARCHAR(100) NULL,       -- username for Manual triggers
        Status         NVARCHAR(20)  NOT NULL,   -- Requested / InProgress / Success / Fail
        CreatedOn      DATETIME2     NOT NULL CONSTRAINT DF_PayerMapperRun_CreatedOn DEFAULT (SYSUTCDATETIME()),
        StartedOn      DATETIME2     NULL,
        CompletedOn    DATETIME2     NULL,
        TotalProcessed INT           NOT NULL CONSTRAINT DF_PayerMapperRun_Total DEFAULT (0),
        AutoMapped     INT           NOT NULL CONSTRAINT DF_PayerMapperRun_Auto DEFAULT (0),
        PendingReview  INT           NOT NULL CONSTRAINT DF_PayerMapperRun_Review DEFAULT (0),
        NoMatch        INT           NOT NULL CONSTRAINT DF_PayerMapperRun_NoMatch DEFAULT (0),
        FailedRows     INT           NOT NULL CONSTRAINT DF_PayerMapperRun_FailedRows DEFAULT (0),
        ErrorMessage   NVARCHAR(MAX) NULL
    );
    CREATE INDEX IX_PayerMapperRun_Status ON dbo.PayerMapperRun (Status) INCLUDE (CreatedOn);
    CREATE INDEX IX_PayerMapperRun_CreatedOn ON dbo.PayerMapperRun (CreatedOn DESC);
END
GO

-- 2. Link evaluations to their run ----------------------------------------
IF COL_LENGTH('dbo.PayerMatchAudit', 'RunId') IS NULL
BEGIN
    ALTER TABLE dbo.PayerMatchAudit ADD RunId UNIQUEIDENTIFIER NULL;
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PayerMatchAudit_RunId' AND object_id = OBJECT_ID('dbo.PayerMatchAudit'))
    CREATE INDEX IX_PayerMatchAudit_RunId ON dbo.PayerMatchAudit (RunId) INCLUDE (LabInsuranceMasterId, Decision, PerformedOn);
GO

-- 3. Menu item under Master Values (idempotent; visible to Admin role by default,
--    map to other roles via Admin > Role Menu Mapping) ----------------------
DECLARE @ParentId INT = (SELECT TOP 1 MenuItemId FROM dbo.MenuItems
                         WHERE MenuName = 'Master Values' AND IsDeleted = 0 ORDER BY MenuItemId);
IF @ParentId IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM dbo.MenuItems
    WHERE ControllerName = 'MasterValues' AND ActionName = 'PayerServiceAudit' AND IsDeleted = 0)
BEGIN
    INSERT INTO dbo.MenuItems (ParentMenuItemId, MenuName, ControllerName, ActionName, IconClass, MenuOrder, IsDisabled, IsDeleted, CreatedBy, CreatedOn)
    VALUES (@ParentId, 'Payer Service Audit', 'MasterValues', 'PayerServiceAudit', 'bi-clock-history',
            (SELECT ISNULL(MAX(MenuOrder), 0) + 1 FROM dbo.MenuItems WHERE ParentMenuItemId = @ParentId AND IsDeleted = 0),
            0, 0, 'system (payer service audit)', SYSUTCDATETIME());

    DECLARE @NewMenuId INT = SCOPE_IDENTITY();
    DECLARE @AdminRoleId INT = (SELECT TOP 1 RoleID FROM dbo.Roles WHERE RoleName = 'Admin');
    IF @AdminRoleId IS NOT NULL AND OBJECT_ID('dbo.UserRoleMenu', 'U') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dbo.UserRoleMenu WHERE RoleId = @AdminRoleId AND MenuItemId = @NewMenuId)
        INSERT INTO dbo.UserRoleMenu (RoleId, MenuItemId, CreatedBy, CreatedOn)
        VALUES (@AdminRoleId, @NewMenuId, 'system (payer service audit)', SYSUTCDATETIME());
END
GO
