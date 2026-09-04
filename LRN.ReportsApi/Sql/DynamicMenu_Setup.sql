/* ============================================================================
   LRNMetrics - Dynamic Role-Based Menu Management Setup
   Target database: LRNMaster (DefaultConnection)

   Creates:
     dbo.MenuItems         - menu master (2-level: parent -> submenu)
     dbo.UserRoleMenu      - role -> menu mapping (FK to dbo.Roles)
     dbo.RoleFeatureAccess - role -> screen element toggles (header icons and other
                             UI that is not a navbar menu item)
     dbo.usp_GetMenusForRole - menu fetch per role (date-window filtered)

   Seeds the menu tree matching the current LRN Metrics navbar and grants
   every menu to the Admin role (default script for admin user access).

   The script is idempotent - safe to run multiple times.
   ============================================================================ */

SET NOCOUNT ON;

/* ── 1. dbo.MenuItems ─────────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.MenuItems', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.MenuItems
    (
        MenuItemId        INT IDENTITY(1,1)  NOT NULL CONSTRAINT PK_MenuItems PRIMARY KEY,
        ParentMenuItemId  INT                NULL,      -- NULL = top-level menu
        MenuName          NVARCHAR(100)      NOT NULL,
        ControllerName    NVARCHAR(100)      NULL,      -- NULL allowed for grouping-only parents
        ActionName        NVARCHAR(100)      NULL,
        AreaName          NVARCHAR(100)      NULL,      -- optional MVC Area
        IconClass         NVARCHAR(100)      NULL,      -- e.g. 'bi-speedometer2'
        IconImagePath     NVARCHAR(300)      NULL,      -- optional uploaded image fallback
        MenuOrder         INT                NOT NULL CONSTRAINT DF_MenuItems_Order DEFAULT(0),
        ActiveFrom        DATE               NULL,      -- NULL = no start restriction
        ActiveTo          DATE               NULL,      -- NULL = no end restriction (forever)
        IsDisabled        BIT                NOT NULL CONSTRAINT DF_MenuItems_Disabled DEFAULT(0),
        IsDeleted         BIT                NOT NULL CONSTRAINT DF_MenuItems_Deleted DEFAULT(0),
        CreatedBy         NVARCHAR(100)      NOT NULL CONSTRAINT DF_MenuItems_CreatedBy DEFAULT(N'system'),
        CreatedOn         DATETIME2(0)       NOT NULL CONSTRAINT DF_MenuItems_CreatedOn DEFAULT(SYSDATETIME()),
        ModifiedBy        NVARCHAR(100)      NULL,
        ModifiedOn        DATETIME2(0)       NULL,

        CONSTRAINT FK_MenuItems_Parent
            FOREIGN KEY (ParentMenuItemId) REFERENCES dbo.MenuItems(MenuItemId),
        CONSTRAINT CK_MenuItems_DateRange
            CHECK (ActiveFrom IS NULL OR ActiveTo IS NULL OR ActiveFrom <= ActiveTo),
        CONSTRAINT CK_MenuItems_NotOwnParent
            CHECK (ParentMenuItemId IS NULL OR ParentMenuItemId <> MenuItemId)
    );

    PRINT 'Created table dbo.MenuItems';
END

/* One name per level - siblings cannot share a name (soft-deleted rows excluded) */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_MenuItems_Name_PerParent' AND object_id = OBJECT_ID(N'dbo.MenuItems'))
BEGIN
    CREATE UNIQUE INDEX UX_MenuItems_Name_PerParent
        ON dbo.MenuItems (ParentMenuItemId, MenuName)
        WHERE IsDeleted = 0;
END

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_MenuItems_Parent_Order' AND object_id = OBJECT_ID(N'dbo.MenuItems'))
BEGIN
    CREATE INDEX IX_MenuItems_Parent_Order
        ON dbo.MenuItems (ParentMenuItemId, MenuOrder)
        INCLUDE (MenuName, ControllerName, ActionName, IconClass, IsDisabled, ActiveFrom, ActiveTo)
        WHERE IsDeleted = 0;
END

