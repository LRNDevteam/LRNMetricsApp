-- Hybrid authentication: local username/password AND Microsoft Entra ID (MFA) sign-in.
-- Run against LRNMaster (DefaultConnection) BEFORE deploying the matching LabMetricsDashboard build:
-- the new build reads these columns on every sign-in. Safe to re-run.
--
-- Every existing row becomes AuthProvider = 'Local', so current logins keep working unchanged.
-- Roles, UserRoles and UserLabs are untouched.

-- 0) Run this first and review the result. From this release, an active user with NO role is
--    sent to the "Access pending" page instead of being signed in - whichever way they log in.
--    Give each of these users a role (or deactivate them) before deploying.
SELECT u.LabUserID, u.UserName, u.FirstName, u.LastName, u.Email
FROM dbo.LabUsers u
WHERE u.IsActive = 1
  AND NOT EXISTS (SELECT 1 FROM dbo.UserRoles ur WHERE ur.LabUserID = u.LabUserID)
ORDER BY u.UserName;
GO

SET XACT_ABORT ON;
BEGIN TRAN;

-- 1) New columns on LabUsers
IF COL_LENGTH('dbo.LabUsers','AuthProvider') IS NULL
    ALTER TABLE dbo.LabUsers ADD AuthProvider VARCHAR(20) NOT NULL
        CONSTRAINT DF_LabUsers_AuthProvider DEFAULT ('Local') WITH VALUES;
IF COL_LENGTH('dbo.LabUsers','EntraObjectId') IS NULL
    ALTER TABLE dbo.LabUsers ADD EntraObjectId UNIQUEIDENTIFIER NULL;
IF COL_LENGTH('dbo.LabUsers','EntraTenantId') IS NULL
    ALTER TABLE dbo.LabUsers ADD EntraTenantId UNIQUEIDENTIFIER NULL;
IF COL_LENGTH('dbo.LabUsers','FailedLoginCount') IS NULL
    ALTER TABLE dbo.LabUsers ADD FailedLoginCount INT NOT NULL
        CONSTRAINT DF_LabUsers_FailedLoginCount DEFAULT (0) WITH VALUES;
IF COL_LENGTH('dbo.LabUsers','LockoutEndUtc') IS NULL
    ALTER TABLE dbo.LabUsers ADD LockoutEndUtc DATETIME2 NULL;
-- Rotated whenever a password changes or accounts are linked; a signed-in cookie carrying the old
-- value is rejected at its next re-validation (every HybridAuth:RevalidateMinutes).
IF COL_LENGTH('dbo.LabUsers','SecurityStamp') IS NULL
    ALTER TABLE dbo.LabUsers ADD SecurityStamp UNIQUEIDENTIFIER NOT NULL
        CONSTRAINT DF_LabUsers_SecurityStamp DEFAULT (NEWID()) WITH VALUES;
IF COL_LENGTH('dbo.LabUsers','LastLoginUtc') IS NULL
    ALTER TABLE dbo.LabUsers ADD LastLoginUtc DATETIME2 NULL;

COMMIT;
GO

-- 2) Rules (separate batch so the new columns are visible)
IF OBJECT_ID('dbo.CK_LabUsers_AuthProvider','C') IS NULL
    ALTER TABLE dbo.LabUsers ADD CONSTRAINT CK_LabUsers_AuthProvider
        CHECK (AuthProvider IN ('Local','Entra'));
IF OBJECT_ID('dbo.CK_LabUsers_EntraHasOid','C') IS NULL
    ALTER TABLE dbo.LabUsers ADD CONSTRAINT CK_LabUsers_EntraHasOid
        CHECK (AuthProvider <> 'Entra' OR EntraObjectId IS NOT NULL);

-- One LabUsers row per Microsoft account. Sign-in matches on the Entra object id (oid), never on
-- email or UPN, which can be reassigned.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_LabUsers_EntraObjectId' AND object_id = OBJECT_ID('dbo.LabUsers'))
    CREATE UNIQUE INDEX UX_LabUsers_EntraObjectId
        ON dbo.LabUsers(EntraObjectId) WHERE EntraObjectId IS NOT NULL;
