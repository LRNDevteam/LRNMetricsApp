-- ============================================================
-- Cove – Executive Summary Aggregate Tables
-- File : 15_Cove_ExecutiveSummary_Tables.sql
-- DB   : Cove_LRN
--
-- Mirrors PhiLife\15_PhiLife_ExecutiveSummary_Tables.sql. Defines the
-- 4 aggregate tables that back Cove's Executive Summary breakdown:
--   Cove_ES_LIS   - "LIS Breakdown" (image 1): A, B (+16 PanelType subs),
--                   C, D (+20 sub-statuses, D.5/D.6 with nested PanelType
--                   subs), E (+7 NewStatus subs)
--   Cove_ES_PMS   - "Billable Samples - PMS Breakdown" (image 2): F-N (+3 subs)
--   Cove_ES_Cash  - "Cash Breakdown" (image 2): O-U (+3 subs)
--   Cove_ES_Avg   - "Average Payment Per Claim" (image 2): V, W, X
--
-- Unlike RisingTides\27_..._LIS_Alt_NewLogicScheme.sql, Cove does NOT need
-- a separate *_LIS_Panel table: the B.1-B.16 / D.5.1-D.5.12 / D.6.1-D.6.10
-- PanelType sub-rows are a FIXED, enumerated set of RoleIDs defined by the
-- spec (not a dynamic CROSS JOIN over distinct panel names found in the
-- data), so they are stored as ordinary rows directly in Cove_ES_LIS.
--
-- RoleID is widened to NVARCHAR(50) (vs PhiLife's NVARCHAR(10)) to
-- comfortably fit the deepest codes (e.g. 'D.5.12', 'D.6.10').
--
-- Common schema (all 4 tables):
--   Id                   INT IDENTITY PK
--   RoleID               NVARCHAR(50)   - row identifier (A, B, B.1, C, D, D.5.1, F, O, V, ...)
--   Description          NVARCHAR(300)  - display label
--   ESYear               INT            - 0 = grand-total sentinel
--   ESMonth              INT            - 0 = grand-total sentinel
--   ESMonthClaimCount    INT            - sample/claim counts (LIS, PMS)
--   ESMonthChargeAmount  DECIMAL(18,2)  - dollar amounts (Cash, Avg)
--   RefreshedAt          DATETIME
--
-- Each table has a nonclustered index on (ESYear, ESMonth, RoleID) to
-- support the read SP's period-bucketed lookups.
-- ============================================================
SET NOCOUNT ON;
GO

-- ── Cove_ES_LIS ──────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.Cove_ES_LIS', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Cove_ES_LIS
    (
        Id                  INT IDENTITY(1,1) PRIMARY KEY,
        -- RoleID holds panel-keyed codes like 'B.<PanelType>'; Cove panel names
        -- can be long (≈200 chars), so this is sized well above NVARCHAR(50).
        RoleID              NVARCHAR(420)   NOT NULL,
        Description         NVARCHAR(420)   NOT NULL,
        ESYear              INT             NOT NULL,
        ESMonth             INT             NOT NULL,
        ESMonthClaimCount   INT             NOT NULL DEFAULT 0,
        ESMonthChargeAmount DECIMAL(18,2)   NOT NULL DEFAULT 0,
        RefreshedAt         DATETIME        NOT NULL DEFAULT GETDATE()
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Cove_ES_LIS_Period' AND object_id = OBJECT_ID('dbo.Cove_ES_LIS'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Cove_ES_LIS_Period ON dbo.Cove_ES_LIS (ESYear, ESMonth, RoleID);
END
GO

-- ── Cove_ES_PMS ──────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.Cove_ES_PMS', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Cove_ES_PMS
    (
        Id                  INT IDENTITY(1,1) PRIMARY KEY,
        RoleID              NVARCHAR(50)    NOT NULL,
        Description         NVARCHAR(300)   NOT NULL,
        ESYear              INT             NOT NULL,
        ESMonth             INT             NOT NULL,
        ESMonthClaimCount   INT             NOT NULL DEFAULT 0,
        ESMonthChargeAmount DECIMAL(18,2)   NOT NULL DEFAULT 0,
        RefreshedAt         DATETIME        NOT NULL DEFAULT GETDATE()
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Cove_ES_PMS_Period' AND object_id = OBJECT_ID('dbo.Cove_ES_PMS'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Cove_ES_PMS_Period ON dbo.Cove_ES_PMS (ESYear, ESMonth, RoleID);
END
GO

-- ── Cove_ES_Cash ─────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.Cove_ES_Cash', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Cove_ES_Cash
    (
        Id                  INT IDENTITY(1,1) PRIMARY KEY,
        RoleID              NVARCHAR(50)    NOT NULL,
        Description         NVARCHAR(300)   NOT NULL,
        ESYear              INT             NOT NULL,
        ESMonth             INT             NOT NULL,
        ESMonthClaimCount   INT             NOT NULL DEFAULT 0,
        ESMonthChargeAmount DECIMAL(18,2)   NOT NULL DEFAULT 0,
        RefreshedAt         DATETIME        NOT NULL DEFAULT GETDATE()
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Cove_ES_Cash_Period' AND object_id = OBJECT_ID('dbo.Cove_ES_Cash'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Cove_ES_Cash_Period ON dbo.Cove_ES_Cash (ESYear, ESMonth, RoleID);
END
GO

-- ── Cove_ES_Avg ──────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.Cove_ES_Avg', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Cove_ES_Avg
    (
        Id                  INT IDENTITY(1,1) PRIMARY KEY,
        RoleID              NVARCHAR(50)    NOT NULL,
        Description         NVARCHAR(300)   NOT NULL,
        ESYear              INT             NOT NULL,
        ESMonth             INT             NOT NULL,
        ESMonthClaimCount   INT             NOT NULL DEFAULT 0,
        ESMonthChargeAmount DECIMAL(18,2)   NOT NULL DEFAULT 0,
        RefreshedAt         DATETIME        NOT NULL DEFAULT GETDATE()
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Cove_ES_Avg_Period' AND object_id = OBJECT_ID('dbo.Cove_ES_Avg'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Cove_ES_Avg_Period ON dbo.Cove_ES_Avg (ESYear, ESMonth, RoleID);
END
GO

PRINT '15_Cove_ExecutiveSummary_Tables.sql completed.';
GO
