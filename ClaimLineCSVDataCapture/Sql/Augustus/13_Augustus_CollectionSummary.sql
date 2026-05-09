-- =============================================================
-- Augustus Labs -- Collection Summary Aggregates
--
-- Column mapping (confirmed from Augustus TVP):
--   Panel row grouping   = PanelNew
--   Date column          = CheckDate  (ClaimLevelData; NOT LineLevelData)
--   Weekly week range    = Wed-Tue  (not Fri-Thu)
--   Pre-computed cols    = Adjudicated/'Adjudicated', AdjudicatedAmount,
--                          Bucket30/'30 Bucket', Bucket30Amount,
--                          Bucket60/'60 Bucket', Bucket60Amount,
--                          FullyPaidCount, FullyPaidAmount
--   No BilledUnbilled / AgingBucket -- aging derived from DaystoDOS.
-- =============================================================

SET NOCOUNT ON;

-- ----------------------------------------------------------------
-- TABLES  (all 13 in ONE batch -- IF OBJECT_ID pattern, no GO needed)
-- ----------------------------------------------------------------

IF OBJECT_ID('dbo.Aug_CS_Top5ReimbursementPct','U') IS NOT NULL DROP TABLE dbo.Aug_CS_Top5ReimbursementPct;
CREATE TABLE dbo.Aug_CS_Top5ReimbursementPct (
    SummaryId           INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerRank           TINYINT       NOT NULL,
    PayerName           NVARCHAR(500) NOT NULL,
    SumInsurancePayment DECIMAL(18,2) NOT NULL DEFAULT 0,
    SumChargeAmount     DECIMAL(18,2) NOT NULL DEFAULT 0,
    UniqueVisitCount    INT           NOT NULL DEFAULT 0,
    PaymentPct          DECIMAL(9,4)  NOT NULL DEFAULT 0,
    RefreshedAt         DATETIME      NOT NULL DEFAULT GETDATE()
);

IF OBJECT_ID('dbo.Aug_CS_Top5ReimbursementPay','U') IS NOT NULL DROP TABLE dbo.Aug_CS_Top5ReimbursementPay;
CREATE TABLE dbo.Aug_CS_Top5ReimbursementPay (
    SummaryId        INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerRank        TINYINT       NOT NULL,
    PayerName        NVARCHAR(500) NOT NULL,
    TotalPayments    DECIMAL(18,2) NOT NULL DEFAULT 0,
    UniqueVisitCount INT           NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME      NOT NULL DEFAULT GETDATE()
);

IF OBJECT_ID('dbo.Aug_CS_MonthlyClaimVolume','U') IS NOT NULL DROP TABLE dbo.Aug_CS_MonthlyClaimVolume;
CREATE TABLE dbo.Aug_CS_MonthlyClaimVolume (
    SummaryId        INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName        NVARCHAR(500) NOT NULL,
    PayerName        NVARCHAR(500) NOT NULL,
    PayerRank        TINYINT       NOT NULL,
    BillYear         INT           NOT NULL,
    BillMonth        TINYINT       NOT NULL,
    NoOfClaims       INT           NOT NULL DEFAULT 0,
    InsurancePayment DECIMAL(18,2) NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME      NOT NULL DEFAULT GETDATE()
);

IF OBJECT_ID('dbo.Aug_CS_WeeklyClaimVolume','U') IS NOT NULL DROP TABLE dbo.Aug_CS_WeeklyClaimVolume;
CREATE TABLE dbo.Aug_CS_WeeklyClaimVolume (
    SummaryId        INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName        NVARCHAR(500) NOT NULL,
    PayerName        NVARCHAR(500) NOT NULL,
    PayerRank        TINYINT       NOT NULL,
    WeekKey          TINYINT       NOT NULL,
    WeekStart        DATE          NOT NULL,
    WeekEnd          DATE          NOT NULL,
    NoOfClaims       INT           NOT NULL DEFAULT 0,
    InsurancePayment DECIMAL(18,2) NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME      NOT NULL DEFAULT GETDATE()
);

IF OBJECT_ID('dbo.Aug_CS_PanelAverages','U') IS NOT NULL DROP TABLE dbo.Aug_CS_PanelAverages;
CREATE TABLE dbo.Aug_CS_PanelAverages (
    SummaryId         INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName         NVARCHAR(500) NOT NULL,
    PayerName         NVARCHAR(500) NOT NULL,
    NoOfClaims        INT           NOT NULL DEFAULT 0,
    TotalCharges      DECIMAL(18,2) NOT NULL DEFAULT 0,
    CarrierPayment    DECIMAL(18,2) NOT NULL DEFAULT 0,
    AvgCarrierPayment DECIMAL(18,2) NOT NULL DEFAULT 0,
    FullyPaidCount    INT           NOT NULL DEFAULT 0,
    FullyPaidAmount   DECIMAL(18,2) NOT NULL DEFAULT 0,
    AvgFullyPaid      DECIMAL(18,2) NOT NULL DEFAULT 0,
    Days30Count       INT           NOT NULL DEFAULT 0,
    Days30Amount      DECIMAL(18,2) NOT NULL DEFAULT 0,
    AvgDays30         DECIMAL(18,2) NOT NULL DEFAULT 0,
    Days60Count       INT           NOT NULL DEFAULT 0,
    Days60Amount      DECIMAL(18,2) NOT NULL DEFAULT 0,
    AvgDays60         DECIMAL(18,2) NOT NULL DEFAULT 0,
    RefreshedAt       DATETIME      NOT NULL DEFAULT GETDATE()
);

