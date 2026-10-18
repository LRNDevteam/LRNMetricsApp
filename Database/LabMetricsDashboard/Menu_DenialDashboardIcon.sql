-- Gives the Denial Dashboard navbar item an icon that says what the screen is.
--
-- It shipped with bi-exclamation-triangle-fill — a generic warning triangle that reads as
-- "something is wrong with this menu" rather than "denied claims", and that is the same
-- glyph the rest of the app uses for genuine error states. bi-clipboard2-x-fill is a claim
-- form with a cross on it: denials, at a glance, and distinct from the Denial Workflow
-- board beside it (bi-kanban-fill).
--
-- Menu rows live in the database, so the matching change in DynamicMenu_Setup.sql only
-- reaches a fresh install. This script updates one that is already seeded.
--
-- Idempotent: safe to run more than once.
-- Menus are cached for 30 minutes in MenuService — recycle the dashboard app or save any
-- Menu Master screen afterwards to flush the cache.
USE LRNMaster;
GO

-- dbo.MenuItems carries a filtered index, so writes require these ON. SSMS sets them by
-- default but sqlcmd does not — without this the UPDATE fails with Msg 1934.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-- Only the untouched original is replaced: an admin who has already chosen an icon in
-- Admin > Menu Master keeps it.
UPDATE dbo.MenuItems
SET IconClass  = 'bi-clipboard2-x-fill',
    ModifiedBy = 'system',
    ModifiedOn = SYSUTCDATETIME()
WHERE ControllerName = 'DenialDashboard'
  AND ActionName     = 'Index'
  AND IsDeleted      = 0
  AND IconClass      = 'bi-exclamation-triangle-fill';

PRINT CAST(@@ROWCOUNT AS VARCHAR(12)) + ' Denial Dashboard menu row(s) re-iconed.';
GO

/* ------------------------------------------------------------------- Verify */
SELECT MenuItemId, ParentMenuItemId, MenuName, ControllerName, ActionName,
       IconClass, MenuOrder, IsDisabled, IsDeleted
FROM dbo.MenuItems
WHERE ControllerName = 'DenialDashboard';
GO
