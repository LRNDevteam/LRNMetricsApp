/* ============================================================================
   Super Admin + Lab Admin roles (LRNMaster).

   1. Renames the existing "Admin" role IN PLACE to "Super Admin". The RoleID is
      untouched, so every dbo.UserRoles row and every UserRoleMenu grant still
      points at it and no existing administrator has to be reassigned. The app
      still accepts the old spelling from already-issued cookies - see
      Services/Security/AppRoles.cs - so a signed-in admin is not locked out
      between this script running and their next login.

   2. Adds "Lab Admin": administers users, but only inside the labs it has been
      assigned in dbo.UserLabs. The scoping is enforced in AdminController, not
      here; this script only creates the role and grants it the user-management
      menus.

   RE-RUNNABLE. Running it twice changes nothing the second time.
   ============================================================================ */

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

BEGIN TRANSACTION;

BEGIN TRY
    DECLARE @SuperAdminRoleId INT;
    DECLARE @LabAdminRoleId   INT;

    /* ── 1. Admin -> Super Admin ─────────────────────────────────────────── */
    SELECT TOP (1) @SuperAdminRoleId = RoleID
    FROM   dbo.Roles
    WHERE  RoleName IN ('Super Admin', 'SuperAdmin', 'Admin')
    ORDER  BY CASE RoleName WHEN 'Admin' THEN 0 ELSE 1 END, RoleID;

    IF @SuperAdminRoleId IS NULL
    BEGIN
        INSERT INTO dbo.Roles (RoleName, IsActive, CreatedDate, CreatedBy)
        VALUES ('Super Admin', 1, SYSUTCDATETIME(), 'system');

        SET @SuperAdminRoleId = SCOPE_IDENTITY();
        PRINT 'Created role "Super Admin" (RoleID ' + CAST(@SuperAdminRoleId AS VARCHAR(12)) + ').';
    END
    ELSE
    BEGIN
        UPDATE dbo.Roles
        SET    RoleName     = 'Super Admin',
               IsActive     = 1,
               ModifiedDate = SYSUTCDATETIME(),
               ModifiedBy   = 'system'
        WHERE  RoleID = @SuperAdminRoleId
          AND  RoleName <> 'Super Admin';

        PRINT 'Role ' + CAST(@SuperAdminRoleId AS VARCHAR(12)) + ' is now "Super Admin" ('
              + CAST(@@ROWCOUNT AS VARCHAR(12)) + ' row(s) renamed).';
    END

    /* ── 2. Lab Admin ────────────────────────────────────────────────────── */
    SELECT TOP (1) @LabAdminRoleId = RoleID
    FROM   dbo.Roles
    WHERE  RoleName IN ('Lab Admin', 'LabAdmin')
    ORDER  BY RoleID;

    IF @LabAdminRoleId IS NULL
    BEGIN
        INSERT INTO dbo.Roles (RoleName, IsActive, CreatedDate, CreatedBy)
        VALUES ('Lab Admin', 1, SYSUTCDATETIME(), 'system');

        SET @LabAdminRoleId = SCOPE_IDENTITY();
        PRINT 'Created role "Lab Admin" (RoleID ' + CAST(@LabAdminRoleId AS VARCHAR(12)) + ').';
    END
    ELSE
    BEGIN
        UPDATE dbo.Roles
        SET    RoleName = 'Lab Admin', IsActive = 1,
               ModifiedDate = SYSUTCDATETIME(), ModifiedBy = 'system'
        WHERE  RoleID = @LabAdminRoleId;

        PRINT 'Role "Lab Admin" already existed (RoleID ' + CAST(@LabAdminRoleId AS VARCHAR(12)) + ').';
    END

    /* ── 3. Menus for Lab Admin ──────────────────────────────────────────────
       The user-management screens plus the Admin parent they hang under - a
       child menu whose parent is not granted never renders. Deliberately NOT
       granted: Manage Labs, Menu Master, Role Menu Mapping, Roles and the
       Master Values screens, which are estate-wide and belong to Super Admin. */
    INSERT INTO dbo.UserRoleMenu (RoleId, MenuItemId)
    SELECT @LabAdminRoleId, m.MenuItemId
    FROM   dbo.MenuItems AS m
    WHERE  m.IsDeleted = 0
      AND  (
             (m.ControllerName = 'Admin' AND m.ActionName IN ('ListUsers', 'CreateUser', 'AssignUserLabs', 'AssignUserRole'))
             OR (m.ParentMenuItemId IS NULL AND m.MenuName = 'Admin')
           )
      AND  NOT EXISTS (SELECT 1
                       FROM   dbo.UserRoleMenu AS existing
                       WHERE  existing.RoleId     = @LabAdminRoleId
                         AND  existing.MenuItemId = m.MenuItemId);

    PRINT CAST(@@ROWCOUNT AS VARCHAR(12)) + ' menu grant(s) added for Lab Admin.';

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH
GO

SELECT r.RoleID, r.RoleName, r.IsActive,
       (SELECT COUNT(*) FROM dbo.UserRoles  ur WHERE ur.RoleID = r.RoleID) AS Users,
       (SELECT COUNT(*) FROM dbo.UserRoleMenu rm WHERE rm.RoleId = r.RoleID) AS Menus
FROM   dbo.Roles AS r
WHERE  r.RoleName IN ('Super Admin', 'Lab Admin')
ORDER  BY r.RoleID;
GO