IF OBJECT_ID('dbo.Aug_CS_AvgPayments','U') IS NOT NULL DROP TABLE dbo.Aug_CS_AvgPayments;
CREATE TABLE dbo.Aug_CS_AvgPayments (
    SummaryId           INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName           NVARCHAR(500) NOT NULL,
    PayerName           NVARCHAR(500) NOT NULL,
    PayerRank           TINYINT       NOT NULL,
    ClaimCount          INT           NOT NULL DEFAULT 0,
    TotalCharges        DECIMAL(18,2) NOT NULL DEFAULT 0,
    AvgCharges          DECIMAL(18,2) NOT NULL DEFAULT 0,
    InsurancePayment    DECIMAL(18,2) NOT NULL DEFAULT 0,
    AvgInsurancePayment DECIMAL(18,2) NOT NULL DEFAULT 0,
    FullyPaidCount      INT           NOT NULL DEFAULT 0,
    FullyPaidAmount     DECIMAL(18,2) NOT NULL DEFAULT 0,
    AvgFullyPaid        DECIMAL(18,2) NOT NULL DEFAULT 0,
    AdjudicatedCount    INT           NOT NULL DEFAULT 0,
    AdjudicatedAmount   DECIMAL(18,2) NOT NULL DEFAULT 0,
    AvgAdjudicated      DECIMAL(18,2) NOT NULL DEFAULT 0,
    Over30Count         INT           NOT NULL DEFAULT 0,
    Over30Amount        DECIMAL(18,2) NOT NULL DEFAULT 0,
    AvgOver30           DECIMAL(18,2) NOT NULL DEFAULT 0,
    Over60Count         INT           NOT NULL DEFAULT 0,
    Over60Amount        DECIMAL(18,2) NOT NULL DEFAULT 0,
    AvgOver60           DECIMAL(18,2) NOT NULL DEFAULT 0,
    RefreshedAt         DATETIME      NOT NULL DEFAULT GETDATE()
);

IF OBJECT_ID('dbo.Aug_CS_InsuranceVsAging','U') IS NOT NULL DROP TABLE dbo.Aug_CS_InsuranceVsAging;
CREATE TABLE dbo.Aug_CS_InsuranceVsAging (
    SummaryId        INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName        NVARCHAR(500) NOT NULL,
    AgingBucket      NVARCHAR(50)  NOT NULL,
    ClaimCount       INT           NOT NULL DEFAULT 0,
    InsuranceBalance DECIMAL(18,2) NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME      NOT NULL DEFAULT GETDATE()
);

IF OBJECT_ID('dbo.Aug_CS_PanelVsPayment','U') IS NOT NULL DROP TABLE dbo.Aug_CS_PanelVsPayment;
CREATE TABLE dbo.Aug_CS_PanelVsPayment (
    SummaryId        INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName        NVARCHAR(500) NOT NULL,
    BillYear         INT           NOT NULL,
    BillMonth        TINYINT       NOT NULL,
    NoOfClaims       INT           NOT NULL DEFAULT 0,
    InsurancePayment DECIMAL(18,2) NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME      NOT NULL DEFAULT GETDATE()
);

IF OBJECT_ID('dbo.Aug_CS_RepVsPayment','U') IS NOT NULL DROP TABLE dbo.Aug_CS_RepVsPayment;
CREATE TABLE dbo.Aug_CS_RepVsPayment (
    SummaryId        INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
    SalesRepName     NVARCHAR(500) NOT NULL,
    CheckYear        INT           NOT NULL,
    CheckMonth       TINYINT       NOT NULL,
    NoOfClaims       INT           NOT NULL DEFAULT 0,
    InsurancePayment DECIMAL(18,2) NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME      NOT NULL DEFAULT GETDATE()
);

IF OBJECT_ID('dbo.Aug_CS_InsuranceVsPaymentPct','U') IS NOT NULL DROP TABLE dbo.Aug_CS_InsuranceVsPaymentPct;
CREATE TABLE dbo.Aug_CS_InsuranceVsPaymentPct (
    SummaryId        INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName        NVARCHAR(500) NOT NULL,
    NoOfPaidClaims   INT           NOT NULL DEFAULT 0,
    InsurancePayment DECIMAL(18,2) NOT NULL DEFAULT 0,
    PaymentPct       DECIMAL(9,4)  NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME      NOT NULL DEFAULT GETDATE()
);

