
-- =============================================
-- Dashboard Pre-Aggregated Tables
-- Lab-specific DB (no LabKey needed)
-- Panel data sourced from PanelType column
-- Aging used for avg aging KPI
-- Refreshed on file receive (not daily)
-- =============================================

-- 1. KPI Summary (#2 + #8 combined)
IF OBJECT_ID('dbo.DashboardKPISummary', 'U') IS NOT NULL
    DROP TABLE dbo.DashboardKPISummary;

CREATE TABLE dbo.DashboardKPISummary
(
    Id                      INT IDENTITY(1,1) PRIMARY KEY,
    TotalClaims             INT,
    TotalCharges            DECIMAL(18,2),
    TotalPayments           DECIMAL(18,2),
    TotalBalance            DECIMAL(18,2),
    CollectionNumerator     DECIMAL(18,2),
    DenialNumerator         DECIMAL(18,2),
    AdjustmentNumerator     DECIMAL(18,2),
    OutstandingNumerator    DECIMAL(18,2),
    AvgAging                DECIMAL(18,2),     -- Avg of Aging column
    TotalLines              INT,
    LineTotalCharges        DECIMAL(18,2),
    LineTotalPayments       DECIMAL(18,2),
    LineTotalBalance        DECIMAL(18,2),
    RefreshedAt             DATETIME DEFAULT GETDATE()
);
GO

-- 2. Claim Status Breakdown (#3)
IF OBJECT_ID('dbo.DashboardClaimStatusBreakdown', 'U') IS NOT NULL
    DROP TABLE dbo.DashboardClaimStatusBreakdown;

CREATE TABLE dbo.DashboardClaimStatusBreakdown
(
    Id              INT IDENTITY(1,1) PRIMARY KEY,
    ClaimStatus     NVARCHAR(100),
    Claims          INT,
    Charges         DECIMAL(18,2),
    Payments        DECIMAL(18,2),
    Balance         DECIMAL(18,2),
    RefreshedAt     DATETIME DEFAULT GETDATE()
);
GO

-- 3. Payer Type Payments (#4)
IF OBJECT_ID('dbo.DashboardPayerTypePayments', 'U') IS NOT NULL
    DROP TABLE dbo.DashboardPayerTypePayments;

CREATE TABLE dbo.DashboardPayerTypePayments
(
    Id              INT IDENTITY(1,1) PRIMARY KEY,
    PayerType       NVARCHAR(100),
    TotalPayments   DECIMAL(18,2),
    RefreshedAt     DATETIME DEFAULT GETDATE()
);
GO

-- 4. Insight Breakdown (#5) — PayerName, PanelType, ClinicName, ReferringProvider
IF OBJECT_ID('dbo.DashboardInsightBreakdown', 'U') IS NOT NULL
    DROP TABLE dbo.DashboardInsightBreakdown;

CREATE TABLE dbo.DashboardInsightBreakdown
(
    Id              INT IDENTITY(1,1) PRIMARY KEY,
    InsightType     NVARCHAR(50)    NOT NULL,  -- 'PayerName','PanelType','ClinicName','ReferringProvider'
    Label           NVARCHAR(200),
    Claims          INT,
    Charges         DECIMAL(18,2),
    Payments        DECIMAL(18,2),
    Balance         DECIMAL(18,2),
    RefreshedAt     DATETIME DEFAULT GETDATE()
);
GO

-- 5. Monthly Trends (#6)
IF OBJECT_ID('dbo.DashboardMonthlyTrends', 'U') IS NOT NULL
    DROP TABLE dbo.DashboardMonthlyTrends;

CREATE TABLE dbo.DashboardMonthlyTrends
(
    Id              INT IDENTITY(1,1) PRIMARY KEY,
    TrendType       NVARCHAR(20)    NOT NULL,  -- 'DateOfService' or 'FirstBilledDate'
    Month           NVARCHAR(7),               -- 'yyyy-MM'
    ClaimCount      INT,
    RefreshedAt     DATETIME DEFAULT GETDATE()
);
GO

-- 6. Avg Allowed by PanelType x Month (#7)
IF OBJECT_ID('dbo.DashboardPanelMonthlyAllowed', 'U') IS NOT NULL
    DROP TABLE dbo.DashboardPanelMonthlyAllowed;

CREATE TABLE dbo.DashboardPanelMonthlyAllowed
(
    Id              INT IDENTITY(1,1) PRIMARY KEY,
    PanelType       NVARCHAR(200),             -- PanelType column (not Panelname)
    Month           NVARCHAR(7),
    AvgAllowed      DECIMAL(18,2),
    RefreshedAt     DATETIME DEFAULT GETDATE()
);
GO

-- 7. Top CPT Summary (#9 + #11 Combined)
IF OBJECT_ID('dbo.DashboardTopCPT', 'U') IS NOT NULL
    DROP TABLE dbo.DashboardTopCPT;

CREATE TABLE dbo.DashboardTopCPT
(
    Id                  INT IDENTITY(1,1) PRIMARY KEY,
    CPTCode             NVARCHAR(20),
    Charges             DECIMAL(18,2),
    AllowedAmount       DECIMAL(18,2),
    InsuranceBalance    DECIMAL(18,2),
    CollectionAllowed   DECIMAL(18,2),
    DenialCharges       DECIMAL(18,2),
    NoRespCharges       DECIMAL(18,2),
    RefreshedAt         DATETIME DEFAULT GETDATE()
);
GO

-- 8. Pay Status Breakdown (#10)
IF OBJECT_ID('dbo.DashboardPayStatusBreakdown', 'U') IS NOT NULL
    DROP TABLE dbo.DashboardPayStatusBreakdown;

CREATE TABLE dbo.DashboardPayStatusBreakdown
(
    Id              INT IDENTITY(1,1) PRIMARY KEY,
    PayStatus       NVARCHAR(100),
    ClaimCount      INT,
    RefreshedAt     DATETIME DEFAULT GETDATE()
);
GO

-- 9. Filter Lookup Cache (#1)
IF OBJECT_ID('dbo.DashboardFilterLookup', 'U') IS NOT NULL
    DROP TABLE dbo.DashboardFilterLookup;

CREATE TABLE dbo.DashboardFilterLookup
(
    Id              INT IDENTITY(1,1) PRIMARY KEY,
    FilterType      NVARCHAR(50)    NOT NULL,  -- 'PayerName','PayerType','PanelType','ClinicName','ReferringProvider'
    FilterValue     NVARCHAR(300)   NOT NULL,
    RefreshedAt     DATETIME DEFAULT GETDATE()
);
GO

