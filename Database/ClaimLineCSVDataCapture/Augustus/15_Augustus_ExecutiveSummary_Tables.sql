-- ============================================================
-- Augustus – Executive Summary Aggregate Tables
-- File : 15_Augustus_ExecutiveSummary_Tables.sql
-- DB   : Augustus_LRN  (or whatever the Augustus target DB is named)
--
-- Mirrors Cove\15_Cove_ExecutiveSummary_Tables.sql.
-- Defines the 4 aggregate tables that back Augustus's Executive Summary:
--
--   Augustus_ES_LIS   - "LIS Breakdown":
--       A   Insurance Bills
--         A.1  Billed
--           A.1.1  Claim Submitted in IRCM
--           A.1.2  Claim Submitted in Daqbilling
--         A.2  Unbilled
--           A.2.1  Resulted yet to be billed
--           A.2.1* Ready to bill (sub of A.2.1)
--           A.2.2  Insurance name not listed
--       B   Yet to be Validated
--         B.1  Billed
--       C   Client Bills
--         C.1  Billed
--       D   System Test
--         D.1  Billed
--       E   Self pay
--         E.1  Billed
--
--   Augustus_ES_PMS   - "Billable Samples - PMS Breakdown":
--       F    No. of Billed Claims
--         F.1  No. of Claims Billed in IRCM
--         F.2  No. of Claims Billed in Daq Billing
--       G    No. of Unbilled Claims
--       H    Client bill claims
--       I    No. of Fully Paid Claims
--       J    No. of Patient Paid Claims
--       K    No. of Patient Responsibility Claims
--       L    No. of Partially Paid Claims
--       M    No. of Adjusted/Written Off Claims
--       N    No. of Partially Adjusted/Written Off Claims
--       O    No. of Insurance Balance Claims
--         O.1  No. of Fully Denied Claims
--         O.2  No. of Partially Denied Claims
--         O.3  No. of No Response from Payor
--
--   Augustus_ES_Cash  - "Cash Breakdown":
--       P    Total Billed ($)
--         P.1  Total Charge of Claims Billed (IRCM)
--         P.2  Total Charge of Claims Billed (Daq)
--       Q    Total Unbilled ($)
--       R    Insurance Payment ($)
--       S    Partially Paid ($)
--       T    Patient Paid ($)
--       U    Patient Responsibility ($)
--         U.1  Daqbilling
--         U.2  IRCM
--       V    Adjustment amount ($)
--       W    Total Payments ($) - Insurance
--       X    Insurance Balance ($)
--         X.1  Fully Denied
--         X.2  Partially Denied
--         X.3  No Response from Payor
--
--   Augustus_ES_Avg   - "Average Payment Per Claim":
--       Y    Average Payment ($) - Total Pay/Billed Claims
--       Z    Average Payment ($) - Total Pay/Paid Claims
--       AA   Average Payment ($) - Total Pay/Adjudicated Claims
--
-- Common schema (all 4 tables):
--   Id                   INT IDENTITY PK
--   RoleID               NVARCHAR(50)   - row identifier
--   Description          NVARCHAR(300)  - display label
--   ESYear               INT            - 0 = grand-total sentinel
--   ESMonth              INT            - 0 = grand-total sentinel
--   ESMonthClaimCount    INT            - sample/claim counts (LIS, PMS)
--   ESMonthChargeAmount  DECIMAL(18,2)  - dollar amounts (Cash, Avg)
--   RefreshedAt          DATETIME
--
-- Each table has a nonclustered index on (ESYear, ESMonth, RoleID).
-- ============================================================
SET NOCOUNT ON;
GO

-- ── Augustus_ES_LIS ──────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.Augustus_ES_LIS', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Augustus_ES_LIS
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Augustus_ES_LIS_Period' AND object_id = OBJECT_ID('dbo.Augustus_ES_LIS'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Augustus_ES_LIS_Period ON dbo.Augustus_ES_LIS (ESYear, ESMonth, RoleID);
END
GO

-- ── Augustus_ES_PMS ──────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.Augustus_ES_PMS', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Augustus_ES_PMS
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Augustus_ES_PMS_Period' AND object_id = OBJECT_ID('dbo.Augustus_ES_PMS'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Augustus_ES_PMS_Period ON dbo.Augustus_ES_PMS (ESYear, ESMonth, RoleID);
END
GO

-- ── Augustus_ES_Cash ─────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.Augustus_ES_Cash', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Augustus_ES_Cash
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Augustus_ES_Cash_Period' AND object_id = OBJECT_ID('dbo.Augustus_ES_Cash'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Augustus_ES_Cash_Period ON dbo.Augustus_ES_Cash (ESYear, ESMonth, RoleID);
END
GO

-- ── Augustus_ES_Avg ──────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.Augustus_ES_Avg', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Augustus_ES_Avg
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Augustus_ES_Avg_Period' AND object_id = OBJECT_ID('dbo.Augustus_ES_Avg'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Augustus_ES_Avg_Period ON dbo.Augustus_ES_Avg (ESYear, ESMonth, RoleID);
END
GO

PRINT '15_Augustus_ExecutiveSummary_Tables.sql completed.';
GO