IF OBJECT_ID('dbo.Aug_CS_CptVsPaymentPct','U') IS NOT NULL DROP TABLE dbo.Aug_CS_CptVsPaymentPct;
CREATE TABLE dbo.Aug_CS_CptVsPaymentPct (
    SummaryId            INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
    CPTCode              NVARCHAR(50)  NOT NULL,
    SumUnits             DECIMAL(18,2) NOT NULL DEFAULT 0,
    PaidInsurancePayment DECIMAL(18,2) NOT NULL DEFAULT 0,
    PaidChargeAmount     DECIMAL(18,2) NOT NULL DEFAULT 0,
    PaymentPct           DECIMAL(9,4)  NOT NULL DEFAULT 0,
    RefreshedAt          DATETIME      NOT NULL DEFAULT GETDATE()
);

IF OBJECT_ID('dbo.Aug_CS_StatusSummary','U') IS NOT NULL DROP TABLE dbo.Aug_CS_StatusSummary;
CREATE TABLE dbo.Aug_CS_StatusSummary (
    SummaryId        INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
    ClaimStatus      NVARCHAR(200) NOT NULL,
    PanelName        NVARCHAR(500) NOT NULL,
    CptCode          NVARCHAR(MAX) NOT NULL,
    PayerName        NVARCHAR(500) NOT NULL,
    NoOfClaims       INT           NOT NULL DEFAULT 0,
    InsurancePayment DECIMAL(18,2) NOT NULL DEFAULT 0,
    InsuranceBalance DECIMAL(18,2) NOT NULL DEFAULT 0,
    PatientBalance   DECIMAL(18,2) NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME      NOT NULL DEFAULT GETDATE()
);

IF OBJECT_ID('dbo.Aug_CS_ProviderSummary','U') IS NOT NULL DROP TABLE dbo.Aug_CS_ProviderSummary;
CREATE TABLE dbo.Aug_CS_ProviderSummary (
    SummaryId         INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
    ProviderRank      INT           NOT NULL,
    ReferringProvider NVARCHAR(500) NOT NULL,
    NoOfClaims        INT           NOT NULL DEFAULT 0,
    InsurancePayment  DECIMAL(18,2) NOT NULL DEFAULT 0,
    InsuranceBalance  DECIMAL(18,2) NOT NULL DEFAULT 0,
    PatientBalance    DECIMAL(18,2) NOT NULL DEFAULT 0,
    RefreshedAt       DATETIME      NOT NULL DEFAULT GETDATE()
);

GO

-- ================================================================
-- STORED PROCEDURES
-- ================================================================

-- 1. Top-5 Reimbursement % vs Billed Charge
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_Top5ReimbursementPct
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(PayerName_Raw))                                AS PayerName,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0) AS SumIns,
            ISNULL(SUM(TRY_CAST(ChargeAmount     AS DECIMAL(18,2))),0) AS SumChg,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(AccessionNumber)),''))   AS Visits
        FROM dbo.ClaimLevelData
        WHERE PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''
          AND ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0) > 0
        GROUP BY LTRIM(RTRIM(PayerName_Raw))
    ),
    grand AS (SELECT NULLIF(SUM(SumIns),0) AS GrandTotal FROM agg),
    ranked AS (
        SELECT TOP 5
               ROW_NUMBER() OVER (ORDER BY a.SumIns DESC) AS Rnk,
               a.PayerName, a.SumIns, a.SumChg, a.Visits,
               CAST(a.SumIns * 100.0 / ISNULL(g.GrandTotal,1) AS DECIMAL(9,4)) AS PayPct
        FROM agg a CROSS JOIN grand g
        ORDER BY a.SumIns DESC
    )
    SELECT * INTO #out FROM ranked;
    TRUNCATE TABLE dbo.Aug_CS_Top5ReimbursementPct;
    INSERT INTO dbo.Aug_CS_Top5ReimbursementPct
        (PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount, PaymentPct, RefreshedAt)
    SELECT CAST(Rnk AS TINYINT), PayerName, SumIns, SumChg, Visits, PayPct, GETDATE()
    FROM #out ORDER BY Rnk;
    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshAug_CS_Top5ReimbursementPct completed.';
END
GO