GO

-- 3) Sign-in audit: one row per attempt, both providers.
IF OBJECT_ID('dbo.LoginAudit','U') IS NULL
    CREATE TABLE dbo.LoginAudit (
        AuditId      BIGINT IDENTITY(1,1) PRIMARY KEY,
        LabUserID    INT           NULL,
        LoginValue   NVARCHAR(256) NULL,      -- username typed, or the Entra UPN
        AuthProvider VARCHAR(20)   NOT NULL,  -- Local | Entra
        Succeeded    BIT           NOT NULL,
        Reason       NVARCHAR(200) NULL,      -- BadPassword, LockedOut, UseMicrosoft, NoRole, Inactive, Provisioned ...
        IpAddress    NVARCHAR(64)  NULL,
        CreatedUtc   DATETIME2     NOT NULL CONSTRAINT DF_LoginAudit_Created DEFAULT SYSUTCDATETIME()
    );
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LoginAudit_Created' AND object_id = OBJECT_ID('dbo.LoginAudit'))
    CREATE INDEX IX_LoginAudit_Created ON dbo.LoginAudit(CreatedUtc DESC)
        INCLUDE (LabUserID, Succeeded, Reason);
GO

-- 4) Link a first Microsoft sign-in to an existing local account.
--
-- A staff member's first "Sign in with Microsoft" creates a new Entra row with no role (Access
-- pending). Admin > Manage Users > Link moves that Microsoft identity onto their existing account,
-- which keeps its UserName, roles, labs, manager and team, and removes the pending row. The old
-- password stops working: the account becomes Microsoft-only.
--
-- UserName is deliberately NOT changed: the denial workflow stores it in AssignedTo and the AR
-- reports join on it.
CREATE OR ALTER PROCEDURE dbo.usp_LinkEntraUser
    @ExistingLabUserID INT,             -- the existing local account to keep
    @PendingLabUserID  INT,             -- the row created by the first Microsoft sign-in
    @LinkedBy          NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;

    DECLARE @Oid UNIQUEIDENTIFIER, @Tid UNIQUEIDENTIFIER, @Email NVARCHAR(255);
    SELECT @Oid = EntraObjectId, @Tid = EntraTenantId, @Email = Email
    FROM dbo.LabUsers WITH (UPDLOCK, HOLDLOCK)
    WHERE LabUserID = @PendingLabUserID AND AuthProvider = 'Entra';

    IF @Oid IS NULL THROW 50001, 'The pending row is not a Microsoft sign-in.', 1;
    IF @ExistingLabUserID = @PendingLabUserID THROW 50004, 'Choose a different account to link to.', 1;
    IF EXISTS (SELECT 1 FROM dbo.UserRoles WHERE LabUserID = @PendingLabUserID)
        THROW 50002, 'The Microsoft account already has roles; remove them before linking.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabUsers WHERE LabUserID = @ExistingLabUserID AND AuthProvider = 'Local')
        THROW 50003, 'The existing account was not found or is already a Microsoft account.', 1;

    UPDATE dbo.LabUsers SET ManagerUserID = NULL WHERE ManagerUserID = @PendingLabUserID;
    DELETE dbo.UserLabs WHERE LabUserID = @PendingLabUserID;
    DELETE dbo.LabUsers WHERE LabUserID = @PendingLabUserID;   -- frees the unique oid

    UPDATE dbo.LabUsers SET
        AuthProvider = 'Entra', EntraObjectId = @Oid, EntraTenantId = @Tid,
        Email = CASE WHEN NULLIF(LTRIM(RTRIM(Email)), '') IS NULL THEN @Email ELSE Email END,
        PasswordHash = NULL, FailedLoginCount = 0, LockoutEndUtc = NULL, SecurityStamp = NEWID(),
        ModifiedDate = SYSUTCDATETIME(), ModifiedBy = @LinkedBy
    WHERE LabUserID = @ExistingLabUserID AND AuthProvider = 'Local';

    COMMIT;
END
GO
