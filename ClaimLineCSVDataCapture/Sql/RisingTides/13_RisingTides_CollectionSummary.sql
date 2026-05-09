-- =====================================================================
-- RisingTides — Collection Summary Aggregates
-- Pre-computes the data behind the 13 Collection Summary tabs in the
-- LabMetricsDashboard web app:
--   1.  Top 5 Insurances | Reimbursement Percentages (vs Billed Charge)
--   2.  Top 5 Insurances | Reimbursement Payments
--   3.  Monthly Claim Volume                  (Posted Date, Line level)
--   4.  Weekly Claim Volume                   (Posted Date, Line level)
--   5.  Panel Averages
--   6.  Avg Payments  (per Panel | last 6 months | Posted Date)
--   7.  Insurance vs Aging
--   8.  Panel vs Payment
--   9.  Rep vs Payment
--   10. Insurance vs Payment %
--   11. CPT vs Payment %
--   12. Status Summary
--   13. Provider Summary
--
-- Per the RisingTides spec, several tabs add an extra exclusion:
--      ClaimStatus = 'No Response' AND BilledUnbilled = 'Unbilled'
-- and use PayerName_Raw + Panelname.
-- All SPs are idempotent (TRUNCATE + INSERT) and safe to re-run.
-- =====================================================================

SET NOCOUNT ON;
GO

-- ?????????????????????????????????????????????????????????????????????
-- TABLE DEFINITIONS
-- ?????????????????????????????????????????????????????????????????????

-- 1. Top 5 Insurances | Reimbursement % (vs Billed Charge)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'RT_CS_Top5ReimbursementPct')
CREATE TABLE dbo.RT_CS_Top5ReimbursementPct
(
    SummaryId           INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerRank           TINYINT         NOT NULL,
    PayerName           NVARCHAR(500)   NOT NULL,
    SumInsurancePayment DECIMAL(18,2)   NOT NULL DEFAULT 0,
    SumChargeAmount     DECIMAL(18,2)   NOT NULL DEFAULT 0,
    UniqueVisitCount    INT             NOT NULL DEFAULT 0,
    RefreshedAt         DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- 2. Top 5 Insurances | Reimbursement Payments
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'RT_CS_Top5ReimbursementPay')
CREATE TABLE dbo.RT_CS_Top5ReimbursementPay
(
    SummaryId         INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerRank         TINYINT         NOT NULL,
    PayerName         NVARCHAR(500)   NOT NULL,
    TotalPayments     DECIMAL(18,2)   NOT NULL DEFAULT 0,
    UniqueVisitCount  INT             NOT NULL DEFAULT 0,
    RefreshedAt       DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- 3. Monthly Claim Volume  (LineLevelData, Posted Date)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'RT_CS_MonthlyClaimVolume')
CREATE TABLE dbo.RT_CS_MonthlyClaimVolume
(
    SummaryId         INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName         NVARCHAR(500)   NOT NULL,
    PayerName         NVARCHAR(500)   NOT NULL,
    PayerRank         TINYINT         NOT NULL,
    BillYear          INT             NOT NULL,
    BillMonth         TINYINT         NOT NULL,
    NoOfClaims        INT             NOT NULL DEFAULT 0,
    InsurancePayment  DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt       DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- 4. Weekly Claim Volume  (LineLevelData, Posted Date, Fri-Thu weeks)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'RT_CS_WeeklyClaimVolume')