-- 2. Top-5 Reimbursement Payments
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_Top5ReimbursementPay
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(PayerName_Raw))                                AS PayerName,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0) AS TotalPay,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(AccessionNumber)),''))   AS Visits
        FROM dbo.ClaimLevelData
        WHERE PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''
          AND ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0) > 0
        GROUP BY LTRIM(RTRIM(PayerName_Raw))
    ),
    ranked AS (
        SELECT TOP 5 ROW_NUMBER() OVER (ORDER BY TotalPay DESC) AS Rnk,
               PayerName, TotalPay, Visits
        FROM agg ORDER BY TotalPay DESC
    )
    SELECT * INTO #out FROM ranked;
    TRUNCATE TABLE dbo.Aug_CS_Top5ReimbursementPay;
    INSERT INTO dbo.Aug_CS_Top5ReimbursementPay
        (PayerRank, PayerName, TotalPayments, UniqueVisitCount, RefreshedAt)
    SELECT CAST(Rnk AS TINYINT), PayerName, TotalPay, Visits, GETDATE()
    FROM #out ORDER BY Rnk;
    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshAug_CS_Top5ReimbursementPay completed.';
END
GO

-- 3. Monthly Claim Volume  (ClaimLevelData / CheckDate / Top-3 payer per PanelNew)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_MonthlyClaimVolume
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown')))              AS PanelName,
        LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown')))              AS PayerName,
        YEAR (TRY_CAST(CheckDate AS DATE))                         AS BillYear,
        MONTH(TRY_CAST(CheckDate AS DATE))                         AS BillMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),''))           AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0) AS InsurancePayment
    INTO #raw
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0) > 0
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
    GROUP BY
        LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))),
        LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE));
    SELECT PanelName, PayerName,
           DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
    INTO #ranks FROM #raw GROUP BY PanelName, PayerName;
    TRUNCATE TABLE dbo.Aug_CS_MonthlyClaimVolume;
    INSERT INTO dbo.Aug_CS_MonthlyClaimVolume
        (PanelName, PayerName, PayerRank, BillYear, BillMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT r.PanelName, r.PayerName, CAST(k.PayerRank AS TINYINT),
           r.BillYear, CAST(r.BillMonth AS TINYINT), r.NoOfClaims, r.InsurancePayment, GETDATE()
    FROM #raw r JOIN #ranks k ON k.PanelName = r.PanelName AND k.PayerName = r.PayerName
    --WHERE k.PayerRank <= 3
    ORDER BY r.PanelName, k.PayerRank, r.BillYear, r.BillMonth;
    DROP TABLE IF EXISTS #raw; DROP TABLE IF EXISTS #ranks;
    PRINT 'usp_RefreshAug_CS_MonthlyClaimVolume completed.';
END
GO

-- 4. Weekly Claim Volume  (ClaimLevelData / CheckDate / Wed-Tue / last 4 complete weeks)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_WeeklyClaimVolume
AS
BEGIN
    SET NOCOUNT ON;
    -- 1900-01-02 was a Tuesday -- used as anchor to calculate days-since-Tuesday
    DECLARE @Today        DATE = CAST(GETDATE() AS DATE);
    DECLARE @DaysSinceTue INT  = ((DATEDIFF(DAY,'1900-01-02',@Today) % 7) + 7) % 7;
    DECLARE @LastTue      DATE = DATEADD(DAY, -@DaysSinceTue, @Today);
    IF @LastTue = @Today SET @LastTue = DATEADD(DAY, -7, @LastTue);
    DECLARE @W4End  DATE = @LastTue,                     @W4Start DATE = DATEADD(DAY,  -6, @LastTue);
    DECLARE @W3End  DATE = DATEADD(DAY,  -7, @LastTue),  @W3Start DATE = DATEADD(DAY, -13, @LastTue);
    DECLARE @W2End  DATE = DATEADD(DAY, -14, @LastTue),  @W2Start DATE = DATEADD(DAY, -20, @LastTue);
    DECLARE @W1End  DATE = DATEADD(DAY, -21, @LastTue),  @W1Start DATE = DATEADD(DAY, -27, @LastTue);
    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) AS PayerName,
            CASE
              WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W1Start AND @W1End THEN 1
              WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W2Start AND @W2End THEN 2
              WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W3Start AND @W3End THEN 3
              WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W4Start AND @W4End THEN 4
            END AS WeekKey,
            ClaimID,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2)) AS InsPay
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0) > 0
          AND TRY_CAST(CheckDate AS DATE) BETWEEN @W1Start AND @W4End
    ),
    agg AS (
        SELECT PanelName, PayerName, WeekKey,
               COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),'')) AS NoOfClaims,
               ISNULL(SUM(InsPay),0)                            AS InsurancePayment
        FROM src WHERE WeekKey IS NOT NULL
        GROUP BY PanelName, PayerName, WeekKey
    ),
    ranks AS (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
        FROM agg GROUP BY PanelName, PayerName
    )
    SELECT a.PanelName, a.PayerName, CAST(r.PayerRank AS TINYINT) AS PayerRank,
           CAST(a.WeekKey AS TINYINT) AS WeekKey,
           CASE a.WeekKey WHEN 1 THEN @W1Start WHEN 2 THEN @W2Start
                          WHEN 3 THEN @W3Start ELSE @W4Start END AS WeekStart,
           CASE a.WeekKey WHEN 1 THEN @W1End   WHEN 2 THEN @W2End
                          WHEN 3 THEN @W3End   ELSE @W4End   END AS WeekEnd,
           a.NoOfClaims, a.InsurancePayment
    INTO #out FROM agg a
    JOIN ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName;
   -- WHERE r.PayerRank <= 3;
    TRUNCATE TABLE dbo.Aug_CS_WeeklyClaimVolume;
    INSERT INTO dbo.Aug_CS_WeeklyClaimVolume
        (PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment, GETDATE()
    FROM #out ORDER BY PanelName, PayerRank, WeekKey;
    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshAug_CS_WeeklyClaimVolume completed.';
END
GO

-- 5. Panel Averages
-- Col1: ClaimStatus <> 'No Response'  -> NoOfClaims, TotalCharges, CarrierPayment, Avg
-- Col2: ClaimStatus = 'Fully Paid'    -> FullyPaidCount, FullyPaidAmount, Avg
-- Col3: Bucket30 = '30 Bucket'        -> Days30Count, Days30Amount, Avg
-- Col4: Bucket60 = '60 Bucket'        -> Days60Count, Days60Amount, Avg
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_PanelAverages
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown')))           AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown')))           AS PayerName,
            COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)),''),
                     LTRIM(RTRIM(ClaimID)))                         AS VisitKey,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))             AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))             AS InsPay,
            LTRIM(RTRIM(ClaimStatus))                               AS ClaimStatus,
            LTRIM(RTRIM(Bucket30))                                  AS Bucket30,
            TRY_CAST(Bucket30Amount AS DECIMAL(18,2))               AS Bucket30Amt,
            LTRIM(RTRIM(Bucket60))                                  AS Bucket60,
            TRY_CAST(Bucket60Amount AS DECIMAL(18,2))               AS Bucket60Amt
        FROM dbo.ClaimLevelData
        WHERE PanelNew IS NOT NULL AND LTRIM(RTRIM(PanelNew)) <> ''
    )
    SELECT PanelName, PayerName,
        COUNT(DISTINCT CASE WHEN ClaimStatus <> 'No Response' THEN VisitKey END)      AS NoOfClaims,
        ISNULL(SUM(CASE WHEN ClaimStatus <> 'No Response' THEN Chg    ELSE 0 END),0)  AS TotalCharges,
        ISNULL(SUM(CASE WHEN ClaimStatus <> 'No Response' THEN InsPay ELSE 0 END),0)  AS CarrierPayment,
        COUNT(DISTINCT CASE WHEN ClaimStatus = 'Fully Paid' THEN VisitKey END)        AS FullyPaidCount,
        ISNULL(SUM(CASE WHEN ClaimStatus = 'Fully Paid' THEN InsPay ELSE 0 END),0)    AS FullyPaidAmount,
        COUNT(DISTINCT CASE WHEN Bucket30 = '30 Bucket' THEN VisitKey END)            AS Days30Count,
        ISNULL(SUM(CASE WHEN Bucket30 = '30 Bucket' THEN Bucket30Amt ELSE 0 END),0)   AS Days30Amount,
        COUNT(DISTINCT CASE WHEN Bucket60 = '60 Bucket' THEN VisitKey END)            AS Days60Count,
        ISNULL(SUM(CASE WHEN Bucket60 = '60 Bucket' THEN Bucket60Amt ELSE 0 END),0)   AS Days60Amount
    INTO #out FROM src GROUP BY PanelName, PayerName;
    TRUNCATE TABLE dbo.Aug_CS_PanelAverages;
    INSERT INTO dbo.Aug_CS_PanelAverages
        (PanelName, PayerName,
         NoOfClaims, TotalCharges, CarrierPayment, AvgCarrierPayment,
         FullyPaidCount, FullyPaidAmount, AvgFullyPaid,
         Days30Count, Days30Amount, AvgDays30,
         Days60Count, Days60Amount, AvgDays60, RefreshedAt)
    SELECT PanelName, PayerName,
        NoOfClaims, TotalCharges, CarrierPayment,
        CASE WHEN NoOfClaims     > 0 THEN CarrierPayment  / NoOfClaims     ELSE 0 END,
        FullyPaidCount, FullyPaidAmount,
        CASE WHEN FullyPaidCount > 0 THEN FullyPaidAmount / FullyPaidCount ELSE 0 END,
        Days30Count, Days30Amount,
        CASE WHEN Days30Count    > 0 THEN Days30Amount    / Days30Count    ELSE 0 END,
        Days60Count, Days60Amount,
        CASE WHEN Days60Count    > 0 THEN Days60Amount    / Days60Count    ELSE 0 END,
        GETDATE()
    FROM #out ORDER BY PanelName, PayerName;
    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshAug_CS_PanelAverages completed.';
