-- Adds the "Reimbursement Insights" chat screen (ReimbursementChat/Index) to the navbar.
--
-- The screen itself works the moment the code is deployed — MenuAccessFilter only blocks
-- routes the Menu Master actually manages, so /ReimbursementChat is reachable by direct URL
-- either way. This script is what makes it appear as a menu item.
--
-- Placed under the Analytics parent, next to "CPT & Panel Lookup": same audience, same
-- subject matter (CPT / panel / payer reimbursement), just asked in plain language instead
-- of filtered in a grid.
--
-- Role mappings are seeded from whoever can already see Analytics/CptLookup. That is a
-- starting point, not a policy — review it in Admin > Role Menu Mapping. Admins need no
-- mapping; they bypass menu enforcement entirely.
--
-- Idempotent: safe to run more than once.
-- Menus are cached for 30 minutes in MenuService — recycle the dashboard app or save any
-- Menu Master screen afterwards to flush the cache.
USE LRNMaster;
GO

-- dbo.MenuItems carries a filtered index, so writes require these ON. SSMS sets them by
-- default but sqlcmd does not — without this the INSERT fails with Msg 1934.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

BEGIN TRANSACTION;

BEGIN TRY
    DECLARE @MenuItemId  INT;
    DECLARE @ParentId    INT;
    DECLARE @SiblingId   INT;
    DECLARE @MenuOrder   INT;

    -- Sit beside CPT & Panel Lookup wherever that lives, rather than assuming a parent id.
    SELECT TOP (1) @SiblingId = MenuItemId,
                   @ParentId  = ParentMenuItemId
    FROM dbo.MenuItems
    WHERE ControllerName = 'Analytics'
      AND ActionName     = 'CptLookup'
      AND IsDeleted      = 0
    ORDER BY MenuItemId;

    -- Fresh/renamed install: fall back to the Analytics parent by name, then to top level.
    IF @SiblingId IS NULL
        SELECT TOP (1) @ParentId = MenuItemId
        FROM dbo.MenuItems
        WHERE MenuName = 'Analytics'
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
    WHERE ControllerName = 'ReimbursementChat'
      AND ActionName     = 'Index'
    ORDER BY MenuItemId;

    IF @MenuItemId IS NULL
    BEGIN
        INSERT INTO dbo.MenuItems
            (ParentMenuItemId, MenuName, ControllerName, ActionName, AreaName,
             IconClass, MenuOrder, IsDisabled, IsDeleted, CreatedBy, CreatedOn)
        VALUES
            (@ParentId, 'Reimbursement Insights', 'ReimbursementChat', 'Index', NULL,
             'bi-robot', @MenuOrder, 0, 0, 'system', SYSUTCDATETIME());

        SET @MenuItemId = SCOPE_IDENTITY();
        PRINT 'MenuItem created for ReimbursementChat/Index (MenuItemId '
              + CAST(@MenuItemId AS VARCHAR(12)) + ').';
    END
    ELSE
    BEGIN
        -- Re-running after a soft delete, or after the row was disabled, should restore it.
        UPDATE dbo.MenuItems
        SET MenuName   = 'Reimbursement Insights',
            IconClass  = 'bi-robot',
            IsDeleted  = 0,
            IsDisabled = 0,
            ModifiedBy = 'system',
            ModifiedOn = SYSUTCDATETIME()
        WHERE MenuItemId = @MenuItemId;

        PRINT 'MenuItem ' + CAST(@MenuItemId AS VARCHAR(12)) + ' refreshed for ReimbursementChat/Index.';
    END

    -- Seed role access from the CPT & Panel Lookup screen's existing mappings.
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
              + ' role mapping(s) copied from Analytics/CptLookup.';
    END
    ELSE
        PRINT 'Analytics/CptLookup not found — no role mappings seeded. '
              + 'Grant access in Admin > Role Menu Mapping.';

    COMMIT TRANSACTION;
    PRINT 'Reimbursement Insights menu migration committed.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'Reimbursement Insights menu migration rolled back: ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

/* ------------------------------------------------------------------- Verify */
SELECT m.MenuItemId, m.ParentMenuItemId, m.MenuName, m.ControllerName, m.ActionName,
       m.IconClass, m.MenuOrder, m.IsDisabled, m.IsDeleted,
       (SELECT COUNT(*) FROM dbo.UserRoleMenu r WHERE r.MenuItemId = m.MenuItemId) AS RoleMappings
FROM dbo.MenuItems m
WHERE m.ControllerName = 'ReimbursementChat';
GO
