/* ============================================================================================
   AR Workbench - LRNMaster: the 8 AR Workbench roles, their permissions, and access scope
   Target database: LRNMaster (DefaultConnection). Run ONCE per environment, not per lab.

   Fresh start: the AR Workbench does NOT use any existing LRN Metrics role (Admin, AR Manager,
   AR Reviewer, Client Manager, ...). It has its own 8 roles, taken from the AR Workbench mockup:

     Role (dbo.Roles.RoleName)                          Mockup role   Sees
     AR Workbench - System Administrator                admin         whole lab
     AR Workbench - RCM Manager                         manager       whole lab
     AR Workbench - Senior AR Analyst / Team Lead       lead          whole lab
     AR Workbench - AR Agent                            agent         own assigned caseload
     AR Workbench - QA Reviewer                         qa            whole lab
     AR Workbench - Client Viewer                       viewer        whole lab (client level)
     AR Workbench - Clinic Viewer                       viewer        one clinic      (dbo.ARWB_UserScope.ClinicName)
     AR Workbench - Provider Viewer                     viewer        one provider    (dbo.ARWB_UserScope.ProviderName)

   Permission matrix: Developer Handoff v1.1 section 15.2. Session decision: the Team Lead CAN
   approve CIPs to the client, so 'lead' has ARWorkbench.Approve (the mockup did not).

   The roles live in the EXISTING user tables, so users are managed in the existing screens:
     dbo.LabUsers (user)  dbo.UserLabs (labs)  dbo.UserRoles -> dbo.Roles (role)
     dbo.RoleFeatureAccess (what each role may do; FeatureKey 'ARWorkbench.*')

   The one AR Workbench table here, dbo.ARWB_UserScope, holds WHICH clinic / provider a Clinic
   Viewer or Provider Viewer is limited to, per lab. It replaces dbo.ARWorkbenchUserScope: rows in
   the old table are copied across and the old table is dropped.

   Requires dbo.RoleFeatureAccess (LRN.ReportsApi/Sql/DynamicMenu_Setup.sql).
   Idempotent - safe to run again; it only adds what is missing, so admin edits are kept.
   ============================================================================================ */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'dbo.LabUsers', N'U') IS NULL OR OBJECT_ID(N'dbo.Roles', N'U') IS NULL
   OR OBJECT_ID(N'dbo.UserRoles', N'U') IS NULL OR OBJECT_ID(N'dbo.UserLabs', N'U') IS NULL
    THROW 52001, 'Run this script in LRNMaster: dbo.LabUsers, dbo.Roles, dbo.UserRoles and dbo.UserLabs are required.', 1;
IF OBJECT_ID(N'dbo.RoleFeatureAccess', N'U') IS NULL
    THROW 52002, 'dbo.RoleFeatureAccess is missing. Run LRN.ReportsApi/Sql/DynamicMenu_Setup.sql first.', 1;
GO

/* ---------- 1. The 8 AR Workbench roles --------------------------------------------------- */
DECLARE @Roles TABLE (RoleName nvarchar(200) NOT NULL, Persona varchar(20) NOT NULL, ScopeKey nvarchar(100) NULL);
INSERT INTO @Roles (RoleName, Persona, ScopeKey) VALUES
    (N'AR Workbench - System Administrator',          'admin',   NULL),
    (N'AR Workbench - RCM Manager',                   'manager', NULL),
    (N'AR Workbench - Senior AR Analyst / Team Lead', 'lead',    NULL),
    (N'AR Workbench - AR Agent',                      'agent',   NULL),
    (N'AR Workbench - QA Reviewer',                   'qa',      NULL),
    (N'AR Workbench - Client Viewer',                 'viewer',  NULL),
    (N'AR Workbench - Clinic Viewer',                 'viewer',  N'ARWorkbench.Scope.Clinic'),
    (N'AR Workbench - Provider Viewer',               'viewer',  N'ARWorkbench.Scope.Provider');

INSERT INTO dbo.Roles (RoleName, IsActive, CreatedBy)
SELECT r.RoleName, 1, N'system'
FROM @Roles r
WHERE NOT EXISTS (SELECT 1 FROM dbo.Roles x WHERE x.RoleName = r.RoleName);
PRINT CONCAT('AR Workbench roles added: ', @@ROWCOUNT);