END
GO

-- 6. Avg Payments  (CheckDate last 6 months / Top-3 payer per PanelNew)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_AvgPayments
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Cutoff DATE = DATEADD(MONTH, -6, CAST(GETDATE() AS DATE));
    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown')))           AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown')))           AS PayerName,
            ClaimID,
            TRY_CAST(ChargeAmount      AS DECIMAL(18,2))            AS Chg,
            TRY_CAST(InsurancePayment  AS DECIMAL(18,2))            AS InsPay,
            LTRIM(RTRIM(ClaimStatus))                               AS ClaimStatus,
            LTRIM(RTRIM(Adjudicated))                               AS Adjudicated,
            TRY_CAST(AdjudicatedAmount AS DECIMAL(18,2))            AS AdjAmt,
            LTRIM(RTRIM(Bucket30))                                  AS Bucket30,
            TRY_CAST(Bucket30Amount    AS DECIMAL(18,2))            AS Bucket30Amt,
            LTRIM(RTRIM(Bucket60))                                  AS Bucket60,
            TRY_CAST(Bucket60Amount    AS DECIMAL(18,2))            AS Bucket60Amt
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND TRY_CAST(CheckDate AS DATE) >= @Cutoff
          AND PanelNew      IS NOT NULL AND LTRIM(RTRIM(PanelNew))      <> ''
          AND PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''
    ),
    agg AS (
        SELECT PanelName, PayerName,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),''))                             AS ClaimCount,
            ISNULL(SUM(Chg),0)                                                           AS TotalCharges,
            ISNULL(SUM(InsPay),0)                                                        AS InsurancePayment,
            COUNT(DISTINCT CASE WHEN ClaimStatus = 'Fully Paid'  THEN ClaimID END)       AS FullyPaidCount,
            ISNULL(SUM(CASE WHEN ClaimStatus = 'Fully Paid'  THEN InsPay    ELSE 0 END),0) AS FullyPaidAmount,
            COUNT(DISTINCT CASE WHEN Adjudicated = 'Adjudicated' THEN ClaimID END)       AS AdjudicatedCount,
            ISNULL(SUM(CASE WHEN Adjudicated = 'Adjudicated' THEN AdjAmt    ELSE 0 END),0) AS AdjudicatedAmount,
            COUNT(DISTINCT CASE WHEN Bucket30 = '30 Bucket'  THEN ClaimID END)           AS Over30Count,
            ISNULL(SUM(CASE WHEN Bucket30 = '30 Bucket'  THEN Bucket30Amt ELSE 0 END),0) AS Over30Amount,
            COUNT(DISTINCT CASE WHEN Bucket60 = '60 Bucket' THEN ClaimID END)            AS Over60Count,
            ISNULL(SUM(CASE WHEN Bucket60 = '60 Bucket' THEN Bucket60Amt ELSE 0 END),0)  AS Over60Amount
        FROM base GROUP BY PanelName, PayerName
    ),
    ranks AS (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY ClaimCount DESC) AS PayerRank
        FROM agg
    )
    SELECT a.*, CAST(r.PayerRank AS TINYINT) AS PayerRank
    INTO #out FROM agg a
    JOIN ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    WHERE r.PayerRank <= 3;
    TRUNCATE TABLE dbo.Aug_CS_AvgPayments;
    INSERT INTO dbo.Aug_CS_AvgPayments
        (PanelName, PayerName, PayerRank,
         ClaimCount, TotalCharges, AvgCharges, InsurancePayment, AvgInsurancePayment,
         FullyPaidCount,   FullyPaidAmount,   AvgFullyPaid,
         AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,
         Over30Count, Over30Amount, AvgOver30,
         Over60Count, Over60Amount, AvgOver60, RefreshedAt)
    SELECT PanelName, PayerName, PayerRank,
        ClaimCount, TotalCharges,
        CASE WHEN ClaimCount       > 0 THEN TotalCharges      / ClaimCount       ELSE 0 END,
        InsurancePayment,
        CASE WHEN ClaimCount       > 0 THEN InsurancePayment  / ClaimCount       ELSE 0 END,
        FullyPaidCount,   FullyPaidAmount,
        CASE WHEN FullyPaidCount   > 0 THEN FullyPaidAmount   / FullyPaidCount   ELSE 0 END,
        AdjudicatedCount, AdjudicatedAmount,
        CASE WHEN AdjudicatedCount > 0 THEN AdjudicatedAmount / AdjudicatedCount ELSE 0 END,
        Over30Count, Over30Amount,
        CASE WHEN Over30Count      > 0 THEN Over30Amount      / Over30Count      ELSE 0 END,
        Over60Count, Over60Amount,
        CASE WHEN Over60Count      > 0 THEN Over60Amount      / Over60Count      ELSE 0 END,
        GETDATE()
    FROM #out ORDER BY PanelName, PayerRank;
    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshAug_CS_AvgPayments completed.';
