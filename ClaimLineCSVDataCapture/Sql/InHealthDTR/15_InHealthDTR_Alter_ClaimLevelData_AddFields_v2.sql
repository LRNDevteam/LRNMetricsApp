-- =====================================================================
-- InHealthDTR — Add NEW ClaimLevelData columns (v2 CSV layout)
-- New CSV headers introduced: Panel Name LIS, Panel Name Based on CPT,
-- Total Write off, Bill Status, Aging DOS, ResponsibleParty, SubscriberID,
-- ClientAccNum, EndDOS, DOD Week, Check Number, Line Level ICD, Aging DOE,
-- Facility.
--
-- NOTE: "Bill Status" / "Aging DOS" replace the old "Billed/Unbilled" /
-- "Aging" CSV headers. The original BilledUnbilled and AgingBucket columns
-- are left in place (unused going forward) to avoid any data loss; new
-- BillStatus / AgingDOS columns are added instead.
--
-- Safe to re-run (IF NOT EXISTS guards).
-- =====================================================================

SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PanelNameLIS')
    ALTER TABLE dbo.ClaimLevelData ADD PanelNameLIS NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PanelNameBasedOnCPT')
    ALTER TABLE dbo.ClaimLevelData ADD PanelNameBasedOnCPT NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'TotalWO')
    ALTER TABLE dbo.ClaimLevelData ADD TotalWO NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'BillStatus')
    ALTER TABLE dbo.ClaimLevelData ADD BillStatus NVARCHAR(200) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'AgingDOS')
    ALTER TABLE dbo.ClaimLevelData ADD AgingDOS NVARCHAR(100) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'AgingDOE')
    ALTER TABLE dbo.ClaimLevelData ADD AgingDOE NVARCHAR(100) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'ResponsibleParty')
    ALTER TABLE dbo.ClaimLevelData ADD ResponsibleParty NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'SubscriberID')
    ALTER TABLE dbo.ClaimLevelData ADD SubscriberID NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'ClientAccNum')
    ALTER TABLE dbo.ClaimLevelData ADD ClientAccNum NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'EndDOS')
    ALTER TABLE dbo.ClaimLevelData ADD EndDOS NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'DODWeek')
    ALTER TABLE dbo.ClaimLevelData ADD DODWeek NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'CheckNumber')
    ALTER TABLE dbo.ClaimLevelData ADD CheckNumber NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'LineLevelICD')
    ALTER TABLE dbo.ClaimLevelData ADD LineLevelICD NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Facility')
    ALTER TABLE dbo.ClaimLevelData ADD Facility NVARCHAR(500) NULL;

GO

-- ── Archive table (mirror the same columns) ──────────────────────────────────
IF OBJECT_ID('dbo.ClaimLevelDataArchive', 'U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PanelNameLIS')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD PanelNameLIS NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PanelNameBasedOnCPT')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD PanelNameBasedOnCPT NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'TotalWO')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD TotalWO NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'BillStatus')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD BillStatus NVARCHAR(200) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'AgingDOS')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD AgingDOS NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'AgingDOE')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD AgingDOE NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'ResponsibleParty')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD ResponsibleParty NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'SubscriberID')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD SubscriberID NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'ClientAccNum')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD ClientAccNum NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'EndDOS')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD EndDOS NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'DODWeek')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD DODWeek NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'CheckNumber')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD CheckNumber NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'LineLevelICD')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD LineLevelICD NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Facility')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD Facility NVARCHAR(500) NULL;
END
GO

PRINT '15_InHealthDTR_Alter_ClaimLevelData_AddFields_v2.sql completed.';
GO
