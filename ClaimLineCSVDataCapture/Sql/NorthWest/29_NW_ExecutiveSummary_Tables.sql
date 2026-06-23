-- ============================================================
-- NorthWest – Executive Summary Aggregate Tables
-- File : 29_NW_ExecutiveSummary_Tables.sql
-- DB   : NorthWest_LRN  (or NWL_LRN)
-- ============================================================
SET NOCOUNT ON;
GO

-- ── NW_ES_LIS ────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.NW_ES_LIS', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.NW_ES_LIS
    (
        Id                   INT           IDENTITY(1,1) NOT NULL,
        RoleID               NVARCHAR(100) NOT NULL,
        Description          NVARCHAR(500) NOT NULL,
        ESYear               INT           NOT NULL,
        ESMonth              INT           NOT NULL,
        ESMonthClaimCount    INT           NOT NULL DEFAULT 0,
        ESMonthChargeAmount  DECIMAL(18,2) NOT NULL DEFAULT 0,
        RefreshedAt          DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT PK_NW_ES_LIS PRIMARY KEY (Id)
    );
    CREATE NONCLUSTERED INDEX IX_NW_ES_LIS_Period
        ON dbo.NW_ES_LIS (ESYear, ESMonth, RoleID);
    PRINT 'Created dbo.NW_ES_LIS';
END
ELSE PRINT 'dbo.NW_ES_LIS already exists – skipped.';
GO

-- ── NW_ES_PMS ────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.NW_ES_PMS', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.NW_ES_PMS
    (
        Id                   INT           IDENTITY(1,1) NOT NULL,
        RoleID               NVARCHAR(100) NOT NULL,
        Description          NVARCHAR(500) NOT NULL,
        ESYear               INT           NOT NULL,
        ESMonth              INT           NOT NULL,
        ESMonthClaimCount    INT           NOT NULL DEFAULT 0,
        ESMonthChargeAmount  DECIMAL(18,2) NOT NULL DEFAULT 0,
        RefreshedAt          DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT PK_NW_ES_PMS PRIMARY KEY (Id)
    );
    CREATE NONCLUSTERED INDEX IX_NW_ES_PMS_Period
        ON dbo.NW_ES_PMS (ESYear, ESMonth, RoleID);
    PRINT 'Created dbo.NW_ES_PMS';
END
ELSE PRINT 'dbo.NW_ES_PMS already exists – skipped.';
GO

-- ── NW_ES_Cash ───────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.NW_ES_Cash', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.NW_ES_Cash
    (
        Id                   INT           IDENTITY(1,1) NOT NULL,
        RoleID               NVARCHAR(100) NOT NULL,
        Description          NVARCHAR(500) NOT NULL,
        ESYear               INT           NOT NULL,
        ESMonth              INT           NOT NULL,
        ESMonthClaimCount    INT           NOT NULL DEFAULT 0,
        ESMonthChargeAmount  DECIMAL(18,2) NOT NULL DEFAULT 0,
        RefreshedAt          DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT PK_NW_ES_Cash PRIMARY KEY (Id)
    );
    CREATE NONCLUSTERED INDEX IX_NW_ES_Cash_Period
        ON dbo.NW_ES_Cash (ESYear, ESMonth, RoleID);
    PRINT 'Created dbo.NW_ES_Cash';
END
ELSE PRINT 'dbo.NW_ES_Cash already exists – skipped.';
GO

-- ── NW_ES_Avg ────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.NW_ES_Avg', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.NW_ES_Avg
    (
        Id                   INT           IDENTITY(1,1) NOT NULL,
        RoleID               NVARCHAR(100) NOT NULL,
        Description          NVARCHAR(500) NOT NULL,
        ESYear               INT           NOT NULL,
        ESMonth              INT           NOT NULL,
        ESMonthClaimCount    INT           NOT NULL DEFAULT 0,
        ESMonthChargeAmount  DECIMAL(18,2) NOT NULL DEFAULT 0,
        RefreshedAt          DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT PK_NW_ES_Avg PRIMARY KEY (Id)
    );
    CREATE NONCLUSTERED INDEX IX_NW_ES_Avg_Period
        ON dbo.NW_ES_Avg (ESYear, ESMonth, RoleID);
    PRINT 'Created dbo.NW_ES_Avg';
END
ELSE PRINT 'dbo.NW_ES_Avg already exists – skipped.';
GO

PRINT '29_NW_ExecutiveSummary_Tables.sql completed.';
GO
