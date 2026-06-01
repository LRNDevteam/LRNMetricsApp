SET NOCOUNT ON;

-- PhiLife-specific LineLevel additional columns
-- Run after base table creation script (01_CreateTables.sql).
-- PhiLife LineLevel CSV uses aggregate CPT columns (CPT Code X Units X Modifier)
-- plus aging/payment-bucket and adjudication summary fields.

-- ── CPT aggregate columns (PhiLife uses rolled-up format for LineLevel) ───────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CPTCodeXUnitsXModifierOrginal')
    ALTER TABLE dbo.LineLevelData ADD CPTCodeXUnitsXModifierOrginal NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CPTCodeXUnitsXModifier')
    ALTER TABLE dbo.LineLevelData ADD CPTCodeXUnitsXModifier NVARCHAR(MAX) NULL;

-- ── Patient / billing extra fields ───────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PatientName')
    ALTER TABLE dbo.LineLevelData ADD PatientName NVARCHAR(1000) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'BilledUnbilled')
    ALTER TABLE dbo.LineLevelData ADD BilledUnbilled NVARCHAR(100) NULL;

-- ── Payment / aging summary fields ───────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PaymentPercent')
    ALTER TABLE dbo.LineLevelData ADD PaymentPercent NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'Aging')
    ALTER TABLE dbo.LineLevelData ADD Aging NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'AgingBucket')
    ALTER TABLE dbo.LineLevelData ADD AgingBucket NVARCHAR(200) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'BilledWeek')
    ALTER TABLE dbo.LineLevelData ADD BilledWeek NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PostedWeek')
    ALTER TABLE dbo.LineLevelData ADD PostedWeek NVARCHAR(500) NULL;

-- ── Fully Paid / Adjudicated summary fields ───────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'FullyPaidCount')
    ALTER TABLE dbo.LineLevelData ADD FullyPaidCount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'FullyPaidAmount')
    ALTER TABLE dbo.LineLevelData ADD FullyPaidAmount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'AdjudicatedCount')
    ALTER TABLE dbo.LineLevelData ADD AdjudicatedCount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'AdjudicatedAmount')
    ALTER TABLE dbo.LineLevelData ADD AdjudicatedAmount NVARCHAR(500) NULL;

-- ── 30/60-day bucket fields ────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'Days30Count')
    ALTER TABLE dbo.LineLevelData ADD Days30Count NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'Days30Amount')
    ALTER TABLE dbo.LineLevelData ADD Days30Amount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'Days60Count')
    ALTER TABLE dbo.LineLevelData ADD Days60Count NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'Days60Amount')
    ALTER TABLE dbo.LineLevelData ADD Days60Amount NVARCHAR(500) NULL;

-- ── DOE period fields ──────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'DOE_Year')
    ALTER TABLE dbo.LineLevelData ADD DOE_Year NVARCHAR(20) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'DOE_Month')
    ALTER TABLE dbo.LineLevelData ADD DOE_Month NVARCHAR(20) NULL;

-- ── Mirror changes to LineLevelDataArchive ────────────────────────────────────
IF OBJECT_ID('dbo.LineLevelDataArchive') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'CPTCodeXUnitsXModifierOrginal')
        ALTER TABLE dbo.LineLevelDataArchive ADD CPTCodeXUnitsXModifierOrginal NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'CPTCodeXUnitsXModifier')
        ALTER TABLE dbo.LineLevelDataArchive ADD CPTCodeXUnitsXModifier NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PatientName')
        ALTER TABLE dbo.LineLevelDataArchive ADD PatientName NVARCHAR(1000) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'BilledUnbilled')
        ALTER TABLE dbo.LineLevelDataArchive ADD BilledUnbilled NVARCHAR(100) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PaymentPercent')
        ALTER TABLE dbo.LineLevelDataArchive ADD PaymentPercent NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'Aging')
        ALTER TABLE dbo.LineLevelDataArchive ADD Aging NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'AgingBucket')
        ALTER TABLE dbo.LineLevelDataArchive ADD AgingBucket NVARCHAR(200) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'BilledWeek')
        ALTER TABLE dbo.LineLevelDataArchive ADD BilledWeek NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PostedWeek')
        ALTER TABLE dbo.LineLevelDataArchive ADD PostedWeek NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'FullyPaidCount')
        ALTER TABLE dbo.LineLevelDataArchive ADD FullyPaidCount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'FullyPaidAmount')
        ALTER TABLE dbo.LineLevelDataArchive ADD FullyPaidAmount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'AdjudicatedCount')
        ALTER TABLE dbo.LineLevelDataArchive ADD AdjudicatedCount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'AdjudicatedAmount')
        ALTER TABLE dbo.LineLevelDataArchive ADD AdjudicatedAmount NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'Days30Count')
        ALTER TABLE dbo.LineLevelDataArchive ADD Days30Count NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'Days30Amount')
        ALTER TABLE dbo.LineLevelDataArchive ADD Days30Amount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'Days60Count')
        ALTER TABLE dbo.LineLevelDataArchive ADD Days60Count NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'Days60Amount')
        ALTER TABLE dbo.LineLevelDataArchive ADD Days60Amount NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'DOE_Year')
        ALTER TABLE dbo.LineLevelDataArchive ADD DOE_Year NVARCHAR(20) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'DOE_Month')
        ALTER TABLE dbo.LineLevelDataArchive ADD DOE_Month NVARCHAR(20) NULL;
END

PRINT 'PhiLife LineLevel alter script completed.';
