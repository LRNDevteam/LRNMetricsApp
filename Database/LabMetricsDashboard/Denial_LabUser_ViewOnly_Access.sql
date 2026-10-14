-- Grants the "Lab User" role view-only access to the Denial Workflow application.
--
-- What this role gets (enforced in code, not here):
--   * The Denial Workflow navbar link, opening the React app.
--   * Denial Dashboard, Aging Dashboard, and the Claim View queues
--     (New, Unassigned, Assigned, Closed, All Claims) for their assigned labs.
--   * Excel/CSV export of that claim data - exporting is reading.
--
-- What it cannot do:
--   * Any write at all. LRN.ReportsApi's DenialWorkflowController refuses every write
--     endpoint for this role (IsLabUserRole / DenyWriteForLabUser): assignment, task status,
--     comments, document upload and delete, escalations, escalation responses, verification
--     decisions, CSV upload and task import. Hiding the buttons is not the boundary - the API is.
--   * Escalation queues. A Lab User never acts on an escalation, so none is theirs to read.
--   * My Worklist. Nothing is ever assigned to them.
--
-- Role matching is on the normalised name containing "labuser", so "Lab User", "LabUser" and
-- "Lab-User" all resolve. Keep the role name recognisable as such or the code will not match it.
--
-- Lab scoping is NOT done here: a Lab User sees only the labs assigned to them in
-- Admin > Assign User Labs, the same as every other role. Assign labs there after running this.
--
-- Prerequisite: Menu_AddDenialWorkflow.sql must have run first, so the Denial Workflow menu
-- row exists to grant.
--
-- Idempotent: safe to run more than once.
-- Menus are cached for 30 minutes in MenuService - recycle the dashboard app or save any
-- Menu Master screen afterwards to flush the cache.
USE LRNMaster;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

BEGIN TRANSACTION;

BEGIN TRY
    DECLARE @RoleId             INT;
    DECLARE @DenialWorkflowId   INT;
    DECLARE @DenialDashboardId  INT;

    /* 1. The role itself. Created inactive-safe (IsActive = 1) so it shows up in
          Admin > Assign User Role and in Role Menu Mapping immediately. */
    SELECT TOP (1) @RoleId = RoleID
    FROM dbo.Roles
    WHERE REPLACE(REPLACE(RoleName, ' ', ''), '-', '') = 'LabUser'
    ORDER BY RoleID;

    IF @RoleId IS NULL
    BEGIN
        INSERT INTO dbo.Roles (RoleName, IsActive, CreatedBy)
        VALUES ('Lab User', 1, 'system');

        SET @RoleId = SCOPE_IDENTITY();
        PRINT 'Created role "Lab User" (RoleID ' + CAST(@RoleId AS VARCHAR(12)) + ').';
    END
    ELSE
    BEGIN
        UPDATE dbo.Roles SET IsActive = 1 WHERE RoleID = @RoleId AND ISNULL(IsActive, 0) = 0;
        PRINT 'Role "Lab User" already exists (RoleID ' + CAST(@RoleId AS VARCHAR(12)) + ').';
    END

    /* 2. Menu access: the Denial Workflow link (the React app) and the Denial Dashboard
          it sits beside. Both are read-only screens for this role. */
    SELECT TOP (1) @DenialWorkflowId = MenuItemId
    FROM dbo.MenuItems
    WHERE ControllerName = 'DenialWorkflow' AND ActionName = 'Index' AND IsDeleted = 0
    ORDER BY MenuItemId;

    SELECT TOP (1) @DenialDashboardId = MenuItemId
    FROM dbo.MenuItems
    WHERE ControllerName = 'DenialDashboard' AND ActionName = 'Index' AND IsDeleted = 0
    ORDER BY MenuItemId;

    IF @DenialWorkflowId IS NULL
        PRINT 'WARNING: Denial Workflow menu row not found. Run Menu_AddDenialWorkflow.sql first, '
            + 'then re-run this script - otherwise the role has no navbar link to the app.';

    INSERT INTO dbo.UserRoleMenu (RoleId, MenuItemId, CreatedBy)
    SELECT @RoleId, m.MenuItemId, 'system'
    FROM dbo.MenuItems m
    WHERE m.MenuItemId IN (@DenialWorkflowId, @DenialDashboardId)
      AND m.IsDeleted = 0
      AND NOT EXISTS (SELECT 1 FROM dbo.UserRoleMenu x
                      WHERE x.RoleId = @RoleId AND x.MenuItemId = m.MenuItemId);

    PRINT CAST(@@ROWCOUNT AS VARCHAR(12)) + ' menu mapping(s) granted to "Lab User".';

    COMMIT TRANSACTION;
    PRINT 'Lab User view-only access committed.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'Lab User view-only access rolled back: ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

/* ------------------------------------------------------------------- Verify */
SELECT r.RoleID, r.RoleName, r.IsActive,
       m.MenuItemId, m.MenuName, m.ControllerName, m.ActionName
FROM dbo.Roles r
LEFT JOIN dbo.UserRoleMenu rm ON rm.RoleId = r.RoleID
LEFT JOIN dbo.MenuItems    m  ON m.MenuItemId = rm.MenuItemId AND m.IsDeleted = 0
WHERE REPLACE(REPLACE(r.RoleName, ' ', ''), '-', '') = 'LabUser'
ORDER BY m.MenuOrder, m.MenuName;
GO
