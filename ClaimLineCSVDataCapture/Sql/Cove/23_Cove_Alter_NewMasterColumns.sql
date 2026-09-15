SET NOCOUNT ON;

-- ============================================================================================
-- Migration: columns the NEW Cove master tables carry that the destination tables cannot hold
-- File  : 23_Cove_Alter_NewMasterColumns.sql
--
-- Source of truth:
--   LabMetricsDashboard\Template\Cove_ColumMapping_NewMasterReports_v1.0.xlsx
--   Every row this script acts on is one the workbook flags "Missing", meaning the new master
--   carries the column and the application report has nowhere to put it.
--
--   Rows flagged "Required" are NOT touched: those are columns the application derives or
--   generates (PayerName, Payer_Code, DaystoBill, RowHash, ...) and they already exist.
--   Rows flagged "Not Required" are NOT touched either, per instruction - they stay as they are
--   and are dealt with in the UI.
--
-- Two workbook rows are deliberately skipped because the column ALREADY EXISTS:
--   T/F       -> dbo.LineLevelData.T_F and dbo.ClaimLevelData.T_F
--   Provider  -> dbo.LineLevelData.BillingProvider (the Claim Level sheet maps it there and the
--                column is present on both tables; only the Line Level sheet leaves it blank)
--
-- Types: every data column on these two tables is NVARCHAR - the loader writes CSV text and lets
--   the reporting layer parse it - so a source DATE or FLOAT becomes NVARCHAR here too. Widths
--   follow the source: NVARCHAR(1000) sources get 1000 rather than the table's older 500, because
--   SqlBulkCopy fails the whole load on an overflow rather than truncating.
--
-- Adding NULLable columns is a metadata-only change: no row is rewritten and no data is moved.
-- Safe to re-run - every statement is guarded.
--
-- THE SCHEMA SIDE IS ALREADY DONE. Both halves ship together:
--   Schemas\LineLevel.schema.json (+4) and ClaimLevel.schema.json (+2) - dedicated columns for
--     the handful of source headers a greedy alias on another column was swallowing. Without
--     these, those headers never reach the CSV at all, so no mapping could rescue them.
--   Schemas\LabMappings\CoveFieldMappings.Json (+23 line, +19 claim) - the CsvHeader/SqlColumn
--     pair for every column added below.
--
-- The Cove LAB schemas (Cove_LineLevel / Cove_ClaimLevel) are deliberately NOT changed. A header
-- declared there becomes "lab preferred" and sorts ahead of a common column's own aliases, so
-- declaring [Claim Level CPT] would make CPTCode bind to the CLAIM level value instead of
-- [Procedure]. Leaving them alone is what keeps today's bindings intact.
--
-- Cove loads both levels with SqlBulkCopy (BulkCopyToTable = true), so the TVP types and
-- usp_BulkInsert* procedures in 04_/05_ are off the live path and need no change for this.
-- ============================================================================================


-- ── dbo.LineLevelData ───────────────────────────────────────────────────────────────────────
-- 23 columns. The Line Level master carries claim-level context alongside the line, which is why
-- ClaimLevelCPT / ClaimLevelDenialCode / ClaimLevelICD appear on the LINE table: they sit beside
-- the existing LineLevelCPT, LineLevelDenialCode and ICDCode (which holds Line Level ICD).

IF COL_LENGTH('dbo.LineLevelData', 'PlanName') IS NULL
    ALTER TABLE dbo.LineLevelData ADD PlanName NVARCHAR(1000) NULL;          -- [Plan Name]
GO
IF COL_LENGTH('dbo.LineLevelData', 'PanelNameLIS') IS NULL
    ALTER TABLE dbo.LineLevelData ADD PanelNameLIS NVARCHAR(1000) NULL;      -- [LIS Panel Name]
GO
IF COL_LENGTH('dbo.LineLevelData', 'PanelNameBasedOnCPT') IS NULL
    ALTER TABLE dbo.LineLevelData ADD PanelNameBasedOnCPT NVARCHAR(1000) NULL; -- [Panel Name as per CPT]
GO
IF COL_LENGTH('dbo.LineLevelData', 'ServiceLocation') IS NULL
    ALTER TABLE dbo.LineLevelData ADD ServiceLocation NVARCHAR(1000) NULL;   -- [Service Location]
