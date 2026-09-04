-- Adds "Production Insight Templates" (InsightTemplate/Production) to the navbar.
--
-- The screen is reachable by direct URL for Admins either way. This script is
-- what makes it appear as a menu item. Sit beside Production Report so the
-- same audience that fills Production insights can maintain the template.
--
-- Role mappings are seeded from whoever can already see Production Report.
-- Admins need no mapping; they bypass menu enforcement entirely.
--
-- Idempotent. Recycle the dashboard app or save any Menu Master screen to
-- flush the 30-minute menu cache.
-- Run on LRNMaster.
USE LRNMaster;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

BEGIN TRANSACTION;

BEGIN TRY
    DECLARE @MenuItemId  INT;
    DECLARE @ParentId    INT;
    DECLARE @SiblingId   INT;
    DECLARE @MenuOrder   INT;

    SELECT TOP (1) @SiblingId = MenuItemId,
                   @ParentId  = ParentMenuItemId
    FROM dbo.MenuItems
    WHERE ControllerName = 'Dashboard'
      AND ActionName     IN ('ProductionSummaryReport', 'ProductionReport')
      AND IsDeleted      = 0
    ORDER BY CASE ActionName WHEN 'ProductionSummaryReport' THEN 0 ELSE 1 END, MenuItemId;

    IF @SiblingId IS NULL
        SELECT TOP (1) @ParentId = MenuItemId
        FROM dbo.MenuItems
        WHERE MenuName IN ('Reports', 'Dashboard')
          AND ParentMenuItemId IS NULL
          AND IsDeleted = 0
        ORDER BY MenuItemId;

    SELECT @MenuOrder = ISNULL(MAX(MenuOrder), 0) + 1
    FROM dbo.MenuItems
    WHERE IsDeleted = 0
      AND (
            (@ParentId IS NULL AND ParentMenuItemId IS NULL)
         OR ParentMenuItemId = @ParentId
          );

    SELECT TOP (1) @MenuItemId = MenuItemId
    FROM dbo.MenuItems
    WHERE ControllerName = 'InsightTemplate'
      AND ActionName     = 'Production'
    ORDER BY MenuItemId;

    IF @MenuItemId IS NULL
    BEGIN
        INSERT INTO dbo.MenuItems
            (ParentMenuItemId, MenuName, ControllerName, ActionName, AreaName,
             IconClass, MenuOrder, IsDisabled, IsDeleted, CreatedBy, CreatedOn)
        VALUES
            (@ParentId, 'Production Insight Templates', 'InsightTemplate', 'Production', NULL,
             'bi-lightbulb', @MenuOrder, 0, 0, 'system', SYSUTCDATETIME());

        SET @MenuItemId = SCOPE_IDENTITY();
        PRINT 'MenuItem created for InsightTemplate/Production (MenuItemId '
              + CAST(@MenuItemId AS VARCHAR(12)) + ').';
    END
    ELSE
    BEGIN
        UPDATE dbo.MenuItems
        SET MenuName   = 'Production Insight Templates',
            IconClass  = 'bi-lightbulb',
            IsDeleted  = 0,
            IsDisabled = 0,
            ModifiedBy = 'system',
            ModifiedOn = SYSUTCDATETIME()
        WHERE MenuItemId = @MenuItemId;

        PRINT 'MenuItem ' + CAST(@MenuItemId AS VARCHAR(12)) + ' refreshed for InsightTemplate/Production.';
    END

    IF @SiblingId IS NOT NULL
    BEGIN
        INSERT INTO dbo.UserRoleMenu (RoleId, MenuItemId)
        SELECT src.RoleId, @MenuItemId
        FROM dbo.UserRoleMenu AS src
        WHERE src.MenuItemId = @SiblingId
          AND NOT EXISTS (SELECT 1
                          FROM dbo.UserRoleMenu AS existing
                          WHERE existing.RoleId     = src.RoleId
                            AND existing.MenuItemId = @MenuItemId);

        PRINT CAST(@@ROWCOUNT AS VARCHAR(12))
              + ' role mapping(s) copied from Production Report.';
    END
    ELSE
        PRINT 'Production Report menu not found — no role mappings seeded. '
              + 'Grant access in Admin > Role Menu Mapping.';

    COMMIT TRANSACTION;
    PRINT 'Production Insight Templates menu migration committed.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'Production Insight Templates menu migration rolled back: ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

SELECT m.MenuItemId, m.ParentMenuItemId, m.MenuName, m.ControllerName, m.ActionName,
       m.IconClass, m.MenuOrder, m.IsDisabled, m.IsDeleted,
       (SELECT COUNT(*) FROM dbo.UserRoleMenu r WHERE r.MenuItemId = m.MenuItemId) AS RoleMappings
FROM dbo.MenuItems m
WHERE m.ControllerName = 'InsightTemplate';
GO
