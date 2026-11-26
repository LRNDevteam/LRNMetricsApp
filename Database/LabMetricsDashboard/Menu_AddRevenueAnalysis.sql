/* ============================================================================
   Adds the "Revenue Analysis" menu item (LRNMaster.dbo.MenuItems).

   The page is RevenueAnalysisController/Index in LabMetricsDashboard: the launcher
   for the client revenue dashboard (Overview, Trends, Payer, Panel & Billing, CPT,
   Clinic & Provider, Claim Status, Denial, Source Data) built from the lab's Claim
   Level and Line Level data - live or from a weekly snapshot. Each dashboard page
   opens in its own window from there; those windows (RevenueAnalysis/Page,
   RevenueAnalysis/Download) are not menu rows.

   Placed under "Standard Reports" beside Executive Summary, with the same audience:
   Executive Summary's role mappings are copied. Adjust afterwards in
   Admin > Role Menu Mapping.

   RE-RUNNABLE: re-running restores the row if it was disabled or soft-deleted.
   Menus are cached for 30 minutes in MenuService - recycle the dashboard app or save
   any Menu Master screen afterwards to flush the cache.
   ============================================================================ */

USE LRNMaster;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

BEGIN TRANSACTION;

BEGIN TRY
    DECLARE @MenuItemId   INT;
    DECLARE @ParentId     INT;
    DECLARE @ExecId       INT;
    DECLARE @MenuOrder    INT;

    SELECT TOP (1) @ParentId = MenuItemId
    FROM dbo.MenuItems
    WHERE MenuName = N'Standard Reports'
      AND ParentMenuItemId IS NULL
      AND IsDeleted = 0
    ORDER BY MenuItemId;

    SELECT TOP (1) @ExecId = MenuItemId
    FROM dbo.MenuItems
    WHERE ControllerName = 'ExecutiveSummary'
      AND ActionName     = 'Index'
      AND IsDeleted      = 0
    ORDER BY MenuItemId;

    -- Directly after Executive Summary when it is in the same group, else at the end of the group.
    SELECT @MenuOrder = COALESCE(
        (SELECT MenuOrder + 1 FROM dbo.MenuItems
         WHERE MenuItemId = @ExecId
           AND ((@ParentId IS NULL AND ParentMenuItemId IS NULL) OR ParentMenuItemId = @ParentId)),
        (SELECT ISNULL(MAX(MenuOrder), 0) + 1 FROM dbo.MenuItems
         WHERE IsDeleted = 0
           AND ((@ParentId IS NULL AND ParentMenuItemId IS NULL) OR ParentMenuItemId = @ParentId)));

    SELECT TOP (1) @MenuItemId = MenuItemId
    FROM dbo.MenuItems
    WHERE ControllerName = 'RevenueAnalysis'
      AND ActionName     = 'Index'
    ORDER BY MenuItemId;

    IF @MenuItemId IS NULL
    BEGIN
        INSERT INTO dbo.MenuItems
            (ParentMenuItemId, MenuName, ControllerName, ActionName, AreaName,
             IconClass, MenuOrder, IsDisabled, IsDeleted, CreatedBy, CreatedOn)
        VALUES
            (@ParentId, 'Revenue Analysis', 'RevenueAnalysis', 'Index', NULL,
             'bi-window-stack', @MenuOrder, 0, 0, 'system', SYSUTCDATETIME());

        SET @MenuItemId = SCOPE_IDENTITY();
        PRINT 'MenuItem created for RevenueAnalysis/Index (MenuItemId ' + CAST(@MenuItemId AS VARCHAR(12)) + ').';
    END
    ELSE
    BEGIN
        UPDATE dbo.MenuItems
        SET MenuName         = 'Revenue Analysis',
            ParentMenuItemId = COALESCE(@ParentId, ParentMenuItemId),
            IconClass        = 'bi-window-stack',
            IsDisabled       = 0,
            IsDeleted        = 0,
            ModifiedBy       = 'system',
            ModifiedOn       = SYSUTCDATETIME()
        WHERE MenuItemId = @MenuItemId;

        PRINT 'MenuItem ' + CAST(@MenuItemId AS VARCHAR(12)) + ' refreshed for RevenueAnalysis/Index.';
    END

    -- Without a UserRoleMenu row the item exists but nobody can see it.
    IF @ExecId IS NOT NULL
    BEGIN
        INSERT INTO dbo.UserRoleMenu (RoleId, MenuItemId)
        SELECT src.RoleId, @MenuItemId
        FROM dbo.UserRoleMenu AS src
        WHERE src.MenuItemId = @ExecId
          AND NOT EXISTS (SELECT 1
                          FROM dbo.UserRoleMenu AS existing
                          WHERE existing.RoleId     = src.RoleId
                            AND existing.MenuItemId = @MenuItemId);

        PRINT CAST(@@ROWCOUNT AS VARCHAR(12)) + ' role mapping(s) copied from Executive Summary.';
    END
    ELSE
        PRINT 'Executive Summary menu not found - no role mappings seeded. Grant access in Admin > Role Menu Mapping.';

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'Revenue Analysis menu migration rolled back: ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

SELECT m.MenuItemId, m.ParentMenuItemId, m.MenuName, m.ControllerName, m.ActionName,
       m.IconClass, m.MenuOrder, m.IsDisabled, m.IsDeleted
FROM dbo.MenuItems m
WHERE m.ControllerName = 'RevenueAnalysis';
GO