CREATE TABLE dbo.RT_CS_WeeklyClaimVolume
(
    SummaryId         INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName         NVARCHAR(500)   NOT NULL,
    PayerName         NVARCHAR(500)   NOT NULL,
    PayerRank         TINYINT         NOT NULL,
    WeekKey           TINYINT         NOT NULL,         -- 1..4 (oldest..most recent)
    WeekStart         DATE            NOT NULL,         -- Friday
    WeekEnd           DATE            NOT NULL,         -- Thursday
    NoOfClaims        INT             NOT NULL DEFAULT 0,
    InsurancePayment  DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt       DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- 5. Panel Averages
--    Row     : PanelName | PayerName
--    Col-1 base (exclude ClaimStatus='No Response' AND BilledUnbilled='Unbilled'):
--              NoOfClaims = COUNT(DISTINCT AccessionNumber)  ("Unique Visit Number")
--              TotalCharges, CarrierPayment, AvgCarrierPayment
--    Col-2 (Filter: BilledUnbilled='Unbilled' AND ClaimStatus='Fully Paid'):
--              FullyPaidCount, FullyPaidAmount, AvgFullyPaid
--    Col-3 (base + AgingBucket = '30 Days'):
--              Days30Count, Days30Amount, AvgDays30
--    Col-4 (base + AgingBucket = '60 Days'):
--              Days60Count, Days60Amount, AvgDays60
DROP TABLE IF EXISTS dbo.RT_CS_PanelAverages;
GO
CREATE TABLE dbo.RT_CS_PanelAverages
(
    SummaryId           INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName           NVARCHAR(500)   NOT NULL,
    PayerName           NVARCHAR(500)   NOT NULL,
    NoOfClaims          INT             NOT NULL DEFAULT 0,   -- distinct AccessionNumber
    TotalCharges        DECIMAL(18,2)   NOT NULL DEFAULT 0,
    CarrierPayment      DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgCarrierPayment   DECIMAL(18,2)   NOT NULL DEFAULT 0,
    FullyPaidCount      INT             NOT NULL DEFAULT 0,
    FullyPaidAmount     DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgFullyPaid        DECIMAL(18,2)   NOT NULL DEFAULT 0,
    Days30Count         INT             NOT NULL DEFAULT 0,
    Days30Amount        DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgDays30           DECIMAL(18,2)   NOT NULL DEFAULT 0,
    Days60Count         INT             NOT NULL DEFAULT 0,
    Days60Amount        DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgDays60           DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt         DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- 6. AvgPayments — same shape as Panel Averages, but uses CheckDate (Posted)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'RT_CS_AvgPayments')
CREATE TABLE dbo.RT_CS_AvgPayments
(
    SummaryId         INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName         NVARCHAR(500)   NOT NULL,
    PayerName         NVARCHAR(500)   NOT NULL,
    PayerRank         TINYINT         NOT NULL,
    ClaimCount        INT             NOT NULL DEFAULT 0,
    TotalCharges      DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgCharges        DECIMAL(18,2)   NOT NULL DEFAULT 0,
    InsurancePayment  DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgInsurancePayment DECIMAL(18,2) NOT NULL DEFAULT 0,
    FullyPaidCount    INT             NOT NULL DEFAULT 0,
    FullyPaidAmount   DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgFullyPaid      DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AdjudicatedCount  INT             NOT NULL DEFAULT 0,
    AdjudicatedAmount DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgAdjudicated    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    Over30Count       INT             NOT NULL DEFAULT 0,
    Over30Amount      DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgOver30         DECIMAL(18,2)   NOT NULL DEFAULT 0,
    Over60Count       INT             NOT NULL DEFAULT 0,
    Over60Amount      DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgOver60         DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt       DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- 7. Insurance vs Aging
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'RT_CS_InsuranceVsAging')
CREATE TABLE dbo.RT_CS_InsuranceVsAging
(
    SummaryId        INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName        NVARCHAR(500)   NOT NULL,
    AgingBucket      NVARCHAR(200)   NOT NULL,
    VisitCount       INT             NOT NULL DEFAULT 0,
    InsuranceBalance DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- 8. Panel vs Payment
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'RT_CS_PanelVsPayment')
CREATE TABLE dbo.RT_CS_PanelVsPayment
(
    SummaryId        INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName        NVARCHAR(500)   NOT NULL,
    NoOfClaims       INT             NOT NULL DEFAULT 0,
    InsurancePayment DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- 9. Rep vs Payment
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'RT_CS_RepVsPayment')
CREATE TABLE dbo.RT_CS_RepVsPayment
(
    SummaryId        INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    SalesRepName     NVARCHAR(500)   NOT NULL,
    CheckYear        INT             NOT NULL,
    CheckMonth       TINYINT         NOT NULL,
    NoOfClaims       INT             NOT NULL DEFAULT 0,
    InsurancePayment DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- 10. Insurance vs Payment %
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'RT_CS_InsuranceVsPaymentPct')
CREATE TABLE dbo.RT_CS_InsuranceVsPaymentPct
(
    SummaryId        INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName        NVARCHAR(500)   NOT NULL,
    PanelGroupCount  INT             NOT NULL DEFAULT 0,    -- count of distinct panel-group rows
    InsurancePayment DECIMAL(18,2)   NOT NULL DEFAULT 0,
    PaymentPct       DECIMAL(9,4)    NOT NULL DEFAULT 0,    -- payer share of grand total payments
    RefreshedAt      DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- 11. CPT vs Payment %
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'RT_CS_CptVsPaymentPct')
CREATE TABLE dbo.RT_CS_CptVsPaymentPct
(
    SummaryId            INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    CPTCode              NVARCHAR(50)    NOT NULL,
    SumUnits             DECIMAL(18,2)   NOT NULL DEFAULT 0,
    PaidInsurancePayment DECIMAL(18,2)   NOT NULL DEFAULT 0,
    PaidChargeAmount     DECIMAL(18,2)   NOT NULL DEFAULT 0,
    PaymentPct           DECIMAL(9,4)    NOT NULL DEFAULT 0,    -- PaidIns / PaidCharge
    RefreshedAt          DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- 12. Status Summary  (flat 4-level grain — UI builds the hierarchy)
DROP TABLE IF EXISTS dbo.RT_CS_StatusSummary;
GO
CREATE TABLE dbo.RT_CS_StatusSummary
(
    SummaryId        INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    ClaimStatus      NVARCHAR(200)   NOT NULL,
    PanelName        NVARCHAR(500)   NOT NULL,
    CptCode          NVARCHAR(MAX)   NOT NULL,   -- CPTCodeXUnitsXModifier can be a long concatenated list
    PayerName        NVARCHAR(500)   NOT NULL,
    NoOfClaims       INT             NOT NULL DEFAULT 0,
    InsurancePayment DECIMAL(18,2)   NOT NULL DEFAULT 0,
    InsuranceBalance DECIMAL(18,2)   NOT NULL DEFAULT 0,
    PatientBalance   DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- 13. Provider Summary
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'RT_CS_ProviderSummary')
CREATE TABLE dbo.RT_CS_ProviderSummary
(
    SummaryId         INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    ProviderRank      INT             NOT NULL,
    ReferringProvider NVARCHAR(500)   NOT NULL,
    NoOfClaims        INT             NOT NULL DEFAULT 0,
    InsurancePayment  DECIMAL(18,2)   NOT NULL DEFAULT 0,
    InsuranceBalance  DECIMAL(18,2)   NOT NULL DEFAULT 0,
    PatientBalance    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt       DATETIME        NOT NULL DEFAULT GETDATE()
);
GO


-- =====================================================================
-- STORED PROCEDURES
-- =====================================================================

-- 1. Top 5 Insurances | Reimbursement % (vs Billed Charge)
--    Exclude  : ClaimStatus = 'No Response' AND BilledUnbilled = 'Unbilled'
--    Filter   : InsurancePayment > 0
--    Row      : Top 5 PayerName_Raw  (ordered by Sum(InsurancePayment) DESC)
--    Columns  : Sum(InsurancePayment), Sum(ChargeAmount) — % is computed in UI
CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_CS_Top5ReimbursementPct
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(PayerName_Raw))                                AS PayerName,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0) AS SumIns,
            ISNULL(SUM(TRY_CAST(ChargeAmount     AS DECIMAL(18,2))),0) AS SumChg,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(AccessionNumber)), '')) AS Visits
        FROM dbo.ClaimLevelData
        WHERE PayerName_Raw IS NOT NULL
          AND LTRIM(RTRIM(PayerName_Raw)) <> ''
          AND ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND NOT (LTRIM(RTRIM(ClaimStatus)) = 'No Response'
                   AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled')
        GROUP BY LTRIM(RTRIM(PayerName_Raw))
    ),
    ranked AS (
        SELECT TOP 5 PayerName, SumIns, SumChg, Visits,
               ROW_NUMBER() OVER (ORDER BY SumIns DESC) AS Rnk
        FROM agg
        ORDER BY SumIns DESC
    )
    SELECT * INTO #out FROM ranked;

    TRUNCATE TABLE dbo.RT_CS_Top5ReimbursementPct;
    INSERT INTO dbo.RT_CS_Top5ReimbursementPct
        (PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount, RefreshedAt)
    SELECT CAST(Rnk AS TINYINT), PayerName, SumIns, SumChg, Visits, GETDATE()
    FROM #out
    ORDER BY Rnk;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshRT_CS_Top5ReimbursementPct completed.';