END
GO

-- 7. Insurance vs Aging  (AgingBucket derived from DaystoDOS; exclude No Response)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_InsuranceVsAging
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dbo.Aug_CS_InsuranceVsAging;
    INSERT INTO dbo.Aug_CS_InsuranceVsAging (PayerName, AgingBucket, ClaimCount, InsuranceBalance, RefreshedAt)
    SELECT
        LTRIM(RTRIM(PayerName_Raw)),
        CASE
          WHEN ISNULL(TRY_CAST(DaystoDOS AS INT),-1) <   0 THEN '(blank)'
          WHEN TRY_CAST(DaystoDOS AS INT)             <  30 THEN 'Current'
          WHEN TRY_CAST(DaystoDOS AS INT)             <  60 THEN '30 Days'
          WHEN TRY_CAST(DaystoDOS AS INT)             <  90 THEN '60 Days'
          WHEN TRY_CAST(DaystoDOS AS INT)             < 120 THEN '90 Days'
          ELSE '120+ Days'
        END,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),'')), 
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))),0),
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''
      AND ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)),0) <> 0
      AND LTRIM(RTRIM(ClaimStatus)) <> 'No Response'
    GROUP BY LTRIM(RTRIM(PayerName_Raw)),
        CASE
          WHEN ISNULL(TRY_CAST(DaystoDOS AS INT),-1) <   0 THEN '(blank)'
          WHEN TRY_CAST(DaystoDOS AS INT)             <  30 THEN 'Current'
          WHEN TRY_CAST(DaystoDOS AS INT)             <  60 THEN '30 Days'
          WHEN TRY_CAST(DaystoDOS AS INT)             <  90 THEN '60 Days'
          WHEN TRY_CAST(DaystoDOS AS INT)             < 120 THEN '90 Days'
          ELSE '120+ Days'
        END;
    PRINT 'usp_RefreshAug_CS_InsuranceVsAging completed.';