/* ── 2. dbo.UserRoleMenu ──────────────────────────────────────────────────── */
IF OBJECT_ID(N'dbo.UserRoleMenu', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.UserRoleMenu
    (
        UserRoleMenuId  INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_UserRoleMenu PRIMARY KEY,
        RoleId          INT               NOT NULL,
        MenuItemId      INT               NOT NULL,
        CreatedBy       NVARCHAR(100)     NOT NULL CONSTRAINT DF_UserRoleMenu_CreatedBy DEFAULT(N'system'),
        CreatedOn       DATETIME2(0)      NOT NULL CONSTRAINT DF_UserRoleMenu_CreatedOn DEFAULT(SYSDATETIME()),

        CONSTRAINT FK_UserRoleMenu_Role FOREIGN KEY (RoleId)     REFERENCES dbo.Roles(RoleID),
        CONSTRAINT FK_UserRoleMenu_Menu FOREIGN KEY (MenuItemId) REFERENCES dbo.MenuItems(MenuItemId),
        CONSTRAINT UX_UserRoleMenu UNIQUE (RoleId, MenuItemId)
    );

    CREATE INDEX IX_UserRoleMenu_Role ON dbo.UserRoleMenu (RoleId) INCLUDE (MenuItemId);

    PRINT 'Created table dbo.UserRoleMenu';
END

/* ── 2b. dbo.RoleFeatureAccess ────────────────────────────────────────────
   Screen elements that are NOT navbar menu items (the reimbursement chat icon in
   the header, the shortcut inside the help chat bubble) and so cannot be granted
   through dbo.UserRoleMenu. A missing row means "not decided": the application
   falls back to the role's menu access, which is the pre-existing behaviour.
   FeatureKey values are defined in LRN.ReportsApi MenuFeatureCatalog.           */
IF OBJECT_ID(N'dbo.RoleFeatureAccess', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RoleFeatureAccess
    (
        RoleFeatureAccessId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_RoleFeatureAccess PRIMARY KEY,
        RoleId              INT               NOT NULL,
        FeatureKey          NVARCHAR(100)     NOT NULL,
        IsEnabled           BIT               NOT NULL CONSTRAINT DF_RoleFeatureAccess_Enabled DEFAULT(1),
        CreatedBy           NVARCHAR(100)     NOT NULL CONSTRAINT DF_RoleFeatureAccess_CreatedBy DEFAULT(N'system'),
        CreatedOn           DATETIME2(0)      NOT NULL CONSTRAINT DF_RoleFeatureAccess_CreatedOn DEFAULT(SYSDATETIME()),
        ModifiedBy          NVARCHAR(100)     NULL,
        ModifiedOn          DATETIME2(0)      NULL,

        CONSTRAINT FK_RoleFeatureAccess_Role FOREIGN KEY (RoleId) REFERENCES dbo.Roles(RoleID),
        CONSTRAINT UX_RoleFeatureAccess UNIQUE (RoleId, FeatureKey)
    );

    PRINT 'Created table dbo.RoleFeatureAccess';
END

/* ── 3. Seed menu items (matches the current LRN Metrics navbar) ─────────── */
IF NOT EXISTS (SELECT 1 FROM dbo.MenuItems)
BEGIN
    SET IDENTITY_INSERT dbo.MenuItems ON;

    INSERT dbo.MenuItems (MenuItemId, ParentMenuItemId, MenuName, ControllerName, ActionName, IconClass, MenuOrder, IsDisabled, CreatedBy)
    VALUES
     -- Top level
     (1,  NULL, N'Home',                          N'Home',              N'Index',                       N'bi-house-door-fill',            1, 0, N'system'),
     (2,  NULL, N'Revenue Dashboard',             N'Dashboard',         N'Index',                       N'bi-speedometer2',               2, 0, N'system'),
     (3,  NULL, N'Standard Reports',              NULL,                 NULL,                           N'bi-file-earmark-bar-graph',     3, 0, N'system'),
     (10, NULL, N'Denial Dashboard',              N'DenialDashboard',   N'Index',                       N'bi-exclamation-triangle-fill',  4, 0, N'system'),
     (11, NULL, N'Analytics',                     NULL,                 NULL,                           N'bi-graph-up-arrow',             5, 0, N'system'),
     (17, NULL, N'Master Values',                 NULL,                 NULL,                           N'bi-database-gear',              6, 0, N'system'),
     (23, NULL, N'Admin',                         NULL,                 NULL,                           N'bi-shield-lock',                7, 0, N'system'),

     -- Standard Reports children
     (4,  3,    N'LIS Summary',                   N'LisSummary',        N'Index',                       N'bi-clipboard2-pulse-fill',      1, 0, N'system'),
     (5,  3,    N'Production Summary Report',     N'Dashboard',         N'ProductionSummaryReport',     N'bi-bar-chart-steps',            2, 0, N'system'),
     (6,  3,    N'Collection Summary',            N'CollectionSummary', N'Index',                       N'bi-cash-stack',                 3, 0, N'system'),
     (7,  3,    N'Executive Summary',             N'ExecutiveSummary',  N'Index',                       N'bi-table',                      4, 0, N'system'),
     (8,  3,    N'Claim Level Details',           N'Dashboard',         N'ClaimLevel',                  N'bi-file-text',                  5, 0, N'system'),
     (9,  3,    N'Line Level Details',            N'Dashboard',         N'LineLevel',                   N'bi-list-ul',                    6, 0, N'system'),

     -- Analytics children
     (12, 11,   N'Prediction Analysis',           N'Prediction',        N'Index',                       N'bi-activity',                   1, 0, N'system'),
     (13, 11,   N'Forecasting Summary',           N'Prediction',        N'ForecastingSummary',          N'bi-calendar3',                  2, 0, N'system'),
     (14, 11,   N'Coding Summary',                N'Coding',            N'Summary',                     N'bi-pencil-square',              3, 0, N'system'),
     (15, 11,   N'Clinic Summary',                N'Dashboard',         N'ClinicSummary',               N'bi-hospital',                   4, 0, N'system'),
     (16, 11,   N'Sales Rep Summary',             N'Dashboard',         N'SalesRepSummary',             N'bi-people-fill',                5, 0, N'system'),

     -- Master Values children
     (18, 17,   N'Lab Insurance Master',          N'MasterValues',      N'InsurancePayerMaster',        N'bi-building-check',             1, 0, N'system'),
     (19, 17,   N'Payer Policy Insurance Master', N'MasterValues',      N'PayerPolicyInsuranceMaster',  N'bi-file-earmark-medical',       2, 0, N'system'),
     (20, 17,   N'Approval Queue',                N'MasterValues',      N'ApprovalQueue',               N'bi-check2-square',              3, 0, N'system'),
     (21, 17,   N'Audit Trail',                   N'MasterValues',      N'AuditTrail',                  N'bi-clock-history',              4, 0, N'system'),
     (22, 17,   N'Notifications',                 N'MasterValues',      N'PayerMasterNotifications',    N'bi-bell',                       5, 0, N'system'),

     -- Admin children
     (24, 23,   N'Manage Users',                  N'Admin',             N'ListUsers',                   N'bi-people',                     1, 0, N'system'),
     (25, 23,   N'Assign User Role',              N'Admin',             N'AssignUserRole',              N'bi-person-badge',               2, 0, N'system'),
     (26, 23,   N'Assign User Labs',              N'Admin',             N'AssignUserLabs',              N'bi-building',                   3, 0, N'system'),
     (27, 23,   N'Roles',                         N'Admin',             N'Roles',                       N'bi-shield-check',               4, 0, N'system'),
     (28, 23,   N'Manage Labs',                   N'Admin',             N'ManageLabs',                  N'bi-buildings',                  5, 0, N'system'),
     (29, 23,   N'Menu Master',                   N'Admin',             N'MenuMaster',                  N'bi-list-nested',                6, 0, N'system'),
     (30, 23,   N'Role Menu Mapping',             N'Admin',             N'RoleMenuMapping',             N'bi-person-gear',                7, 0, N'system');

    SET IDENTITY_INSERT dbo.MenuItems OFF;

    PRINT 'Seeded dbo.MenuItems with the default navbar menus';
END

/* ── 3b. Analytics reference lists: Modes & Meridian (idempotent add) ──────
   Runs for both fresh installs (after the seed above) and existing databases. */
DECLARE @AnalyticsId INT =
    (SELECT MenuItemId FROM dbo.MenuItems
     WHERE MenuName = N'Analytics' AND ParentMenuItemId IS NULL AND IsDeleted = 0);

IF @AnalyticsId IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.MenuItems
                   WHERE ParentMenuItemId = @AnalyticsId AND MenuName = N'Modes' AND IsDeleted = 0)
    BEGIN
        INSERT dbo.MenuItems (ParentMenuItemId, MenuName, ControllerName, ActionName, IconClass, MenuOrder, IsDisabled, CreatedBy)
        VALUES (@AnalyticsId, N'Modes', N'Analytics', N'Modes', N'bi-bar-chart-line', 6, 0, N'system');
        PRINT 'Added Analytics > Modes menu item';
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.MenuItems
                   WHERE ParentMenuItemId = @AnalyticsId AND MenuName = N'Meridian' AND IsDeleted = 0)
    BEGIN
        INSERT dbo.MenuItems (ParentMenuItemId, MenuName, ControllerName, ActionName, IconClass, MenuOrder, IsDisabled, CreatedBy)
        VALUES (@AnalyticsId, N'Meridian', N'Analytics', N'Meridian', N'bi-graph-up', 7, 0, N'system');
        PRINT 'Added Analytics > Meridian menu item';
    END
