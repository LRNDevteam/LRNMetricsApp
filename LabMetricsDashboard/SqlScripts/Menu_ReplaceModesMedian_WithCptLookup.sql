-- Analytics menu: replace the two "Modes" and "Median" list pages with the single
-- "CPT & Panel Lookup" screen (Analytics/CptLookup).
--
-- Both old pages were removed from the dashboard; their data now appears as the
-- Mode/Median rate columns on the CPT tab of the new screen.
--
-- The existing "Modes" row (MenuItemId 31) is REPOINTED rather than deleted so the
-- role mappings in dbo.UserRoleMenu survive — every role that could see Modes can
-- see the new page with no re-mapping. The "Median" row (32) is soft-deleted and
-- its mapping removed, since it no longer has a page behind it.
--
-- Idempotent: safe to run more than once.
-- Menus are cached for 30 minutes in MenuService — recycle the dashboard app or
-- save any Menu Master screen afterwards to flush the cache.
USE LRNMaster;
GO

-- dbo.MenuItems carries a filtered index, so writes require these ON. SSMS sets them
-- by default but sqlcmd does not — without this the UPDATE fails with Msg 1934.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

BEGIN TRANSACTION;

BEGIN TRY
    -- 1. Repoint "Modes" -> "CPT & Panel Lookup"
    IF EXISTS (SELECT 1 FROM dbo.MenuItems WHERE MenuItemId = 31 AND ControllerName = 'Analytics')
    BEGIN
        UPDATE dbo.MenuItems
        SET MenuName   = 'CPT & Panel Lookup',
            ActionName = 'CptLookup',
            IconClass  = 'bi-search',
            IsDeleted  = 0,
            IsDisabled = 0,
            ModifiedBy = 'system',
            ModifiedOn = SYSUTCDATETIME()
        WHERE MenuItemId = 31;

        PRINT 'MenuItem 31 repointed to Analytics/CptLookup.';
    END
    ELSE
    BEGIN
        -- Fresh install / row already gone: create it under the Analytics parent (11).
        IF NOT EXISTS (SELECT 1 FROM dbo.MenuItems
                       WHERE ControllerName = 'Analytics' AND ActionName = 'CptLookup' AND IsDeleted = 0)
        BEGIN
            INSERT INTO dbo.MenuItems
                (ParentMenuItemId, MenuName, ControllerName, ActionName, AreaName,
                 IconClass, MenuOrder, IsDisabled, IsDeleted, CreatedBy, CreatedOn)
            VALUES
                (11, 'CPT & Panel Lookup', 'Analytics', 'CptLookup', NULL,
                 'bi-search', 6, 0, 0, 'system', SYSUTCDATETIME());

            PRINT 'MenuItem for Analytics/CptLookup created.';
        END
    END

    -- 2. Retire "Median" — the page behind it no longer exists.
    IF EXISTS (SELECT 1 FROM dbo.MenuItems WHERE MenuItemId = 32 AND ActionName = 'Median' AND IsDeleted = 0)
    BEGIN
        UPDATE dbo.MenuItems
        SET IsDeleted  = 1,
            ModifiedBy = 'system',
            ModifiedOn = SYSUTCDATETIME()
        WHERE MenuItemId = 32;

        DELETE FROM dbo.UserRoleMenu WHERE MenuItemId = 32;

        PRINT 'MenuItem 32 (Median) soft-deleted and its role mappings removed.';
    END
    ELSE
        PRINT 'MenuItem 32 (Median) already retired — no change.';

    -- 3. Any other stale Analytics/Modes or Analytics/Median rows (defensive).
    UPDATE dbo.MenuItems
    SET IsDeleted  = 1,
        ModifiedBy = 'system',
        ModifiedOn = SYSUTCDATETIME()
    WHERE ControllerName = 'Analytics'
      AND ActionName IN ('Modes', 'Median')
      AND IsDeleted = 0;

    COMMIT TRANSACTION;
    PRINT 'Menu migration committed.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'Menu migration rolled back: ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

/* ------------------------------------------------------------------- Verify */
SELECT m.MenuItemId, m.ParentMenuItemId, m.MenuName, m.ControllerName, m.ActionName,
       m.IconClass, m.MenuOrder, m.IsDisabled, m.IsDeleted,
       (SELECT COUNT(*) FROM dbo.UserRoleMenu r WHERE r.MenuItemId = m.MenuItemId) AS RoleMappings
FROM dbo.MenuItems m
WHERE m.ControllerName = 'Analytics'
ORDER BY m.MenuOrder, m.MenuItemId;
GO