END
GO

-- 8. Panel vs Payment  (monthly by PanelNew / ClaimLevelData / CheckDate)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_PanelVsPayment
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dbo.Aug_CS_PanelVsPayment;
    INSERT INTO dbo.Aug_CS_PanelVsPayment (PanelName, BillYear, BillMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT LTRIM(RTRIM(ISNULL(PanelNew,'Unknown'))),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT),
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),'')), 
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0),
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0) > 0
      AND PanelNew IS NOT NULL AND LTRIM(RTRIM(PanelNew)) <> ''
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
    GROUP BY LTRIM(RTRIM(ISNULL(PanelNew,'Unknown'))),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE));
    PRINT 'usp_RefreshAug_CS_PanelVsPayment completed.';
END
GO

-- 9. Rep vs Payment
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_RepVsPayment
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dbo.Aug_CS_RepVsPayment;
    INSERT INTO dbo.Aug_CS_RepVsPayment (SalesRepName, CheckYear, CheckMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT LTRIM(RTRIM(SalesRepname)),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT),
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),'')), 
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0),
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0) > 0
      AND SalesRepname IS NOT NULL AND LTRIM(RTRIM(SalesRepname)) <> ''
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
    GROUP BY LTRIM(RTRIM(SalesRepname)),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE));
    PRINT 'usp_RefreshAug_CS_RepVsPayment completed.';
END
GO

-- 10. Insurance vs Payment %
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_InsuranceVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH agg AS (
        SELECT LTRIM(RTRIM(PayerName_Raw))                                AS PayerName,
               COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),''))           AS NoOfPaidClaims,
               ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0) AS InsurancePayment
        FROM dbo.ClaimLevelData
        WHERE PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''
          AND ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0) > 0
        GROUP BY LTRIM(RTRIM(PayerName_Raw))
    ),
    grand AS (SELECT NULLIF(SUM(InsurancePayment),0) AS Total FROM agg)
    SELECT a.PayerName, a.NoOfPaidClaims, a.InsurancePayment,
           CAST(a.InsurancePayment * 100.0 / ISNULL(g.Total,1) AS DECIMAL(9,4)) AS PaymentPct
    INTO #out FROM agg a CROSS JOIN grand g;
    TRUNCATE TABLE dbo.Aug_CS_InsuranceVsPaymentPct;
    INSERT INTO dbo.Aug_CS_InsuranceVsPaymentPct (PayerName, NoOfPaidClaims, InsurancePayment, PaymentPct, RefreshedAt)
    SELECT PayerName, NoOfPaidClaims, InsurancePayment, PaymentPct, GETDATE()
    FROM #out ORDER BY InsurancePayment DESC;
    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshAug_CS_InsuranceVsPaymentPct completed.';
END
GO