GO
IF COL_LENGTH('dbo.LineLevelData', 'BillType') IS NULL
    ALTER TABLE dbo.LineLevelData ADD BillType NVARCHAR(1000) NULL;          -- [Bill Type]
GO
IF COL_LENGTH('dbo.LineLevelData', 'ClaimLevelCPT') IS NULL
    ALTER TABLE dbo.LineLevelData ADD ClaimLevelCPT NVARCHAR(MAX) NULL;      -- [Claim Level CPT]
GO
IF COL_LENGTH('dbo.LineLevelData', 'ClaimLevelDenialCode') IS NULL
    ALTER TABLE dbo.LineLevelData ADD ClaimLevelDenialCode NVARCHAR(MAX) NULL; -- [Claim Level Denial Code]
GO
IF COL_LENGTH('dbo.LineLevelData', 'ClaimLevelICD') IS NULL
    ALTER TABLE dbo.LineLevelData ADD ClaimLevelICD NVARCHAR(MAX) NULL;      -- [Claim Level ICD]
GO
IF COL_LENGTH('dbo.LineLevelData', 'ManualCWO') IS NULL
    ALTER TABLE dbo.LineLevelData ADD ManualCWO NVARCHAR(500) NULL;          -- [Manual CWO]
GO
IF COL_LENGTH('dbo.LineLevelData', 'PhysicianNPI') IS NULL
    ALTER TABLE dbo.LineLevelData ADD PhysicianNPI NVARCHAR(1000) NULL;      -- [Physician NPI]
GO
-- Distinct from FirstBilledDate, which holds [LastBillDate]. The master carries both.
IF COL_LENGTH('dbo.LineLevelData', 'LastBilledDate') IS NULL
    ALTER TABLE dbo.LineLevelData ADD LastBilledDate NVARCHAR(500) NULL;     -- [Last Billed Date]
GO
IF COL_LENGTH('dbo.LineLevelData', 'ClaimState') IS NULL
    ALTER TABLE dbo.LineLevelData ADD ClaimState NVARCHAR(1000) NULL;        -- [Claim State]
GO
IF COL_LENGTH('dbo.LineLevelData', 'SubState') IS NULL
    ALTER TABLE dbo.LineLevelData ADD SubState NVARCHAR(1000) NULL;          -- [Sub State]
GO
IF COL_LENGTH('dbo.LineLevelData', 'ActiveBucket') IS NULL
    ALTER TABLE dbo.LineLevelData ADD ActiveBucket NVARCHAR(1000) NULL;      -- [Active Bucket]
GO
IF COL_LENGTH('dbo.LineLevelData', 'BalanceResponsibility') IS NULL
    ALTER TABLE dbo.LineLevelData ADD BalanceResponsibility NVARCHAR(1000) NULL; -- [Balance Responsibility]
GO
IF COL_LENGTH('dbo.LineLevelData', 'PrimaryDepositDate') IS NULL
    ALTER TABLE dbo.LineLevelData ADD PrimaryDepositDate NVARCHAR(500) NULL; -- [Primary Deposit Date]
GO
IF COL_LENGTH('dbo.LineLevelData', 'SecondaryDepositDate') IS NULL
    ALTER TABLE dbo.LineLevelData ADD SecondaryDepositDate NVARCHAR(500) NULL; -- [Secondary Deposit Date]
GO
IF COL_LENGTH('dbo.LineLevelData', 'PatientDepositDate') IS NULL
    ALTER TABLE dbo.LineLevelData ADD PatientDepositDate NVARCHAR(500) NULL; -- [Patient Deposit Date]
GO
IF COL_LENGTH('dbo.LineLevelData', 'LastUpdatedDate') IS NULL
    ALTER TABLE dbo.LineLevelData ADD LastUpdatedDate NVARCHAR(MAX) NULL;    -- [Last Updated Date]
GO

