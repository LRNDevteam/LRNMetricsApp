-- LRN Averages Import Worker — schema for SOP v1.1.
--
-- The worker now computes CPTAverage / PanelAverage directly from each lab's
-- dbo.LineLevelData (CPT level) and dbo.ClaimLevelData (panel level) instead of
-- reading CSVs. v1.1 needs four things the live schema does not have:
--
--   RunId                 the sp_GetRecentSuccessRunByLab run the rows came from.
--                         Also the dedup key: a lab+RunId already present is skipped.
--   WindowBasis           'DOS' or 'Billed' — v1.1 classifies every row twice, once
--                         off Days to DOS and once off Days to Bill, and each basis
--                         is its own set of rows.
--   MedianAllowedAmount   §1.1.3 / §2.1.3
--   ModeAllowedAmount     §1.1.5 / §2.1.5
--   ModePaidAmount        §1.1.6 / §2.1.6 (mode of the insurance payment)
--
-- The SOP's "Median Insurance Payment" lands in the existing MedianPaidAmount column
-- ("Paid" is the insurance payment throughout these tables), so it is not added here.
--
-- All new columns are NULLable with no default: existing readers are untouched, and a
-- group with no scored amounts writes NULL rather than a misleading zero.
-- Idempotent — safe to re-run.
--
-- NOTE ON EXISTING ROWS: rows written before this change have RunId = NULL and
-- WindowBasis = NULL. The worker replaces all rows for a lab on its next successful
-- run, so they clear themselves lab by lab; nothing here backfills them.
USE LRNMaster;
GO

/* ------------------------------------------------------------------ CPTAverage */
IF COL_LENGTH('dbo.CPTAverage', 'RunId') IS NULL
BEGIN
    ALTER TABLE dbo.CPTAverage ADD RunId NVARCHAR(50) NULL;
    PRINT 'dbo.CPTAverage.RunId added';
END
ELSE PRINT 'dbo.CPTAverage.RunId already exists — no change';
GO

IF COL_LENGTH('dbo.CPTAverage', 'WindowBasis') IS NULL
BEGIN
    ALTER TABLE dbo.CPTAverage ADD WindowBasis NVARCHAR(20) NULL;
    PRINT 'dbo.CPTAverage.WindowBasis added';
END
ELSE PRINT 'dbo.CPTAverage.WindowBasis already exists — no change';
GO

IF COL_LENGTH('dbo.CPTAverage', 'MedianAllowedAmount') IS NULL
BEGIN
    ALTER TABLE dbo.CPTAverage ADD MedianAllowedAmount DECIMAL(18,2) NULL;
    PRINT 'dbo.CPTAverage.MedianAllowedAmount added';
END
ELSE PRINT 'dbo.CPTAverage.MedianAllowedAmount already exists — no change';
GO

IF COL_LENGTH('dbo.CPTAverage', 'ModeAllowedAmount') IS NULL
BEGIN
    ALTER TABLE dbo.CPTAverage ADD ModeAllowedAmount DECIMAL(18,2) NULL;
    PRINT 'dbo.CPTAverage.ModeAllowedAmount added';
END
ELSE PRINT 'dbo.CPTAverage.ModeAllowedAmount already exists — no change';
GO

IF COL_LENGTH('dbo.CPTAverage', 'ModePaidAmount') IS NULL
BEGIN
    ALTER TABLE dbo.CPTAverage ADD ModePaidAmount DECIMAL(18,2) NULL;
    PRINT 'dbo.CPTAverage.ModePaidAmount added';
END
ELSE PRINT 'dbo.CPTAverage.ModePaidAmount already exists — no change';
GO

/* ---------------------------------------------------------------- PanelAverage */
IF COL_LENGTH('dbo.PanelAverage', 'RunId') IS NULL
BEGIN
    ALTER TABLE dbo.PanelAverage ADD RunId NVARCHAR(50) NULL;
    PRINT 'dbo.PanelAverage.RunId added';
END
ELSE PRINT 'dbo.PanelAverage.RunId already exists — no change';
GO

IF COL_LENGTH('dbo.PanelAverage', 'WindowBasis') IS NULL
BEGIN
    ALTER TABLE dbo.PanelAverage ADD WindowBasis NVARCHAR(20) NULL;
    PRINT 'dbo.PanelAverage.WindowBasis added';
END
ELSE PRINT 'dbo.PanelAverage.WindowBasis already exists — no change';
GO

IF COL_LENGTH('dbo.PanelAverage', 'MedianAllowedAmount') IS NULL
BEGIN
    ALTER TABLE dbo.PanelAverage ADD MedianAllowedAmount DECIMAL(18,2) NULL;
    PRINT 'dbo.PanelAverage.MedianAllowedAmount added';
END
ELSE PRINT 'dbo.PanelAverage.MedianAllowedAmount already exists — no change';
GO

IF COL_LENGTH('dbo.PanelAverage', 'ModeAllowedAmount') IS NULL
BEGIN
    ALTER TABLE dbo.PanelAverage ADD ModeAllowedAmount DECIMAL(18,2) NULL;
    PRINT 'dbo.PanelAverage.ModeAllowedAmount added';
END
ELSE PRINT 'dbo.PanelAverage.ModeAllowedAmount already exists — no change';
GO

IF COL_LENGTH('dbo.PanelAverage', 'ModePaidAmount') IS NULL
BEGIN
    ALTER TABLE dbo.PanelAverage ADD ModePaidAmount DECIMAL(18,2) NULL;
    PRINT 'dbo.PanelAverage.ModePaidAmount added';
END
ELSE PRINT 'dbo.PanelAverage.ModePaidAmount already exists — no change';
GO

/* ------------------------------------------------ Dedup / read-path indexes */
-- IsAlreadyImportedAsync probes (LabId, RunId) once per lab per cycle; without these
-- that probe is a full scan of a table the worker is about to rewrite anyway.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_CPTAverage_Lab_Run'
               AND object_id = OBJECT_ID('dbo.CPTAverage'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_CPTAverage_Lab_Run ON dbo.CPTAverage(LabID, RunId);
    PRINT 'IX_CPTAverage_Lab_Run created';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PanelAverage_Lab_Run'
               AND object_id = OBJECT_ID('dbo.PanelAverage'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_PanelAverage_Lab_Run ON dbo.PanelAverage(LabId, RunId);
    PRINT 'IX_PanelAverage_Lab_Run created';
END
GO

/* --------------------------------------------------------------------- Verify */
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, NUMERIC_PRECISION, NUMERIC_SCALE,
       CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME IN ('CPTAverage', 'PanelAverage')
  AND COLUMN_NAME IN ('RunId', 'WindowBasis', 'WindowType',
                      'MedianAllowedAmount', 'MedianPaidAmount',
                      'ModeAllowedAmount', 'ModePaidAmount')
ORDER BY TABLE_NAME, COLUMN_NAME;
GO
