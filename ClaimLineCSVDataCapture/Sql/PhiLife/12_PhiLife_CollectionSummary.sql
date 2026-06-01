-- =====================================================================
-- PhiLife — Collection Summary Aggregates
-- Pre-computes the data behind the 13 Collection Summary tabs in the
-- LabMetricsDashboard web app.
-- All SPs are idempotent (TRUNCATE + INSERT) and safe to re-run.
--
-- Per-lab settings:
--   Panel column        = Panelname
--   Has BilledUnbilled  = True  (LineLevelData)
--   Has AgingBucket     = True  (LineLevelData)
--   Has PaymentPercent  = True  (LineLevelData)
--
-- Source routing (PhiLife inverted structure):
--   ClaimLevelData : individual CPT (CPTCode/Units/Modifier), CheckDate,
--                    InsurancePayment, ChargeAmount, ReferringProvider,
--                    SalesRepname, InsuranceBalance, PatientBalance
--   LineLevelData  : aggregate CPT (CPTCodeXUnitsXModifier), AgingBucket,
--                    BilledUnbilled, PaymentPercent, FullyPaidCount/Amount,
--                    AdjudicatedCount/Amount, Days30/60 Count/Amount,
--                    InsurancePayment (aggregate), InsuranceBalance, PatientBalance
-- =====================================================================

SET NOCOUNT ON;
GO

