-- =====================================================================
-- InHealthDTR — Add missing LineLevelData columns
-- Adds columns present in InHealthDTR Line Level CSVs that are not
-- in the base 01_CreateTables.sql schema.
-- Safe to re-run (IF NOT EXISTS guards).
-- =====================================================================

SET NOCOUNT ON;
GO

-- ── PatientName ──────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PatientName')
    ALTER TABLE dbo.LineLevelData ADD PatientName NVARCHAR(1000) NULL;

-- ── PaymentPostedDate (InHealthDTR CSV: "Payment Posted Date") ───────────────
-- Global mapping has "Posting Date" -> "PostingDate"; InHealthDTR uses a different header.
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PaymentPostedDate')
    ALTER TABLE dbo.LineLevelData ADD PaymentPostedDate NVARCHAR(100) NULL;

-- ── ResponsibleParty ─────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'ResponsibleParty')
    ALTER TABLE dbo.LineLevelData ADD ResponsibleParty NVARCHAR(500) NULL;

-- ── SubscriberID (global has "SubscriberId"; this adds the exact column if different)
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'SubscriberID')
    AND NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'SubscriberId')
    ALTER TABLE dbo.LineLevelData ADD SubscriberID NVARCHAR(500) NULL;

-- ── EndDOS ───────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'EndDOS')
    ALTER TABLE dbo.LineLevelData ADD EndDOS NVARCHAR(100) NULL;

-- ── BillOccurance ────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'BillOccurance')
    ALTER TABLE dbo.LineLevelData ADD BillOccurance NVARCHAR(100) NULL;

-- ── EntryUser ────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'EntryUser')
    ALTER TABLE dbo.LineLevelData ADD EntryUser NVARCHAR(500) NULL;

-- ── CPTUnits ─────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CPTUnits')
    ALTER TABLE dbo.LineLevelData ADD CPTUnits NVARCHAR(500) NULL;

-- ── CPTMOD ───────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CPTMOD')
    ALTER TABLE dbo.LineLevelData ADD CPTMOD NVARCHAR(500) NULL;

-- ── CPTs ─────────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CPTs')
    ALTER TABLE dbo.LineLevelData ADD CPTs NVARCHAR(500) NULL;

-- ── PostedWeek (on LineLevel; global only has it on ClaimLevel) ──────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PostedWeek')
    ALTER TABLE dbo.LineLevelData ADD PostedWeek NVARCHAR(100) NULL;

GO

-- ── Archive table (mirror the same columns) ──────────────────────────────────
IF OBJECT_ID('dbo.LineLevelDataArchive', 'U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PatientName')
        ALTER TABLE dbo.LineLevelDataArchive ADD PatientName NVARCHAR(1000) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PaymentPostedDate')
        ALTER TABLE dbo.LineLevelDataArchive ADD PaymentPostedDate NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'ResponsibleParty')
        ALTER TABLE dbo.LineLevelDataArchive ADD ResponsibleParty NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'SubscriberID')
        AND NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'SubscriberId')
        ALTER TABLE dbo.LineLevelDataArchive ADD SubscriberID NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'EndDOS')
        ALTER TABLE dbo.LineLevelDataArchive ADD EndDOS NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'BillOccurance')
        ALTER TABLE dbo.LineLevelDataArchive ADD BillOccurance NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'EntryUser')
        ALTER TABLE dbo.LineLevelDataArchive ADD EntryUser NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'CPTUnits')
        ALTER TABLE dbo.LineLevelDataArchive ADD CPTUnits NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'CPTMOD')
        ALTER TABLE dbo.LineLevelDataArchive ADD CPTMOD NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'CPTs')
        ALTER TABLE dbo.LineLevelDataArchive ADD CPTs NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PostedWeek')
        ALTER TABLE dbo.LineLevelDataArchive ADD PostedWeek NVARCHAR(100) NULL;
END
GO

PRINT '03_InHealthDTR_Alter_LineLevelData_AddFields.sql completed.';
GO
