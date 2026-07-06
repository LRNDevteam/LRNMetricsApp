-- ============================================================
-- Certus – Executive Summary Aggregate Tables
-- File : 15_Certus_ExecutiveSummary_Tables.sql
-- DB   : Certus_LRN  (or whatever the Certus target DB is named)
--
-- Mirrors Augustus\15_Augustus_ExecutiveSummary_Tables.sql.
-- Defines the 4 aggregate tables that back Certus's Executive Summary:
--
--   Certus_ES_LIS   - "LIS Breakdown":
--       A     Total Samples
--       B     Billable Samples (BillTo = 'Insurance Bill')
--         B1.<PanelName>  Dynamic per-panel sub-rows
--         C     Billed (BillTo='Insurance Bill', BillingStatus='Billed')
--         D     Unbilled (BillTo='Insurance Bill', BillingStatus='Not Billed')
--           D.1   Claim Entered in Daqbilling
--           D.2   Resulted yet to be billed
--           D.3   D/L Isomer
--       E     Other Samples (BillTo <> 'Insurance Bill')
--         E.1   Duplicate
--         E.2   Client Bill
--         E.3   Yet to be Validated
--         E.4   Selfpay
--         E.5   Rejection
--         E.6   System Test
--
--   Certus_ES_PMS   - "Billable Samples - PMS Breakdown":
--       F      No. of Billed Claims
--         F.<PanelGroup>  Dynamic per-panel-group sub-rows (via dbo.PanelGroup, 'Other' fallback)
--       G      Unbilled Claims
--       H      Billed Mismatches - Other samples billed (PMS Billed - LIS Billed)
--       I      No. of Fully Paid Claims
--         I.<PanelGroup>  Dynamic per-panel-group sub-rows
--       J      No. of Patient Responsibility Claims
--       K      No. of Patient Paid Claims
--       L      No. of Adjusted/Written Off Claims
--       M      Test Patients
--       N      No. of Partially Adjusted Claims
--       O      No. of Partially Paid Claims
--       P      No. of Insurance Balance Claims
--         P.1    No. of Fully Denied Claims
--           P.1.<PanelGroup>  Dynamic per-panel-group sub-rows
--         P.2    No. of Partially Denied Claims
--         P.3    No. of No Response from Payor Claims
--           P.3.<PanelGroup>  Dynamic per-panel-group sub-rows
--
--   Certus_ES_Cash  - "Cash Breakdown":
--       Q      Total Billed ($)
--       R      Unbilled Claims ($)
--       S      Insurance Payment ($)
--       T      Patient Responsibility ($)
--       U      Adjustments / Write Off ($)
--       V      Patient Paid ($)
--       W      Partially Paid ($)
--       X      Insurance Balance ($)
--         X.1    Denials
--         X.2    Partially Denied
--         X.3    No Response from Payor
--
--   Certus_ES_Avg   - "Average Payment Per Claim":
--       Y      Average Payment ($) - Total Pay/Billed Claims
--       Z      Average Payment ($) - Total Pay/Paid Claims
--       AA     Average Payment ($) - Total Pay/Adjudicated Claims
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

-- ── Certus_ES_LIS ────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.Certus_ES_LIS', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Certus_ES_LIS
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Certus_ES_LIS_Period' AND object_id = OBJECT_ID('dbo.Certus_ES_LIS'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Certus_ES_LIS_Period ON dbo.Certus_ES_LIS (ESYear, ESMonth, RoleID);
END
GO

-- ── Certus_ES_PMS ────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.Certus_ES_PMS', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Certus_ES_PMS
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Certus_ES_PMS_Period' AND object_id = OBJECT_ID('dbo.Certus_ES_PMS'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Certus_ES_PMS_Period ON dbo.Certus_ES_PMS (ESYear, ESMonth, RoleID);
END
GO

-- ── Certus_ES_Cash ───────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.Certus_ES_Cash', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Certus_ES_Cash
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Certus_ES_Cash_Period' AND object_id = OBJECT_ID('dbo.Certus_ES_Cash'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Certus_ES_Cash_Period ON dbo.Certus_ES_Cash (ESYear, ESMonth, RoleID);
END
GO

-- ── Certus_ES_Avg ────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.Certus_ES_Avg', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Certus_ES_Avg
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Certus_ES_Avg_Period' AND object_id = OBJECT_ID('dbo.Certus_ES_Avg'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Certus_ES_Avg_Period ON dbo.Certus_ES_Avg (ESYear, ESMonth, RoleID);
END
GO

PRINT '15_Certus_ExecutiveSummary_Tables.sql completed.';
GO