-- ─────────────────────────────────────────────────────────────────────
-- TABLE DEFINITIONS
-- ─────────────────────────────────────────────────────────────────────

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_CS_Top5ReimbursementPct')
CREATE TABLE dbo.Phi_CS_Top5ReimbursementPct
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

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_CS_Top5ReimbursementPay')
CREATE TABLE dbo.Phi_CS_Top5ReimbursementPay
(
    SummaryId         INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerRank         TINYINT         NOT NULL,
    PayerName         NVARCHAR(500)   NOT NULL,
    TotalPayments     DECIMAL(18,2)   NOT NULL DEFAULT 0,
    UniqueVisitCount  INT             NOT NULL DEFAULT 0,
    RefreshedAt       DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_CS_MonthlyClaimVolume')
CREATE TABLE dbo.Phi_CS_MonthlyClaimVolume
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

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_CS_WeeklyClaimVolume')
CREATE TABLE dbo.Phi_CS_WeeklyClaimVolume
(
    SummaryId         INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName         NVARCHAR(500)   NOT NULL,
    PayerName         NVARCHAR(500)   NOT NULL,
    PayerRank         TINYINT         NOT NULL,
    WeekKey           TINYINT         NOT NULL,
    WeekStart         DATE            NOT NULL,
    WeekEnd           DATE            NOT NULL,
    NoOfClaims        INT             NOT NULL DEFAULT 0,
    InsurancePayment  DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt       DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

DROP TABLE IF EXISTS dbo.Phi_CS_PanelAverages;
GO
CREATE TABLE dbo.Phi_CS_PanelAverages
(
    SummaryId           INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName           NVARCHAR(500)   NOT NULL,
    PayerName           NVARCHAR(500)   NOT NULL,
    NoOfClaims          INT             NOT NULL DEFAULT 0,
    TotalCharges        DECIMAL(18,2)   NOT NULL DEFAULT 0,
    CarrierPayment      DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgCarrierPayment   DECIMAL(18,2)   NOT NULL DEFAULT 0,
    FullyPaidCount      INT             NOT NULL DEFAULT 0,
    FullyPaidAmount     DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgFullyPaid        DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AdjudicatedCount    INT             NOT NULL DEFAULT 0,
    AdjudicatedAmount   DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgAdjudicated      DECIMAL(18,2)   NOT NULL DEFAULT 0,
    Days30Count         INT             NOT NULL DEFAULT 0,
    Days30Amount        DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgDays30           DECIMAL(18,2)   NOT NULL DEFAULT 0,
    Days60Count         INT             NOT NULL DEFAULT 0,
    Days60Amount        DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgDays60           DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt         DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_CS_AvgPayments')
CREATE TABLE dbo.Phi_CS_AvgPayments
(
    SummaryId             INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName             NVARCHAR(500)   NOT NULL,
    PayerName             NVARCHAR(500)   NOT NULL,
    PayerRank             TINYINT         NOT NULL,
    ClaimCount            INT             NOT NULL DEFAULT 0,
    TotalCharges          DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgCharges            DECIMAL(18,2)   NOT NULL DEFAULT 0,
    InsurancePayment      DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgInsurancePayment   DECIMAL(18,2)   NOT NULL DEFAULT 0,
    FullyPaidCount        INT             NOT NULL DEFAULT 0,
    FullyPaidAmount       DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgFullyPaid          DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AdjudicatedCount      INT             NOT NULL DEFAULT 0,
    AdjudicatedAmount     DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgAdjudicated        DECIMAL(18,2)   NOT NULL DEFAULT 0,
    Over30Count           INT             NOT NULL DEFAULT 0,
    Over30Amount          DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgOver30             DECIMAL(18,2)   NOT NULL DEFAULT 0,
    Over60Count           INT             NOT NULL DEFAULT 0,
    Over60Amount          DECIMAL(18,2)   NOT NULL DEFAULT 0,
    AvgOver60             DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt           DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_CS_InsuranceVsAging')
CREATE TABLE dbo.Phi_CS_InsuranceVsAging
(
    SummaryId        INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName        NVARCHAR(500)   NOT NULL,
    AgingBucket      NVARCHAR(200)   NOT NULL,
    VisitCount       INT             NOT NULL DEFAULT 0,
    InsuranceBalance DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

DROP TABLE IF EXISTS dbo.Phi_CS_PanelVsPayment;
GO
CREATE TABLE dbo.Phi_CS_PanelVsPayment
(
    SummaryId        INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName        NVARCHAR(500)   NOT NULL,
    BilledYear       INT             NOT NULL,
    BilledMonth      TINYINT         NOT NULL,
    NoOfClaims       INT             NOT NULL DEFAULT 0,
    InsurancePayment DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_CS_RepVsPayment')
CREATE TABLE dbo.Phi_CS_RepVsPayment
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

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_CS_InsuranceVsPaymentPct')
CREATE TABLE dbo.Phi_CS_InsuranceVsPaymentPct
(
    SummaryId        INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName        NVARCHAR(500)   NOT NULL,
    PanelGroupCount  INT             NOT NULL DEFAULT 0,
    InsurancePayment DECIMAL(18,2)   NOT NULL DEFAULT 0,
    PaymentPct       DECIMAL(9,4)    NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_CS_CptVsPaymentPct')
CREATE TABLE dbo.Phi_CS_CptVsPaymentPct
(
    SummaryId            INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    CPTCode              NVARCHAR(50)    NOT NULL,
    SumUnits             DECIMAL(18,2)   NOT NULL DEFAULT 0,
    PaidInsurancePayment DECIMAL(18,2)   NOT NULL DEFAULT 0,
    PaidChargeAmount     DECIMAL(18,2)   NOT NULL DEFAULT 0,
    PaymentPct           DECIMAL(9,4)    NOT NULL DEFAULT 0,
    RefreshedAt          DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

DROP TABLE IF EXISTS dbo.Phi_CS_StatusSummary;
GO
CREATE TABLE dbo.Phi_CS_StatusSummary
(
    SummaryId        INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    ClaimStatus      NVARCHAR(200)   NOT NULL,
    PanelName        NVARCHAR(500)   NOT NULL,
    CptCode          NVARCHAR(MAX)   NOT NULL,
    PayerName        NVARCHAR(500)   NOT NULL,
    NoOfClaims       INT             NOT NULL DEFAULT 0,
    InsurancePayment DECIMAL(18,2)   NOT NULL DEFAULT 0,
    InsuranceBalance DECIMAL(18,2)   NOT NULL DEFAULT 0,
    PatientBalance   DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_CS_ProviderSummary')
CREATE TABLE dbo.Phi_CS_ProviderSummary
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
--    Source: LineLevelData (has PaymentPercent, BilledUnbilled, InsurancePayment)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_CS_Top5ReimbursementPct
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(PayerName_Raw))                                  AS PayerName,
            ISNULL(SUM(TRY_CAST(PaymentPercent    AS DECIMAL(18,2))), 0) AS SumIns,
            ISNULL(SUM(TRY_CAST(ChargeAmount      AS DECIMAL(18,2))), 0) AS SumChg,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(AccessionNumber)), ''))    AS Visits
        FROM dbo.LineLevelData
        WHERE NOT (LTRIM(RTRIM(ClaimStatus)) = 'No Response' AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled')
          AND ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
        GROUP BY LTRIM(RTRIM(PayerName_Raw))
    ),
    ranked AS (
        SELECT TOP 5 PayerName, SumIns, SumChg, Visits,
               ROW_NUMBER() OVER (ORDER BY SumIns DESC) AS Rnk
        FROM agg
        ORDER BY SumIns DESC
    )
    SELECT * INTO #out FROM ranked;

    TRUNCATE TABLE dbo.Phi_CS_Top5ReimbursementPct;
    INSERT INTO dbo.Phi_CS_Top5ReimbursementPct
        (PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount, RefreshedAt)
    SELECT CAST(Rnk AS TINYINT), PayerName, SumIns, SumChg, Visits, GETDATE()
    FROM #out ORDER BY Rnk;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshPhi_CS_Top5ReimbursementPct completed.';
END
GO


-- 2. Top 5 Insurances | Reimbursement Payments
--    Source: LineLevelData
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_CS_Top5ReimbursementPay
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(PayerName_Raw))                                   AS PayerName,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS TotalPay,
            COUNT(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''))              AS Visits
        FROM dbo.LineLevelData
        WHERE NOT (LTRIM(RTRIM(ClaimStatus)) = 'No Response' AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled')
          AND ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
        GROUP BY LTRIM(RTRIM(PayerName_Raw))
    ),
    ranked AS (
        SELECT TOP 5 PayerName, TotalPay, Visits,
               ROW_NUMBER() OVER (ORDER BY TotalPay DESC) AS Rnk
        FROM agg
        ORDER BY TotalPay DESC
    )
    SELECT * INTO #out FROM ranked;

    TRUNCATE TABLE dbo.Phi_CS_Top5ReimbursementPay;
    INSERT INTO dbo.Phi_CS_Top5ReimbursementPay
        (PayerRank, PayerName, TotalPayments, UniqueVisitCount, RefreshedAt)
    SELECT CAST(Rnk AS TINYINT), PayerName, TotalPay, Visits, GETDATE()
    FROM #out ORDER BY Rnk;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshPhi_CS_Top5ReimbursementPay completed.';
END
GO


-- 3. Monthly Claim Volume (ClaimLevelData, PaymentPostedDate, all payers per panel)
--    Source: ClaimLevelData (has PaymentPostedDate, InsurancePayment)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_CS_MonthlyClaimVolume
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))                 AS PanelName,
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                 AS PayerName,
        YEAR (TRY_CAST(PaymentPostedDate AS DATE))                     AS BillYear,
        MONTH(TRY_CAST(PaymentPostedDate AS DATE))                     AS BillMonth,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                       AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)    AS InsurancePayment
    INTO #raw
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST(PaymentPostedDate AS DATE) IS NOT NULL
      AND YEAR(TRY_CAST(PaymentPostedDate AS DATE)) > 1900
      AND LTRIM(RTRIM(PaymentPostedDate)) <> ''
    GROUP BY
        LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))),
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        YEAR (TRY_CAST(PaymentPostedDate AS DATE)),
        MONTH(TRY_CAST(PaymentPostedDate AS DATE));

    SELECT
        PanelName, PayerName,
        DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
    INTO #ranks
    FROM #raw
    GROUP BY PanelName, PayerName;

    TRUNCATE TABLE dbo.Phi_CS_MonthlyClaimVolume;
    INSERT INTO dbo.Phi_CS_MonthlyClaimVolume
        (PanelName, PayerName, PayerRank, BillYear, BillMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT r.PanelName, r.PayerName, CAST(k.PayerRank AS TINYINT),
           r.BillYear, CAST(r.BillMonth AS TINYINT), r.NoOfClaims, r.InsurancePayment, GETDATE()
    FROM #raw r
    JOIN #ranks k ON k.PanelName = r.PanelName AND k.PayerName = r.PayerName
    ORDER BY r.PanelName, k.PayerRank, r.BillYear, r.BillMonth;

    DROP TABLE IF EXISTS #raw;
    DROP TABLE IF EXISTS #ranks;
    PRINT 'usp_RefreshPhi_CS_MonthlyClaimVolume completed.';
END
GO


-- 4. Weekly Claim Volume (ClaimLevelData, PaymentPostedDate, Thu-Wed, last 4 complete weeks)
--    Source: ClaimLevelData (has PaymentPostedDate, InsurancePayment)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_CS_WeeklyClaimVolume
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @MaxPostedDate DATE;
    DECLARE @WeekContainingMaxStart DATE;
    DECLARE @WeekContainingMaxEnd   DATE;
    DECLARE @LatestCompletedWeekStart DATE;
    DECLARE @LatestCompletedWeekEnd   DATE;

    SELECT @MaxPostedDate = MAX(TRY_CAST(PaymentPostedDate AS DATE))
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(PaymentPostedDate AS DATE) IS NOT NULL
      AND TRY_CAST(PaymentPostedDate AS DATE) <= @Today
      AND LTRIM(RTRIM(PaymentPostedDate)) <> '';

    IF @MaxPostedDate IS NULL
    BEGIN
        RAISERROR('No valid PaymentPostedDate <= today found in ClaimLevelData.', 16, 1);
        RETURN;
    END;

    -- Thu-Wed week; 1900-01-04 is Thursday
    SET @WeekContainingMaxStart =
        DATEADD(DAY, -(DATEDIFF(DAY, '19000104', @MaxPostedDate) % 7), @MaxPostedDate);
    SET @WeekContainingMaxEnd = DATEADD(DAY, 6, @WeekContainingMaxStart);

    IF @WeekContainingMaxEnd <= @Today
    BEGIN
        SET @LatestCompletedWeekStart = @WeekContainingMaxStart;
        SET @LatestCompletedWeekEnd   = @WeekContainingMaxEnd;
    END
    ELSE
    BEGIN
        SET @LatestCompletedWeekStart = DATEADD(DAY, -7, @WeekContainingMaxStart);
        SET @LatestCompletedWeekEnd   = DATEADD(DAY,  6, @LatestCompletedWeekStart);
    END;

    DECLARE @W4Start DATE = @LatestCompletedWeekStart;
    DECLARE @W4End   DATE = @LatestCompletedWeekEnd;
    DECLARE @W3Start DATE = DATEADD(DAY, -7, @W4Start);  DECLARE @W3End DATE = DATEADD(DAY, 6, @W3Start);
    DECLARE @W2Start DATE = DATEADD(DAY, -7, @W3Start);  DECLARE @W2End DATE = DATEADD(DAY, 6, @W2Start);
    DECLARE @W1Start DATE = DATEADD(DAY, -7, @W2Start);  DECLARE @W1End DATE = DATEADD(DAY, 6, @W1Start);

    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            CASE
                WHEN TRY_CAST(PaymentPostedDate AS DATE) BETWEEN @W1Start AND @W1End THEN 1
                WHEN TRY_CAST(PaymentPostedDate AS DATE) BETWEEN @W2Start AND @W2End THEN 2
                WHEN TRY_CAST(PaymentPostedDate AS DATE) BETWEEN @W3Start AND @W3End THEN 3
                WHEN TRY_CAST(PaymentPostedDate AS DATE) BETWEEN @W4Start AND @W4End THEN 4
            END AS WeekKey,
            ClaimID,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2)) AS InsPay
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(PaymentPostedDate AS DATE) IS NOT NULL
          AND LTRIM(RTRIM(PaymentPostedDate)) <> ''
          AND TRY_CAST(PaymentPostedDate AS DATE) BETWEEN @W1Start AND @W4End
    ),
    agg AS (
        SELECT PanelName, PayerName, WeekKey,
               COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))  AS NoOfClaims,
               ISNULL(SUM(InsPay), 0)                    AS InsurancePayment
        FROM src WHERE WeekKey IS NOT NULL
        GROUP BY PanelName, PayerName, WeekKey
    ),
    ranks AS (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
        FROM agg GROUP BY PanelName, PayerName
    )
    SELECT
        a.PanelName, a.PayerName, CAST(r.PayerRank AS TINYINT) AS PayerRank,
        CAST(a.WeekKey AS TINYINT) AS WeekKey,
        CASE a.WeekKey WHEN 1 THEN @W1Start WHEN 2 THEN @W2Start WHEN 3 THEN @W3Start WHEN 4 THEN @W4Start END AS WeekStart,
        CASE a.WeekKey WHEN 1 THEN @W1End   WHEN 2 THEN @W2End   WHEN 3 THEN @W3End   WHEN 4 THEN @W4End   END AS WeekEnd,
        a.NoOfClaims, a.InsurancePayment
    INTO #out
    FROM agg a
    JOIN ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName;

    TRUNCATE TABLE dbo.Phi_CS_WeeklyClaimVolume;
    INSERT INTO dbo.Phi_CS_WeeklyClaimVolume
        (PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment, GETDATE()
    FROM #out
    ORDER BY PanelName, PayerRank, WeekKey;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshPhi_CS_WeeklyClaimVolume completed.';
END
GO


-- 5. Panel Averages
--    Source: LineLevelData (has BilledUnbilled, AgingBucket, FullyPaidCount/Amount,
--            AdjudicatedCount/Amount, Days30/60 Count/Amount, CheckDate)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_CS_PanelAverages
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))  AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))  AS PayerName,
            COALESCE(
                NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
                LTRIM(RTRIM(ClaimID))
            )                                               AS VisitKey,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))     AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))     AS InsPay,
            LTRIM(RTRIM(ClaimStatus))                       AS ClaimStatus,
            LTRIM(RTRIM(ISNULL(FullyPaidCount, '')))        AS FPC,
            TRY_CAST(FullyPaidAmount  AS DECIMAL(18,2))     AS FullyPaidAmount,
            LTRIM(RTRIM(ISNULL(AdjudicatedCount, '')))      AS AdjC,
            TRY_CAST(AdjudicatedAmount AS DECIMAL(18,2))    AS AdjAmount,
            LTRIM(RTRIM(ISNULL(AgingBucket, '')))           AS AgingBucket
        FROM dbo.LineLevelData
        WHERE NOT (
            LTRIM(RTRIM(ClaimStatus)) = 'No Response'
            AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled'
        )
        AND Panelname <> '' AND LEN(Panelname) > 0
        AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
        AND TRY_CAST(CheckDate AS DATE) <= CAST(GETDATE() AS DATE)
        AND TRY_CAST(CheckDate AS DATE) >=
            DATEADD(DAY, 1, EOMONTH((
                SELECT MAX(TRY_CAST(CheckDate AS DATE))
                FROM dbo.LineLevelData
                WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL
                  AND TRY_CAST(CheckDate AS DATE) <= CAST(GETDATE() AS DATE)
            ), -6))
    )
    SELECT
        PanelName, PayerName,
        COUNT(VisitKey)                                          AS ClaimCount,
        ISNULL(SUM(Chg),   0)                                   AS TotalCharges,
        ISNULL(SUM(InsPay), 0)                                  AS CarrierPayment,
        COUNT(DISTINCT CASE WHEN FPC = 'Fully Paid'     THEN VisitKey END) AS FullyPaidCount,
        ISNULL(SUM(CASE WHEN FPC = 'Fully Paid'         THEN FullyPaidAmount ELSE 0 END), 0) AS FullyPaidAmount,
        COUNT(DISTINCT CASE WHEN AdjC = 'Adjucticated'  THEN VisitKey END) AS AdjudicatedCount,
        ISNULL(SUM(CASE WHEN AdjC = 'Adjucticated'      THEN AdjAmount ELSE 0 END), 0) AS AdjudicatedAmount,
        COUNT(DISTINCT CASE WHEN AgingBucket = '30+'    THEN VisitKey END) AS Days30Count,
        ISNULL(SUM(CASE WHEN AgingBucket = '30+'        THEN Chg ELSE 0 END), 0) AS Days30Amount,
        COUNT(DISTINCT CASE WHEN AgingBucket = '60+'    THEN VisitKey END) AS Days60Count,
        ISNULL(SUM(CASE WHEN AgingBucket = '60+'        THEN Chg ELSE 0 END), 0) AS Days60Amount
    INTO #out
    FROM src
    GROUP BY PanelName, PayerName;

    TRUNCATE TABLE dbo.Phi_CS_PanelAverages;
    INSERT INTO dbo.Phi_CS_PanelAverages
    (
        PanelName, PayerName,
        NoOfClaims, TotalCharges, CarrierPayment, AvgCarrierPayment,
        FullyPaidCount, FullyPaidAmount, AvgFullyPaid,
        AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,
        Days30Count, Days30Amount, AvgDays30,
        Days60Count, Days60Amount, AvgDays60,
        RefreshedAt
    )
    SELECT
        PanelName, PayerName,
        ClaimCount, TotalCharges, CarrierPayment,
        CASE WHEN ClaimCount    > 0 THEN CarrierPayment    / ClaimCount    ELSE 0 END,
        FullyPaidCount, FullyPaidAmount,
        CASE WHEN FullyPaidCount  > 0 THEN FullyPaidAmount  / FullyPaidCount  ELSE 0 END,
        AdjudicatedCount, AdjudicatedAmount,
        CASE WHEN AdjudicatedCount > 0 THEN AdjudicatedAmount / AdjudicatedCount ELSE 0 END,
        Days30Count, Days30Amount,
        CASE WHEN Days30Count   > 0 THEN Days30Amount   / Days30Count   ELSE 0 END,
        Days60Count, Days60Amount,
        CASE WHEN Days60Count   > 0 THEN Days60Amount   / Days60Count   ELSE 0 END,
        GETDATE()
    FROM #out
    ORDER BY PanelName, PayerName;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshPhi_CS_PanelAverages completed.';
