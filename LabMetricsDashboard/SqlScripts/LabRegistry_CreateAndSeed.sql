-- ============================================================
-- LabRegistry  –  Central lab database registry for CPT Search
-- Deploy to: LRNMaster  (DefaultConnection database)
--
-- Column defaults cover ALL labs based on field mappings:
--   LineLevelData  → CPTCode, Units, Modifier, Panelname,
--                    DenialCode, ClaimStatus, PayerName, PayerType,
--                    DateofService, TotalPayments, ChargeAmount
--   ClaimLevelData → CPTCodeXUnitsXModifier, ClaimID, Panelname,
--                    ClaimStatus, DenialCode, TotalPayments, ChargeAmount
--
-- To add a new lab: INSERT one row.
-- To disable a lab: UPDATE IsActive = 0.
-- To override a field name: UPDATE the specific column.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabRegistry' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabRegistry
    (
        -- ── Identity ──────────────────────────────────────────────────────────
        LabId           INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
        LabName         NVARCHAR(100)  NOT NULL,   -- config key  e.g. 'Augustus_LRN'
        DisplayName     NVARCHAR(100)  NOT NULL,   -- UI label    e.g. 'Augustus Labs'
        DbName          NVARCHAR(100)  NOT NULL,   -- SQL DB name e.g. 'Augustus_LRN'

        -- ── LineLevelData column names ────────────────────────────────────────
        -- Override only when a specific lab uses a different column name.
        -- All defaults sourced from FieldMappings.json.
        LineTableName       NVARCHAR(100)  NOT NULL DEFAULT 'LineLevelData',
        LineCptCodeCol      NVARCHAR(100)  NOT NULL DEFAULT 'CPTCode',
        LineUnitsCol        NVARCHAR(100)  NOT NULL DEFAULT 'Units',
        LineModifierCol     NVARCHAR(100)  NOT NULL DEFAULT 'Modifier',
        LinePanelCol        NVARCHAR(100)  NOT NULL DEFAULT 'Panelname',
        LineDenialCol       NVARCHAR(100)  NOT NULL DEFAULT 'DenialCode',
        LineClaimStatusCol  NVARCHAR(100)  NOT NULL DEFAULT 'ClaimStatus',
        LinePayerNameCol    NVARCHAR(100)  NOT NULL DEFAULT 'PayerName',
        LinePayerTypeCol    NVARCHAR(100)  NOT NULL DEFAULT 'PayerType',
        LineDosCol          NVARCHAR(100)  NOT NULL DEFAULT 'DateofService',
        LineTotalPayCol     NVARCHAR(100)  NOT NULL DEFAULT 'TotalPayments',
        LineChargeCol       NVARCHAR(100)  NOT NULL DEFAULT 'ChargeAmount',

        -- ── ClaimLevelData column names ───────────────────────────────────────
        ClaimTableName      NVARCHAR(100)  NOT NULL DEFAULT 'ClaimLevelData',
        ClaimCptComboCol    NVARCHAR(100)  NOT NULL DEFAULT 'CPTCodeXUnitsXModifier',
        ClaimClaimIdCol     NVARCHAR(100)  NOT NULL DEFAULT 'ClaimID',
        ClaimPanelCol       NVARCHAR(100)  NOT NULL DEFAULT 'Panelname',
        ClaimStatusCol      NVARCHAR(100)  NOT NULL DEFAULT 'ClaimStatus',
        ClaimDenialCol      NVARCHAR(100)  NOT NULL DEFAULT 'DenialCode',
        ClaimTotalPayCol    NVARCHAR(100)  NOT NULL DEFAULT 'TotalPayments',
        ClaimChargeCol      NVARCHAR(100)  NOT NULL DEFAULT 'ChargeAmount',

        -- ── Control ───────────────────────────────────────────────────────────
        IsActive        BIT            NOT NULL DEFAULT 1,
        SortOrder       INT            NOT NULL DEFAULT 0,
        Notes           NVARCHAR(500)  NULL,
        CreatedAt       DATETIME       NOT NULL DEFAULT GETDATE(),
        UpdatedAt       DATETIME       NOT NULL DEFAULT GETDATE()
    );

    PRINT 'dbo.LabRegistry created.';
END
ELSE
BEGIN
    PRINT 'dbo.LabRegistry already exists — skipping CREATE.';
END
GO

-- ============================================================
-- Seed: 10 labs
-- All use default column names from the field mapping files.
-- Only DbName and DisplayName differ per row.
-- ============================================================

-- Use MERGE so re-running this script is safe (idempotent).
MERGE dbo.LabRegistry AS tgt
USING (VALUES
    -- LabName,            DisplayName,         DbName,          SortOrder, Notes
    ( 'Augustus_LRN',  'Augustus Labs',      'Augustus_LRN',  1,  'Augustus Laboratories' ),
    ( 'Beech_Tree',    'Beech Tree',         'Beech_Tree',    2,  NULL ),
    ( 'Certus_LRN',    'Certus',             'Certus_LRN',    3,  'Certus Laboratories' ),
    ( 'CoveLRN',       'Cove',               'CoveLRN',       4,  NULL ),
    ( 'Elixir_LRN',    'Elixir',             'Elixir_LRN',    5,  NULL ),
    ( 'InHealthDTRLRN','InHealth DTR',        'InHealthDTRLRN',6,  NULL ),
    ( 'NWL',           'NorthWest Labs',     'NWL',           7,  NULL ),
    ( 'PCRLOA',        'PCR Labs of America','PCRLOA',         8,  NULL ),
    ( 'Phi_Life',      'Phi Life',           'Phi_Life',      9,  NULL ),
    ( 'Rising_Tides',  'Rising Tides',       'Rising_Tides',  10, NULL )
) AS src (LabName, DisplayName, DbName, SortOrder, Notes)
ON tgt.LabName = src.LabName

WHEN MATCHED THEN
    UPDATE SET
        DisplayName = src.DisplayName,
        DbName      = src.DbName,
        SortOrder   = src.SortOrder,
        Notes       = src.Notes,
        UpdatedAt   = GETDATE()

WHEN NOT MATCHED BY TARGET THEN
    INSERT (LabName, DisplayName, DbName, SortOrder, Notes)
    VALUES (src.LabName, src.DisplayName, src.DbName, src.SortOrder, src.Notes);

PRINT CAST(@@ROWCOUNT AS NVARCHAR(10)) + ' row(s) merged into dbo.LabRegistry.';
GO

-- ============================================================
-- Verify
-- ============================================================
SELECT LabId, LabName, DisplayName, DbName, IsActive, SortOrder
FROM   dbo.LabRegistry
ORDER  BY SortOrder;
GO

-- ============================================================
-- USAGE NOTES
-- ============================================================
-- Add a new lab:
--   INSERT INTO dbo.LabRegistry (LabName, DisplayName, DbName, SortOrder)
--   VALUES ('NewLab_LRN', 'New Lab', 'NewLab_LRN', 11);
--
-- Disable a lab without deleting:
--   UPDATE dbo.LabRegistry SET IsActive = 0 WHERE LabName = 'Beech_Tree';
--
-- Override a column name for one lab (e.g. different DOS column):
--   UPDATE dbo.LabRegistry
--   SET    LineDosCol = 'ServiceDate'
--   WHERE  LabName = 'SomeLab_LRN';
-- ============================================================
