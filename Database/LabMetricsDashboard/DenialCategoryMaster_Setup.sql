-- Denial Category Master and Non-Collectible Denial Master (LRNMaster), and the "Denial Category
-- Master" screen (DenialCategoryMaster/Index) that imports both from
-- docs/Denial_Codes_And_Categorization_Master.xlsx:
--   sheet 1 "Denial Category Clasification" -> dbo.DenialCategoryMaster
--            Denial Code, Denial Code Description, Denial Categorization (the action category)
--   sheet 2 "Non-collectible Denials"        -> dbo.NonCollectibleDenialMaster
--            Denial Code, Denial Code Description
--
-- An import replaces the rows of each sheet it contains, so each table always matches the last
-- workbook imported; CreatedOn / CreatedBy record that import.
--
-- The menu item is placed beside "Email Log" / "Manage Users" in the Admin menu. Importing is
-- restricted to Admin / Super Admin / LRN Admin in code; other roles mapped to the menu can view.
--
-- Idempotent: safe to run more than once.
-- Menus are cached for 30 minutes in MenuService - recycle the dashboard app or save any
-- Menu Master screen afterwards to flush the cache.
USE LRNMaster;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ----------------------------------------------------------------- Tables */
IF OBJECT_ID(N'dbo.DenialCategoryMaster', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialCategoryMaster
    (
        DenialCategoryMasterId INT            IDENTITY(1,1) NOT NULL,
        DenialCode             NVARCHAR(50)   NOT NULL,
        Description            NVARCHAR(1000) NULL,
        ActionCategory         NVARCHAR(300)  NULL,
        CreatedOn              DATETIME2(0)   NOT NULL CONSTRAINT DF_DenialCategoryMaster_CreatedOn DEFAULT (SYSUTCDATETIME()),
        CreatedBy              NVARCHAR(256)  NULL,
        CONSTRAINT PK_DenialCategoryMaster PRIMARY KEY CLUSTERED (DenialCategoryMasterId),
        CONSTRAINT UQ_DenialCategoryMaster_DenialCode UNIQUE (DenialCode)
    );
    PRINT 'Created dbo.DenialCategoryMaster.';
END
GO

IF OBJECT_ID(N'dbo.NonCollectibleDenialMaster', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.NonCollectibleDenialMaster
    (
        NonCollectibleDenialMasterId INT            IDENTITY(1,1) NOT NULL,
        DenialCode                   NVARCHAR(50)   NOT NULL,
        Description                  NVARCHAR(1000) NULL,
        CreatedOn                    DATETIME2(0)   NOT NULL CONSTRAINT DF_NonCollectibleDenialMaster_CreatedOn DEFAULT (SYSUTCDATETIME()),
        CreatedBy                    NVARCHAR(256)  NULL,
        CONSTRAINT PK_NonCollectibleDenialMaster PRIMARY KEY CLUSTERED (NonCollectibleDenialMasterId),
        CONSTRAINT UQ_NonCollectibleDenialMaster_DenialCode UNIQUE (DenialCode)
    );
    PRINT 'Created dbo.NonCollectibleDenialMaster.';
END
GO

/* ------------------------------------------------------------------- Menu */
BEGIN TRANSACTION;

BEGIN TRY
    DECLARE @MenuItemId INT;
    DECLARE @ParentId   INT;
    DECLARE @SiblingId  INT;
    DECLARE @MenuOrder  INT;

    SELECT TOP (1) @SiblingId = MenuItemId,
                   @ParentId  = ParentMenuItemId
    FROM dbo.MenuItems
    WHERE ControllerName = 'Admin'
      AND ActionName     IN ('EmailLog', 'ListUsers')
      AND IsDeleted      = 0
    ORDER BY CASE ActionName WHEN 'EmailLog' THEN 0 ELSE 1 END, MenuItemId;

    -- No Email Log / Manage Users item: fall back to the Admin parent by name, then to top level.
    IF @SiblingId IS NULL
        SELECT TOP (1) @ParentId = MenuItemId
        FROM dbo.MenuItems
        WHERE MenuName = 'Admin'
          AND ParentMenuItemId IS NULL
          AND IsDeleted = 0
        ORDER BY MenuItemId;

    SELECT @MenuOrder = ISNULL(MAX(MenuOrder), 0) + 1
    FROM dbo.MenuItems
    WHERE IsDeleted = 0
      AND ((@ParentId IS NULL AND ParentMenuItemId IS NULL) OR ParentMenuItemId = @ParentId);

    SELECT TOP (1) @MenuItemId = MenuItemId
    FROM dbo.MenuItems
    WHERE ControllerName = 'DenialCategoryMaster'
      AND ActionName     = 'Index'
    ORDER BY MenuItemId;

    IF @MenuItemId IS NULL
    BEGIN
        INSERT INTO dbo.MenuItems
            (ParentMenuItemId, MenuName, ControllerName, ActionName, AreaName,
             IconClass, MenuOrder, IsDisabled, IsDeleted, CreatedBy, CreatedOn)
        VALUES
            (@ParentId, 'Denial Category Master', 'DenialCategoryMaster', 'Index', NULL,
             'bi-tags', @MenuOrder, 0, 0, 'system', SYSUTCDATETIME());

        SET @MenuItemId = SCOPE_IDENTITY();
        PRINT 'MenuItem created for DenialCategoryMaster/Index (MenuItemId ' + CAST(@MenuItemId AS VARCHAR(12)) + ').';
    END
    ELSE
    BEGIN
        UPDATE dbo.MenuItems
        SET MenuName   = 'Denial Category Master',
            IconClass  = 'bi-tags',
            IsDeleted  = 0,
            IsDisabled = 0,
            ModifiedBy = 'system',
            ModifiedOn = SYSUTCDATETIME()
        WHERE MenuItemId = @MenuItemId;

        PRINT 'MenuItem ' + CAST(@MenuItemId AS VARCHAR(12)) + ' refreshed for DenialCategoryMaster/Index.';
    END

    COMMIT TRANSACTION;
    PRINT 'Denial Category Master setup committed.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'Denial Category Master menu migration rolled back: ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

/* ----------------------------------------------------------------- Verify */
SELECT m.MenuItemId, m.ParentMenuItemId, m.MenuName, m.ControllerName, m.ActionName, m.IconClass, m.MenuOrder
FROM dbo.MenuItems m
WHERE m.ControllerName = 'DenialCategoryMaster' AND m.ActionName = 'Index';

SELECT (SELECT COUNT(*) FROM dbo.DenialCategoryMaster)       AS DenialCategoryRows,
       (SELECT COUNT(*) FROM dbo.NonCollectibleDenialMaster) AS NonCollectibleRows;
GO