END
GO


-- 6. Avg Payments (ClaimLevelData, CheckDate last 6 months)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_CS_AvgPayments
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Cutoff DATE = DATEADD(MONTH, -6, CAST(GETDATE() AS DATE));

    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))  AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))  AS PayerName,
            ClaimID,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))     AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))     AS InsPay,
            LTRIM(RTRIM(ClaimStatus))                       AS Status,
            ISNULL(TRY_CAST(DaystoDOS AS INT), 9999)        AS Days
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND TRY_CAST(CheckDate AS DATE) >= @Cutoff
          AND Panelname IS NOT NULL AND LTRIM(RTRIM(Panelname)) <> ''
          AND PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''
    ),
    agg AS (
        SELECT PanelName, PayerName,
               COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS ClaimCount,
               ISNULL(SUM(Chg),    0)  AS TotalCharges,
               ISNULL(SUM(InsPay), 0)  AS InsurancePayment,
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
               COUNT(DISTINCT CASE WHEN Days <= 30 THEN ClaimID END) AS Over30Count,
               ISNULL(SUM(CASE WHEN Days <= 30 THEN InsPay ELSE 0 END), 0) AS Over30Amount,
               COUNT(DISTINCT CASE WHEN Days <= 60 THEN ClaimID END) AS Over60Count,
               ISNULL(SUM(CASE WHEN Days <= 60 THEN InsPay ELSE 0 END), 0) AS Over60Amount
        FROM base GROUP BY PanelName, PayerName
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

    TRUNCATE TABLE dbo.Phi_CS_AvgPayments;
    INSERT INTO dbo.Phi_CS_AvgPayments
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
    FROM #out ORDER BY PanelName, PayerRank;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshPhi_CS_AvgPayments completed.';
END
GO


-- 7. Insurance vs Aging
--    Source: LineLevelData (has AgingBucket, InsuranceBalance, BilledUnbilled)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_CS_InsuranceVsAging
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Phi_CS_InsuranceVsAging;

    INSERT INTO dbo.Phi_CS_InsuranceVsAging
        (PayerName, AgingBucket, VisitCount, InsuranceBalance, RefreshedAt)
    SELECT
        LTRIM(RTRIM(PayerName_Raw))                                  AS PayerName,
        LTRIM(RTRIM(ISNULL(AgingBucket, '(blank)')))                 AS AgingBucket,
        COUNT(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''))             AS VisitCount,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)  AS InsuranceBalance,
        GETDATE()
    FROM dbo.LineLevelData
    WHERE ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) <> 0
      AND NOT (LTRIM(RTRIM(ClaimStatus)) = 'No Response' AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled')
    GROUP BY LTRIM(RTRIM(PayerName_Raw)), LTRIM(RTRIM(ISNULL(AgingBucket, '(blank)')));

    PRINT 'usp_RefreshPhi_CS_InsuranceVsAging completed.';
END
GO


-- 8. Panel vs Payment (ClaimLevelData, CheckDate)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_CS_PanelVsPayment
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Phi_CS_PanelVsPayment;

    INSERT INTO dbo.Phi_CS_PanelVsPayment
        (PanelName, BilledYear, BilledMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT
        LTRIM(RTRIM(Panelname))                                         AS PanelName,
        YEAR (TRY_CAST(CheckDate AS DATE))                             AS BilledYear,
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)            AS BilledMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))              AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)    AS InsurancePayment,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE Panelname IS NOT NULL AND LTRIM(RTRIM(Panelname)) <> ''
      AND ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(Panelname)),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE));

    PRINT 'usp_RefreshPhi_CS_PanelVsPayment completed.';
