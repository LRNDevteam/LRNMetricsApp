/* ============================================================================================
   System email log + user invitations (LRNMaster)

   Target database: LRNMaster (DefaultConnection). Run ONCE per environment. Idempotent.

   dbo.EmailLog   - every email LRN.ReportsApi sends, whatever its kind (EmailType):
                      UserInvitation / UserInvitationResend  (LRN Metrics + AR Workbench users)
                      DenialWorkflowSupport                  (Denial Workflow "contact support")
                      PayerMasterNotification                (Payer Master approvals / SLA)
                    Shown in LRN Metrics Admin > Email Log, the users screens' Sent Emails tab and
                    AR Workbench User Management. Secrets in a message (one-time password, link)
                    are redacted before they are stored.
   dbo.UserInvitation - first-login link token + one-time password, stored only as hashes. The
                    link opens LRN Metrics /Account/SetPassword; a resend revokes earlier ones.

   Earlier names (dbo.ARWB_UserInvitation, dbo.ARWB_EmailLog, dbo.UserEmailLog) are renamed.
   ============================================================================================ */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- ---------- 0. Earlier names -> current ----------
IF OBJECT_ID(N'dbo.ARWB_UserInvitation', N'U') IS NOT NULL AND OBJECT_ID(N'dbo.UserInvitation', N'U') IS NULL
    EXEC sp_rename N'dbo.ARWB_UserInvitation', N'UserInvitation';
IF OBJECT_ID(N'dbo.ARWB_EmailLog', N'U') IS NOT NULL AND OBJECT_ID(N'dbo.EmailLog', N'U') IS NULL
    EXEC sp_rename N'dbo.ARWB_EmailLog', N'EmailLog';
IF OBJECT_ID(N'dbo.UserEmailLog', N'U') IS NOT NULL AND OBJECT_ID(N'dbo.EmailLog', N'U') IS NULL
    EXEC sp_rename N'dbo.UserEmailLog', N'EmailLog';
GO

-- ---------- 1. Invitations ----------
IF OBJECT_ID(N'dbo.UserInvitation', N'U') IS NULL
CREATE TABLE dbo.UserInvitation
(
    InvitationId    bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_UserInvitation PRIMARY KEY,
    LabUserID       int            NOT NULL CONSTRAINT FK_UserInvitation_LabUsers REFERENCES dbo.LabUsers (LabUserID) ON DELETE CASCADE,
    Application     nvarchar(50)   NOT NULL CONSTRAINT DF_UserInvitation_Application DEFAULT (N'LRN Metrics'),
    TokenHash       char(64)       NOT NULL,            -- SHA-256 (hex) of the link token
    OtpHash         nvarchar(200)  NOT NULL,            -- PBKDF2 "iterations:salt:hash", same format as LabUsers.PasswordHash
    ExpiresUtc      datetime2(0)   NOT NULL,
    FailedAttempts  int            NOT NULL CONSTRAINT DF_UserInvitation_Failed DEFAULT (0),
    UsedUtc         datetime2(0)   NULL,
    RevokedUtc      datetime2(0)   NULL,
    CreatedBy       nvarchar(100)  NULL,
    CreatedUtc      datetime2(0)   NOT NULL CONSTRAINT DF_UserInvitation_Created DEFAULT (SYSUTCDATETIME())
);
GO
IF COL_LENGTH(N'dbo.UserInvitation', N'Application') IS NULL
    ALTER TABLE dbo.UserInvitation ADD Application nvarchar(50) NOT NULL
        CONSTRAINT DF_UserInvitation_Application DEFAULT (N'AR Workbench') WITH VALUES;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.UserInvitation') AND name IN (N'UX_UserInvitation_Token', N'UX_ARWB_UserInvitation_Token'))
    CREATE UNIQUE INDEX UX_UserInvitation_Token ON dbo.UserInvitation (TokenHash);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.UserInvitation') AND name IN (N'IX_UserInvitation_User', N'IX_ARWB_UserInvitation_User'))
    CREATE INDEX IX_UserInvitation_User ON dbo.UserInvitation (LabUserID) INCLUDE (UsedUtc, RevokedUtc, ExpiresUtc);
GO

-- ---------- 2. Every email the system sends (no FK on LabUserID: the log outlives a deleted user) ----------
IF OBJECT_ID(N'dbo.EmailLog', N'U') IS NULL
CREATE TABLE dbo.EmailLog
(
    EmailLogId      bigint          IDENTITY(1,1) NOT NULL CONSTRAINT PK_EmailLog PRIMARY KEY,
    LabUserID       int             NULL,               -- the user the email is about, when there is one
    UserName        nvarchar(256)   NULL,
    Application     nvarchar(50)    NOT NULL CONSTRAINT DF_EmailLog_Application DEFAULT (N'LRN Metrics'),
    EmailType       nvarchar(50)    NOT NULL,
    ToAddress       nvarchar(1000)  NOT NULL,           -- several recipients are comma-separated
    FromAddress     nvarchar(256)   NULL,
    Subject         nvarchar(400)   NOT NULL,
    BodyHtml        nvarchar(max)   NULL,               -- secrets redacted; plain-text bodies stored inside <pre>
    Status          varchar(20)     NOT NULL,           -- Sent | Failed
    ErrorMessage    nvarchar(2000)  NULL,
    SentBy          nvarchar(100)   NULL,
    CreatedUtc      datetime2(0)    NOT NULL CONSTRAINT DF_EmailLog_Created DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_EmailLog_Status CHECK (Status IN ('Sent', 'Failed'))
);
GO
IF COL_LENGTH(N'dbo.EmailLog', N'Application') IS NULL
    ALTER TABLE dbo.EmailLog ADD Application nvarchar(50) NOT NULL
        CONSTRAINT DF_EmailLog_Application DEFAULT (N'AR Workbench') WITH VALUES;
GO
-- Several recipients per row (support and Payer Master emails go to a list).
IF COL_LENGTH(N'dbo.EmailLog', N'ToAddress') < 2000
    ALTER TABLE dbo.EmailLog ALTER COLUMN ToAddress nvarchar(1000) NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.EmailLog') AND name = N'IX_EmailLog_Created')
    CREATE INDEX IX_EmailLog_Created ON dbo.EmailLog (CreatedUtc DESC) INCLUDE (LabUserID, Status, EmailType, Application);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.EmailLog') AND name = N'IX_EmailLog_Type')
    CREATE INDEX IX_EmailLog_Type ON dbo.EmailLog (EmailType, CreatedUtc DESC) INCLUDE (Status);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.EmailLog') AND name IN (N'IX_EmailLog_User', N'IX_UserEmailLog_User', N'IX_ARWB_EmailLog_User'))
    CREATE INDEX IX_EmailLog_User ON dbo.EmailLog (LabUserID, CreatedUtc DESC) INCLUDE (Status, EmailType);
GO

PRINT 'Email log and user invitation tables ready.';
GO
