-- Adds "Email Log" (Admin/EmailLog) to the Admin menu: every email the system sends, filterable
-- by mail type, sortable, newest first. Data: dbo.EmailLog (Database/LRN.ReportsApi/UserMail_Setup.sql).
--
-- Placed beside "Manage Users" (Admin/ListUsers) wherever that lives. No role mappings are seeded:
-- the page is restricted to Admin / Super Admin / LRN Admin in code ([Authorize(FullAdmin)]), and
-- those roles bypass menu mapping, so mapping other roles would only show them a link they cannot open.
--
-- Idempotent: safe to run more than once.
-- Menus are cached for 30 minutes in MenuService — recycle the dashboard app or save any
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
      AND ActionName     = 'ListUsers'
      AND IsDeleted      = 0
    ORDER BY MenuItemId;

    -- No Manage Users item: fall back to the Admin parent by name, then to top level.
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
      AND ActionName     = 'EmailLog'
    ORDER BY MenuItemId;

    IF @MenuItemId IS NULL
    BEGIN
        INSERT INTO dbo.MenuItems
            (ParentMenuItemId, MenuName, ControllerName, ActionName, AreaName,
             IconClass, MenuOrder, IsDisabled, IsDeleted, CreatedBy, CreatedOn)
        VALUES
            (@ParentId, 'Email Log', 'Admin', 'EmailLog', NULL,
             'bi-envelope-paper', @MenuOrder, 0, 0, 'system', SYSUTCDATETIME());

        SET @MenuItemId = SCOPE_IDENTITY();
        PRINT 'MenuItem created for Admin/EmailLog (MenuItemId ' + CAST(@MenuItemId AS VARCHAR(12)) + ').';
    END
    ELSE
    BEGIN
        UPDATE dbo.MenuItems
        SET MenuName   = 'Email Log',
            IconClass  = 'bi-envelope-paper',
            IsDeleted  = 0,
            IsDisabled = 0,
            ModifiedBy = 'system',
            ModifiedOn = SYSUTCDATETIME()
        WHERE MenuItemId = @MenuItemId;

        PRINT 'MenuItem ' + CAST(@MenuItemId AS VARCHAR(12)) + ' refreshed for Admin/EmailLog.';
    END

    COMMIT TRANSACTION;
    PRINT 'Email Log menu migration committed.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'Email Log menu migration rolled back: ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

/* ------------------------------------------------------------------- Verify */
SELECT m.MenuItemId, m.ParentMenuItemId, m.MenuName, m.ControllerName, m.ActionName, m.IconClass, m.MenuOrder, m.IsDisabled, m.IsDeleted
FROM dbo.MenuItems m
WHERE m.ControllerName = 'Admin' AND m.ActionName = 'EmailLog';
GO