END
GO


-- 9. Rep vs Payment (ClaimLevelData, CheckDate)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_CS_RepVsPayment
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Phi_CS_RepVsPayment;

    INSERT INTO dbo.Phi_CS_RepVsPayment
        (SalesRepName, CheckYear, CheckMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT
        LTRIM(RTRIM(SalesRepname))                                   AS SalesRepName,
        YEAR (TRY_CAST(CheckDate AS DATE))                           AS CheckYear,
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)          AS CheckMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))            AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND SalesRepname IS NOT NULL AND LTRIM(RTRIM(SalesRepname)) <> ''
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(SalesRepname)),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE));

    PRINT 'usp_RefreshPhi_CS_RepVsPayment completed.';
END
GO


-- 10. Insurance vs Payment %
--     Source: LineLevelData (has PaymentPercent, InsurancePayment)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_CS_InsuranceVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(PayerName_Raw))                          AS PayerName,
            LTRIM(RTRIM(Panelname))                              AS PanelName,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))          AS InsPay,
            TRY_CAST(PaymentPercent   AS DECIMAL(9,4))           AS PayPct
        FROM dbo.LineLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) <> 0
    ),
    agg AS (
        SELECT PayerName,
               COUNT(PanelName)                       AS PanelGroupCount,
               ISNULL(SUM(InsPay), 0)                 AS InsurancePayment,
               ROUND(ISNULL(AVG(PayPct), 0) * 100, 0) AS PaymentPct
        FROM base GROUP BY PayerName
    )
    SELECT PayerName, PanelGroupCount, InsurancePayment, PaymentPct
    INTO #out FROM agg;

    TRUNCATE TABLE dbo.Phi_CS_InsuranceVsPaymentPct;
    INSERT INTO dbo.Phi_CS_InsuranceVsPaymentPct
        (PayerName, PanelGroupCount, InsurancePayment, PaymentPct, RefreshedAt)
    SELECT PayerName, PanelGroupCount, InsurancePayment, PaymentPct, GETDATE()
    FROM #out ORDER BY InsurancePayment DESC;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshPhi_CS_InsuranceVsPaymentPct completed.';