END

/* ── 3c. Master Values: Report Audit Log (idempotent add) ─────────────────
   Report run status by RunId + downloadable run error log.                  */
DECLARE @MasterValuesId INT =
    (SELECT MenuItemId FROM dbo.MenuItems
     WHERE MenuName = N'Master Values' AND ParentMenuItemId IS NULL AND IsDeleted = 0);

IF @MasterValuesId IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM dbo.MenuItems
                   WHERE ParentMenuItemId = @MasterValuesId AND MenuName = N'Report Audit Log' AND IsDeleted = 0)
BEGIN
    INSERT dbo.MenuItems (ParentMenuItemId, MenuName, ControllerName, ActionName, IconClass, MenuOrder, IsDisabled, CreatedBy)
    VALUES (@MasterValuesId, N'Report Audit Log', N'MasterValues', N'ReportAuditLog', N'bi-journal-text', 6, 0, N'system');
    PRINT 'Added Master Values > Report Audit Log menu item';
END

/* ── 3c-2. Denial Workflow (idempotent add) ───────────────────────────────
   The screen itself is the separate React app; the menu row exists so the
   link can be granted per role in Admin > Role Menu Mapping and so it stops
   being hard-coded into the navbar for everyone. Placed directly after
   Denial Dashboard, which is where it has always rendered.

   Role access is seeded from Denial Dashboard so nobody loses the link on
   upgrade - review it in Admin > Role Menu Mapping afterwards.            */