-- The master's own audit columns. Prefixed Source* so they can never be read as this pipeline's
-- audit trail: InsertedDateTime and IngestedOn already mean "when LRN loaded the row", and
-- dbo.LIMSMaster.CreatedOn means the same thing again.
IF COL_LENGTH('dbo.LineLevelData', 'SourceCreatedOn') IS NULL
    ALTER TABLE dbo.LineLevelData ADD SourceCreatedOn NVARCHAR(500) NULL;    -- [Created On]
GO
IF COL_LENGTH('dbo.LineLevelData', 'SourceCreatedBy') IS NULL
    ALTER TABLE dbo.LineLevelData ADD SourceCreatedBy NVARCHAR(1000) NULL;   -- [Created By]
GO
IF COL_LENGTH('dbo.LineLevelData', 'SourceUpdatedOn') IS NULL
    ALTER TABLE dbo.LineLevelData ADD SourceUpdatedOn NVARCHAR(500) NULL;    -- [Updated On]
GO
IF COL_LENGTH('dbo.LineLevelData', 'SourceUpdatedBy') IS NULL
    ALTER TABLE dbo.LineLevelData ADD SourceUpdatedBy NVARCHAR(1000) NULL;   -- [Updated By]
GO


-- ── dbo.ClaimLevelData ──────────────────────────────────────────────────────────────────────
-- 19 columns. Fewer than the line table because the claim master's extra summary columns
-- (Total WO, Bill Status, the paid and bucket counts, Panel Name as per CPT) already have homes.

IF COL_LENGTH('dbo.ClaimLevelData', 'PlanName') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD PlanName NVARCHAR(1000) NULL;         -- [Plan Name]
GO
IF COL_LENGTH('dbo.ClaimLevelData', 'ServiceLocation') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD ServiceLocation NVARCHAR(1000) NULL;  -- [Service Location]
GO
IF COL_LENGTH('dbo.ClaimLevelData', 'BillType') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD BillType NVARCHAR(1000) NULL;         -- [Bill Type]
GO

-- The master has THREE denial-code columns: [Denial Code], [Line Level Denial Code] and
-- [Claim Level Denial Code], and this table has homes for only two of them.
--
-- Which one is homeless was settled by tracing the exporter rather than by reading the mapping
-- workbook, and the two disagree. The workbook says [Claim Level Denial Code] lands in DenialCode.
-- It does not: Cove's claim schema declares the plain [Denial Code], a lab-declared spelling sorts
-- ahead of a common alias, so DenialCode binds to the plain column and the claim-level spelling is
-- consumed and dropped. The new column therefore takes the CLAIM LEVEL value, and DenialCode keeps
-- meaning exactly what it means today - no existing populated column changes its contents.
IF COL_LENGTH('dbo.ClaimLevelData', 'ClaimLevelDenialCode') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD ClaimLevelDenialCode NVARCHAR(MAX) NULL; -- [Claim Level Denial Code]
GO
IF COL_LENGTH('dbo.ClaimLevelData', 'ManualCWO') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD ManualCWO NVARCHAR(500) NULL;         -- [Manual CWO]
GO
IF COL_LENGTH('dbo.ClaimLevelData', 'PhysicianNPI') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD PhysicianNPI NVARCHAR(1000) NULL;     -- [Physician NPI]
GO
IF COL_LENGTH('dbo.ClaimLevelData', 'ClaimState') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD ClaimState NVARCHAR(1000) NULL;       -- [Claim State]
GO
IF COL_LENGTH('dbo.ClaimLevelData', 'SubState') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD SubState NVARCHAR(1000) NULL;         -- [Sub State]
GO
IF COL_LENGTH('dbo.ClaimLevelData', 'ActiveBucket') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD ActiveBucket NVARCHAR(1000) NULL;     -- [Active Bucket]
GO
IF COL_LENGTH('dbo.ClaimLevelData', 'BalanceResponsibility') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD BalanceResponsibility NVARCHAR(1000) NULL; -- [Balance Responsibility]
GO
IF COL_LENGTH('dbo.ClaimLevelData', 'PrimaryDepositDate') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD PrimaryDepositDate NVARCHAR(500) NULL; -- [Primary Deposit Date]
GO
IF COL_LENGTH('dbo.ClaimLevelData', 'SecondaryDepositDate') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD SecondaryDepositDate NVARCHAR(500) NULL; -- [Secondary Deposit Date]
GO
IF COL_LENGTH('dbo.ClaimLevelData', 'PatientDepositDate') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD PatientDepositDate NVARCHAR(500) NULL; -- [Patient Deposit Date]
GO
IF COL_LENGTH('dbo.ClaimLevelData', 'LastUpdatedDate') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD LastUpdatedDate NVARCHAR(MAX) NULL;   -- [Last Updated Date]
GO
IF COL_LENGTH('dbo.ClaimLevelData', 'SourceCreatedOn') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD SourceCreatedOn NVARCHAR(500) NULL;   -- [Created On]
GO
IF COL_LENGTH('dbo.ClaimLevelData', 'SourceCreatedBy') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD SourceCreatedBy NVARCHAR(1000) NULL;  -- [Created By]
GO
IF COL_LENGTH('dbo.ClaimLevelData', 'SourceUpdatedOn') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD SourceUpdatedOn NVARCHAR(500) NULL;   -- [Updated On]
GO
IF COL_LENGTH('dbo.ClaimLevelData', 'SourceUpdatedBy') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD SourceUpdatedBy NVARCHAR(1000) NULL;  -- [Updated By]
GO