END
GO


-- 11. CPT vs Payment %
--     Source: ClaimLevelData (has individual CPTCode, Units, InsurancePayment, ClaimStatus)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_CS_CptVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(CPTCode))                                       AS CPTCode,
            ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))), 0)            AS SumUnits,
            ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                            THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0) AS PaidIns,
            ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                            THEN TRY_CAST(ChargeAmount     AS DECIMAL(18,2)) ELSE 0 END), 0) AS PaidChg
        FROM dbo.ClaimLevelData
        WHERE CPTCode IS NOT NULL AND LTRIM(RTRIM(CPTCode)) <> ''
        GROUP BY LTRIM(RTRIM(CPTCode))
    )
    SELECT CPTCode, SumUnits, PaidIns, PaidChg,
           CASE WHEN PaidChg > 0
                THEN CAST(PaidIns * 100.0 / PaidChg AS DECIMAL(9,4))
                ELSE 0 END AS PaymentPct
    INTO #out FROM agg;

    TRUNCATE TABLE dbo.Phi_CS_CptVsPaymentPct;
    INSERT INTO dbo.Phi_CS_CptVsPaymentPct
        (CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, PaymentPct, RefreshedAt)
    SELECT CPTCode, SumUnits, PaidIns, PaidChg, PaymentPct, GETDATE()
    FROM #out ORDER BY SumUnits DESC;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshPhi_CS_CptVsPaymentPct completed.';