DECLARE @DenialDashboardId INT =
    (SELECT TOP (1) MenuItemId FROM dbo.MenuItems
     WHERE ParentMenuItemId IS NULL AND ControllerName = N'DenialDashboard'
       AND ActionName = N'Index' AND IsDeleted = 0
     ORDER BY MenuItemId);

DECLARE @DenialWorkflowId INT =
    (SELECT TOP (1) MenuItemId FROM dbo.MenuItems
     WHERE ParentMenuItemId IS NULL AND ControllerName = N'DenialWorkflow'
       AND ActionName = N'Index'
     ORDER BY MenuItemId);

IF @DenialWorkflowId IS NULL
BEGIN
    INSERT dbo.MenuItems (ParentMenuItemId, MenuName, ControllerName, ActionName, IconClass, MenuOrder, IsDisabled, CreatedBy)
    VALUES (NULL, N'Denial Workflow', N'DenialWorkflow', N'Index', N'bi-kanban-fill',
            ISNULL((SELECT MenuOrder FROM dbo.MenuItems WHERE MenuItemId = @DenialDashboardId), 4), 0, N'system');

    SET @DenialWorkflowId = SCOPE_IDENTITY();
    PRINT 'Added Denial Workflow menu item';
END
ELSE
BEGIN
    /* Re-running after a soft delete or a disable should restore the link. */
    UPDATE dbo.MenuItems
    SET IsDeleted = 0, IsDisabled = 0, ModifiedBy = N'system', ModifiedOn = SYSDATETIME()
    WHERE MenuItemId = @DenialWorkflowId AND (IsDeleted = 1 OR IsDisabled = 1);
END

/* Denial Workflow sorts immediately after Denial Dashboard. Both share a MenuOrder;
   MenuService breaks the tie on MenuName, and "Denial Dashboard" < "Denial Workflow". */
IF @DenialDashboardId IS NOT NULL
BEGIN
    UPDATE dbo.MenuItems
    SET MenuOrder = (SELECT MenuOrder FROM dbo.MenuItems WHERE MenuItemId = @DenialDashboardId),
        ModifiedBy = N'system', ModifiedOn = SYSDATETIME()
    WHERE MenuItemId = @DenialWorkflowId
      AND MenuOrder <> (SELECT MenuOrder FROM dbo.MenuItems WHERE MenuItemId = @DenialDashboardId);

    INSERT dbo.UserRoleMenu (RoleId, MenuItemId, CreatedBy)
    SELECT src.RoleId, @DenialWorkflowId, N'system'
    FROM dbo.UserRoleMenu src
    WHERE src.MenuItemId = @DenialDashboardId
      AND NOT EXISTS (SELECT 1 FROM dbo.UserRoleMenu x
                      WHERE x.RoleId = src.RoleId AND x.MenuItemId = @DenialWorkflowId);

    PRINT 'Denial Workflow role access seeded from Denial Dashboard';
END

