/* ============================================================================
   Adds the "Lab Master Configuration" menu item (LRNMaster.dbo.MenuItems).

   The page is LabSchemaController/Index: it maps a new lab's file columns onto
   the master Claim/Line schemas and generates that lab's schema JSON plus its
   landing-table DDL.

   Granted to Super Admin only. What the page emits decides how a lab's data is
   read from then on, and the DDL it produces runs against a lab database.

   RE-RUNNABLE.
   ============================================================================ */

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

BEGIN TRANSACTION;

BEGIN TRY
    DECLARE @MenuItemId   INT;
    DECLARE @AdminMenuId  INT;
    DECLARE @MenuOrder    INT;
    DECLARE @SuperAdminId INT;

    -- Sits under Admin, beside the other estate-wide screens.
    SELECT TOP (1) @AdminMenuId = MenuItemId
    FROM   dbo.MenuItems
    WHERE  ParentMenuItemId IS NULL
      AND  MenuName = 'Admin'
      AND  IsDeleted = 0
    ORDER  BY MenuItemId;

    SELECT @MenuOrder = ISNULL(MAX(MenuOrder), 0) + 1
    FROM   dbo.MenuItems
    WHERE  ParentMenuItemId = @AdminMenuId AND IsDeleted = 0;

    SELECT TOP (1) @MenuItemId = MenuItemId
    FROM   dbo.MenuItems
    WHERE  ControllerName = 'LabSchema' AND ActionName = 'Index'
    ORDER  BY MenuItemId;

    IF @MenuItemId IS NULL
    BEGIN
        INSERT INTO dbo.MenuItems
            (ParentMenuItemId, MenuName, ControllerName, ActionName, AreaName,
             IconClass, MenuOrder, IsDisabled, IsDeleted, CreatedBy, CreatedOn)
        VALUES
            (@AdminMenuId, 'Lab Master Configuration', 'LabSchema', 'Index', NULL,
             'bi-diagram-3', @MenuOrder, 0, 0, 'system', SYSUTCDATETIME());

        SET @MenuItemId = SCOPE_IDENTITY();
        PRINT 'MenuItem created for LabSchema/Index (MenuItemId ' + CAST(@MenuItemId AS VARCHAR(12)) + ').';
    END
    ELSE
    BEGIN
        UPDATE dbo.MenuItems
        SET    MenuName         = 'Lab Master Configuration',
               ParentMenuItemId = @AdminMenuId,
               IconClass        = 'bi-diagram-3',
               IsDisabled       = 0,
               IsDeleted        = 0
        WHERE  MenuItemId = @MenuItemId;

        PRINT 'MenuItem restored/updated for LabSchema/Index (MenuItemId ' + CAST(@MenuItemId AS VARCHAR(12)) + ').';
    END

    -- Super Admin only. Deliberately NOT granted to Lab Admin: this screen defines how a lab's
    -- data is read and emits DDL, which is estate-wide authority.
    SELECT TOP (1) @SuperAdminId = RoleID
    FROM   dbo.Roles
    WHERE  RoleName IN ('Super Admin', 'SuperAdmin', 'Admin')
    ORDER  BY CASE RoleName WHEN 'Super Admin' THEN 0 ELSE 1 END, RoleID;

    IF @SuperAdminId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dbo.UserRoleMenu
                       WHERE RoleId = @SuperAdminId AND MenuItemId = @MenuItemId)
    BEGIN
        INSERT INTO dbo.UserRoleMenu (RoleId, MenuItemId) VALUES (@SuperAdminId, @MenuItemId);
        PRINT 'Granted to Super Admin.';
    END

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH
GO

SELECT m.MenuItemId, m.ParentMenuItemId, m.MenuName, m.ControllerName, m.ActionName, m.MenuOrder
FROM   dbo.MenuItems m
WHERE  m.ControllerName = 'LabSchema';
GO
