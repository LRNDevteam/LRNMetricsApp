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
go


-----
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_PanelAverages
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Cutoff DATE = DATEADD(MONTH, -6, CAST(GETDATE() AS DATE));

    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,        'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))    AS PayerName,
            COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
                     LTRIM(RTRIM(ClaimID)))                   AS VisitKey,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))       AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))       AS InsPay,
            -- Text-flag columns: not blank means the row belongs to that bucket
            NULLIF(LTRIM(RTRIM(FullyPaidCount)),  '') AS FullyPaidFlag,
            TRY_CAST(FullyPaidAmount   AS DECIMAL(18,2))      AS FullyPaidAmt,
            NULLIF(LTRIM(RTRIM(Adjudicated)),     '') AS AdjudicatedFlag,
            TRY_CAST(AdjudicatedAmount AS DECIMAL(18,2))      AS AdjudicatedAmt,
            NULLIF(LTRIM(RTRIM(Bucket30)),        '') AS Bucket30Flag,
            TRY_CAST(Bucket30Amount    AS DECIMAL(18,2))      AS Bucket30Amt,
            NULLIF(LTRIM(RTRIM(Bucket60)),        '') AS Bucket60Flag,
            TRY_CAST(Bucket60Amount    AS DECIMAL(18,2))      AS Bucket60Amt,
            TRY_CAST(ChargeEnteredDate AS DATE)               AS EnteredDate
        FROM dbo.ClaimLevelData
        WHERE NULLIF(LTRIM(RTRIM(Panelname)), '') IS NOT NULL
		 AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
		 AND TRY_CAST(CheckDate AS DATE) <= CAST(GETDATE() AS DATE)
		AND TRY_CAST(CheckDate AS DATE) >=
			 DATEADD
			 (
				 DAY,1,
				 EOMONTH
				 (
					 (
						 SELECT MAX(TRY_CAST(CheckDate AS DATE))
						 FROM dbo.ClaimLevelData
						 WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL
						 AND TRY_CAST(CheckDate AS DATE) <= CAST(GETDATE() AS DATE)
					 ),
				 -6)
			 )
    )
    SELECT
        PanelName, PayerName,
        COUNT(DISTINCT VisitKey)                                                               AS NoOfClaims,
        ISNULL(SUM(Chg),    0)                                                                 AS TotalCharges,
        ISNULL(SUM(InsPay), 0)                                                                 AS CarrierPayment,

        COUNT(DISTINCT CASE WHEN FullyPaidFlag   IS NOT NULL THEN VisitKey END)                AS FullyPaidCount,
        ISNULL(SUM(CASE WHEN FullyPaidFlag   IS NOT NULL THEN FullyPaidAmt   ELSE 0 END), 0)   AS FullyPaidAmount,

        COUNT(DISTINCT CASE WHEN AdjudicatedFlag IS NOT NULL THEN VisitKey END)                AS AdjudicatedCount,
        ISNULL(SUM(CASE WHEN AdjudicatedFlag IS NOT NULL THEN AdjudicatedAmt ELSE 0 END), 0)   AS AdjudicatedAmount,

        COUNT(DISTINCT CASE WHEN Bucket30Flag    IS NOT NULL THEN VisitKey END)                AS Days30Count,
        ISNULL(SUM(CASE WHEN Bucket30Flag    IS NOT NULL THEN Bucket30Amt    ELSE 0 END), 0)   AS Days30Amount,

        COUNT(DISTINCT CASE WHEN Bucket60Flag    IS NOT NULL THEN VisitKey END)                AS Days60Count,
        ISNULL(SUM(CASE WHEN Bucket60Flag    IS NOT NULL THEN Bucket60Amt    ELSE 0 END), 0)   AS Days60Amount
    INTO #out
    FROM src
    WHERE EnteredDate IS NOT NULL
      AND EnteredDate >= @Cutoff
    GROUP BY PanelName, PayerName;

    TRUNCATE TABLE dbo.Aug_CS_PanelAverages;

    INSERT INTO dbo.Aug_CS_PanelAverages
        (PanelName, PayerName,
         NoOfClaims, TotalCharges, CarrierPayment, AvgCarrierPayment,
         FullyPaidCount,    FullyPaidAmount,    AvgFullyPaid,
         AdjudicatedCount,  AdjudicatedAmount,  AvgAdjudicated,
         Days30Count,       Days30Amount,       AvgDays30,
         Days60Count,       Days60Amount,       AvgDays60,
         RefreshedAt)
    SELECT
        PanelName, PayerName,
        NoOfClaims, TotalCharges, CarrierPayment,
        CASE WHEN NoOfClaims       > 0 THEN CarrierPayment    / NoOfClaims       ELSE 0 END,
        FullyPaidCount,    FullyPaidAmount,
        CASE WHEN FullyPaidCount   > 0 THEN FullyPaidAmount   / FullyPaidCount   ELSE 0 END,
        AdjudicatedCount,  AdjudicatedAmount,
        CASE WHEN AdjudicatedCount > 0 THEN AdjudicatedAmount / AdjudicatedCount ELSE 0 END,
        Days30Count,       Days30Amount,
        CASE WHEN Days30Count      > 0 THEN Days30Amount      / Days30Count      ELSE 0 END,
        Days60Count,       Days60Amount,
        CASE WHEN Days60Count      > 0 THEN Days60Amount      / Days60Count      ELSE 0 END,
        GETDATE()
    FROM #out
    ORDER BY PanelName, PayerName;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshAug_CS_PanelAverages completed.';
