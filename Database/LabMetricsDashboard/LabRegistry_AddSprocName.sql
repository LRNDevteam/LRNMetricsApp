-- ============================================================
-- LabRegistry  –  Add SprocName column
-- Deploy on: LRNMaster
--
-- Adds an explicit SprocName so the C# calls the correct SP
-- regardless of how the lab config key is named.
-- ============================================================

-- Step 1: Add SprocName column if it doesn't already exist
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.LabRegistry')
      AND name = 'SprocName')
BEGIN
    ALTER TABLE dbo.LabRegistry
        ADD SprocName NVARCHAR(200) NULL;

    PRINT 'SprocName column added.';
END
ELSE
BEGIN
    PRINT 'SprocName column already exists.';
END
GO

-- Step 2: Populate SprocName for all 10 labs
--   Convention: dbo.usp_CPTCodeSearch_{DbName}
--   (SP is named after the DB it queries, not the config key)
UPDATE dbo.LabRegistry SET SprocName = 'dbo.usp_CPTCodeSearch_Augustus_LRN'  WHERE LabName = 'Augustus_LRN';
UPDATE dbo.LabRegistry SET SprocName = 'dbo.usp_CPTCodeSearch_Beech_Tree'    WHERE LabName = 'Beech_Tree';
UPDATE dbo.LabRegistry SET SprocName = 'dbo.usp_CPTCodeSearch_Certus_LRN'    WHERE LabName = 'Certus_LRN';
UPDATE dbo.LabRegistry SET SprocName = 'dbo.usp_CPTCodeSearch_CoveLRN'       WHERE LabName = 'CoveLRN';
UPDATE dbo.LabRegistry SET SprocName = 'dbo.usp_CPTCodeSearch_Elixir_LRN'    WHERE LabName = 'Elixir_LRN';
UPDATE dbo.LabRegistry SET SprocName = 'dbo.usp_CPTCodeSearch_InHealthDTRLRN' WHERE LabName = 'InHealthDTRLRN';
UPDATE dbo.LabRegistry SET SprocName = 'dbo.usp_CPTCodeSearch_NWL'           WHERE LabName = 'NWL';
UPDATE dbo.LabRegistry SET SprocName = 'dbo.usp_CPTCodeSearch_PCRLOA'        WHERE LabName = 'PCRLOA';
UPDATE dbo.LabRegistry SET SprocName = 'dbo.usp_CPTCodeSearch_Phi_Life'      WHERE LabName = 'Phi_Life';
UPDATE dbo.LabRegistry SET SprocName = 'dbo.usp_CPTCodeSearch_Rising_Tides'  WHERE LabName = 'Rising_Tides';
GO

-- Step 3: Verify
SELECT LabId, LabName, DisplayName, DbName, SprocName, IsActive
FROM   dbo.LabRegistry
ORDER  BY SortOrder;
GO

-- ── Notes ──────────────────────────────────────────────────────────────────
-- Only Augustus_LRN has the SP deployed so far.
-- Other labs show IsActive=1 but their SP doesn't exist yet — the C# will
-- catch the "could not find stored procedure" error and show a pending badge.
--
-- To mark a lab as not yet deployed (suppress error in UI):
--   UPDATE dbo.LabRegistry SET IsActive = 0 WHERE LabName <> 'Augustus_LRN';
-- ──────────────────────────────────────────────────────────────────────────
