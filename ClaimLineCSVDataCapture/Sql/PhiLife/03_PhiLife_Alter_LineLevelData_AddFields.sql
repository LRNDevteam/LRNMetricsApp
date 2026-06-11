SET NOCOUNT ON;

-- PhiLife-specific LineLevel additional columns
-- Run after base table creation script (01_CreateTables.sql).
-- Adds ONLY columns not already in the base LineLevelData table.
-- Base table already includes: CPTCode, Units, Modifier, ChargeAmountPerUnit,
--   AllowedAmountPerUnit, InsurancePaymentPerUnit, PatientPaymentPerUnit,
--   PatientBalancePerUnit, PostingDate, PayStatus, DenialDate.

-- ── PaymentPostedDate (PhiLife maps "Payment Posted Date" to this column) ─────
-- Note: base table has PostingDate for the same concept; PhiLife uses PaymentPostedDate.
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PaymentPostedDate')
    ALTER TABLE dbo.LineLevelData ADD PaymentPostedDate NVARCHAR(500) NULL;

-- ── Patient / provider extra fields ──────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PatientName')
    ALTER TABLE dbo.LineLevelData ADD PatientName NVARCHAR(1000) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'ResponsibleParty')
    ALTER TABLE dbo.LineLevelData ADD ResponsibleParty NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'SubscriberId')
    ALTER TABLE dbo.LineLevelData ADD SubscriberId NVARCHAR(1000) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'EndDOS')
    ALTER TABLE dbo.LineLevelData ADD EndDOS NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'BillOccurance')
    ALTER TABLE dbo.LineLevelData ADD BillOccurance NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'EntryUser')
    ALTER TABLE dbo.LineLevelData ADD EntryUser NVARCHAR(500) NULL;

-- ── CPT summary / composite fields ───────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CPTUnits')
    ALTER TABLE dbo.LineLevelData ADD CPTUnits NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CPTMOD')
    ALTER TABLE dbo.LineLevelData ADD CPTMOD NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CPTs')
    ALTER TABLE dbo.LineLevelData ADD CPTs NVARCHAR(MAX) NULL;

-- ── Aging bucket (used by usp_RefreshPhi_UnbilledAging) ──────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'AgingBucket')
    ALTER TABLE dbo.LineLevelData ADD AgingBucket NVARCHAR(200) NULL;

-- ── Posted week ───────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PostedWeek')
    ALTER TABLE dbo.LineLevelData ADD PostedWeek NVARCHAR(500) NULL;

-- ── Mirror changes to LineLevelDataArchive ────────────────────────────────────
IF OBJECT_ID('dbo.LineLevelDataArchive') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PaymentPostedDate')
        ALTER TABLE dbo.LineLevelDataArchive ADD PaymentPostedDate NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PatientName')
        ALTER TABLE dbo.LineLevelDataArchive ADD PatientName NVARCHAR(1000) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'ResponsibleParty')
        ALTER TABLE dbo.LineLevelDataArchive ADD ResponsibleParty NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'SubscriberId')
        ALTER TABLE dbo.LineLevelDataArchive ADD SubscriberId NVARCHAR(1000) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'EndDOS')
        ALTER TABLE dbo.LineLevelDataArchive ADD EndDOS NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'BillOccurance')
        ALTER TABLE dbo.LineLevelDataArchive ADD BillOccurance NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'EntryUser')
        ALTER TABLE dbo.LineLevelDataArchive ADD EntryUser NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'CPTUnits')
        ALTER TABLE dbo.LineLevelDataArchive ADD CPTUnits NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'CPTMOD')
        ALTER TABLE dbo.LineLevelDataArchive ADD CPTMOD NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'CPTs')
        ALTER TABLE dbo.LineLevelDataArchive ADD CPTs NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PostedWeek')
        ALTER TABLE dbo.LineLevelDataArchive ADD PostedWeek NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'AgingBucket')
        ALTER TABLE dbo.LineLevelDataArchive ADD AgingBucket NVARCHAR(200) NULL;
END

PRINT 'PhiLife LineLevel alter script completed.';