END
GO

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
            ISNULL(SUM(TRY_CAST(PaymentPercent AS DECIMAL(18,2))),0) AS SumIns,
            ISNULL(SUM(TRY_CAST(ChargeAmount     AS DECIMAL(18,2))),0) AS SumChg,
            COUNT(NULLIF(LTRIM(RTRIM(Claimid)), '')) AS Visits
        FROM dbo.ClaimLevelData 
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
		and PayerName_Raw not in ('None', 'ClientBill', 'Selfpay')
         GROUP BY LTRIM(RTRIM(PayerName_Raw))
    ),
    ranked AS (
        SELECT TOP 5 PayerName, SumIns, SumChg, Visits,
               ROW_NUMBER() OVER (ORDER BY SumIns DESC) AS Rnk
        FROM agg
        ORDER BY SumIns DESC
    )
    SELECT * INTO #out FROM ranked;

    TRUNCATE TABLE dbo.Aug_CS_Top5ReimbursementPct;
    INSERT INTO dbo.Aug_CS_Top5ReimbursementPct
        (PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount, RefreshedAt)
    SELECT CAST(Rnk AS TINYINT), PayerName, SumIns, SumChg, Visits, GETDATE()
    FROM #out
    ORDER BY Rnk;

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
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),''))   AS Visits
        FROM dbo.ClaimLevelData
        WHERE PayerName_Raw not in ('None', 'ClientBill', 'Selfpay') and ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0) > 0
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
        YEAR (TRY_CAST(PostingDate AS DATE))                         AS BillYear,
        MONTH(TRY_CAST(PostingDate AS DATE))                         AS BillMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),''))           AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0) AS InsurancePayment
    INTO #raw
    FROM dbo.CollectionClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0) > 0
     GROUP BY
        LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))),
        LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))),
        YEAR (TRY_CAST(PostingDate AS DATE)),
        MONTH(TRY_CAST(PostingDate AS DATE));
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

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @MaxPostingDate DATE;
    DECLARE @WeekContainingMaxStart DATE;
    DECLARE @WeekContainingMaxEnd DATE;
    DECLARE @LatestCompletedWeekStart DATE;
    DECLARE @LatestCompletedWeekEnd DATE;

    /*
      Get latest available PostingDate up to today
    */
    SELECT
        @MaxPostingDate = MAX(TRY_CAST(PostingDate AS DATE))
    FROM dbo.CollectionClaimLevelData
    WHERE TRY_CAST(PostingDate AS DATE) IS NOT NULL
      AND TRY_CAST(PostingDate AS DATE) <= @Today;

    IF @MaxPostingDate IS NULL
    BEGIN
        RAISERROR('No valid PostingDate <= today found in CollectionCollectionClaimLevelData.', 16, 1);
        RETURN;
    END;

    /*
      Mon-Sun week logic based on latest available PostingDate.
      1900-01-01 was Monday.
    */
    SET @WeekContainingMaxStart =
        DATEADD(DAY,
            -((DATEDIFF(DAY, '19000101', @MaxPostingDate) % 7)),
            @MaxPostingDate
        );

    SET @WeekContainingMaxEnd = DATEADD(DAY, 6, @WeekContainingMaxStart);

    /*
      Week 4 should be the week containing the latest available PostingDate.
      Example:
      If @MaxPostingDate = 2026-05-17,
      Week 4 = 2026-05-11 to 2026-05-17.
    */
    SET @LatestCompletedWeekStart = @WeekContainingMaxStart;
    SET @LatestCompletedWeekEnd   = @WeekContainingMaxEnd;

    DECLARE @W4Start DATE = @LatestCompletedWeekStart;
    DECLARE @W4End   DATE = @LatestCompletedWeekEnd;

    DECLARE @W3Start DATE = DATEADD(DAY, -7, @W4Start);
    DECLARE @W3End   DATE = DATEADD(DAY,  6, @W3Start);

    DECLARE @W2Start DATE = DATEADD(DAY, -7, @W3Start);
    DECLARE @W2End   DATE = DATEADD(DAY,  6, @W2Start);

    DECLARE @W1Start DATE = DATEADD(DAY, -7, @W2Start);
    DECLARE @W1End   DATE = DATEADD(DAY,  6, @W1Start);

    PRINT 'Max Posting Date: ' + CONVERT(varchar(10), @MaxPostingDate, 120);
    PRINT 'Week 1: ' + CONVERT(varchar(10), @W1Start, 120) + ' to ' + CONVERT(varchar(10), @W1End, 120);
    PRINT 'Week 2: ' + CONVERT(varchar(10), @W2Start, 120) + ' to ' + CONVERT(varchar(10), @W2End, 120);
    PRINT 'Week 3: ' + CONVERT(varchar(10), @W3Start, 120) + ' to ' + CONVERT(varchar(10), @W3End, 120);
    PRINT 'Week 4: ' + CONVERT(varchar(10), @W4Start, 120) + ' to ' + CONVERT(varchar(10), @W4End, 120);

    ;WITH src AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname, 'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            CASE
                WHEN TRY_CAST(PostingDate AS DATE) BETWEEN @W1Start AND @W1End THEN 1
                WHEN TRY_CAST(PostingDate AS DATE) BETWEEN @W2Start AND @W2End THEN 2
                WHEN TRY_CAST(PostingDate AS DATE) BETWEEN @W3Start AND @W3End THEN 3
                WHEN TRY_CAST(PostingDate AS DATE) BETWEEN @W4Start AND @W4End THEN 4
            END AS WeekKey,
            ClaimID,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2)) AS InsPay
        FROM dbo.CollectionClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(PostingDate AS DATE) BETWEEN @W1Start AND @W4End
    ),
    agg AS
    (
        SELECT
            PanelName,
            PayerName,
            WeekKey,
            COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfClaims,
            ISNULL(SUM(InsPay), 0) AS InsurancePayment
        FROM src
        WHERE WeekKey IS NOT NULL
        GROUP BY PanelName, PayerName, WeekKey
    ),
    ranks AS
    (
        SELECT
            PanelName,
            PayerName,
            DENSE_RANK() OVER
            (
                PARTITION BY PanelName
                ORDER BY SUM(NoOfClaims) DESC
            ) AS PayerRank
        FROM agg
        GROUP BY PanelName, PayerName
    )
    SELECT
        a.PanelName,
        a.PayerName,
        CAST(r.PayerRank AS TINYINT) AS PayerRank,
        CAST(a.WeekKey AS TINYINT) AS WeekKey,
        CASE a.WeekKey
            WHEN 1 THEN @W1Start
            WHEN 2 THEN @W2Start
            WHEN 3 THEN @W3Start
            WHEN 4 THEN @W4Start
        END AS WeekStart,
        CASE a.WeekKey
            WHEN 1 THEN @W1End
            WHEN 2 THEN @W2End
            WHEN 3 THEN @W3End
            WHEN 4 THEN @W4End
        END AS WeekEnd,
        a.NoOfClaims,
        a.InsurancePayment
    INTO #out
    FROM agg a
    JOIN ranks r
      ON r.PanelName = a.PanelName
     AND r.PayerName = a.PayerName;

    TRUNCATE TABLE dbo.Aug_CS_WeeklyClaimVolume;

    INSERT INTO dbo.Aug_CS_WeeklyClaimVolume
    (
        PanelName,
        PayerName,
        PayerRank,
        WeekKey,
        WeekStart,
        WeekEnd,
        NoOfClaims,
        InsurancePayment,
        RefreshedAt
    )
    SELECT
        PanelName,
        PayerName,
        PayerRank,
        WeekKey,
        WeekStart,
        WeekEnd,
        NoOfClaims,
        InsurancePayment,
        GETDATE()
    FROM #out
    ORDER BY PanelName, PayerRank, WeekKey;

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
	print 'Aug_CS_InsuranceVsAging table truncated';
    INSERT INTO dbo.Aug_CS_InsuranceVsAging (PayerName, AgingBucket, ClaimCount, InsuranceBalance, RefreshedAt)
		SELECT
			LTRIM(RTRIM(Source))                                  AS PayerName,      
			LTRIM(RTRIM(ISNULL(Aging, '(blank)')))                 AS AgingBucket,
			COUNT( NULLIF(LTRIM(RTRIM(Claimid)), ''))    AS VisitCount,
			ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)  AS InsuranceBalance,
			GETDATE()
		FROM dbo.ClaimLevelData
		WHERE LTRIM(RTRIM(ClaimStatus)) = 'No Response' 
		GROUP BY LTRIM(RTRIM(Source)), LTRIM(RTRIM(ISNULL(Aging, '(blank)')));

    PRINT 'usp_RefreshAug_CS_InsuranceVsAging completed.';
