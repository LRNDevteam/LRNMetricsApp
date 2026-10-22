/* ============================================================================================
   AR Workbench - LRNMaster: client (lab) activation for Client Management (T068)
   Target database: LRNMaster (DefaultConnection). Run ONCE per environment. Idempotent.

   One row per lab that has been deactivated or reactivated in AR Workbench > Client Management.
   A lab with no row is ACTIVE. A deactivated lab: hidden from the lab picker for non-admins,
   closed to everyone except site admins and AR Workbench System Administrators (who can
   reactivate it), and skipped by the nightly queue snapshot. Claims and history are kept.
   Open decision D-15 (what "client" means beyond the lab) may refine this.
   ============================================================================================ */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.ARWB_ClientSetting', N'U') IS NULL
CREATE TABLE dbo.ARWB_ClientSetting
(
    LabId           int            NOT NULL CONSTRAINT PK_ARWB_ClientSetting PRIMARY KEY,
    IsActive        bit            NOT NULL CONSTRAINT DF_ARWB_ClientSetting_IsActive DEFAULT (1),
    StatusNote      nvarchar(500)  NULL,
    ChangedBy       nvarchar(256)  NOT NULL,
    ChangedOn       datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_ClientSetting_ChangedOn DEFAULT (SYSUTCDATETIME())
);
GO

-- Every activation change, for the audit trail.
IF OBJECT_ID(N'dbo.ARWB_ClientSettingHistory', N'U') IS NULL
CREATE TABLE dbo.ARWB_ClientSettingHistory
(
    ClientSettingHistoryId  bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_ClientSettingHistory PRIMARY KEY,
    LabId                   int            NOT NULL,
    IsActive                bit            NOT NULL,
    StatusNote              nvarchar(500)  NULL,
    ChangedBy               nvarchar(256)  NOT NULL,
    ChangedOn               datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_ClientSettingHistory_ChangedOn DEFAULT (SYSUTCDATETIME())
);
GO

/* Per-client configuration on the Client Management card (handoff FR-CM-03, retest DEF-31, 10/21/2026):
   the SharePoint folder the weekly master files come from, the onboarding status and the primary account
   manager. Added after the first release, so existing installs get the columns here. */
IF COL_LENGTH(N'dbo.ARWB_ClientSetting', N'SharePointFolder') IS NULL   ALTER TABLE dbo.ARWB_ClientSetting ADD SharePointFolder nvarchar(1000) NULL;
IF COL_LENGTH(N'dbo.ARWB_ClientSetting', N'OnboardingStatus') IS NULL   ALTER TABLE dbo.ARWB_ClientSetting ADD OnboardingStatus varchar(30) NULL;   -- Not Started | Onboarding | Live | On Hold
IF COL_LENGTH(N'dbo.ARWB_ClientSetting', N'AccountManager') IS NULL     ALTER TABLE dbo.ARWB_ClientSetting ADD AccountManager nvarchar(256) NULL;
IF COL_LENGTH(N'dbo.ARWB_ClientSetting', N'ConfigUpdatedBy') IS NULL    ALTER TABLE dbo.ARWB_ClientSetting ADD ConfigUpdatedBy nvarchar(256) NULL;
IF COL_LENGTH(N'dbo.ARWB_ClientSetting', N'ConfigUpdatedOn') IS NULL    ALTER TABLE dbo.ARWB_ClientSetting ADD ConfigUpdatedOn datetime2(0) NULL;
IF COL_LENGTH(N'dbo.ARWB_ClientSettingHistory', N'SharePointFolder') IS NULL ALTER TABLE dbo.ARWB_ClientSettingHistory ADD SharePointFolder nvarchar(1000) NULL;
IF COL_LENGTH(N'dbo.ARWB_ClientSettingHistory', N'OnboardingStatus') IS NULL ALTER TABLE dbo.ARWB_ClientSettingHistory ADD OnboardingStatus varchar(30) NULL;
IF COL_LENGTH(N'dbo.ARWB_ClientSettingHistory', N'AccountManager') IS NULL   ALTER TABLE dbo.ARWB_ClientSettingHistory ADD AccountManager nvarchar(256) NULL;
GO

PRINT 'AR Workbench client activation (dbo.ARWB_ClientSetting) ready.';
GO