END
GO


-- 12. Status Summary
--     Source: LineLevelData (has CPTCodeXUnitsXModifier, BilledUnbilled, ClaimStatus,
--             InsurancePayment, InsuranceBalance, PatientBalance)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_CS_StatusSummary
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Phi_CS_StatusSummary;

    INSERT INTO dbo.Phi_CS_StatusSummary
        (ClaimStatus, PanelName, CptCode, PayerName,
         NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance, RefreshedAt)
    SELECT
        ISNULL(LTRIM(RTRIM(ClaimStatus)),             '(blank)') AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(Panelname)),               '(blank)') AS PanelName,
        ISNULL(LTRIM(RTRIM(CPTCodeXUnitsXModifier)),  '(blank)') AS CptCode,
        ISNULL(LTRIM(RTRIM(PayerName_Raw)),           '(blank)') AS PayerName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))        AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0) AS InsuranceBalance,
        ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0) AS PatientBalance,
        GETDATE()
    FROM dbo.LineLevelData
    GROUP BY
        LTRIM(RTRIM(ClaimStatus)),
        LTRIM(RTRIM(Panelname)),
        LTRIM(RTRIM(CPTCodeXUnitsXModifier)),
        LTRIM(RTRIM(PayerName_Raw));

    PRINT 'usp_RefreshPhi_CS_StatusSummary completed.';
