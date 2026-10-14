-- =====================================================================
-- InHealthDTR — Add missing ClaimLevelData columns for Collection Summary
-- Adds DOE_Year, DOE_Month, AgingBucket, and other collection-required
-- fields that are not in the base 01_CreateTables.sql schema.
-- Safe to re-run (IF NOT EXISTS guards).
-- =====================================================================

SET NOCOUNT ON;
GO

-- ── DOE period fields ─────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'DOE_Year')
    ALTER TABLE dbo.ClaimLevelData ADD DOE_Year NVARCHAR(20) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'DOE_Month')
    ALTER TABLE dbo.ClaimLevelData ADD DOE_Month NVARCHAR(20) NULL;

-- ── Aging bucket label ────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'AgingBucket')
    ALTER TABLE dbo.ClaimLevelData ADD AgingBucket NVARCHAR(200) NULL;

-- ── Billed/Unbilled flag ──────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'BilledUnbilled')
    ALTER TABLE dbo.ClaimLevelData ADD BilledUnbilled NVARCHAR(100) NULL;

-- ── Modifier ──────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Modifier')
    ALTER TABLE dbo.ClaimLevelData ADD Modifier NVARCHAR(500) NULL;

-- ── CPT individual columns ────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'CPTCode')
    ALTER TABLE dbo.ClaimLevelData ADD CPTCode NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Units')
    ALTER TABLE dbo.ClaimLevelData ADD Units NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'CPTCodeXUnitsXModifierOrginal')
    ALTER TABLE dbo.ClaimLevelData ADD CPTCodeXUnitsXModifierOrginal NVARCHAR(MAX) NULL;

-- ── PaymentPercent ────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PaymentPercent')
    ALTER TABLE dbo.ClaimLevelData ADD PaymentPercent NVARCHAR(100) NULL;

-- ── Adjudicated count (base has AdjudicatedAmount; InHealthDTR also needs count)
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'AdjudicatedCount')
    ALTER TABLE dbo.ClaimLevelData ADD AdjudicatedCount NVARCHAR(500) NULL;

-- ── 30-day bucket ─────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Days30Count')
    ALTER TABLE dbo.ClaimLevelData ADD Days30Count NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Days30Amount')
    ALTER TABLE dbo.ClaimLevelData ADD Days30Amount NVARCHAR(500) NULL;

-- ── 60-day bucket ─────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Days60Count')
    ALTER TABLE dbo.ClaimLevelData ADD Days60Count NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Days60Amount')
    ALTER TABLE dbo.ClaimLevelData ADD Days60Amount NVARCHAR(500) NULL;

-- ── FullyPaidCount / FullyPaidAmount ──────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'FullyPaidCount')
    ALTER TABLE dbo.ClaimLevelData ADD FullyPaidCount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'FullyPaidAmount')
    ALTER TABLE dbo.ClaimLevelData ADD FullyPaidAmount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'AdjudicatedAmount')
    ALTER TABLE dbo.ClaimLevelData ADD AdjudicatedAmount NVARCHAR(500) NULL;


IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PatientName')
 ALTER TABLE dbo.ClaimLevelData ADD PatientName NVARCHAR(1000) NULL;
 
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'BilledWeek')
 ALTER TABLE dbo.ClaimLevelData ADD BilledWeek NVARCHAR(500) NULL;


IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PostedWeek')
 ALTER TABLE dbo.ClaimLevelData ADD PostedWeek NVARCHAR(500) NULL;

GO


-- ── Archive table (mirror the same columns) ──────────────────────────────────
IF OBJECT_ID('dbo.ClaimLevelDataArchive', 'U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'DOE_Year')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD DOE_Year NVARCHAR(20) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'DOE_Month')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD DOE_Month NVARCHAR(20) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'AgingBucket')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD AgingBucket NVARCHAR(200) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'BilledUnbilled')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD BilledUnbilled NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Modifier')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD Modifier NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'CPTCode')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD CPTCode NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Units')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD Units NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'CPTCodeXUnitsXModifierOrginal')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD CPTCodeXUnitsXModifierOrginal NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PaymentPercent')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD PaymentPercent NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'AdjudicatedCount')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD AdjudicatedCount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Days30Count')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD Days30Count NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Days30Amount')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD Days30Amount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Days60Count')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD Days60Count NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Days60Amount')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD Days60Amount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'FullyPaidCount')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD FullyPaidCount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'FullyPaidAmount')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD FullyPaidAmount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'AdjudicatedAmount')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD AdjudicatedAmount NVARCHAR(500) NULL;
END
GO

PRINT '02_InHealthDTR_Alter_ClaimLevelData_AddFields.sql completed.';
GO