-- [LastBillDate] and [Last Billed Date] are two different master columns and both currently
-- resolve to FirstBilledDate: the first supplies the value, the second is marked as consumed and
-- then discarded. FirstBilledDate keeps taking [LastBillDate]; this column takes the other.
IF COL_LENGTH('dbo.ClaimLevelData', 'LastBilledDate') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD LastBilledDate NVARCHAR(500) NULL;    -- [Last Billed Date]
GO


-- ============================================================================================
-- SECTION 3 - dbo.LIMSMaster. NOTHING IS REQUIRED. Kept here only so the LIS answer is on record.
--
-- The workbook has no LIS sheet, so dbo.Cove_LIS_Master was compared against
-- Schemas\Cove_LIMS_Schema.json and dbo.LIMSMaster directly. All 51 mapped columns resolve to
-- columns that already exist - no gaps, nothing to add.
--
-- Three source columns are not in the schema JSON:
--   SocialSecurityNumber  DROPPED ON PURPOSE by the sensitive-column policy. It is excluded from
--                         the load and from AdditionalFields, and the exclusion is logged. DO NOT
--                         add a column for it.
--   Time, T/F             Unmapped, so they are captured as JSON in LIMSMaster.AdditionalFields.
--                         Nothing is lost. Promote them to real columns only if a report needs to
--                         filter or join on them - the two statements below do that, and a
--                         matching entry in Cove_LIMS_Schema.json is needed as well.
-- ============================================================================================

-- IF COL_LENGTH('dbo.LIMSMaster', 'T_F') IS NULL
--     ALTER TABLE dbo.LIMSMaster ADD T_F NVARCHAR(50) NULL;                 -- [T/F]
-- GO
-- IF COL_LENGTH('dbo.LIMSMaster', 'CollectionTime') IS NULL
--     ALTER TABLE dbo.LIMSMaster ADD CollectionTime NVARCHAR(50) NULL;      -- [Time]
-- GO


-- ── verification ────────────────────────────────────────────────────────────────────────────
SELECT t.name AS TableName, c.name AS ColumnName,
       ty.name AS DataType, c.max_length, c.is_nullable
FROM sys.columns c
JOIN sys.tables t  ON t.object_id = c.object_id
JOIN sys.types ty  ON ty.user_type_id = c.user_type_id
WHERE t.name IN ('LineLevelData', 'ClaimLevelData')
  AND c.name IN ('PlanName','PanelNameLIS','PanelNameBasedOnCPT','ServiceLocation','BillType',
                 'ClaimLevelCPT','ClaimLevelDenialCode','ClaimLevelICD','ManualCWO','PhysicianNPI',
                 'LastBilledDate','ClaimState','SubState','ActiveBucket','BalanceResponsibility',
                 'PrimaryDepositDate','SecondaryDepositDate','PatientDepositDate','LastUpdatedDate',
                 'SourceCreatedOn','SourceCreatedBy','SourceUpdatedOn','SourceUpdatedBy',
                 'ClaimLevelDenialCode')
ORDER BY t.name, c.name;
