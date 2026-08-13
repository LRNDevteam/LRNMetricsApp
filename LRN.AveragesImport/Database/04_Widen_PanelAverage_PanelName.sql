-- LRN Averages Import Worker — widen PanelAverage.PanelName.
--
-- PanelAverage.PanelName was NVARCHAR(50). At claim level, dbo.ClaimLevelData.Panelname
-- holds the comma-joined SET of panels on the claim, not a single panel, so it grows with
-- the number of panels a claim covers. Augustus overflows today:
--
--   "String or binary data would be truncated in table 'PanelAverage', column 'PanelName'.
--    Truncated value: 'LABCORP,MOLECULAR,Pathology,ROUTINE BLOOD,TOXICOLO'."
--
-- and the whole panel import for that lab rolls back. Measured maximums across all
-- 12 lab databases: Augustus 52, BeechTree 50 (exactly at the old limit), NorthWest 47,
-- RisingTides 37, everything else <= 32.
--
-- Sized to NVARCHAR(500) to match the source column (ClaimLevelData.Panelname is itself
-- NVARCHAR(500)), which makes truncation impossible by construction rather than merely
-- unlikely — important because a lab adding one more panel to a claim lengthens this
-- value with no upper bound of its own.
--
-- Truncating instead was not an option: two different panel sets that share a 50-char
-- prefix would collapse into one group and silently blend their averages.
--
-- PanelName participates in the non-unique index IX_PanelAverage_Payer_Panel
-- (PayerID, PanelName, WindowType). At the new width that key is
-- 50*2 + 500*2 + 50*2 = 1200 bytes, still inside the 1700-byte nonclustered limit,
-- so the index stays valid and needs no rebuild.
--
-- Idempotent — safe to re-run. Run this in addition to 03_Averages_v1_1_Columns.sql.
USE LRNMaster;
GO

IF EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.PanelAverage')
      AND name = 'PanelName'
      AND max_length < 1000)          -- max_length is in bytes; NVARCHAR(500) = 1000
BEGIN
    ALTER TABLE dbo.PanelAverage ALTER COLUMN PanelName NVARCHAR(500) NULL;
    PRINT 'dbo.PanelAverage.PanelName -> NVARCHAR(500)';
END
ELSE
    PRINT 'dbo.PanelAverage.PanelName already NVARCHAR(500) or wider — no change';
GO

/* --------------------------------------------------------------------- Verify */
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE (TABLE_NAME = 'PanelAverage' AND COLUMN_NAME IN ('PanelName', 'PayerID', 'PayerDisplayName', 'LabName'))
   OR (TABLE_NAME = 'CPTAverage'   AND COLUMN_NAME IN ('PanelName', 'CPTCode', 'PayerDisplayName'))
ORDER BY TABLE_NAME, COLUMN_NAME;
GO
