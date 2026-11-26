/* ============================================================================================
   AR Workbench sign-in accounts (LRNMaster)

   Target database: LRNMaster (DefaultConnection). Run AFTER HybridAuth_Setup.sql and
   Database/LRN.ReportsApi/UserMail_Setup.sql, and BEFORE deploying the matching LabMetricsDashboard
   and LRN.ReportsApi builds. Idempotent - safe to re-run.

   Every AR Workbench user now signs in one of two ways:
     Microsoft  - a Lab Revenue Navigator account (Sign in with Microsoft, MFA by Entra). The
                  administrator creates it with the person's organization email; it is linked to
                  their Microsoft identity on their first Microsoft sign-in (EntraObjectId is NULL
                  until then, and the account never has a password).
     External   - any other email address. The username IS the email address. The user gets the
                  invitation (one-time password + link) to create a password, and on EVERY sign-in
                  a new one-time sign-in code is emailed to them (dbo.UserLoginOtp).

   1. CK_LabUsers_EntraHasOid  - a Microsoft account may wait for its first sign-in with no object
                                 id, provided it has no password.
   2. dbo.UserLoginOtp         - one row per emailed sign-in code (hash only).
   3. UX_LabUsers_Email        - one account per email address, for every role. Created only when
                                 no duplicates exist; the duplicates are listed for clean-up.
   ============================================================================================ */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF COL_LENGTH(N'dbo.LabUsers', N'AuthProvider') IS NULL
    THROW 50010, 'Run Database/LabMetricsDashboard/HybridAuth_Setup.sql first.', 1;
GO

-- ---------- 1. Pre-created Microsoft accounts ----------
IF OBJECT_ID(N'dbo.CK_LabUsers_EntraHasOid', N'C') IS NOT NULL
    ALTER TABLE dbo.LabUsers DROP CONSTRAINT CK_LabUsers_EntraHasOid;
GO
ALTER TABLE dbo.LabUsers ADD CONSTRAINT CK_LabUsers_EntraHasOid
    CHECK (AuthProvider <> 'Entra' OR EntraObjectId IS NOT NULL OR NULLIF(PasswordHash, N'') IS NULL);
GO

-- ---------- 2. One-time sign-in codes (external users, every sign-in) ----------
IF OBJECT_ID(N'dbo.UserLoginOtp', N'U') IS NULL
CREATE TABLE dbo.UserLoginOtp
(
    LoginOtpId      bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_UserLoginOtp PRIMARY KEY,
    LabUserID       int            NOT NULL CONSTRAINT FK_UserLoginOtp_LabUsers REFERENCES dbo.LabUsers (LabUserID) ON DELETE CASCADE,
    CodeHash        nvarchar(200)  NOT NULL,            -- PBKDF2 "iterations:salt:hash", same format as LabUsers.PasswordHash
    ExpiresUtc      datetime2(0)   NOT NULL,
    FailedAttempts  int            NOT NULL CONSTRAINT DF_UserLoginOtp_Failed DEFAULT (0),
    UsedUtc         datetime2(0)   NULL,
    RevokedUtc      datetime2(0)   NULL,
    CreatedUtc      datetime2(0)   NOT NULL CONSTRAINT DF_UserLoginOtp_Created DEFAULT (SYSUTCDATETIME())
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.UserLoginOtp') AND name = N'IX_UserLoginOtp_User')
    CREATE INDEX IX_UserLoginOtp_User ON dbo.UserLoginOtp (LabUserID, CreatedUtc DESC) INCLUDE (UsedUtc, RevokedUtc, ExpiresUtc);
GO

-- ---------- 3. One account per email address ----------
-- Review this list: give each person their own address (or deactivate / delete the extra
-- accounts), then re-run this script to create the unique index. Until then the applications
-- still refuse a NEW duplicate, but existing ones are not blocked.
SELECT LTRIM(RTRIM(u.Email)) AS Email, u.LabUserID, u.UserName, CAST(ISNULL(u.IsActive, 0) AS bit) AS IsActive, u.AuthProvider
FROM dbo.LabUsers u
WHERE NULLIF(LTRIM(RTRIM(u.Email)), N'') IS NOT NULL
  AND EXISTS (SELECT 1 FROM dbo.LabUsers d
              WHERE d.LabUserID <> u.LabUserID AND LTRIM(RTRIM(d.Email)) = LTRIM(RTRIM(u.Email)))
ORDER BY LTRIM(RTRIM(u.Email)), u.LabUserID;
GO

-- Leading / trailing blanks would let the same address in twice.
UPDATE dbo.LabUsers SET Email = LTRIM(RTRIM(Email)) WHERE Email <> LTRIM(RTRIM(Email));
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.LabUsers') AND name = N'UX_LabUsers_Email')
BEGIN
    IF EXISTS (SELECT Email FROM dbo.LabUsers WHERE Email IS NOT NULL AND Email <> N'' GROUP BY Email HAVING COUNT(*) > 1)
        PRINT 'UX_LabUsers_Email NOT created: duplicate email addresses exist (see the list above). Fix them and re-run.';
    ELSE
    BEGIN
        CREATE UNIQUE INDEX UX_LabUsers_Email ON dbo.LabUsers (Email) WHERE Email IS NOT NULL AND Email <> N'';
        PRINT 'UX_LabUsers_Email created.';
    END
END
GO

PRINT 'AR Workbench sign-in accounts ready.';
GO
