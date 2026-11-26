-- Adds "Report Visibility" (Admin/ReportVisibility) to the Admin menu: per role, which tabs it sees on
-- the Standard Reports pages (LIS Summary, Production, Collection, Executive Summary, Denial Summary)
-- and whether it can see / edit each page's Key Insights.
--
-- Settings are stored as 'Report.*' rows of dbo.RoleFeatureAccess (Menu_AddRoleFeatureAccess.sql must
-- have been run). No other schema change. With no rows saved every page behaves exactly as before.
--
-- Placed beside "Role Menu Mapping" (Admin/RoleMenuMapping) wherever that lives. No role mappings are
-- seeded: the page is restricted to Admin / Super Admin / LRN Admin in code ([Authorize(FullAdmin)]),
-- and those roles bypass menu mapping.
--
-- Idempotent: safe to run more than once.
-- Menus are cached for 30 minutes in MenuService - recycle the dashboard app or save any
-- Menu Master screen afterwards to flush the cache.
USE LRNMaster;
GO

-- dbo.MenuItems carries a filtered index, so writes require these ON (sqlcmd defaults them OFF).
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

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
      AND ActionName     = 'RoleMenuMapping'
      AND IsDeleted      = 0
    ORDER BY MenuItemId;

    -- No Role Menu Mapping item: fall back to the Admin parent by name, then to top level.
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
    WHERE ControllerName = 'Admin'
      AND ActionName     = 'ReportVisibility'
    ORDER BY MenuItemId;

    IF @MenuItemId IS NULL
    BEGIN
        INSERT INTO dbo.MenuItems
            (ParentMenuItemId, MenuName, ControllerName, ActionName, AreaName,
             IconClass, MenuOrder, IsDisabled, IsDeleted, CreatedBy, CreatedOn)
        VALUES
            (@ParentId, 'Report Visibility', 'Admin', 'ReportVisibility', NULL,
             'bi-eye', @MenuOrder, 0, 0, 'system', SYSUTCDATETIME());

        SET @MenuItemId = SCOPE_IDENTITY();
        PRINT 'MenuItem created for Admin/ReportVisibility (MenuItemId ' + CAST(@MenuItemId AS VARCHAR(12)) + ').';
    END
    ELSE
    BEGIN
        UPDATE dbo.MenuItems
        SET MenuName   = 'Report Visibility',
            IconClass  = 'bi-eye',
            IsDeleted  = 0,
            IsDisabled = 0,
            ModifiedBy = 'system',
            ModifiedOn = SYSUTCDATETIME()
        WHERE MenuItemId = @MenuItemId;

        PRINT 'MenuItem ' + CAST(@MenuItemId AS VARCHAR(12)) + ' refreshed for Admin/ReportVisibility.';
    END

    COMMIT TRANSACTION;
    PRINT 'Report Visibility menu migration committed.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'Report Visibility menu migration rolled back: ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

/* ------------------------------------------------------------------- Verify */
SELECT m.MenuItemId, m.ParentMenuItemId, m.MenuName, m.ControllerName, m.ActionName, m.IconClass, m.MenuOrder, m.IsDisabled, m.IsDeleted
FROM dbo.MenuItems m
WHERE m.ControllerName = 'Admin' AND m.ActionName = 'ReportVisibility';

-- Saved Report Visibility settings, per role.
SELECT r.RoleName, fa.FeatureKey, fa.IsEnabled, fa.CreatedBy, fa.CreatedOn
FROM dbo.RoleFeatureAccess fa
LEFT JOIN dbo.Roles r ON r.RoleID = fa.RoleId
WHERE fa.FeatureKey LIKE N'Report.%'
ORDER BY r.RoleName, fa.FeatureKey;
GO
