-- ============================================================
-- Deploy: usp_GetNW_ExecutiveSummary to NWL_LRN
-- Run this in SSMS connected to NWL_LRN
-- ============================================================
USE [NWL_LRN];
GO

-- Quick check: verify what @BilledExpr will produce after deploy
-- (should show FirstBilledDate and EmedixSubmissionDate, NOT BilledStatus)
PRINT 'Column detection check:';
SELECT name FROM sys.columns
WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
  AND name IN ('FirstBilledDate','EmedixSubmissionDate','BilledStatus','Billed','BillStatus')
ORDER BY name;
GO

-- ============================================================
-- Paste and run the full contents of 31_NW_ExecutiveSummary_Read.sql below
-- (starting from SET NOCOUNT ON through the final GO)
-- ============================================================
