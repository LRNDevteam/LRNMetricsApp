/* =============================================================================
   VariantX Labs — cloned from Elixir (15_Elixir_ExecutiveSummary_Tables.sql)
   Prefix: VarX_ / VarX_CS_ / VarX_ES_
   Refresh: usp_RefreshVarX_*
   Read:    usp_GetVarX_*
   Source tables: dbo.ClaimLevelData, dbo.LineLevelData, dbo.LIMSMaster
   No inline UI queries — dashboard/ReportWorker must call these SPs only.
   ============================================================================= */
-- ============================================================
-- VariantX – Executive Summary aggregate tables
-- File : 15_VariantX_ExecutiveSummary_Tables.sql
-- DB   : VariantX_LRN
--
-- Mirrors the PhiLife/PCRLabsofAmerica 15-21 architecture
-- (see PhiLife\15_PhiLife_ExecutiveSummary_Tables.sql), but uses the
-- SIMPLER RoleID scheme provided in the VariantX LIS/PMS/Cash/Avg
-- breakdown spec:
--   LIS Breakdown   : A, B, C, D (+D.1), E (+E.1-E.6)
--   PMS Breakdown   : F, G, H, I, J, K, L, M, N, O, P (+P.1-P.3)
--   Cash Breakdown  : Q, R, S, T, U, V, W, X (+X.1-X.3)
--   Average/Claim   : Y, Z, AA
--
-- Four category tables (1 row per RoleID per Year-Month).
-- VarX_ES_LIS.RoleID is NVARCHAR(420) to accommodate dynamic B.x panel
-- sub-rows (e.g. 'B.Comprehensive Metabolic Panel') whose names can be long.
--   dbo.VarX_ES_LIS   – LIS Breakdown (A, B, B.x panel sub-rows, C, D, D.1, E, E.1-E.6)
--   dbo.VarX_ES_PMS   – PMS Breakdown (F-P + P.1-P.3)
--   dbo.VarX_ES_Cash  – Cash Breakdown ($) (Q-X + X.1-X.3)
--   dbo.VarX_ES_Avg   – Average Payment Per Claim (Y, Z, AA)
--
-- Columns are intentionally identical across the tables so the
-- display SP (usp_GetVarX_ExecutiveSummary) can union them cleanly.
--   RoleID                 (A, B, C, ... AA)
--   Description            (human-readable label)
--   ESYear                 (DateofService year; 0 = grand total sentinel)
--   ESMonth                (DateofService month; 0 = grand total sentinel)
--   ESMonthClaimCount      (Accession/Claim count)
--   ESMonthChargeAmount    (Dollar value – used by Cash/Avg categories)
-- ============================================================
SET NOCOUNT ON;
GO

-- ── 1. VarX_ES_LIS (LIS Breakdown) ────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'VarX_ES_LIS')
CREATE TABLE dbo.VarX_ES_LIS
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
IF COL_LENGTH('dbo.VarX_ES_LIS', 'RoleID') < 420
	ALTER TABLE dbo.VarX_ES_LIS ALTER COLUMN RoleID NVARCHAR(420) NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_VarX_ES_LIS_Period' AND object_id=OBJECT_ID('dbo.VarX_ES_LIS'))
	CREATE NONCLUSTERED INDEX IX_VarX_ES_LIS_Period
		ON dbo.VarX_ES_LIS (ESYear, ESMonth, RoleID);
GO

-- ── 2. VarX_ES_PMS (PMS Breakdown) ────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'VarX_ES_PMS')
CREATE TABLE dbo.VarX_ES_PMS
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_VarX_ES_PMS_Period' AND object_id=OBJECT_ID('dbo.VarX_ES_PMS'))
	CREATE NONCLUSTERED INDEX IX_VarX_ES_PMS_Period
		ON dbo.VarX_ES_PMS (ESYear, ESMonth, RoleID);
GO

-- ── 3. VarX_ES_Cash (Cash Breakdown) ──────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'VarX_ES_Cash')
CREATE TABLE dbo.VarX_ES_Cash
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_VarX_ES_Cash_Period' AND object_id=OBJECT_ID('dbo.VarX_ES_Cash'))
	CREATE NONCLUSTERED INDEX IX_VarX_ES_Cash_Period
		ON dbo.VarX_ES_Cash (ESYear, ESMonth, RoleID);
GO

-- ── 4. VarX_ES_Avg (Average Payment Per Claim) ────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'VarX_ES_Avg')
CREATE TABLE dbo.VarX_ES_Avg
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_VarX_ES_Avg_Period' AND object_id=OBJECT_ID('dbo.VarX_ES_Avg'))
	CREATE NONCLUSTERED INDEX IX_VarX_ES_Avg_Period
		ON dbo.VarX_ES_Avg (ESYear, ESMonth, RoleID);
GO

PRINT '15_VariantX_ExecutiveSummary_Tables.sql completed.';
GO

