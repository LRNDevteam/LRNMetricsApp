-- ============================================================
-- PCR_CS_PanelAverages  –  Add AvgAdjudicated column
-- Run on: the PCR lab database (PCRLOA or whichever DB holds this table)
-- ============================================================

-- Step 1: Add AvgAdjudicated column after AdjucticatedAmount
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE  object_id = OBJECT_ID('dbo.PCR_CS_PanelAverages')
      AND  name = 'AvgAdjudicated')
BEGIN
    ALTER TABLE dbo.PCR_CS_PanelAverages
        ADD AvgAdjudicated DECIMAL(18,2) NOT NULL DEFAULT 0;

    PRINT 'AvgAdjudicated column added to dbo.PCR_CS_PanelAverages.';
END
ELSE
BEGIN
    PRINT 'AvgAdjudicated already exists — skipped.';
END
GO

-- Step 2: Back-fill existing rows
UPDATE dbo.PCR_CS_PanelAverages
SET    AvgAdjudicated = CASE
           WHEN AdjucticatedCount > 0
           THEN AdjucticatedAmount / AdjucticatedCount
           ELSE 0
       END;

PRINT 'Back-fill complete. Rows updated: ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- Step 3: Verify
SELECT TOP 10
    PanelName, PayerName,
    AdjucticatedCount, AdjucticatedAmount, AvgAdjudicated,
    RefreshedAt
FROM dbo.PCR_CS_PanelAverages
ORDER BY AdjucticatedAmount DESC;
GO
