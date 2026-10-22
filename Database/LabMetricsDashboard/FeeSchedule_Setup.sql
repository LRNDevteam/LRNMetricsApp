-- Fee Schedule (LRNMaster) and the "Fees Schedule Import" screen (FeeSchedule/Index) under
-- Master Values. Imports the Medicare Clinical Laboratory Fee Schedule
-- (docs/ar-workbench/ClinicalLaboratoryFeeSchedule_2026_Q1V1.xls, or the .xlsx / .csv of a later quarter):
--   mandatory columns  HCPCS (= the CPT code on the claim lines), RATE
--   optional columns   MOD, YEAR, EFF_DATE, INDICATOR, SHORTDESC
--
-- An import REPLACES the whole schedule, so the table always matches the last file imported.
-- One row per HCPCS: the CLFS repeats some codes with modifier QW at the same rate, and the AR
-- Workbench prices a line on its CPT.
--
-- How the rate is used: the Master File Processor (and AR Workbench Data Processing > Run) copies
-- this table into each AR Workbench lab database's dbo.ARWB_CptFeeSchedule before a claim sync,
-- re-prices the claim lines when the schedule changed, and the sync computes each claim's Revenue
-- Expectation (rate x units over its denied lines) and Recovery Status.
--
-- Idempotent: safe to run more than once.
-- Menus are cached for 30 minutes in MenuService - recycle the dashboard app or save any
-- Menu Master screen afterwards to flush the cache.
USE LRNMaster;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ----------------------------------------------------------------- Table */
IF OBJECT_ID(N'dbo.FeeSchedule', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.FeeSchedule
    (
        FeeScheduleId     INT            IDENTITY(1,1) NOT NULL,
        HCPCS             NVARCHAR(20)   NOT NULL,      -- the CPT / HCPCS code
        Rate              DECIMAL(18,2)  NOT NULL,
        Modifier          NVARCHAR(20)   NULL,          -- as listed on the kept row (informational)
        FeeYear           INT            NULL,
        EffectiveDate     DATE           NULL,
        Indicator         NVARCHAR(10)   NULL,          -- CLFS: N = national limit, L = local (rate 0)
        ShortDescription  NVARCHAR(300)  NULL,
        SourceFile        NVARCHAR(260)  NULL,
        ImportedOn        DATETIME2(0)   NOT NULL CONSTRAINT DF_FeeSchedule_ImportedOn DEFAULT (SYSUTCDATETIME()),
        ImportedBy        NVARCHAR(256)  NULL,
        CONSTRAINT PK_FeeSchedule PRIMARY KEY CLUSTERED (FeeScheduleId),
        CONSTRAINT UQ_FeeSchedule_HCPCS UNIQUE (HCPCS),
        CONSTRAINT CK_FeeSchedule_Rate CHECK (Rate >= 0)
    );
    PRINT 'Created dbo.FeeSchedule.';
END
GO

/* ------------------------------------------------------------------- Menu */
-- Placed under "Master Values" (DynamicMenu_Setup.sql), beside the other masters.
BEGIN TRANSACTION;

BEGIN TRY
    DECLARE @MenuItemId INT;
    DECLARE @ParentId   INT;
    DECLARE @MenuOrder  INT;

    SELECT TOP (1) @ParentId = MenuItemId
    FROM dbo.MenuItems
    WHERE MenuName = N'Master Values'
      AND ParentMenuItemId IS NULL
      AND IsDeleted = 0
    ORDER BY MenuItemId;

    SELECT @MenuOrder = ISNULL(MAX(MenuOrder), 0) + 1
    FROM dbo.MenuItems
    WHERE IsDeleted = 0
      AND ((@ParentId IS NULL AND ParentMenuItemId IS NULL) OR ParentMenuItemId = @ParentId);

    SELECT TOP (1) @MenuItemId = MenuItemId
    FROM dbo.MenuItems
    WHERE ControllerName = 'FeeSchedule'
      AND ActionName     = 'Index'
    ORDER BY MenuItemId;

    IF @MenuItemId IS NULL
    BEGIN
        INSERT INTO dbo.MenuItems
            (ParentMenuItemId, MenuName, ControllerName, ActionName, AreaName,
             IconClass, MenuOrder, IsDisabled, IsDeleted, CreatedBy, CreatedOn)
        VALUES
            (@ParentId, 'Fees Schedule Import', 'FeeSchedule', 'Index', NULL,
             'bi-currency-dollar', @MenuOrder, 0, 0, 'system', SYSUTCDATETIME());

        SET @MenuItemId = SCOPE_IDENTITY();
        PRINT 'MenuItem created for FeeSchedule/Index (MenuItemId ' + CAST(@MenuItemId AS VARCHAR(12)) + ').';
    END
    ELSE
    BEGIN
        UPDATE dbo.MenuItems
        SET MenuName         = 'Fees Schedule Import',
            ParentMenuItemId = COALESCE(@ParentId, ParentMenuItemId),
            IconClass        = 'bi-currency-dollar',
            IsDeleted        = 0,
            IsDisabled       = 0,
            ModifiedBy       = 'system',
            ModifiedOn       = SYSUTCDATETIME()
        WHERE MenuItemId = @MenuItemId;

        PRINT 'MenuItem ' + CAST(@MenuItemId AS VARCHAR(12)) + ' refreshed for FeeSchedule/Index.';
    END

    COMMIT TRANSACTION;
    PRINT 'Fee Schedule setup committed.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'Fee Schedule menu migration rolled back: ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

/* ----------------------------------------------------------------- Verify */
SELECT m.MenuItemId, m.ParentMenuItemId, m.MenuName, m.ControllerName, m.ActionName, m.IconClass, m.MenuOrder
FROM dbo.MenuItems m
WHERE m.ControllerName = 'FeeSchedule' AND m.ActionName = 'Index';

SELECT COUNT(*) AS FeeScheduleRows, MAX(ImportedOn) AS LastImportedOn FROM dbo.FeeSchedule;
GO
