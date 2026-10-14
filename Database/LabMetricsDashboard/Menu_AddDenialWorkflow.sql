-- Brings the "Denial Workflow" navbar link under Role Menu Mapping.
--
-- Until now the link was hard-coded into the navbar (DynamicMenu/Default.cshtml) and shown
-- to every user who could see Denial Dashboard, with no way to grant or revoke it per role.
-- This script creates the menu row that replaces it. The link still opens the separate
-- React app (DenialWorkflowReactUrl) - the row drives visibility, order and placement only.
--
-- Existing access is preserved: role mappings are copied from Denial Dashboard, so the same
-- people keep the link on upgrade. That is a starting point, not a policy - review it in
-- Admin > Role Menu Mapping. Admins need no mapping; they bypass menu enforcement entirely.
--
-- Side effect worth knowing: /DenialWorkflow/Index (the MVC page) becomes menu-managed, so
-- MenuAccessFilter now returns AccessDenied there for roles without the mapping. The React
-- app's own endpoints (/DenialWorkflow/AuthToken, /DenialWorkflow/Logout, exports) are not
-- menu-managed and stay reachable.
--
-- Idempotent: safe to run more than once.
-- Menus are cached for 30 minutes in MenuService - recycle the dashboard app or save any
-- Menu Master screen afterwards to flush the cache.
USE LRNMaster;
GO

-- dbo.MenuItems carries a filtered index, so writes require these ON. SSMS sets them by
-- default but sqlcmd does not - without this the INSERT fails with Msg 1934.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
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

    -- Share Denial Dashboard's MenuOrder so the two sort together; MenuService breaks the
    -- tie on MenuName and "Denial Dashboard" sorts before "Denial Workflow".
    SELECT @MenuOrder = ISNULL((SELECT MenuOrder FROM dbo.MenuItems WHERE MenuItemId = @DenialDashboardId),
                               ISNULL((SELECT MAX(MenuOrder) FROM dbo.MenuItems
                                       WHERE ParentMenuItemId IS NULL AND IsDeleted = 0), 0) + 1);

    SELECT TOP (1) @MenuItemId = MenuItemId
    FROM dbo.MenuItems
    WHERE ControllerName = 'DenialWorkflow'
      AND ActionName     = 'Index'
    ORDER BY MenuItemId;

    IF @MenuItemId IS NULL
    BEGIN
        INSERT INTO dbo.MenuItems
            (ParentMenuItemId, MenuName, ControllerName, ActionName, AreaName,
             IconClass, MenuOrder, IsDisabled, IsDeleted, CreatedBy, CreatedOn)
        VALUES
            (NULL, 'Denial Workflow', 'DenialWorkflow', 'Index', NULL,
             'bi-kanban-fill', @MenuOrder, 0, 0, 'system', SYSUTCDATETIME());

        SET @MenuItemId = SCOPE_IDENTITY();
        PRINT 'MenuItem created for DenialWorkflow/Index (MenuItemId '
              + CAST(@MenuItemId AS VARCHAR(12)) + ').';
    END
    ELSE
    BEGIN
        -- Re-running after a soft delete, or after the row was disabled, should restore it.
        UPDATE dbo.MenuItems
        SET MenuName   = 'Denial Workflow',
            IconClass  = 'bi-kanban-fill',
            MenuOrder  = @MenuOrder,
            IsDeleted  = 0,
            IsDisabled = 0,
            ModifiedBy = 'system',
            ModifiedOn = SYSUTCDATETIME()
        WHERE MenuItemId = @MenuItemId;

        PRINT 'MenuItem ' + CAST(@MenuItemId AS VARCHAR(12)) + ' refreshed for DenialWorkflow/Index.';
    END

    -- Preserve today's audience: whoever can see Denial Dashboard keeps Denial Workflow.
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

        PRINT CAST(@@ROWCOUNT AS VARCHAR(12))
              + ' role mapping(s) copied from Denial Dashboard.';
    END
    ELSE
        PRINT 'Denial Dashboard menu not found - no role mappings seeded. '
              + 'Grant access in Admin > Role Menu Mapping.';

    COMMIT TRANSACTION;
    PRINT 'Denial Workflow menu migration committed.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'Denial Workflow menu migration rolled back: ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

/* ------------------------------------------------------------------- Verify */
SELECT m.MenuItemId, m.ParentMenuItemId, m.MenuName, m.ControllerName, m.ActionName,
       m.IconClass, m.MenuOrder, m.IsDisabled, m.IsDeleted,
       (SELECT COUNT(*) FROM dbo.UserRoleMenu r WHERE r.MenuItemId = m.MenuItemId) AS RoleMappings
FROM dbo.MenuItems m
WHERE m.ControllerName = 'DenialWorkflow';
GO