END
GO




-- 8. Panel vs Payment  (monthly by PanelNew / ClaimLevelData / CheckDate)
DROP TABLE IF EXISTS dbo.Aug_CS_PanelVsPayment;
GO
CREATE TABLE dbo.Aug_CS_PanelVsPayment
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




CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_PanelVsPayment
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Aug_CS_PanelVsPayment;

    INSERT INTO dbo.Aug_CS_PanelVsPayment
        (PanelName, BilledYear, BilledMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT
        LTRIM(RTRIM(Panelname))                                         AS PanelName,
		YEAR (TRY_CAST(CheckDate AS DATE))                            AS BilledYear,
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)           AS BilledMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))            AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
     
    GROUP BY LTRIM(RTRIM(Panelname)) ,YEAR (TRY_CAST(CheckDate AS DATE)),  
        MONTH(TRY_CAST(CheckDate AS DATE));;  

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
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_InsuranceVsPaymentPct
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Augustus does not maintain aggregate snapshot tables, so this SP always
    -- reads live from ClaimLevelData regardless of whether filters are active.

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            CAST(YEAR (TRY_CAST(CheckDate AS DATE)) AS INT) AS BillYear,
            CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS INT) AS BillMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfPaidClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
          AND CheckDate <> ''
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            CAST(YEAR (TRY_CAST(CheckDate AS DATE)) AS INT),
            CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS INT)
    ),
    grand AS (
        SELECT BillYear, BillMonth,
               NULLIF(SUM(InsurancePayment), 0) AS TotalInsurancePayment
        FROM agg
        GROUP BY BillYear, BillMonth
    )
    SELECT a.PayerName, a.BillYear, a.BillMonth,
           a.NoOfPaidClaims, a.InsurancePayment,
           CAST(a.InsurancePayment * 100.0 / ISNULL(g.TotalInsurancePayment, 1) AS DECIMAL(9,4)) AS PaymentPct
    FROM agg a
    INNER JOIN grand g ON a.BillYear = g.BillYear AND a.BillMonth = g.BillMonth
    ORDER BY a.BillYear DESC, a.BillMonth DESC, a.InsurancePayment DESC;
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




