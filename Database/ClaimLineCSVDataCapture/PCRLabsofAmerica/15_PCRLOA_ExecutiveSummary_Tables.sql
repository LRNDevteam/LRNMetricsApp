-- ============================================================
-- RisingTides – Executive Summary aggregate tables
-- File : 15_RisingTides_ExecutiveSummary_Tables.sql
-- DB   : Rising_Tides
--
-- Five category tables (1 row per RoleID per Year-Month):
--   dbo.PCR_ES_LIS         – LIS Breakdown (header rows)
--   dbo.PCR_ES_LIS_Panel   – Panel-wise sub-rows under "Billable Samples - Resulted"
--   dbo.PCR_ES_PMS         – Billable Samples - PMS Breakdown
--   dbo.PCR_ES_Cash        – Cash Breakdown (dollar values)
--   dbo.PCR_ES_Avg         – Average Payment Per Claim (AH/AI1/AJ)
--
-- Columns are intentionally identical across the tables so the
-- display SP (usp_GetPCR_ExecutiveSummary) can union them cleanly.
--   RoleID                 (A, B, C, ... AB)
--   Description            (human-readable label)
--   ESYear                 (DateofService year; 0 = grand total sentinel)
--   ESMonth                (DateofService month; 0 = grand total sentinel)
--   ESMonthClaimCount      (Visit count – COUNT(DISTINCT ClaimID))
--   ESMonthChargeAmount    (Dollar value – used by Cash category)
-- ============================================================
SET NOCOUNT ON;
GO

-- ── 1. PCR_ES_LIS (LIS Breakdown) ─────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PCR_ES_LIS')
CREATE TABLE dbo.PCR_ES_LIS
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_PCR_ES_LIS_Period' AND object_id=OBJECT_ID('dbo.PCR_ES_LIS'))
	CREATE NONCLUSTERED INDEX IX_PCR_ES_LIS_Period
		ON dbo.PCR_ES_LIS (ESYear, ESMonth, RoleID);
GO

-- ── 2. PCR_ES_LIS_Panel (panel-wise sub-rows for "Billable Samples - Resulted") ─
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PCR_ES_LIS_Panel')
CREATE TABLE dbo.PCR_ES_LIS_Panel
(
	Id                  INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
	RoleID              NVARCHAR(350)   NOT NULL,      -- e.g. 'B.UTI ABR Panel' (panel names can be long)
	PanelName           NVARCHAR(300)   NOT NULL,
	Description         NVARCHAR(300)   NOT NULL,      -- indented panel label
	ESYear              INT             NOT NULL,
	ESMonth             INT             NOT NULL,
	ESMonthClaimCount   INT             NOT NULL DEFAULT 0,
	ESMonthChargeAmount DECIMAL(18,2)   NOT NULL DEFAULT 0,
	RefreshedAt         DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_PCR_ES_LIS_Panel_Period' AND object_id=OBJECT_ID('dbo.PCR_ES_LIS_Panel'))
	CREATE NONCLUSTERED INDEX IX_PCR_ES_LIS_Panel_Period
		ON dbo.PCR_ES_LIS_Panel (ESYear, ESMonth, PanelName);
GO

-- Widen RoleID on existing installs – 'B.<PanelName>' codes (e.g. 'B.ABR/Nail PCR Reflex/Wound PCR Reflex')
-- can exceed the original NVARCHAR(20).
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.PCR_ES_LIS_Panel') AND name = 'RoleID' AND max_length < 700)
	ALTER TABLE dbo.PCR_ES_LIS_Panel ALTER COLUMN RoleID NVARCHAR(350) NOT NULL;
GO

-- ── 3. PCR_ES_PMS (Billable Samples - PMS Breakdown) ──────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PCR_ES_PMS')
CREATE TABLE dbo.PCR_ES_PMS
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_PCR_ES_PMS_Period' AND object_id=OBJECT_ID('dbo.PCR_ES_PMS'))
	CREATE NONCLUSTERED INDEX IX_PCR_ES_PMS_Period
		ON dbo.PCR_ES_PMS (ESYear, ESMonth, RoleID);
GO

-- ── 4. PCR_ES_Cash (Cash Breakdown) ───────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PCR_ES_Cash')
CREATE TABLE dbo.PCR_ES_Cash
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_PCR_ES_Cash_Period' AND object_id=OBJECT_ID('dbo.PCR_ES_Cash'))
	CREATE NONCLUSTERED INDEX IX_PCR_ES_Cash_Period
		ON dbo.PCR_ES_Cash (ESYear, ESMonth, RoleID);
GO

-- ── 5. PCR_ES_Avg (Average Payment Per Claim) ─────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PCR_ES_Avg')
CREATE TABLE dbo.PCR_ES_Avg
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_PCR_ES_Avg_Period' AND object_id=OBJECT_ID('dbo.PCR_ES_Avg'))
	CREATE NONCLUSTERED INDEX IX_PCR_ES_Avg_Period
		ON dbo.PCR_ES_Avg (ESYear, ESMonth, RoleID);
GO

PRINT '15_PCRLOA_ExecutiveSummary_Tables.sql completed.';
GO