END
GO


-- 2. Top 5 Insurances | Reimbursement Payments
CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_CS_Top5ReimbursementPay
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(PayerName_Raw))                                AS PayerName,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0) AS TotalPay,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(AccessionNumber)), '')) AS Visits
        FROM dbo.ClaimLevelData
        WHERE PayerName_Raw IS NOT NULL
          AND LTRIM(RTRIM(PayerName_Raw)) <> ''
          AND ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND NOT (LTRIM(RTRIM(ClaimStatus)) = 'No Response'
                   AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled')
        GROUP BY LTRIM(RTRIM(PayerName_Raw))
    ),
    ranked AS (
        SELECT TOP 5 PayerName, TotalPay, Visits,
               ROW_NUMBER() OVER (ORDER BY TotalPay DESC) AS Rnk
        FROM agg
        ORDER BY TotalPay DESC
    )
    SELECT * INTO #out FROM ranked;

    TRUNCATE TABLE dbo.RT_CS_Top5ReimbursementPay;
    INSERT INTO dbo.RT_CS_Top5ReimbursementPay
        (PayerRank, PayerName, TotalPayments, UniqueVisitCount, RefreshedAt)
    SELECT CAST(Rnk AS TINYINT), PayerName, TotalPay, Visits, GETDATE()
    FROM #out
    ORDER BY Rnk;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshRT_CS_Top5ReimbursementPay completed.';
END
GO