/* ── 3d. Report Board - the landing/home page (replaces Revenue Dashboard) ──
   Report Control Board: every report of each lab's latest run, from the workflow
   tracker. MenuOrder 0 puts it first; MenuService sorts roots by MenuOrder.

   Matched by controller/action (not name) so it upgrades an existing "Home Dashboard"
   row to "Report Board" in place instead of creating a duplicate. Granted to EVERY
   role (landing page); the page itself limits each user to the labs on their claims. */
IF EXISTS (SELECT 1 FROM dbo.MenuItems
           WHERE ParentMenuItemId IS NULL AND ControllerName = N'ReportBoard' AND ActionName = N'Index' AND IsDeleted = 0)
BEGIN
    UPDATE dbo.MenuItems
    SET MenuName = N'Report Board', MenuOrder = 0, ModifiedBy = N'system', ModifiedOn = SYSDATETIME()
    WHERE ParentMenuItemId IS NULL AND ControllerName = N'ReportBoard' AND ActionName = N'Index' AND IsDeleted = 0
      AND (MenuName <> N'Report Board' OR MenuOrder <> 0);
END
ELSE
BEGIN
    INSERT dbo.MenuItems (ParentMenuItemId, MenuName, ControllerName, ActionName, IconClass, MenuOrder, IsDisabled, CreatedBy)
    VALUES (NULL, N'Report Board', N'ReportBoard', N'Index', N'bi-grid-3x3-gap-fill', 0, 0, N'system');
    PRINT 'Added Report Board (Report Control Board) menu item';
END

INSERT dbo.UserRoleMenu (RoleId, MenuItemId, CreatedBy)
SELECT r.RoleID, m.MenuItemId, N'system'
FROM dbo.Roles r
CROSS JOIN dbo.MenuItems m
WHERE m.ParentMenuItemId IS NULL AND m.ControllerName = N'ReportBoard' AND m.ActionName = N'Index' AND m.IsDeleted = 0
  AND NOT EXISTS (SELECT 1 FROM dbo.UserRoleMenu x
                  WHERE x.RoleId = r.RoleID AND x.MenuItemId = m.MenuItemId);

/* Remove the top-level "Revenue Dashboard" link (Dashboard/Index). Soft delete only:
   the Dashboard page/controller stays, and the report pages under Standard Reports
   (Claim Level, Line Level, Production Summary, etc.) are unaffected. */
UPDATE dbo.MenuItems
SET IsDeleted = 1, ModifiedBy = N'system', ModifiedOn = SYSDATETIME()
WHERE ParentMenuItemId IS NULL AND ControllerName = N'Dashboard' AND ActionName = N'Index' AND IsDeleted = 0;
PRINT 'Report Board set as landing menu; Revenue Dashboard link removed (page kept).';

/* ── 4. Default access: grant EVERY menu to the Admin role ────────────────
   Re-runnable: newly added menu items are granted to Admin on each run.     */
INSERT dbo.UserRoleMenu (RoleId, MenuItemId, CreatedBy)
SELECT r.RoleID, m.MenuItemId, N'system'
FROM dbo.Roles r
CROSS JOIN dbo.MenuItems m
WHERE r.RoleName IN (N'Admin', N'LRN Admin', N'LRNAdmin')
  AND m.IsDeleted = 0
  AND NOT EXISTS (SELECT 1 FROM dbo.UserRoleMenu x
                  WHERE x.RoleId = r.RoleID AND x.MenuItemId = m.MenuItemId);

PRINT 'Granted all menus to the Admin role(s)';
GO

/* ── 5. Menu fetch per role (date-window filtered) ────────────────────────── */
CREATE OR ALTER PROCEDURE dbo.usp_GetMenusForRole
    @RoleId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(SYSDATETIME() AS DATE);

    SELECT  m.MenuItemId, m.ParentMenuItemId, m.MenuName,
            m.ControllerName, m.ActionName, m.AreaName,
            m.IconClass, m.IconImagePath, m.MenuOrder, m.IsDisabled
    FROM    dbo.MenuItems m
    INNER JOIN dbo.UserRoleMenu rm
            ON rm.MenuItemId = m.MenuItemId AND rm.RoleId = @RoleId
    WHERE   m.IsDeleted = 0
      AND  (m.ActiveFrom IS NULL OR m.ActiveFrom <= @Today)
      AND  (m.ActiveTo   IS NULL OR m.ActiveTo   >= @Today)
    ORDER BY ISNULL(m.ParentMenuItemId, m.MenuItemId), m.MenuOrder, m.MenuName;
END
GO

PRINT 'DynamicMenu_Setup completed.';
