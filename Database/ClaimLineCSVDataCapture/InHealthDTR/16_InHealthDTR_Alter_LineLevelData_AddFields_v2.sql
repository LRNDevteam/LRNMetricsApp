-- =====================================================================
-- InHealthDTR — Add NEW LineLevelData columns (v2 CSV layout)
-- New CSV headers introduced: CPTXUnitsxMod, Payment %, Facility, ClientAccNum.
--
-- NOTE: "CPTUnits" and "Posted Week" CSV headers no longer appear in the
-- v2 layout. The existing CPTUnits / PostedWeek columns are left in place
-- (unused going forward) to avoid any data loss.
--
-- Safe to re-run (IF NOT EXISTS guards).
-- =====================================================================

SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CPTXUnitsxMod')
    ALTER TABLE dbo.LineLevelData ADD CPTXUnitsxMod NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PaymentPercent')
    ALTER TABLE dbo.LineLevelData ADD PaymentPercent NVARCHAR(100) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'Facility')
    ALTER TABLE dbo.LineLevelData ADD Facility NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'ClientAccNum')
    ALTER TABLE dbo.LineLevelData ADD ClientAccNum NVARCHAR(500) NULL;

GO

-- ── Archive table (mirror the same columns) ──────────────────────────────────
IF OBJECT_ID('dbo.LineLevelDataArchive', 'U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'CPTXUnitsxMod')
        ALTER TABLE dbo.LineLevelDataArchive ADD CPTXUnitsxMod NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PaymentPercent')
        ALTER TABLE dbo.LineLevelDataArchive ADD PaymentPercent NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'Facility')
        ALTER TABLE dbo.LineLevelDataArchive ADD Facility NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'ClientAccNum')
        ALTER TABLE dbo.LineLevelDataArchive ADD ClientAccNum NVARCHAR(500) NULL;
END
GO

PRINT '16_InHealthDTR_Alter_LineLevelData_AddFields_v2.sql completed.';
GO