-- 3. Monthly Claim Volume  (LineLevelData, PostingDate)
--    Filter  : InsurancePayment > 0
--    Row     : Panelname  +  Top-3 PayerName_Raw (by COUNT distinct ClaimID per panel)
--    Column  : Posted Date Year/Month, COUNT(DISTINCT ClaimID), SUM(InsurancePayment)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_CS_MonthlyClaimVolume
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))               AS PanelName,
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))               AS PayerName,
        YEAR (TRY_CAST(PostingDate AS DATE))                         AS BillYear,
        MONTH(TRY_CAST(PostingDate AS DATE))                         AS BillMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))            AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment
    INTO #raw
    FROM dbo.LineLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST(PostingDate AS DATE) IS NOT NULL
      AND YEAR(TRY_CAST(PostingDate AS DATE)) > 1900
    GROUP BY
        LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))),
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        YEAR (TRY_CAST(PostingDate AS DATE)),
        MONTH(TRY_CAST(PostingDate AS DATE));

    SELECT
        PanelName, PayerName,
        DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
    INTO #ranks
    FROM #raw
    GROUP BY PanelName, PayerName;

    TRUNCATE TABLE dbo.RT_CS_MonthlyClaimVolume;
    INSERT INTO dbo.RT_CS_MonthlyClaimVolume
        (PanelName, PayerName, PayerRank, BillYear, BillMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT r.PanelName, r.PayerName, CAST(k.PayerRank AS TINYINT),
           r.BillYear, CAST(r.BillMonth AS TINYINT), r.NoOfClaims, r.InsurancePayment, GETDATE()
    FROM #raw r
    JOIN #ranks k ON k.PanelName = r.PanelName AND k.PayerName = r.PayerName
   -- WHERE k.PayerRank <= 3
    ORDER BY r.PanelName, k.PayerRank, r.BillYear, r.BillMonth;

    DROP TABLE IF EXISTS #raw;
    DROP TABLE IF EXISTS #ranks;
    PRINT 'usp_RefreshRT_CS_MonthlyClaimVolume completed.';
END
GO


-- 4. Weekly Claim Volume  (LineLevelData, PostingDate, Fri-Thu, last 4 complete weeks)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_CS_WeeklyClaimVolume
AS
BEGIN
    SET NOCOUNT ON;

    -- Build the last 4 complete Fri-Thu weeks ending strictly before today.
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    -- DATEPART(weekday) is locale-dependent; compute days since last Thursday safely.
    -- Thursday = 5 in ISO_WEEK numbering (Mon=1..Sun=7).
    DECLARE @DaysSinceThu INT =
        ((DATEDIFF(DAY, '1900-01-04', @Today) % 7) + 7) % 7;  -- 1900-01-04 was a Thursday
    DECLARE @LastThu DATE = DATEADD(DAY, -@DaysSinceThu, @Today);
    IF @LastThu = @Today SET @LastThu = DATEADD(DAY, -7, @LastThu);

    DECLARE @W4End DATE = @LastThu;                           -- most-recent week end (Thu)
    DECLARE @W4Start DATE = DATEADD(DAY, -6, @W4End);         -- Fri
    DECLARE @W3End DATE = DATEADD(DAY, -7, @W4End), @W3Start DATE = DATEADD(DAY, -6, DATEADD(DAY,-7,@W4End));
    DECLARE @W2End DATE = DATEADD(DAY,-14, @W4End), @W2Start DATE = DATEADD(DAY, -6, DATEADD(DAY,-14,@W4End));
    DECLARE @W1End DATE = DATEADD(DAY,-21, @W4End), @W1Start DATE = DATEADD(DAY, -6, DATEADD(DAY,-21,@W4End));

    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))            AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))            AS PayerName,
            CASE
              WHEN TRY_CAST(PostingDate AS DATE) BETWEEN @W1Start AND @W1End THEN 1
              WHEN TRY_CAST(PostingDate AS DATE) BETWEEN @W2Start AND @W2End THEN 2
              WHEN TRY_CAST(PostingDate AS DATE) BETWEEN @W3Start AND @W3End THEN 3
              WHEN TRY_CAST(PostingDate AS DATE) BETWEEN @W4Start AND @W4End THEN 4
            END                                                       AS WeekKey,
            ClaimID,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))               AS InsPay
        FROM dbo.LineLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(PostingDate AS DATE) BETWEEN @W1Start AND @W4End
    ),
    agg AS (
        SELECT PanelName, PayerName, WeekKey,
               COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfClaims,
               ISNULL(SUM(InsPay), 0)                            AS InsurancePayment
        FROM src
        WHERE WeekKey IS NOT NULL
        GROUP BY PanelName, PayerName, WeekKey
    ),
    ranks AS (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
        FROM agg
        GROUP BY PanelName, PayerName
    )
    SELECT a.PanelName, a.PayerName, CAST(r.PayerRank AS TINYINT) AS PayerRank,
           CAST(a.WeekKey AS TINYINT) AS WeekKey,
           CASE a.WeekKey WHEN 1 THEN @W1Start WHEN 2 THEN @W2Start
                          WHEN 3 THEN @W3Start WHEN 4 THEN @W4Start END AS WeekStart,
           CASE a.WeekKey WHEN 1 THEN @W1End   WHEN 2 THEN @W2End
                          WHEN 3 THEN @W3End   WHEN 4 THEN @W4End   END AS WeekEnd,
           a.NoOfClaims, a.InsurancePayment
    INTO #out
    FROM agg a
    JOIN ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName;
   -- WHERE r.PayerRank <= 3;

    TRUNCATE TABLE dbo.RT_CS_WeeklyClaimVolume;
    INSERT INTO dbo.RT_CS_WeeklyClaimVolume
        (PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd,
         NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd,
           NoOfClaims, InsurancePayment, GETDATE()
    FROM #out
    ORDER BY PanelName, PayerRank, WeekKey;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshRT_CS_WeeklyClaimVolume completed.';
END
GO


-- 5 + 6.  Helper macro:  Panel Averages / AvgPayments — same shape, different date column.
--         Built as two separate SPs so each table refreshes independently.

--CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_CS_PanelAverages
--AS
--BEGIN
--    SET NOCOUNT ON;

--    -- "Unique Visit Number" = AccessionNumber (falling back to ClaimID when blank).
--    DECLARE @VisitKey NVARCHAR(200) = N'COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''''), ClaimID)';

--    -- Pre-stage one row per (Panel, Payer, Visit) with the flags each column needs.
--    -- Doing it this way lets each column apply its own filter independently while
--    -- still grouping at the Panel/Payer grain at the end.
--    ;WITH src AS (
--        SELECT
--            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))            AS PanelName,
--            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))            AS PayerName,
--            COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
--                     LTRIM(RTRIM(ClaimID)))                           AS VisitKey,
--            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))               AS Chg,
--            TRY_CAST(InsurancePayment AS DECIMAL(18,2))               AS InsPay,
--            LTRIM(RTRIM(ClaimStatus))                                 AS ClaimStatus,
--            LTRIM(RTRIM(BilledUnbilled))                              AS BilledUnbilled,
--            LTRIM(RTRIM(AgingBucket))                                 AS AgingBucket
--        FROM dbo.ClaimLevelData
--        WHERE Panelname IS NOT NULL AND LTRIM(RTRIM(Panelname)) <> ''
--    )
--    SELECT
--        PanelName,
--        PayerName,

--        -- Column 1 — base set: exclude (No Response & Unbilled)
--        COUNT(DISTINCT CASE
--              WHEN NOT (ClaimStatus = 'No Response' AND BilledUnbilled = 'Unbilled')
--              THEN VisitKey END)                                       AS NoOfClaims,
--        ISNULL(SUM(CASE
--              WHEN NOT (ClaimStatus = 'No Response' AND BilledUnbilled = 'Unbilled')
--              THEN Chg ELSE 0 END), 0)                                 AS TotalCharges,
--        ISNULL(SUM(CASE
--              WHEN NOT (ClaimStatus = 'No Response' AND BilledUnbilled = 'Unbilled')
--              THEN InsPay ELSE 0 END), 0)                              AS CarrierPayment,

--        -- Column 2 — Fully Paid + Unbilled
--        COUNT(DISTINCT CASE
--              WHEN BilledUnbilled = 'Unbilled' AND ClaimStatus = 'Fully Paid'
--              THEN VisitKey END)                                       AS FullyPaidCount,
--        ISNULL(SUM(CASE
--              WHEN BilledUnbilled = 'Unbilled' AND ClaimStatus = 'Fully Paid'
--              THEN InsPay ELSE 0 END), 0)                              AS FullyPaidAmount,

--        -- Column 3 — base + AgingBucket = '30 Days'
--        COUNT(DISTINCT CASE
--              WHEN NOT (ClaimStatus = 'No Response' AND BilledUnbilled = 'Unbilled')
--                   AND AgingBucket = '30 Days'
--              THEN VisitKey END)                                       AS Days30Count,
--        ISNULL(SUM(CASE
--              WHEN NOT (ClaimStatus = 'No Response' AND BilledUnbilled = 'Unbilled')
--                   AND AgingBucket = '30 Days'
--              THEN InsPay ELSE 0 END), 0)                              AS Days30Amount,

--        -- Column 4 — base + AgingBucket = '60 Days'
--        COUNT(DISTINCT CASE
--              WHEN NOT (ClaimStatus = 'No Response' AND BilledUnbilled = 'Unbilled')
--                   AND AgingBucket = '60 Days'
--              THEN VisitKey END)                                       AS Days60Count,
--        ISNULL(SUM(CASE
--              WHEN NOT (ClaimStatus = 'No Response' AND BilledUnbilled = 'Unbilled')
--                   AND AgingBucket = '60 Days'
--              THEN InsPay ELSE 0 END), 0)                              AS Days60Amount
--    INTO #out
--    FROM src
--    GROUP BY PanelName, PayerName;

--    TRUNCATE TABLE dbo.RT_CS_PanelAverages;

--    INSERT INTO dbo.RT_CS_PanelAverages
--        (PanelName, PayerName,
--         NoOfClaims, TotalCharges, CarrierPayment, AvgCarrierPayment,
--         FullyPaidCount, FullyPaidAmount, AvgFullyPaid,
--         Days30Count, Days30Amount, AvgDays30,
--         Days60Count, Days60Amount, AvgDays60,
--         RefreshedAt)
--    SELECT
--        PanelName, PayerName,
--        NoOfClaims, TotalCharges, CarrierPayment,
--        CASE WHEN NoOfClaims    > 0 THEN CarrierPayment  / NoOfClaims    ELSE 0 END,
--        FullyPaidCount, FullyPaidAmount,
--        CASE WHEN FullyPaidCount > 0 THEN FullyPaidAmount / FullyPaidCount ELSE 0 END,
--        Days30Count, Days30Amount,
--        CASE WHEN Days30Count    > 0 THEN Days30Amount    / Days30Count    ELSE 0 END,
--        Days60Count, Days60Amount,
--        CASE WHEN Days60Count    > 0 THEN Days60Amount    / Days60Count    ELSE 0 END,
--        GETDATE()
--    FROM #out
--    ORDER BY PanelName, PayerName;

--    DROP TABLE IF EXISTS #out;
--    PRINT 'usp_RefreshRT_CS_PanelAverages completed.';
--END




CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_CS_PanelAverages
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))            AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))            AS PayerName,
            COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
                     LTRIM(RTRIM(ClaimID)))                           AS VisitKey,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))               AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))               AS InsPay,
            LTRIM(RTRIM(ClaimStatus))                                 AS ClaimStatus,
            LTRIM(RTRIM(BilledUnbilled))                              AS BilledUnbilled,
            -- ✅ Correct fields for Column 3 & 4
            LTRIM(RTRIM(Bucket30Count))                               AS Bucket30Count,
            TRY_CAST(Bucket30Amount AS DECIMAL(18,2))                 AS Bucket30Amount,
            LTRIM(RTRIM(Bucket60Count))                               AS Bucket60Count,
            TRY_CAST(Bucket60Amount AS DECIMAL(18,2))                 AS Bucket60Amount
        FROM dbo.ClaimLevelData
        WHERE Panelname IS NOT NULL AND LTRIM(RTRIM(Panelname)) <> ''
    )
    SELECT
        PanelName,
        PayerName,

        -- =============================================
        -- Column 1
        -- Filter: EXCLUDE (No Response + Unbilled)
        -- =============================================
        COUNT(DISTINCT CASE
              WHEN NOT (ClaimStatus = 'No Response' AND BilledUnbilled = 'Unbilled')
              THEN VisitKey END)                                       AS NoOfClaims,

        ISNULL(SUM(CASE
              WHEN NOT (ClaimStatus = 'No Response' AND BilledUnbilled = 'Unbilled')
              THEN Chg ELSE 0 END), 0)                                AS TotalCharges,

        ISNULL(SUM(CASE
              WHEN NOT (ClaimStatus = 'No Response' AND BilledUnbilled = 'Unbilled')
              THEN InsPay ELSE 0 END), 0)                             AS CarrierPayment,

        -- =============================================
        -- Column 2
        -- Filter: BilledUnbilled = 'Unbilled' AND ClaimStatus = 'Fully Paid'
        -- =============================================
        COUNT(DISTINCT CASE
              WHEN BilledUnbilled = 'Unbilled'
               AND ClaimStatus   = 'Fully Paid'
              THEN VisitKey END)                                      AS FullyPaidCount,

        ISNULL(SUM(CASE
              WHEN BilledUnbilled = 'Unbilled'
               AND ClaimStatus   = 'Fully Paid'
              THEN InsPay ELSE 0 END), 0)                             AS FullyPaidAmount,

        -- =============================================
        -- Column 3
        -- Filter: ClaimStatus = 'No Response' AND BilledUnbilled = 'Unbilled'
        --         AND Bucket30Count = '30 Days Count'
        -- Count VisitKey, Sum Bucket30Amount
        -- ❌ Was: AgingBucket = '30 Days' — FIXED
        -- =============================================
        COUNT(DISTINCT CASE
              WHEN ClaimStatus    = 'No Response'
               AND BilledUnbilled = 'Unbilled'
               AND Bucket30Count  = '30 Days Count'                   -- ← FIXED: correct field
              THEN VisitKey END)                                       AS Days30Count,

        ISNULL(SUM(CASE
              WHEN ClaimStatus    = 'No Response'
               AND BilledUnbilled = 'Unbilled'
               AND Bucket30Count  = '30 Days Count'                   -- ← FIXED: correct field
              THEN Bucket30Amount ELSE 0 END), 0)                     AS Days30Amount,  -- ← FIXED: Bucket30Amount

        -- =============================================
        -- Column 4
        -- Filter: ClaimStatus = 'No Response' AND BilledUnbilled = 'Unbilled'
        --         AND Bucket60Count = '60 Days Count'
        -- Count VisitKey, Sum Bucket60Amount
        -- ❌ Was: AgingBucket = '60 Days' — FIXED
        -- =============================================
        COUNT(DISTINCT CASE
              WHEN ClaimStatus    = 'No Response'
               AND BilledUnbilled = 'Unbilled'
               AND Bucket60Count  = '60 Days Count'                   -- ← FIXED: correct field
              THEN VisitKey END)                                       AS Days60Count,

        ISNULL(SUM(CASE
              WHEN ClaimStatus    = 'No Response'
               AND BilledUnbilled = 'Unbilled'
               AND Bucket60Count  = '60 Days Count'                   -- ← FIXED: correct field
              THEN Bucket60Amount ELSE 0 END), 0)                     AS Days60Amount   -- ← FIXED: Bucket60Amount

    INTO #out
    FROM src
    GROUP BY PanelName, PayerName;

    -- =============================================
    -- Final Insert with Averages
    -- =============================================
    TRUNCATE TABLE dbo.RT_CS_PanelAverages;

    INSERT INTO dbo.RT_CS_PanelAverages
        (PanelName, PayerName,
         NoOfClaims, TotalCharges, CarrierPayment, AvgCarrierPayment,
         FullyPaidCount, FullyPaidAmount, AvgFullyPaid,
         Days30Count, Days30Amount, AvgDays30,
         Days60Count, Days60Amount, AvgDays60,
         RefreshedAt)
    SELECT
        PanelName, PayerName,

        -- Column 1
        NoOfClaims,
        TotalCharges,
        CarrierPayment,
        CASE WHEN NoOfClaims     > 0 THEN CarrierPayment  / NoOfClaims     ELSE 0 END  AS AvgCarrierPayment,

        -- Column 2
        FullyPaidCount,
        FullyPaidAmount,
        CASE WHEN FullyPaidCount > 0 THEN FullyPaidAmount / FullyPaidCount ELSE 0 END  AS AvgFullyPaid,

        -- Column 3
        Days30Count,
        Days30Amount,
        CASE WHEN Days30Count    > 0 THEN Days30Amount    / Days30Count    ELSE 0 END  AS AvgDays30,

        -- Column 4
        Days60Count,
        Days60Amount,
        CASE WHEN Days60Count    > 0 THEN Days60Amount    / Days60Count    ELSE 0 END  AS AvgDays60,

        GETDATE()
    FROM #out
    ORDER BY PanelName, PayerName;

    DROP TABLE IF EXISTS #out;

    PRINT 'usp_RefreshRT_CS_PanelAverages completed.';
END
GO

GO


CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_CS_AvgPayments
AS
BEGIN
    SET NOCOUNT ON;

    -- Same logic as PanelAverages but additionally requires InsurancePayment > 0
    -- (matches the existing AvgPayments tab in the dashboard).
    DECLARE @Cutoff DATE = DATEADD(MONTH, -6, CAST(GETDATE() AS DATE));

    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))            AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))            AS PayerName,
            ClaimID,
            TRY_CAST(ChargeAmount      AS DECIMAL(18,2))              AS Chg,
            TRY_CAST(InsurancePayment  AS DECIMAL(18,2))              AS InsPay,
            LTRIM(RTRIM(ClaimStatus))                                 AS Status,
            LTRIM(RTRIM(AgingBucket))                                 AS Bucket
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND TRY_CAST(CheckDate AS DATE) >= @Cutoff
          AND Panelname     IS NOT NULL AND LTRIM(RTRIM(Panelname))     <> ''
          AND PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''
    ),
    agg AS (
        SELECT PanelName, PayerName,
               COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS ClaimCount,
               ISNULL(SUM(Chg),    0) AS TotalCharges,
               ISNULL(SUM(InsPay), 0) AS InsurancePayment,
               COUNT(DISTINCT CASE WHEN Status = 'Fully Paid' THEN ClaimID END) AS FullyPaidCount,
               ISNULL(SUM(CASE WHEN Status = 'Fully Paid' THEN InsPay ELSE 0 END), 0) AS FullyPaidAmount,
               COUNT(DISTINCT CASE WHEN Status IN
                   ('Fully Paid','Partially Paid','Complete W/O','Fully Adjusted',
                    'Fully Denied','Denied','Partially Denied','Partially Adjusted',
                    'Patient Responsibility')
                 THEN ClaimID END) AS AdjudicatedCount,
               ISNULL(SUM(CASE WHEN Status IN
                   ('Fully Paid','Partially Paid','Complete W/O','Fully Adjusted',
                    'Fully Denied','Denied','Partially Denied','Partially Adjusted',
                    'Patient Responsibility')
                 THEN InsPay ELSE 0 END), 0) AS AdjudicatedAmount,
               COUNT(DISTINCT CASE WHEN Bucket <> 'Current' THEN ClaimID END) AS Over30Count,
               ISNULL(SUM(CASE WHEN Bucket <> 'Current' THEN InsPay ELSE 0 END), 0) AS Over30Amount,
               COUNT(DISTINCT CASE WHEN Bucket NOT IN ('Current','30+') THEN ClaimID END) AS Over60Count,
               ISNULL(SUM(CASE WHEN Bucket NOT IN ('Current','30+') THEN InsPay ELSE 0 END), 0) AS Over60Amount
        FROM base
        GROUP BY PanelName, PayerName
    ),
    ranks AS (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY ClaimCount DESC) AS PayerRank
        FROM agg
    )
    SELECT a.*, CAST(r.PayerRank AS TINYINT) AS PayerRank
    INTO #out
    FROM agg a
    JOIN ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    WHERE r.PayerRank <= 3;

    TRUNCATE TABLE dbo.RT_CS_AvgPayments;
    INSERT INTO dbo.RT_CS_AvgPayments
        (PanelName, PayerName, PayerRank,
         ClaimCount, TotalCharges, AvgCharges,
         InsurancePayment, AvgInsurancePayment,
         FullyPaidCount, FullyPaidAmount, AvgFullyPaid,
         AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,
         Over30Count, Over30Amount, AvgOver30,
         Over60Count, Over60Amount, AvgOver60,
         RefreshedAt)
    SELECT
        PanelName, PayerName, PayerRank,
        ClaimCount, TotalCharges,
        CASE WHEN ClaimCount > 0 THEN TotalCharges / ClaimCount ELSE 0 END,
        InsurancePayment,
        CASE WHEN ClaimCount > 0 THEN InsurancePayment / ClaimCount ELSE 0 END,
        FullyPaidCount, FullyPaidAmount,
        CASE WHEN FullyPaidCount > 0 THEN FullyPaidAmount / FullyPaidCount ELSE 0 END,
        AdjudicatedCount, AdjudicatedAmount,
        CASE WHEN AdjudicatedCount > 0 THEN AdjudicatedAmount / AdjudicatedCount ELSE 0 END,
        Over30Count, Over30Amount,
        CASE WHEN Over30Count > 0 THEN Over30Amount / Over30Count ELSE 0 END,
        Over60Count, Over60Amount,
        CASE WHEN Over60Count > 0 THEN Over60Amount / Over60Count ELSE 0 END,
        GETDATE()
    FROM #out
    ORDER BY PanelName, PayerRank;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshRT_CS_AvgPayments completed.';
END
GO


-- 7. Insurance vs Aging
--    Exclude : ClaimStatus = 'No Response' AND BilledUnbilled = 'Unbilled'
--    Filter  : InsuranceBalance <> 0, PayerName_Raw not blank
--    Row     : PayerName_Raw
--    Column  : AgingBucket, COUNT(DISTINCT AccessionNumber), SUM(InsuranceBalance)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_CS_InsuranceVsAging
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.RT_CS_InsuranceVsAging;

    INSERT INTO dbo.RT_CS_InsuranceVsAging
        (PayerName, AgingBucket, VisitCount, InsuranceBalance, RefreshedAt)
    SELECT
        LTRIM(RTRIM(PayerName_Raw))                                  AS PayerName,
        LTRIM(RTRIM(ISNULL(AgingBucket, '(blank)')))                 AS AgingBucket,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(AccessionNumber)), ''))    AS VisitCount,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)  AS InsuranceBalance,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE PayerName_Raw IS NOT NULL
      AND LTRIM(RTRIM(PayerName_Raw)) <> ''
      AND ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) <> 0
      AND NOT (LTRIM(RTRIM(ClaimStatus)) = 'No Response'
               AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled')
    GROUP BY LTRIM(RTRIM(PayerName_Raw)), LTRIM(RTRIM(ISNULL(AgingBucket, '(blank)')));

    PRINT 'usp_RefreshRT_CS_InsuranceVsAging completed.';
END
GO


-- 8. Panel vs Payment
--    Exclude : ClaimStatus = 'No Response' AND BilledUnbilled = 'Unbilled'
--    Filter  : InsurancePayment > 0, CheckDate not blank
CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_CS_PanelVsPayment
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.RT_CS_PanelVsPayment;

    INSERT INTO dbo.RT_CS_PanelVsPayment
        (PanelName, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT
        LTRIM(RTRIM(Panelname))                                      AS PanelName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))            AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE Panelname IS NOT NULL AND LTRIM(RTRIM(Panelname)) <> ''
      AND ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND NOT (LTRIM(RTRIM(ClaimStatus)) = 'No Response'
               AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled')
    GROUP BY LTRIM(RTRIM(Panelname));

    PRINT 'usp_RefreshRT_CS_PanelVsPayment completed.';
END
GO


-- 9. Rep vs Payment  (Sales-rep level Year x Month)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_CS_RepVsPayment
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.RT_CS_RepVsPayment;

    INSERT INTO dbo.RT_CS_RepVsPayment
        (SalesRepName, CheckYear, CheckMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT
        LTRIM(RTRIM(SalesRepName))                                   AS SalesRepName,
        YEAR (TRY_CAST(CheckDate AS DATE))                           AS CheckYear,
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)          AS CheckMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))            AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND SalesRepName IS NOT NULL AND LTRIM(RTRIM(SalesRepName)) <> ''
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(SalesRepName)),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE));

    PRINT 'usp_RefreshRT_CS_RepVsPayment completed.';
END
GO


-- 10. Insurance vs Payment %
--     Exclude : ClaimStatus = 'No Response' AND BilledUnbilled = 'Unbilled'
--     Filter  : InsurancePayment > 0
--     Row     : PayerName_Raw
--     Column  : Count of PanelName-Group, Sum of InsurancePayment, Payment %
CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_CS_InsuranceVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(PayerName_Raw))                                AS PayerName,
            LTRIM(RTRIM(Panelname))                                    AS PanelName,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))                AS InsPay
        FROM dbo.ClaimLevelData
        WHERE PayerName_Raw IS NOT NULL
          AND LTRIM(RTRIM(PayerName_Raw)) <> ''
          AND ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND NOT (LTRIM(RTRIM(ClaimStatus)) = 'No Response'
                   AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled')
    ),
    agg AS (
        SELECT PayerName,
               COUNT(DISTINCT PanelName) AS PanelGroupCount,
               ISNULL(SUM(InsPay), 0)    AS InsurancePayment
        FROM base
        GROUP BY PayerName
    ),
    grand AS (
        SELECT NULLIF(SUM(InsurancePayment), 0) AS Total FROM agg
    )
    SELECT a.PayerName, a.PanelGroupCount, a.InsurancePayment,
           CAST(a.InsurancePayment * 100.0 / ISNULL(g.Total, 1) AS DECIMAL(9,4)) AS PaymentPct
    INTO #out
    FROM agg a CROSS JOIN grand g;

    TRUNCATE TABLE dbo.RT_CS_InsuranceVsPaymentPct;
    INSERT INTO dbo.RT_CS_InsuranceVsPaymentPct
        (PayerName, PanelGroupCount, InsurancePayment, PaymentPct, RefreshedAt)
    SELECT PayerName, PanelGroupCount, InsurancePayment, PaymentPct, GETDATE()
    FROM #out
    ORDER BY InsurancePayment DESC;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshRT_CS_InsuranceVsPaymentPct completed.';
END
GO


-- 11. CPT vs Payment %  (LineLevelData)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_CS_CptVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(CPTCode))                                      AS CPTCode,
            ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))), 0)           AS SumUnits,
            ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                            THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0) AS PaidIns,
            ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                            THEN TRY_CAST(ChargeAmount     AS DECIMAL(18,2)) ELSE 0 END), 0) AS PaidChg
        FROM dbo.LineLevelData
        WHERE CPTCode IS NOT NULL AND LTRIM(RTRIM(CPTCode)) <> ''
        GROUP BY LTRIM(RTRIM(CPTCode))
    )
    SELECT CPTCode, SumUnits, PaidIns, PaidChg,
           CASE WHEN PaidChg > 0
                THEN CAST(PaidIns * 100.0 / PaidChg AS DECIMAL(9,4))
                ELSE 0 END AS PaymentPct
    INTO #out
    FROM agg;

    TRUNCATE TABLE dbo.RT_CS_CptVsPaymentPct;
    INSERT INTO dbo.RT_CS_CptVsPaymentPct
        (CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, PaymentPct, RefreshedAt)
    SELECT CPTCode, SumUnits, PaidIns, PaidChg, PaymentPct, GETDATE()
    FROM #out
    ORDER BY SumUnits DESC;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshRT_CS_CptVsPaymentPct completed.';
END
GO


-- 12. Status Summary  (flat 4-level grain)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_CS_StatusSummary
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.RT_CS_StatusSummary;

    INSERT INTO dbo.RT_CS_StatusSummary
        (ClaimStatus, PanelName, CptCode, PayerName,
         NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance, RefreshedAt)
    SELECT
        ISNULL(LTRIM(RTRIM(ClaimStatus)),              '(blank)') AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(Panelname)),                '(blank)') AS PanelName,
        ISNULL(LTRIM(RTRIM(CPTCodeXUnitsXModifier)),   '(blank)') AS CptCode,
        ISNULL(LTRIM(RTRIM(PayerName_Raw)),            '(blank)') AS PayerName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),'')) AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0) AS InsuranceBalance,
        ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0) AS PatientBalance,
        GETDATE()
    FROM dbo.ClaimLevelData
    GROUP BY
        LTRIM(RTRIM(ClaimStatus)),
        LTRIM(RTRIM(Panelname)),
        LTRIM(RTRIM(CPTCodeXUnitsXModifier)),
        LTRIM(RTRIM(PayerName_Raw));

    PRINT 'usp_RefreshRT_CS_StatusSummary completed.';
END
GO


-- 13. Provider Summary
CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_CS_ProviderSummary
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(ReferringProvider))                              AS ReferringProvider,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))            AS NoOfClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment,
            ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)  AS InsuranceBalance,
            ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0)  AS PatientBalance
        FROM dbo.ClaimLevelData
        WHERE ReferringProvider IS NOT NULL
          AND LTRIM(RTRIM(ReferringProvider)) <> ''
        GROUP BY LTRIM(RTRIM(ReferringProvider))
    )
    SELECT
        ROW_NUMBER() OVER (ORDER BY NoOfClaims DESC) AS ProviderRank,
        ReferringProvider, NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance
    INTO #out
    FROM agg;

    TRUNCATE TABLE dbo.RT_CS_ProviderSummary;
    INSERT INTO dbo.RT_CS_ProviderSummary
        (ProviderRank, ReferringProvider, NoOfClaims,
         InsurancePayment, InsuranceBalance, PatientBalance, RefreshedAt)
    SELECT ProviderRank, ReferringProvider, NoOfClaims,
           InsurancePayment, InsuranceBalance, PatientBalance, GETDATE()
    FROM #out
    ORDER BY ProviderRank;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshRT_CS_ProviderSummary completed.';
END
GO

PRINT '13_RisingTides_CollectionSummary.sql completed.';
GO

-- =====================================================================
-- TEST / VERIFICATION  (safe to re-run; no DML, just EXEC + SELECT)
-- Uncomment or run interactively after deploying the file to validate
-- that each SP populates its target table.
-- =====================================================================

/*
EXEC dbo.usp_RefreshRT_CS_Top5ReimbursementPct;
EXEC dbo.usp_RefreshRT_CS_Top5ReimbursementPay;
EXEC dbo.usp_RefreshRT_CS_MonthlyClaimVolume;
EXEC dbo.usp_RefreshRT_CS_WeeklyClaimVolume;
EXEC dbo.usp_RefreshRT_CS_PanelAverages;
EXEC dbo.usp_RefreshRT_CS_AvgPayments;
EXEC dbo.usp_RefreshRT_CS_InsuranceVsAging;
EXEC dbo.usp_RefreshRT_CS_PanelVsPayment;
EXEC dbo.usp_RefreshRT_CS_RepVsPayment;
EXEC dbo.usp_RefreshRT_CS_InsuranceVsPaymentPct;
EXEC dbo.usp_RefreshRT_CS_CptVsPaymentPct;
EXEC dbo.usp_RefreshRT_CS_StatusSummary;
EXEC dbo.usp_RefreshRT_CS_ProviderSummary;

SELECT 'RT_CS_Top5ReimbursementPct'  AS [Table], COUNT(*) AS Rows, MAX(RefreshedAt) AS LastRun FROM dbo.RT_CS_Top5ReimbursementPct
UNION ALL SELECT 'RT_CS_Top5ReimbursementPay',   COUNT(*), MAX(RefreshedAt) FROM dbo.RT_CS_Top5ReimbursementPay
UNION ALL SELECT 'RT_CS_MonthlyClaimVolume',     COUNT(*), MAX(RefreshedAt) FROM dbo.RT_CS_MonthlyClaimVolume
UNION ALL SELECT 'RT_CS_WeeklyClaimVolume',      COUNT(*), MAX(RefreshedAt) FROM dbo.RT_CS_WeeklyClaimVolume
UNION ALL SELECT 'RT_CS_PanelAverages',          COUNT(*), MAX(RefreshedAt) FROM dbo.RT_CS_PanelAverages
UNION ALL SELECT 'RT_CS_AvgPayments',            COUNT(*), MAX(RefreshedAt) FROM dbo.RT_CS_AvgPayments
UNION ALL SELECT 'RT_CS_InsuranceVsAging',       COUNT(*), MAX(RefreshedAt) FROM dbo.RT_CS_InsuranceVsAging
UNION ALL SELECT 'RT_CS_PanelVsPayment',         COUNT(*), MAX(RefreshedAt) FROM dbo.RT_CS_PanelVsPayment
UNION ALL SELECT 'RT_CS_RepVsPayment',           COUNT(*), MAX(RefreshedAt) FROM dbo.RT_CS_RepVsPayment
UNION ALL SELECT 'RT_CS_InsuranceVsPaymentPct',  COUNT(*), MAX(RefreshedAt) FROM dbo.RT_CS_InsuranceVsPaymentPct
UNION ALL SELECT 'RT_CS_CptVsPaymentPct',        COUNT(*), MAX(RefreshedAt) FROM dbo.RT_CS_CptVsPaymentPct
UNION ALL SELECT 'RT_CS_StatusSummary',          COUNT(*), MAX(RefreshedAt) FROM dbo.RT_CS_StatusSummary
UNION ALL SELECT 'RT_CS_ProviderSummary',        COUNT(*), MAX(RefreshedAt) FROM dbo.RT_CS_ProviderSummary
ORDER BY [Table];

-- Spot-check the largest tables
SELECT TOP 20 * FROM dbo.RT_CS_PanelAverages          ORDER BY PanelName, PayerName;
SELECT TOP 20 * FROM dbo.RT_CS_MonthlyClaimVolume     ORDER BY PanelName, PayerRank, BillYear, BillMonth;
SELECT TOP 20 * FROM dbo.RT_CS_WeeklyClaimVolume      ORDER BY PanelName, PayerRank, WeekKey;
SELECT *      FROM dbo.RT_CS_Top5ReimbursementPct     ORDER BY PayerRank;
SELECT *      FROM dbo.RT_CS_Top5ReimbursementPay     ORDER BY PayerRank;
*/