CREATE TABLE [dbo].[Aug_CS_InsuranceVsPayment](
	[SummaryId] [int] IDENTITY(1,1) NOT NULL,
	[PayerName] [nvarchar](200) NOT NULL,
	[BillYear] [smallint] NOT NULL,
	[BillMonth] [tinyint] NOT NULL,
	[NoOfPaidClaims] [int] NOT NULL,
	[InsurancePayment] [decimal](18, 2) NOT NULL,
	[PaymentPct] [decimal](9, 4) NOT NULL,
	[RefreshedAt] [datetime] NOT NULL)



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




CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_InsuranceVsPayment
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))              AS PayerName,

            YEAR (TRY_CAST(CheckDate AS DATE))                          AS BillYear,
            MONTH(TRY_CAST(CheckDate AS DATE))                          AS BillMonth,

            COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))           AS NoOfPaidClaims,

            ISNULL(
                SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),
                0
            )                                                           AS InsurancePayment

        FROM dbo.ClaimLevelData                                          -- ✅ RT uses LineLevelData
        WHERE
            ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
            AND CheckDate <> ''
            AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
            AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900

        GROUP BY
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            YEAR (TRY_CAST(CheckDate AS DATE)),
            MONTH(TRY_CAST(CheckDate AS DATE))
    ),

    grand AS
    (
        SELECT
            BillYear,
            BillMonth,
            NULLIF(SUM(InsurancePayment), 0) AS TotalInsurancePayment
        FROM agg
        GROUP BY
            BillYear,
            BillMonth
    )

    SELECT
        a.PayerName,
        CAST(a.BillYear  AS SMALLINT)  AS BillYear,
        CAST(a.BillMonth AS TINYINT)   AS BillMonth,
        a.NoOfPaidClaims,
        a.InsurancePayment,
        CAST
        (
            a.InsurancePayment * 100.0 /
            ISNULL(g.TotalInsurancePayment, 1)
            AS DECIMAL(9,4)
        )                              AS PaymentPct

    INTO #out
    FROM agg a
    INNER JOIN grand g
        ON  a.BillYear  = g.BillYear
        AND a.BillMonth = g.BillMonth;

    TRUNCATE TABLE dbo.Aug_CS_InsuranceVsPayment;

    INSERT INTO dbo.Aug_CS_InsuranceVsPayment
    (
        PayerName,
        BillYear,
        BillMonth,
        NoOfPaidClaims,
        InsurancePayment,
        PaymentPct,
        RefreshedAt
    )
    SELECT
        PayerName,
        BillYear,
        BillMonth,
        NoOfPaidClaims,
        InsurancePayment,
        PaymentPct,
        GETDATE()
    FROM #out
    ORDER BY
        BillYear,
        BillMonth,
        InsurancePayment DESC;

    DROP TABLE IF EXISTS #out;

    PRINT 'usp_RefreshAug_CS_InsuranceVsPayment completed.';
END
GO