-- 11. CPT vs Payment %
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_CptVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH agg AS (
        SELECT LTRIM(RTRIM(CPTCode)) AS CPTCode,
               ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))),0) AS SumUnits,
               ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                               THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END),0) AS PaidIns,
               ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                               THEN TRY_CAST(ChargeAmount     AS DECIMAL(18,2)) ELSE 0 END),0) AS PaidChg
        FROM dbo.LineLevelData
        WHERE CPTCode IS NOT NULL AND LTRIM(RTRIM(CPTCode)) <> ''
        GROUP BY LTRIM(RTRIM(CPTCode))
    )
    SELECT CPTCode, SumUnits, PaidIns, PaidChg,
           CASE WHEN PaidChg > 0 THEN CAST(PaidIns * 100.0 / PaidChg AS DECIMAL(9,4)) ELSE 0 END AS PaymentPct
    INTO #out FROM agg;
    TRUNCATE TABLE dbo.Aug_CS_CptVsPaymentPct;
    INSERT INTO dbo.Aug_CS_CptVsPaymentPct (CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, PaymentPct, RefreshedAt)
    SELECT CPTCode, SumUnits, PaidIns, PaidChg, PaymentPct, GETDATE()
    FROM #out ORDER BY SumUnits DESC;
    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshAug_CS_CptVsPaymentPct completed.';
END
GO

-- 12. Status Summary
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_StatusSummary
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dbo.Aug_CS_StatusSummary;
    INSERT INTO dbo.Aug_CS_StatusSummary
        (ClaimStatus, PanelName, CptCode, PayerName,
         NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance, RefreshedAt)
    SELECT
        ISNULL(LTRIM(RTRIM(ClaimStatus)),           '(blank)'),
        ISNULL(LTRIM(RTRIM(PanelNew)),              '(blank)'),
        ISNULL(LTRIM(RTRIM(CPTCodeXUnitsXModifier)),'(blank)'),
        ISNULL(LTRIM(RTRIM(PayerName_Raw)),         '(blank)'),
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),'')), 
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0),
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))),0),
        ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))),0),
        GETDATE()
    FROM dbo.ClaimLevelData
    GROUP BY LTRIM(RTRIM(ClaimStatus)), LTRIM(RTRIM(PanelNew)),
             LTRIM(RTRIM(CPTCodeXUnitsXModifier)), LTRIM(RTRIM(PayerName_Raw));
    PRINT 'usp_RefreshAug_CS_StatusSummary completed.';
END
GO

-- 13. Provider Summary
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_ProviderSummary
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH agg AS (
        SELECT LTRIM(RTRIM(ReferringProvider))                              AS ReferringProvider,
               COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),''))             AS NoOfClaims,
               ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0)   AS InsurancePayment,
               ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))),0)   AS InsuranceBalance,
               ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))),0)   AS PatientBalance
        FROM dbo.ClaimLevelData
        WHERE ReferringProvider IS NOT NULL AND LTRIM(RTRIM(ReferringProvider)) <> ''
        GROUP BY LTRIM(RTRIM(ReferringProvider))
    )
    SELECT ROW_NUMBER() OVER (ORDER BY NoOfClaims DESC) AS ProviderRank,
           ReferringProvider, NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance
    INTO #out FROM agg;
    TRUNCATE TABLE dbo.Aug_CS_ProviderSummary;
    INSERT INTO dbo.Aug_CS_ProviderSummary
        (ProviderRank, ReferringProvider, NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance, RefreshedAt)
    SELECT ProviderRank, ReferringProvider, NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance, GETDATE()
    FROM #out ORDER BY ProviderRank;
    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshAug_CS_ProviderSummary completed.';
END
GO

PRINT '13_Augustus_CollectionSummary.sql completed.';

-- TEST BLOCK (uncomment to validate)
/*
EXEC dbo.usp_RefreshAug_CS_Top5ReimbursementPct;  EXEC dbo.usp_RefreshAug_CS_Top5ReimbursementPay;
EXEC dbo.usp_RefreshAug_CS_MonthlyClaimVolume;    EXEC dbo.usp_RefreshAug_CS_WeeklyClaimVolume;
EXEC dbo.usp_RefreshAug_CS_PanelAverages;         EXEC dbo.usp_RefreshAug_CS_AvgPayments;
EXEC dbo.usp_RefreshAug_CS_InsuranceVsAging;      EXEC dbo.usp_RefreshAug_CS_PanelVsPayment;
EXEC dbo.usp_RefreshAug_CS_RepVsPayment;          EXEC dbo.usp_RefreshAug_CS_InsuranceVsPaymentPct;
EXEC dbo.usp_RefreshAug_CS_CptVsPaymentPct;       EXEC dbo.usp_RefreshAug_CS_StatusSummary;
EXEC dbo.usp_RefreshAug_CS_ProviderSummary;
*/
