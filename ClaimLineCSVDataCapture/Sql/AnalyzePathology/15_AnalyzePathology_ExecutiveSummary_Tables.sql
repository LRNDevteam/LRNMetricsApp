/* =============================================================================
   Analyze Pathology (prefix AnP_) - GENERATED from Sql/VariantX/15_VariantX_ExecutiveSummary_Tables.sql
   by Generate-FromVariantX.ps1. Edit the VariantX script or the generator, not this file.
   Database: AnalyzePathology

   Analyze Pathology mappings applied on top of the VariantX logic:
     ClaimLevelData.AdjucticatedCount / Bucket30Count / Bucket60Count
         -> Adjudicated / Bucket30 / Bucket60  (AdjucticatedAmount -> AdjudicatedAmount)
     Billed / Unbilled from ClaimLevelData.BilledStatus LIKE 'Unbilled%'
     ClaimStatus 'Fully Denied' counts as 'Denied', '0 Billed Amount' as 'Billed Amount 0'
     LIMSMaster.BillCategory 'Unbilled' counts as 'Not Billed',
         NewStatus 'Yet to Be Validate' as 'Yet to be validated'
     LIMSMaster panel column: PanelName (PanelCategory is never populated)
   Comments further down were written for VariantX ("AnalyzePathology" there
   was substituted for "VariantX").
   ============================================================================= */
/* =============================================================================
   Analyze Pathology — cloned from Elixir (15_Elixir_ExecutiveSummary_Tables.sql)
   Prefix: AnP_ / AnP_CS_ / AnP_ES_
   Refresh: usp_RefreshAnP_*
   Read:    usp_GetAnP_*
   Source tables: dbo.ClaimLevelData, dbo.LineLevelData, dbo.LIMSMaster
   No inline UI queries — dashboard/ReportWorker must call these SPs only.
   ============================================================================= */
-- ============================================================
-- AnalyzePathology – Executive Summary aggregate tables
-- File : 15_AnalyzePathology_ExecutiveSummary_Tables.sql
-- DB   : AnalyzePathology
--
-- Mirrors the PhiLife/PCRLabsofAmerica 15-21 architecture
-- (see PhiLife\15_PhiLife_ExecutiveSummary_Tables.sql), but uses the
-- SIMPLER RoleID scheme provided in the AnalyzePathology LIS/PMS/Cash/Avg
-- breakdown spec:
--   LIS Breakdown   : A, B, C, D (+D.1), E (+E.1-E.6)
--   PMS Breakdown   : F, G, H, I, J, K, L, M, N, O, P (+P.1-P.3)
--   Cash Breakdown  : Q, R, S, T, U, V, W, X (+X.1-X.3)
--   Average/Claim   : Y, Z, AA
--
-- Four category tables (1 row per RoleID per Year-Month).
-- AnP_ES_LIS.RoleID is NVARCHAR(420) to accommodate dynamic B.x panel
-- sub-rows (e.g. 'B.Comprehensive Metabolic Panel') whose names can be long.
--   dbo.AnP_ES_LIS   – LIS Breakdown (A, B, B.x panel sub-rows, C, D, D.1, E, E.1-E.6)
--   dbo.AnP_ES_PMS   – PMS Breakdown (F-P + P.1-P.3)
--   dbo.AnP_ES_Cash  – Cash Breakdown ($) (Q-X + X.1-X.3)
--   dbo.AnP_ES_Avg   – Average Payment Per Claim (Y, Z, AA)
--
-- Columns are intentionally identical across the tables so the
-- display SP (usp_GetAnP_ExecutiveSummary) can union them cleanly.
--   RoleID                 (A, B, C, ... AA)
--   Description            (human-readable label)
--   ESYear                 (DateofService year; 0 = grand total sentinel)
--   ESMonth                (DateofService month; 0 = grand total sentinel)
--   ESMonthClaimCount      (Accession/Claim count)
--   ESMonthChargeAmount    (Dollar value – used by Cash/Avg categories)
-- ============================================================
SET NOCOUNT ON;
GO

