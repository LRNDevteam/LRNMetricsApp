-- ============================================================
-- Inhealth – Executive Summary Aggregate Tables
-- File : 22_Inhealth_ExecutiveSummary_Tables.sql
-- DB   : Inhealth_LRN
--
-- Mirrors Augustus\15_Augustus_ExecutiveSummary_Tables.sql.
-- Defines the 4 aggregate tables that back Inhealth's Executive Summary:
--
--   Inhealth_ES_LIS   - "LIS Breakdown":
--       A    Total Samples
--       B    Billable Samples (SampleStatus = 'Billable')
--         B1.{LRNPanelName}  (one per DISTINCT LRNPanelName in LIMSMaster)
--       C    Billed (BillCategory = 'Billed')
--         C.1  Billed Via AMD (SubStatus = 'Billed Via AMD')
--       D    Unbilled (BillCategory = 'Not Billed')
--         D.1  Nexum_Claim_scrubber_Eligibility
--         D.2  Requires Review
--         D.3  Entered in AMD but not billed
--         D.4  Nexum Pre Processing Queue
--         D.5  Nexum_Claim_scrubber_AMD Output
--         D.6  Nexum_Claim_scrubber_Diagnosis Validity
--       E    Other Samples
--         E.1  Billed
--         E.2  Unbilled
--         E.3  Other Samples (LIS Table breakdown)
--         E.4  Self Pay
--         E.5  Deleted/Rejected
--         E.6  Duplicate
--         E.7  System Test
--
--   Inhealth_ES_PMS   - "Billable Samples - PMS Breakdown":
--       F    No. of Billed Claims
--       G    Billed Mismatches (PMS Billed - LIS BillCategory='Billed')
--       H    No. of UnBilled Claims
--         H.1  Unbilled
--         H.2  Unbilled - Patient Balance
--       I    No. of Fully Paid Claims
--       J    No. of Patient Responsibility Claims
--       K    No. of Fully Adjusted Claims
--       L    No. of Partially Adjusted Claims
--       M    No. of Patient Payments Claims
--       N    No. of Partially Paid Claims
--       O    No. of Insurance Balance Claims
--         O.1  No. of Denied Claims
--         O.2  No. of Partially Denied Claims
--         O.3  No. of No Response from Payor Claims
--
--   Inhealth_ES_Cash  - "Cash Breakdown":
--       P    Total Billed ($)
--       Q    Total Unbilled ($)
--         Q.1  Unbilled
--         Q.2  Unbilled - Patient Balance
--       R    Insurance Payment ($)
--       S    Patient Payments ($)
--       T    Partially Paid ($)
--       U    Patient Responsibility ($)
--       V    Total Adjustments ($)
--       W    Insurance Balance ($)
--         W.1  Denials
--         W.2  Partially Denied
--         W.3  No Response from Payor
--
--   Inhealth_ES_Avg   - "Average Payment Per Claim":
--       X    Average Payment ($) - Total Pay/Billed Claims
--       Y    Average Payment ($) - Fully Paid Claim Value/Paid Claims
--       Z    Average Payment ($) - Total Pay/Adjudicated Claims
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

-- ── Inhealth_ES_LIS ──────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.Inhealth_ES_LIS', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Inhealth_ES_LIS
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Inhealth_ES_LIS_Period' AND object_id = OBJECT_ID('dbo.Inhealth_ES_LIS'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Inhealth_ES_LIS_Period ON dbo.Inhealth_ES_LIS (ESYear, ESMonth, RoleID);
END
GO

-- ── Inhealth_ES_PMS ──────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.Inhealth_ES_PMS', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Inhealth_ES_PMS
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Inhealth_ES_PMS_Period' AND object_id = OBJECT_ID('dbo.Inhealth_ES_PMS'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Inhealth_ES_PMS_Period ON dbo.Inhealth_ES_PMS (ESYear, ESMonth, RoleID);
END
GO

-- ── Inhealth_ES_Cash ─────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.Inhealth_ES_Cash', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Inhealth_ES_Cash
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Inhealth_ES_Cash_Period' AND object_id = OBJECT_ID('dbo.Inhealth_ES_Cash'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Inhealth_ES_Cash_Period ON dbo.Inhealth_ES_Cash (ESYear, ESMonth, RoleID);
END
GO

-- ── Inhealth_ES_Avg ──────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.Inhealth_ES_Avg', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Inhealth_ES_Avg
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Inhealth_ES_Avg_Period' AND object_id = OBJECT_ID('dbo.Inhealth_ES_Avg'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Inhealth_ES_Avg_Period ON dbo.Inhealth_ES_Avg (ESYear, ESMonth, RoleID);
END
GO

PRINT '22_Inhealth_ExecutiveSummary_Tables.sql completed.';
GO
