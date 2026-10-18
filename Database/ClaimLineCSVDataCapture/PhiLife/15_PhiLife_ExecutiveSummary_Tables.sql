-- ============================================================
-- PhiLife – Executive Summary aggregate tables
-- File : 15_PhiLife_ExecutiveSummary_Tables.sql
-- DB   : PhiLife_LRN
--
-- Fresh rewrite mirroring the PCRLabsofAmerica 15-21 architecture
-- (see PCRLabsofAmerica\15_PCRLOA_ExecutiveSummary_Tables.sql).
-- Supersedes the previous single-table PhiLife suite
-- (old 15-18: Phi_ES_Data + 2 DetailRows SPs) — ignore those.
--
-- Five category tables (1 row per RoleID per Year-Month):
--   dbo.Phi_ES_LIS         – LIS Breakdown (header rows: Total, A, A1-A8 + subs, B, B1-B5 + subs)
--   dbo.Phi_ES_LIS_Panel   – Panel-wise sub-rows under "Billable Samples - Resulted" (A.<Panelname>)
--   dbo.Phi_ES_PMS         – PMS Breakdown (Q, R, S, T, U, V, W, X, Y + Y.1-Y.3)
--   dbo.Phi_ES_Cash        – Cash Breakdown ($) (Z, AA-AI + AI.1-AI.3)
--   dbo.Phi_ES_Avg         – Average Payment Per Claim (AJ, AK, AL)
--
-- Columns are intentionally identical across the tables so the
-- display SP (usp_GetPhi_ExecutiveSummary) can union them cleanly.
--   RoleID                 (Total, A, A1, ... AL)
--   Description            (human-readable label)
--   ESYear                 (DateofService year; 0 = grand total sentinel)
--   ESMonth                (DateofService month; 0 = grand total sentinel)
--   ESMonthClaimCount      (Accession count – COUNT(DISTINCT AccessionNumber))
--   ESMonthChargeAmount    (Dollar value – used by Cash/Avg categories)
-- ============================================================
SET NOCOUNT ON;
GO

-- ── 1. Phi_ES_LIS (LIS Breakdown) ─────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_ES_LIS')
CREATE TABLE dbo.Phi_ES_LIS
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Phi_ES_LIS_Period' AND object_id=OBJECT_ID('dbo.Phi_ES_LIS'))
	CREATE NONCLUSTERED INDEX IX_Phi_ES_LIS_Period
		ON dbo.Phi_ES_LIS (ESYear, ESMonth, RoleID);
GO

-- ── 2. Phi_ES_LIS_Panel (panel-wise sub-rows for "Billable Samples - Resulted") ─
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_ES_LIS_Panel')
CREATE TABLE dbo.Phi_ES_LIS_Panel
(
	Id                  INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
	RoleID              NVARCHAR(350)   NOT NULL,      -- e.g. 'A.UTI ABR Panel' (panel names can be long)
	PanelName           NVARCHAR(300)   NOT NULL,
	Description         NVARCHAR(300)   NOT NULL,      -- indented panel label
	ESYear              INT             NOT NULL,
	ESMonth             INT             NOT NULL,
	ESMonthClaimCount   INT             NOT NULL DEFAULT 0,
	ESMonthChargeAmount DECIMAL(18,2)   NOT NULL DEFAULT 0,
	RefreshedAt         DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Phi_ES_LIS_Panel_Period' AND object_id=OBJECT_ID('dbo.Phi_ES_LIS_Panel'))
	CREATE NONCLUSTERED INDEX IX_Phi_ES_LIS_Panel_Period
		ON dbo.Phi_ES_LIS_Panel (ESYear, ESMonth, PanelName);
GO

-- Widen RoleID on existing installs – 'A.<PanelName>' codes can exceed NVARCHAR(20).
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Phi_ES_LIS_Panel') AND name = 'RoleID' AND max_length < 700)
	ALTER TABLE dbo.Phi_ES_LIS_Panel ALTER COLUMN RoleID NVARCHAR(350) NOT NULL;
GO

-- ── 3. Phi_ES_PMS (PMS Breakdown) ─────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_ES_PMS')
CREATE TABLE dbo.Phi_ES_PMS
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Phi_ES_PMS_Period' AND object_id=OBJECT_ID('dbo.Phi_ES_PMS'))
	CREATE NONCLUSTERED INDEX IX_Phi_ES_PMS_Period
		ON dbo.Phi_ES_PMS (ESYear, ESMonth, RoleID);
GO

-- ── 4. Phi_ES_Cash (Cash Breakdown) ───────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_ES_Cash')
CREATE TABLE dbo.Phi_ES_Cash
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Phi_ES_Cash_Period' AND object_id=OBJECT_ID('dbo.Phi_ES_Cash'))
	CREATE NONCLUSTERED INDEX IX_Phi_ES_Cash_Period
		ON dbo.Phi_ES_Cash (ESYear, ESMonth, RoleID);
GO

-- ── 5. Phi_ES_Avg (Average Payment Per Claim) ─────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_ES_Avg')
CREATE TABLE dbo.Phi_ES_Avg
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Phi_ES_Avg_Period' AND object_id=OBJECT_ID('dbo.Phi_ES_Avg'))
	CREATE NONCLUSTERED INDEX IX_Phi_ES_Avg_Period
		ON dbo.Phi_ES_Avg (ESYear, ESMonth, RoleID);
GO

PRINT '15_PhiLife_ExecutiveSummary_Tables.sql completed.';
GO
