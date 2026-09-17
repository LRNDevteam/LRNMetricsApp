/* ============================================================================
   Adds the "Denial Summary" menu item (LRNMaster.dbo.MenuItems).

   The report was renamed from "Denial Claim Report" to "Denial Summary"; the
   controller and route keep their original names so existing links still work.
   Re-run this script on an installed database to rename the existing menu row.

   The page itself is DenialClaimReportController/Index in LabMetricsDashboard;
   this row drives visibility, order and placement only, the same way
   Menu_AddDenialWorkflow.sql does for the Denial Workflow entry.

   The second page (Denial Insight - Claim Level) is reached from a button on
   this page rather than its own menu row, so the two stay together.

   RE-RUNNABLE: re-running restores the row if it was disabled or soft-deleted.
   ============================================================================ */

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

BEGIN TRANSACTION;

BEGIN TRY
    DECLARE @MenuItemId        INT;
    DECLARE @DenialDashboardId INT;
    DECLARE @MenuOrder         INT;

    SELECT TOP (1) @DenialDashboardId = MenuItemId
    FROM dbo.MenuItems
    WHERE ParentMenuItemId IS NULL
      AND ControllerName   = 'DenialDashboard'
      AND ActionName       = 'Index'
      AND IsDeleted        = 0
    ORDER BY MenuItemId;

    -- Sits with the other denial entries: same MenuOrder, and MenuService breaks the tie on
    -- MenuName ("Denial Summary" sorts just after "Denial Dashboard").
    SELECT @MenuOrder = ISNULL((SELECT MenuOrder FROM dbo.MenuItems WHERE MenuItemId = @DenialDashboardId),
                               ISNULL((SELECT MAX(MenuOrder) FROM dbo.MenuItems
                                       WHERE ParentMenuItemId IS NULL AND IsDeleted = 0), 0) + 1);

    SELECT TOP (1) @MenuItemId = MenuItemId
    FROM dbo.MenuItems
    WHERE ControllerName = 'DenialClaimReport'
      AND ActionName     = 'Index'
    ORDER BY MenuItemId;

    IF @MenuItemId IS NULL
    BEGIN
        INSERT INTO dbo.MenuItems
            (ParentMenuItemId, MenuName, ControllerName, ActionName, AreaName,
             IconClass, MenuOrder, IsDisabled, IsDeleted, CreatedBy, CreatedOn)
        VALUES
            (NULL, 'Denial Summary', 'DenialClaimReport', 'Index', NULL,
             'bi-file-earmark-medical', @MenuOrder, 0, 0, 'system', SYSUTCDATETIME());

        SET @MenuItemId = SCOPE_IDENTITY();
        PRINT 'MenuItem created for DenialClaimReport/Index (MenuItemId '
              + CAST(@MenuItemId AS VARCHAR(12)) + ').';
    END
    ELSE
    BEGIN
        UPDATE dbo.MenuItems
        SET MenuName   = 'Denial Summary',
            IconClass  = 'bi-file-earmark-medical',
            MenuOrder  = @MenuOrder,
            IsDisabled = 0,
            IsDeleted  = 0
        WHERE MenuItemId = @MenuItemId;

        PRINT 'MenuItem restored/updated for DenialClaimReport/Index (MenuItemId '
              + CAST(@MenuItemId AS VARCHAR(12)) + ').';
    END

    -- Without a UserRoleMenu row the item exists but nobody can see it. Seed the same audience
    -- Denial Dashboard already has; adjust afterwards in Admin > Role Menu Mapping.
    IF @DenialDashboardId IS NOT NULL
    BEGIN
        INSERT INTO dbo.UserRoleMenu (RoleId, MenuItemId)
        SELECT src.RoleId, @MenuItemId
        FROM dbo.UserRoleMenu AS src
        WHERE src.MenuItemId = @DenialDashboardId
          AND NOT EXISTS (SELECT 1
                          FROM dbo.UserRoleMenu AS existing
                          WHERE existing.RoleId     = src.RoleId
                            AND existing.MenuItemId = @MenuItemId);

        PRINT CAST(@@ROWCOUNT AS VARCHAR(12)) + ' role mapping(s) copied from Denial Dashboard.';
    END
    ELSE
        PRINT 'Denial Dashboard menu not found - no role mappings seeded. '
              + 'Grant access in Admin > Role Menu Mapping.';

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH
GO

SELECT m.MenuItemId, m.ParentMenuItemId, m.MenuName, m.ControllerName, m.ActionName,
       m.IconClass, m.MenuOrder, m.IsDisabled, m.IsDeleted
FROM dbo.MenuItems m
WHERE m.ControllerName = 'DenialClaimReport';
GO
