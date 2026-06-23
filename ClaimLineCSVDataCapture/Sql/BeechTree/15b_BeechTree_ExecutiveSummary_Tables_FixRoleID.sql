-- ============================================================
-- BeechTree – Fix RoleID column width (one-time ALTER)
-- File : 15b_BeechTree_ExecutiveSummary_Tables_FixRoleID.sql
-- DB   : BeechTree_LRN
--
-- RoleID was created as NVARCHAR(50). Panel names like
-- 'Blood, Urinalysis Reflex Culture, Validity Test' make B1.x
-- RoleIDs exceed 50 chars. Widen to NVARCHAR(200) on all 4 tables.
--
-- The nonclustered index on RoleID must be dropped first, then
-- recreated after the ALTER COLUMN.
-- ============================================================
SET NOCOUNT ON;
GO

-- ── BeechTree_ES_LIS ─────────────────────────────────────────────────────────
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BeechTree_ES_LIS_Period' AND object_id = OBJECT_ID('dbo.BeechTree_ES_LIS'))
    DROP INDEX IX_BeechTree_ES_LIS_Period ON dbo.BeechTree_ES_LIS;
GO

ALTER TABLE dbo.BeechTree_ES_LIS
    ALTER COLUMN RoleID NVARCHAR(200) NOT NULL;
GO

CREATE NONCLUSTERED INDEX IX_BeechTree_ES_LIS_Period ON dbo.BeechTree_ES_LIS (ESYear, ESMonth, RoleID);
GO

-- ── BeechTree_ES_PMS ─────────────────────────────────────────────────────────
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BeechTree_ES_PMS_Period' AND object_id = OBJECT_ID('dbo.BeechTree_ES_PMS'))
    DROP INDEX IX_BeechTree_ES_PMS_Period ON dbo.BeechTree_ES_PMS;
GO

ALTER TABLE dbo.BeechTree_ES_PMS
    ALTER COLUMN RoleID NVARCHAR(1000) NOT NULL;
GO

CREATE NONCLUSTERED INDEX IX_BeechTree_ES_PMS_Period ON dbo.BeechTree_ES_PMS (ESYear, ESMonth, RoleID);
GO

-- ── BeechTree_ES_Cash ────────────────────────────────────────────────────────
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BeechTree_ES_Cash_Period' AND object_id = OBJECT_ID('dbo.BeechTree_ES_Cash'))
    DROP INDEX IX_BeechTree_ES_Cash_Period ON dbo.BeechTree_ES_Cash;
GO

ALTER TABLE dbo.BeechTree_ES_Cash
    ALTER COLUMN RoleID NVARCHAR(2000) NOT NULL;
GO

CREATE NONCLUSTERED INDEX IX_BeechTree_ES_Cash_Period ON dbo.BeechTree_ES_Cash (ESYear, ESMonth, RoleID);
GO

-- ── BeechTree_ES_Avg ─────────────────────────────────────────────────────────
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BeechTree_ES_Avg_Period' AND object_id = OBJECT_ID('dbo.BeechTree_ES_Avg'))
    DROP INDEX IX_BeechTree_ES_Avg_Period ON dbo.BeechTree_ES_Avg;
GO

ALTER TABLE dbo.BeechTree_ES_Avg
    ALTER COLUMN RoleID NVARCHAR(2000) NOT NULL;
GO

CREATE NONCLUSTERED INDEX IX_BeechTree_ES_Avg_Period ON dbo.BeechTree_ES_Avg (ESYear, ESMonth, RoleID);
GO

PRINT '15b_BeechTree_ExecutiveSummary_Tables_FixRoleID.sql completed – RoleID widened to NVARCHAR(200) on all 4 tables.';
GO