END
GO


-- 13. Provider Summary (ClaimLevelData)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_CS_ProviderSummary
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
    INTO #out FROM agg;

    TRUNCATE TABLE dbo.Phi_CS_ProviderSummary;
    INSERT INTO dbo.Phi_CS_ProviderSummary
        (ProviderRank, ReferringProvider, NoOfClaims,
         InsurancePayment, InsuranceBalance, PatientBalance, RefreshedAt)
    SELECT ProviderRank, ReferringProvider, NoOfClaims,
           InsurancePayment, InsuranceBalance, PatientBalance, GETDATE()
    FROM #out ORDER BY ProviderRank;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshPhi_CS_ProviderSummary completed.';
END
GO

PRINT '12_PhiLife_CollectionSummary.sql completed.';
GO

/*
-- =====================================================================
-- VERIFICATION (uncomment and run interactively after deployment)
-- =====================================================================
EXEC dbo.usp_RefreshPhi_CS_Top5ReimbursementPct;
EXEC dbo.usp_RefreshPhi_CS_Top5ReimbursementPay;
EXEC dbo.usp_RefreshPhi_CS_MonthlyClaimVolume;
EXEC dbo.usp_RefreshPhi_CS_WeeklyClaimVolume;
EXEC dbo.usp_RefreshPhi_CS_PanelAverages;
EXEC dbo.usp_RefreshPhi_CS_AvgPayments;
EXEC dbo.usp_RefreshPhi_CS_InsuranceVsAging;
EXEC dbo.usp_RefreshPhi_CS_PanelVsPayment;
EXEC dbo.usp_RefreshPhi_CS_RepVsPayment;
EXEC dbo.usp_RefreshPhi_CS_InsuranceVsPaymentPct;
EXEC dbo.usp_RefreshPhi_CS_CptVsPaymentPct;
EXEC dbo.usp_RefreshPhi_CS_StatusSummary;
EXEC dbo.usp_RefreshPhi_CS_ProviderSummary;

SELECT 'Phi_CS_Top5ReimbursementPct'  AS [Table], COUNT(*) AS Rows, MAX(RefreshedAt) AS LastRun FROM dbo.Phi_CS_Top5ReimbursementPct
UNION ALL SELECT 'Phi_CS_Top5ReimbursementPay',   COUNT(*), MAX(RefreshedAt) FROM dbo.Phi_CS_Top5ReimbursementPay
UNION ALL SELECT 'Phi_CS_MonthlyClaimVolume',     COUNT(*), MAX(RefreshedAt) FROM dbo.Phi_CS_MonthlyClaimVolume
UNION ALL SELECT 'Phi_CS_WeeklyClaimVolume',      COUNT(*), MAX(RefreshedAt) FROM dbo.Phi_CS_WeeklyClaimVolume
UNION ALL SELECT 'Phi_CS_PanelAverages',          COUNT(*), MAX(RefreshedAt) FROM dbo.Phi_CS_PanelAverages
UNION ALL SELECT 'Phi_CS_AvgPayments',            COUNT(*), MAX(RefreshedAt) FROM dbo.Phi_CS_AvgPayments
UNION ALL SELECT 'Phi_CS_InsuranceVsAging',       COUNT(*), MAX(RefreshedAt) FROM dbo.Phi_CS_InsuranceVsAging
UNION ALL SELECT 'Phi_CS_PanelVsPayment',         COUNT(*), MAX(RefreshedAt) FROM dbo.Phi_CS_PanelVsPayment
UNION ALL SELECT 'Phi_CS_RepVsPayment',           COUNT(*), MAX(RefreshedAt) FROM dbo.Phi_CS_RepVsPayment
UNION ALL SELECT 'Phi_CS_InsuranceVsPaymentPct',  COUNT(*), MAX(RefreshedAt) FROM dbo.Phi_CS_InsuranceVsPaymentPct
UNION ALL SELECT 'Phi_CS_CptVsPaymentPct',        COUNT(*), MAX(RefreshedAt) FROM dbo.Phi_CS_CptVsPaymentPct
UNION ALL SELECT 'Phi_CS_StatusSummary',          COUNT(*), MAX(RefreshedAt) FROM dbo.Phi_CS_StatusSummary
UNION ALL SELECT 'Phi_CS_ProviderSummary',        COUNT(*), MAX(RefreshedAt) FROM dbo.Phi_CS_ProviderSummary
ORDER BY [Table];
*/