/* ---------- 2. Permission matrix (handoff 15.2) ------------------------------------------- */
DECLARE @Perms TABLE (Persona varchar(20) NOT NULL, FeatureKey nvarchar(100) NOT NULL);
INSERT INTO @Perms (Persona, FeatureKey) VALUES
    ('admin', N'ARWorkbench.Access'), ('admin', N'ARWorkbench.Assign'), ('admin', N'ARWorkbench.EditClaim'),
    ('admin', N'ARWorkbench.QaDecide'), ('admin', N'ARWorkbench.Approve'), ('admin', N'ARWorkbench.ManageUsers'),
    ('admin', N'ARWorkbench.ViewAudit'), ('admin', N'ARWorkbench.ManageSettings'), ('admin', N'ARWorkbench.AllClients'),
    ('admin', N'ARWorkbench.ViewClientMgmt'),

    ('manager', N'ARWorkbench.Access'), ('manager', N'ARWorkbench.Assign'), ('manager', N'ARWorkbench.EditClaim'),
    ('manager', N'ARWorkbench.QaDecide'), ('manager', N'ARWorkbench.Approve'), ('manager', N'ARWorkbench.ViewAudit'),
    ('manager', N'ARWorkbench.AllClients'),

    ('lead', N'ARWorkbench.Access'), ('lead', N'ARWorkbench.Assign'), ('lead', N'ARWorkbench.EditClaim'),
    ('lead', N'ARWorkbench.QaDecide'), ('lead', N'ARWorkbench.Approve'), ('lead', N'ARWorkbench.AllClients'),

    ('agent', N'ARWorkbench.Access'), ('agent', N'ARWorkbench.EditClaim'),

    ('qa', N'ARWorkbench.Access'), ('qa', N'ARWorkbench.QaDecide'), ('qa', N'ARWorkbench.AllClients'),

    ('viewer', N'ARWorkbench.Access');

INSERT INTO dbo.RoleFeatureAccess (RoleId, FeatureKey, IsEnabled, CreatedBy)
SELECT ro.RoleID, g.FeatureKey, 1, N'system'
FROM
(
    SELECT r.RoleName, p.FeatureKey FROM @Roles r INNER JOIN @Perms p ON p.Persona = r.Persona
    UNION
    SELECT r.RoleName, r.ScopeKey FROM @Roles r WHERE r.ScopeKey IS NOT NULL      -- clinic / provider narrowing
) g
INNER JOIN dbo.Roles ro ON ro.RoleName = g.RoleName
WHERE NOT EXISTS (SELECT 1 FROM dbo.RoleFeatureAccess fa WHERE fa.RoleId = ro.RoleID AND fa.FeatureKey = g.FeatureKey);
PRINT CONCAT('AR Workbench feature grants added: ', @@ROWCOUNT);
GO

/* ---------- 3. Which clinic / provider a Clinic Viewer or Provider Viewer sees -------------
   One row per user per lab. Values must match the lab's ClaimLevelData.ClinicName /
   ReferringProvider exactly. A Clinic or Provider Viewer with no row for a lab sees nothing
   there (fails closed). CIP escalations for a clinic are routed to that clinic's users. */
IF OBJECT_ID(N'dbo.ARWB_UserScope', N'U') IS NULL
CREATE TABLE dbo.ARWB_UserScope
(
    UserScopeId             int            IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_UserScope PRIMARY KEY,
    LabUserID               int            NOT NULL CONSTRAINT FK_ARWB_UserScope_LabUsers REFERENCES dbo.LabUsers (LabUserID),
    LabId                   int            NOT NULL,
    ClinicName              nvarchar(500)  NULL,
    ProviderName            nvarchar(500)  NULL,
    CreatedBy               nvarchar(100)  NULL,
    CreatedDate             datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_UserScope_CreatedDate DEFAULT (SYSUTCDATETIME()),
    ModifiedBy              nvarchar(100)  NULL,
    ModifiedDate            datetime2(0)   NULL,
    CONSTRAINT UQ_ARWB_UserScope_User_Lab UNIQUE (LabUserID, LabId),
    CONSTRAINT CK_ARWB_UserScope_Value CHECK (ClinicName IS NOT NULL OR ProviderName IS NOT NULL)
);
GO

-- Move rows from the old table, then drop it.
IF OBJECT_ID(N'dbo.ARWorkbenchUserScope', N'U') IS NOT NULL
BEGIN
    BEGIN TRANSACTION;

    EXEC sys.sp_executesql N'
INSERT INTO dbo.ARWB_UserScope (LabUserID, LabId, ClinicName, ProviderName, CreatedBy, CreatedDate, ModifiedBy, ModifiedDate)
SELECT o.LabUserID, o.LabId, o.ClinicName, o.ProviderName, o.CreatedBy, o.CreatedDate, o.ModifiedBy, o.ModifiedDate
FROM dbo.ARWorkbenchUserScope o
WHERE NOT EXISTS (SELECT 1 FROM dbo.ARWB_UserScope n WHERE n.LabUserID = o.LabUserID AND n.LabId = o.LabId);
PRINT CONCAT(''Scope rows copied from dbo.ARWorkbenchUserScope: '', @@ROWCOUNT);';

    DROP TABLE dbo.ARWorkbenchUserScope;

    COMMIT TRANSACTION;
    PRINT 'Dropped dbo.ARWorkbenchUserScope.';
END;
GO

PRINT 'AR Workbench LRNMaster setup ready.';
GO
