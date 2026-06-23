-- ============================================================
-- BeechTree – Executive Summary Aggregate Tables
-- File : 15_BeechTree_ExecutiveSummary_Tables.sql
-- DB   : BeechTree_LRN
--
-- Mirrors Augustus\15_Augustus_ExecutiveSummary_Tables.sql.
-- Defines the 4 aggregate tables that back BeechTree's Executive Summary:
--
--   BeechTree_ES_LIS   - "LIS Breakdown":
--       A    Total Samples (all accessions)
--       B    Billable Samples - Resulted (RessultedStatus = Resulted)
--         B1.<PanelType>  Panel sub-rows (dynamic)
--         B2   Billed to Insurance
--           B2.1  Billed In AMD
--         B3   Not Entered in AMD
--           B3.1  Received
--           B3.2  Billing Review Required
--           B3.3  In Transit
--           B3.4  Transferred
--           B3.5  Collected
--         B4   Unbilled
--         B5   Client Bill
--           B5.1  Not Entered in AMD
--           B5.2  Billed
--         B6   Self Pay
--           B6.1  Not Entered in AMD
--           B6.2  Billed
--           B6.3  Entered
--         B7   Test Entries
--           B7.1  Not Entered in AMD
--           B7.2  Billed
--         B8   Rejected Sample
--           B8.1  Not Entered in AMD
--           B8.2  Billed
--         B9   Payment Method No Bill
--       C    Not Resulted (RessultedStatus = Not Resulted)
--         C1   No Result date on LIS but Billed
--         C2   Not Entered in AMD
--           C2.1  Received
--           C2.2  In Transit
--           C2.3  Collected
--           C2.4  Transferred
--         C3   Client Bill
--         C4   Self Pay
--           C4.1  Not Entered in AMD
--           C4.2  Billed
--       D    Test Entries (Not Resulted)
--       E    Rejected Sample (Not Resulted)
--
--   BeechTree_ES_PMS   - "PMS Breakdown":
--       R    Billed - Includes all Claims Billed in AMD
--       S    Billed Mismatches - Non Diagnose LIS Samples
--       T    Unbilled - Entered to AMD - Yet to be released to Payer
--       U    Fully Paid - Insurance Pay
--       V    Fully Adjusted
--       W    Patient Responsibility
--       X    Partially Paid
--       Y    Patient Payment
--       Z    Insurance Balance
--         Z.1  Fully Denied
--         Z.2  No Response
--         Z.3  Partially Denied
--
--   BeechTree_ES_Cash  - "Cash Breakdown":
--       AA   Total Billed ($)
--       AB   Unbilled ($)
--       AC   Insurance Payment (fully paid) ($)
--       AD   Partially Paid ($)
--       AE   Patient Payment ($)
--       AF   Fully Adjusted (Complete W/O)
--       AG   Contractual Obligation W/O
--       AH   Patient Balance ($)
--       AI   Patient WO
--       AJ   Insurance Balance ($)
--
--   BeechTree_ES_Avg   - "Average Payment Per Claim":
--       AK   Average Payment ($) - Total Pay/Billed Claims
--       AL   Average Payment ($) - Total Pay/Paid Claims
--       AM   Average Payment ($) - Total Pay/Adjudicated Claims
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

-- ── BeechTree_ES_LIS ─────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.BeechTree_ES_LIS', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.BeechTree_ES_LIS
    (
        Id                  INT IDENTITY(1,1) PRIMARY KEY,
        RoleID              NVARCHAR(200)   NOT NULL,
        Description         NVARCHAR(300)   NOT NULL,
        ESYear              INT             NOT NULL,
        ESMonth             INT             NOT NULL,
        ESMonthClaimCount   INT             NOT NULL DEFAULT 0,
        ESMonthChargeAmount DECIMAL(18,2)   NOT NULL DEFAULT 0,
        RefreshedAt         DATETIME        NOT NULL DEFAULT GETDATE()
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BeechTree_ES_LIS_Period' AND object_id = OBJECT_ID('dbo.BeechTree_ES_LIS'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_BeechTree_ES_LIS_Period ON dbo.BeechTree_ES_LIS (ESYear, ESMonth, RoleID);
END
GO

-- ── BeechTree_ES_PMS ─────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.BeechTree_ES_PMS', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.BeechTree_ES_PMS
    (
        Id                  INT IDENTITY(1,1) PRIMARY KEY,
        RoleID              NVARCHAR(200)   NOT NULL,
        Description         NVARCHAR(300)   NOT NULL,
        ESYear              INT             NOT NULL,
        ESMonth             INT             NOT NULL,
        ESMonthClaimCount   INT             NOT NULL DEFAULT 0,
        ESMonthChargeAmount DECIMAL(18,2)   NOT NULL DEFAULT 0,
        RefreshedAt         DATETIME        NOT NULL DEFAULT GETDATE()
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BeechTree_ES_PMS_Period' AND object_id = OBJECT_ID('dbo.BeechTree_ES_PMS'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_BeechTree_ES_PMS_Period ON dbo.BeechTree_ES_PMS (ESYear, ESMonth, RoleID);
END
GO

-- ── BeechTree_ES_Cash ────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.BeechTree_ES_Cash', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.BeechTree_ES_Cash
    (
        Id                  INT IDENTITY(1,1) PRIMARY KEY,
        RoleID              NVARCHAR(200)   NOT NULL,
        Description         NVARCHAR(300)   NOT NULL,
        ESYear              INT             NOT NULL,
        ESMonth             INT             NOT NULL,
        ESMonthClaimCount   INT             NOT NULL DEFAULT 0,
        ESMonthChargeAmount DECIMAL(18,2)   NOT NULL DEFAULT 0,
        RefreshedAt         DATETIME        NOT NULL DEFAULT GETDATE()
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BeechTree_ES_Cash_Period' AND object_id = OBJECT_ID('dbo.BeechTree_ES_Cash'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_BeechTree_ES_Cash_Period ON dbo.BeechTree_ES_Cash (ESYear, ESMonth, RoleID);
END
GO

-- ── BeechTree_ES_Avg ─────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.BeechTree_ES_Avg', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.BeechTree_ES_Avg
    (
        Id                  INT IDENTITY(1,1) PRIMARY KEY,
        RoleID              NVARCHAR(200)   NOT NULL,
        Description         NVARCHAR(300)   NOT NULL,
        ESYear              INT             NOT NULL,
        ESMonth             INT             NOT NULL,
        ESMonthClaimCount   INT             NOT NULL DEFAULT 0,
        ESMonthChargeAmount DECIMAL(18,2)   NOT NULL DEFAULT 0,
        RefreshedAt         DATETIME        NOT NULL DEFAULT GETDATE()
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_BeechTree_ES_Avg_Period' AND object_id = OBJECT_ID('dbo.BeechTree_ES_Avg'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_BeechTree_ES_Avg_Period ON dbo.BeechTree_ES_Avg (ESYear, ESMonth, RoleID);
END
GO

PRINT '15_BeechTree_ExecutiveSummary_Tables.sql completed.';
GO