-- ── 1. AnP_ES_LIS (LIS Breakdown) ────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'AnP_ES_LIS')
CREATE TABLE dbo.AnP_ES_LIS
(
	Id                  INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
	RoleID              NVARCHAR(420)   NOT NULL,  -- wide: B.x panel names can be long
	Description         NVARCHAR(300)   NOT NULL,
	ESYear              INT             NOT NULL,
	ESMonth             INT             NOT NULL,
	ESMonthClaimCount   INT             NOT NULL DEFAULT 0,
	ESMonthChargeAmount DECIMAL(18,2)   NOT NULL DEFAULT 0,
	RefreshedAt         DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- Widen RoleID if the table already exists with the old NVARCHAR(10) definition.
IF COL_LENGTH('dbo.AnP_ES_LIS', 'RoleID') < 420
	ALTER TABLE dbo.AnP_ES_LIS ALTER COLUMN RoleID NVARCHAR(420) NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_AnP_ES_LIS_Period' AND object_id=OBJECT_ID('dbo.AnP_ES_LIS'))
	CREATE NONCLUSTERED INDEX IX_AnP_ES_LIS_Period
		ON dbo.AnP_ES_LIS (ESYear, ESMonth, RoleID);
GO

-- ── 2. AnP_ES_PMS (PMS Breakdown) ────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'AnP_ES_PMS')
CREATE TABLE dbo.AnP_ES_PMS
(
	Id                  INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
	RoleID              NVARCHAR(10)    NOT NULL,
	Description         NVARCHAR(300)   NOT NULL,
	ESYear              INT             NOT NULL,
	ESMonth             INT             NOT NULL,
	ESMonthClaimCount   INT             NOT NULL DEFAULT 0,
	ESMonthChargeAmount DECIMAL(18,2)   NOT NULL DEFAULT 0,
	RefreshedAt         DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_AnP_ES_PMS_Period' AND object_id=OBJECT_ID('dbo.AnP_ES_PMS'))
	CREATE NONCLUSTERED INDEX IX_AnP_ES_PMS_Period
		ON dbo.AnP_ES_PMS (ESYear, ESMonth, RoleID);
GO

-- ── 3. AnP_ES_Cash (Cash Breakdown) ──────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'AnP_ES_Cash')
CREATE TABLE dbo.AnP_ES_Cash
(
	Id                  INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
	RoleID              NVARCHAR(10)    NOT NULL,
	Description         NVARCHAR(300)   NOT NULL,
	ESYear              INT             NOT NULL,
	ESMonth             INT             NOT NULL,
	ESMonthClaimCount   INT             NOT NULL DEFAULT 0,
	ESMonthChargeAmount DECIMAL(18,2)   NOT NULL DEFAULT 0,
	RefreshedAt         DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_AnP_ES_Cash_Period' AND object_id=OBJECT_ID('dbo.AnP_ES_Cash'))
	CREATE NONCLUSTERED INDEX IX_AnP_ES_Cash_Period
		ON dbo.AnP_ES_Cash (ESYear, ESMonth, RoleID);
GO

-- ── 4. AnP_ES_Avg (Average Payment Per Claim) ────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'AnP_ES_Avg')
CREATE TABLE dbo.AnP_ES_Avg
(
	Id                  INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
	RoleID              NVARCHAR(10)    NOT NULL,
	Description         NVARCHAR(300)   NOT NULL,
	ESYear              INT             NOT NULL,
	ESMonth             INT             NOT NULL,
	ESMonthClaimCount   INT             NOT NULL DEFAULT 0,   -- denominator (claim count) used for the average
	ESMonthChargeAmount DECIMAL(18,2)   NOT NULL DEFAULT 0,   -- the average $ value itself
	RefreshedAt         DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_AnP_ES_Avg_Period' AND object_id=OBJECT_ID('dbo.AnP_ES_Avg'))
	CREATE NONCLUSTERED INDEX IX_AnP_ES_Avg_Period
		ON dbo.AnP_ES_Avg (ESYear, ESMonth, RoleID);
GO

PRINT '15_AnalyzePathology_ExecutiveSummary_Tables.sql completed.';
GO

