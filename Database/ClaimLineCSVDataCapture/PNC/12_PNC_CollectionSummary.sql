/* =============================================================================
   PNC - Collection Summary (SP-only logic, Texas Diagnostic pattern)
   Database : PNC        Prefix : PNC

   Every calculation, ranking, total and row order is done here. The dashboard
   and Excel export read usp_GetPNC_CS_* and keep the SP row order.

     fn_PNC_CS_Claims        claim-level base + dashboard filters
     fn_PNC_CS_WeekEnd       week-range end date of the loaded claim file
     usp_PNC_CS_{X}_Compute  the logic (live, honours filters)
     PNC_CS2_{X}             no-filter snapshot
     usp_GetPNC_CS_{X}       snapshot when unfiltered, else compute
     usp_RefreshPNC_CS_{X}   rebuilds the snapshot (claim-file ingest)

   Client sheet (Claim Level Data unless noted; sorted by claim count). "Week End Date" is the
   end of the claim file's week range (LineClaimFileLogs.WeekFolder, e.g. 11.04.2026 - 11.10.2026).
     1  Monthly                InsurancePayment > 0; CheckDate 2024-01-01 to Week End Date;
                               Panelname + top 5 PayerName_Raw; CheckDate month
     2  Weekly                 InsurancePayment > 0; CheckDate 2024-01-01 to Week End Date;
                               last 4 Wednesday-Tuesday weeks of CheckDate where DepositWeek is
                               filled (DepositWeek Week 1-4 = those weeks); Panelname + top 5 payers
     3  Top 5 Reimbursement %  InsurancePayment > 0; top 5 PayerName_Raw by claim count;
                               Payment % = Average(PaymentPercent)
     4  Top 5 Insurance by Payments  InsurancePayment > 0; top 5 by claim count;
                               Sum(InsurancePayment)
     5  No Response Vs Aging   ClaimStatus = No Response; Aging buckets (AgingDOS when Aging is
                               blank - Aging is empty on the current file); claim count +
                               Sum(InsuranceBalance)
     6  Insurance vs Payment % InsurancePayment > 0; claim count + Average(PaymentPercent)
     7  Panel Vs Payment       InsurancePayment > 0; CheckDate 2024-01-01 to Week End Date;
                               ChargeEnteredDate month; rows Panelname.
                               Billed = FirstBilledDate is a date: claim count + Sum(ChargeAmount).
                               Paid = InsurancePayment > 0: claim count + Sum(InsurancePayment)
     8  Insurance vs Payment   InsurancePayment > 0; CheckDate month; claim count + Sum(InsurancePayment)
                               (14_PNC_CS_InsuranceVsPayment_CheckDate.sql)
     9  CPT vs Payment         Line Level Data; line InsurancePayment > 0; Sum(Units) and
                               Sum(InsurancePayment); sorted by units (not on the client sheet;
                               the dashboard always shows this tab)
    10  Panel Averages         Panelname + top 3 payers, every claim (no billed filter).
                               by DOS        : DateofService in the 6 months ending at Week End Date
                               by Check Date : CheckDate in the 6 calendar months ending with the
                                               Week End Date's month
                               Fully Paid = FullyPaidCount 'Fully Paid', Sum(FullyPaidAmount);
                               Adjudicated = Adjudicated filled, Sum(AdjudicatedAmount);
                               30 / 60 Days = Bucket30 / Bucket60 filled, Sum(Bucket30Amount / Bucket60Amount).

   The dashboard Check Date filter applies to CheckDate.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'PNC'
BEGIN
    RAISERROR('Run 12_PNC_CollectionSummary.sql on the PNC database.', 16, 1);
    SET NOEXEC ON;
END
GO

/* =============================================================================
   Helpers
   ============================================================================= */
CREATE OR ALTER FUNCTION dbo.fn_PNC_CS_HasFilter
(
    @PayerNames    NVARCHAR(MAX),
    @PanelNames    NVARCHAR(MAX),
    @DosFrom       DATE,
    @DosTo         DATE,
    @FirstBillFrom DATE,
    @FirstBillTo   DATE,
    @CheckDateFrom DATE,
    @CheckDateTo   DATE
)
RETURNS BIT
AS
BEGIN
    RETURN CASE
        WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NOT NULL THEN 1
        WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
        WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
        WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
        ELSE 0
    END;
END
GO

CREATE OR ALTER FUNCTION dbo.fn_PNC_CS_Claims
(
    @PayerNames    NVARCHAR(MAX),
    @PanelNames    NVARCHAR(MAX),
    @DosFrom       DATE,
    @DosTo         DATE,
    @FirstBillFrom DATE,
    @FirstBillTo   DATE,
    @CheckDateFrom DATE,
    @CheckDateTo   DATE
)
RETURNS TABLE
AS
RETURN
    SELECT
        ClaimKey        = NULLIF(LTRIM(RTRIM(c.ClaimID)), N''),
        PayerName       = n.PayerName,
        PanelName       = n.PanelName,
        ClaimStatus     = LTRIM(RTRIM(c.ClaimStatus)),
        IsBilled        = CAST(CASE WHEN n.FirstBill IS NOT NULL THEN 1 ELSE 0 END AS BIT),
        Adjudicated     = LTRIM(RTRIM(c.Adjudicated)),
        Bucket30        = NULLIF(LTRIM(RTRIM(c.Bucket30)), N''),
        Bucket60        = NULLIF(LTRIM(RTRIM(c.Bucket60)), N''),
        FullyPaid       = NULLIF(LTRIM(RTRIM(c.FullyPaidCount)), N''),
        FullyPaidAmt    = ISNULL(TRY_CAST(c.FullyPaidAmount   AS DECIMAL(18,2)), 0),
        AdjudicatedAmt  = ISNULL(TRY_CAST(c.AdjudicatedAmount AS DECIMAL(18,2)), 0),
        Bucket30Amt     = ISNULL(TRY_CAST(c.Bucket30Amount    AS DECIMAL(18,2)), 0),
        Bucket60Amt     = ISNULL(TRY_CAST(c.Bucket60Amount    AS DECIMAL(18,2)), 0),
        Dos             = n.Dos,
        CheckDt         = n.CheckDt,
        ChargeEnteredDt = n.ChargeEnteredDt,
        DepositWeek     = NULLIF(LTRIM(RTRIM(c.DepositWeek)), N''),
        InsPay          = ISNULL(TRY_CAST(c.InsurancePayment AS DECIMAL(18,2)), 0),
        ChargeAmt       = ISNULL(TRY_CAST(c.ChargeAmount     AS DECIMAL(18,2)), 0),
        PaymentPct      = TRY_CAST(c.PaymentPercent AS DECIMAL(18,6)) * 100,
        InsBalance      = ISNULL(TRY_CAST(c.InsuranceBalance AS DECIMAL(18,2)), 0),
        AgingDOS        = COALESCE(NULLIF(LTRIM(RTRIM(c.Aging)), N''), NULLIF(LTRIM(RTRIM(c.AgingDOS)), N''))
    FROM dbo.ClaimLevelData c
    CROSS APPLY (SELECT
        PayerName       = ISNULL(NULLIF(LTRIM(RTRIM(c.PayerName_Raw)), N''), N'Unknown'),
        PanelName       = ISNULL(NULLIF(LTRIM(RTRIM(c.Panelname)),     N''), N'Unknown'),
        CheckDt         = COALESCE(TRY_CONVERT(DATE, c.CheckDate,         101), TRY_CAST(c.CheckDate         AS DATE)),
        ChargeEnteredDt = COALESCE(TRY_CONVERT(DATE, c.ChargeEnteredDate, 101), TRY_CAST(c.ChargeEnteredDate AS DATE)),
        Dos             = COALESCE(TRY_CONVERT(DATE, c.DateofService,     101), TRY_CAST(c.DateofService     AS DATE)),
        FirstBill       = COALESCE(TRY_CONVERT(DATE, c.FirstBilledDate,   101), TRY_CAST(c.FirstBilledDate   AS DATE))) n
    WHERE (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR n.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
           OR n.PanelName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|')))
      AND (@DosFrom       IS NULL OR n.Dos       >= @DosFrom)
      AND (@DosTo         IS NULL OR n.Dos       <= @DosTo)
      AND (@FirstBillFrom IS NULL OR n.FirstBill >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR n.FirstBill <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR n.CheckDt   >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR n.CheckDt   <= @CheckDateTo);
GO

/* Week-range end of the loaded claim file (LineClaimFileLogs.WeekFolder "MM.DD.YYYY - MM.DD.YYYY");
   the latest CheckDate on or before today when there is no week folder. */
CREATE OR ALTER FUNCTION dbo.fn_PNC_CS_WeekEnd()
RETURNS DATE
AS
BEGIN
    DECLARE @WeekFolder NVARCHAR(200), @WeekEnd DATE;
    SELECT TOP 1 @WeekFolder = LTRIM(RTRIM(CAST(WeekFolder AS NVARCHAR(200))))
    FROM dbo.LineClaimFileLogs
    WHERE NULLIF(LTRIM(RTRIM(CAST(RunId AS NVARCHAR(50)))), '') IS NOT NULL
    ORDER BY FileLogId DESC;

    IF CHARINDEX('-', ISNULL(@WeekFolder, '')) > 0
        SET @WeekEnd = TRY_CONVERT(DATE,
            REPLACE(LTRIM(RTRIM(RIGHT(@WeekFolder, CHARINDEX('-', REVERSE(@WeekFolder)) - 1))), '.', '/'), 101);

    IF @WeekEnd IS NULL
        SELECT @WeekEnd = MAX(TRY_CAST(CheckDate AS DATE))
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(CheckDate AS DATE) <= CAST(GETDATE() AS DATE);

    RETURN @WeekEnd;
END
GO

/* =============================================================================
   Snapshot tables
   ============================================================================= */
DROP TABLE IF EXISTS dbo.PNC_CS2_MonthlyClaimVolume;
CREATE TABLE dbo.PNC_CS2_MonthlyClaimVolume (
    PanelName NVARCHAR(500) NOT NULL, PayerName NVARCHAR(500) NOT NULL, PayerRank INT NOT NULL,
    BillYear INT NOT NULL, BillMonth INT NOT NULL, NoOfClaims INT NOT NULL,
    InsurancePayment DECIMAL(18,2) NOT NULL, AveragePaidAmount DECIMAL(18,2) NULL, SortOrder INT NOT NULL);

DROP TABLE IF EXISTS dbo.PNC_CS2_WeeklyClaimVolume;
CREATE TABLE dbo.PNC_CS2_WeeklyClaimVolume (
    PanelName NVARCHAR(500) NOT NULL, PayerName NVARCHAR(500) NOT NULL, PayerRank INT NOT NULL,
    WeekKey INT NOT NULL, WeekStart DATE NOT NULL, WeekEnd DATE NOT NULL, NoOfClaims INT NOT NULL,
    InsurancePayment DECIMAL(18,2) NOT NULL, AveragePaidAmount DECIMAL(18,2) NULL, SortOrder INT NOT NULL);

DROP TABLE IF EXISTS dbo.PNC_CS2_Top5ReimbursementPct;
CREATE TABLE dbo.PNC_CS2_Top5ReimbursementPct (
    PayerRank INT NOT NULL, PayerName NVARCHAR(500) NOT NULL,
    SumInsurancePayment DECIMAL(18,2) NOT NULL, SumChargeAmount DECIMAL(18,2) NOT NULL,
    UniqueVisitCount INT NOT NULL, AvgPaymentPct DECIMAL(9,2) NOT NULL, TotalPaymentPct DECIMAL(9,2) NOT NULL);

DROP TABLE IF EXISTS dbo.PNC_CS2_Top5ReimbursementPay;
CREATE TABLE dbo.PNC_CS2_Top5ReimbursementPay (
    PayerRank INT NOT NULL, PayerName NVARCHAR(500) NOT NULL,
    TotalPayments DECIMAL(18,2) NOT NULL, UniqueVisitCount INT NOT NULL);

DROP TABLE IF EXISTS dbo.PNC_CS2_InsuranceVsAging;
CREATE TABLE dbo.PNC_CS2_InsuranceVsAging (
    PayerName NVARCHAR(500) NOT NULL, AgingBucket NVARCHAR(50) NOT NULL, VisitCount INT NOT NULL,
    InsuranceBalance DECIMAL(18,2) NOT NULL, SortOrder INT NOT NULL);

DROP TABLE IF EXISTS dbo.PNC_CS2_InsuranceVsPaymentPct;
CREATE TABLE dbo.PNC_CS2_InsuranceVsPaymentPct (
    PayerName NVARCHAR(500) NOT NULL, NoOfClaims INT NOT NULL, InsurancePayment DECIMAL(18,2) NOT NULL,
    AvgPaymentPct DECIMAL(9,2) NOT NULL, TotalPaymentPct DECIMAL(9,2) NOT NULL, SortOrder INT NOT NULL);

DROP TABLE IF EXISTS dbo.PNC_CS2_PanelVsPayment;
CREATE TABLE dbo.PNC_CS2_PanelVsPayment (
    PanelName NVARCHAR(500) NOT NULL, BillYear INT NOT NULL, BillMonth INT NOT NULL,
    BilledClaims INT NOT NULL, BilledCharges DECIMAL(18,2) NOT NULL,
    NoOfClaims INT NOT NULL, InsurancePayments DECIMAL(18,2) NOT NULL, SortOrder INT NOT NULL);

DROP TABLE IF EXISTS dbo.PNC_CS2_InsuranceVsPayment;
CREATE TABLE dbo.PNC_CS2_InsuranceVsPayment (
    PayerName NVARCHAR(500) NOT NULL, BillYear INT NOT NULL, BillMonth INT NOT NULL,
    NoOfPaidClaims INT NOT NULL, InsurancePayment DECIMAL(18,2) NOT NULL, PaymentPct DECIMAL(9,2) NOT NULL,
    TotalPaymentPct DECIMAL(9,2) NOT NULL, SortOrder INT NOT NULL);

DROP TABLE IF EXISTS dbo.PNC_CS2_CptVsPaymentPct;
CREATE TABLE dbo.PNC_CS2_CptVsPaymentPct (
    CPTCode NVARCHAR(500) NOT NULL, SumUnits DECIMAL(18,2) NOT NULL,
    PaidInsurancePayment DECIMAL(18,2) NOT NULL, PaidChargeAmount DECIMAL(18,2) NOT NULL, SortOrder INT NOT NULL);
GO

/* =============================================================================
   1. Monthly (CheckDate month, 2024-01-01 to Week End Date)
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_PNC_CS_MonthlyClaimVolume_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CheckFrom DATE = '20240101';
    DECLARE @CheckTo   DATE = dbo.fn_PNC_CS_WeekEnd();

    WITH agg AS (
        SELECT PanelName, PayerName,
               YEAR(CheckDt)            AS BillYear,
               MONTH(CheckDt)           AS BillMonth,
               COUNT(DISTINCT ClaimKey) AS NoOfClaims,
               SUM(InsPay)              AS InsurancePayment
        FROM dbo.fn_PNC_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
          AND CheckDt BETWEEN @CheckFrom AND @CheckTo
        GROUP BY PanelName, PayerName, YEAR(CheckDt), MONTH(CheckDt)
    ),
    payer AS (
        SELECT PanelName, PayerName,
               SUM(NoOfClaims)       AS PayerClaims,
               SUM(InsurancePayment) AS PayerPay
        FROM agg
        GROUP BY PanelName, PayerName
    ),
    ranked AS (
        SELECT PanelName, PayerName,
               ROW_NUMBER() OVER (PARTITION BY PanelName
                                  ORDER BY PayerClaims DESC, PayerPay DESC, PayerName) AS PayerRank,
               SUM(PayerClaims) OVER (PARTITION BY PanelName)                         AS PanelClaims,
               SUM(PayerPay)    OVER (PARTITION BY PanelName)                         AS PanelPay
        FROM payer
    )
    SELECT a.PanelName,
           a.PayerName,
           CAST(r.PayerRank AS INT)                                            AS PayerRank,
           a.BillYear,
           a.BillMonth,
           a.NoOfClaims,
           CAST(a.InsurancePayment AS DECIMAL(18,2))                           AS InsurancePayment,
           CAST(a.InsurancePayment / NULLIF(a.NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount,
           CAST(ROW_NUMBER() OVER (ORDER BY r.PanelClaims DESC, r.PanelPay DESC, a.PanelName,
                                            r.PayerRank, a.BillYear, a.BillMonth) AS INT) AS SortOrder
    FROM agg a
    JOIN ranked r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   2. Weekly (CheckDate, Wednesday-Tuesday weeks, CheckDate 2024-01-01 to Week End Date)
      Last 4 weeks ending at the latest week that has DepositWeek filled.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_PNC_CS_WeeklyClaimVolume_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- 2026-09-16 was a Wednesday; ((n % 7) + 7) % 7 keeps the offset positive.
    DECLARE @Wednesday DATE = '20260916';
    DECLARE @CheckFrom DATE = '20240101';
    DECLARE @CheckTo   DATE = dbo.fn_PNC_CS_WeekEnd();

    SELECT PanelName, PayerName, ClaimKey, InsPay,
           WeekStart = DATEADD(DAY, -((DATEDIFF(DAY, @Wednesday, CheckDt) % 7 + 7) % 7), CheckDt)
    INTO #paid
    FROM dbo.fn_PNC_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                             @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    WHERE InsPay > 0
      AND CheckDt BETWEEN @CheckFrom AND @CheckTo
      AND DepositWeek IS NOT NULL;

    DECLARE @LastStart  DATE = (SELECT MAX(WeekStart) FROM #paid);
    DECLARE @FirstStart DATE = DATEADD(DAY, -21, @LastStart);

    WITH wk AS (
        SELECT PanelName, PayerName, ClaimKey, InsPay,
               DATEDIFF(DAY, @FirstStart, WeekStart) / 7 + 1 AS WeekKey
        FROM #paid
        WHERE WeekStart BETWEEN @FirstStart AND @LastStart
    ),
    agg AS (
        SELECT PanelName, PayerName, WeekKey,
               COUNT(DISTINCT ClaimKey) AS NoOfClaims,
               SUM(InsPay)              AS InsurancePayment
        FROM wk
        GROUP BY PanelName, PayerName, WeekKey
    ),
    payer AS (
        SELECT PanelName, PayerName,
               SUM(NoOfClaims)       AS PayerClaims,
               SUM(InsurancePayment) AS PayerPay
        FROM agg
        GROUP BY PanelName, PayerName
    ),
    ranked AS (
        SELECT PanelName, PayerName,
               ROW_NUMBER() OVER (PARTITION BY PanelName
                                  ORDER BY PayerClaims DESC, PayerPay DESC, PayerName) AS PayerRank,
               SUM(PayerClaims) OVER (PARTITION BY PanelName)                         AS PanelClaims,
               SUM(PayerPay)    OVER (PARTITION BY PanelName)                         AS PanelPay
        FROM payer
    )
    SELECT a.PanelName,
           a.PayerName,
           CAST(r.PayerRank AS INT)                                            AS PayerRank,
           CAST(a.WeekKey AS INT)                                              AS WeekKey,
           DATEADD(DAY, 7 * (a.WeekKey - 1),     @FirstStart)                  AS WeekStart,
           DATEADD(DAY, 7 * (a.WeekKey - 1) + 6, @FirstStart)                  AS WeekEnd,
           a.NoOfClaims,
           CAST(a.InsurancePayment AS DECIMAL(18,2))                           AS InsurancePayment,
           CAST(a.InsurancePayment / NULLIF(a.NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount,
           CAST(ROW_NUMBER() OVER (ORDER BY r.PanelClaims DESC, r.PanelPay DESC, a.PanelName,
                                            r.PayerRank, a.WeekKey) AS INT)    AS SortOrder
    FROM agg a
    JOIN ranked r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   3. Top 5 Reimbursement % vs Billed Charges
      Top 5 by claim count; TotalPaymentPct = Average(Payment %) over the 5 payers' claims.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_PNC_CS_Top5ReimbursementPct_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH p AS (
        SELECT PayerName,
               COUNT(DISTINCT ClaimKey) AS Claims,
               SUM(InsPay)              AS InsPay,
               SUM(ChargeAmt)           AS Charge,
               AVG(PaymentPct)          AS AvgPct,
               SUM(PaymentPct)          AS PctSum,
               COUNT(PaymentPct)        AS PctCnt
        FROM dbo.fn_PNC_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
        GROUP BY PayerName
    ),
    top5 AS (
        SELECT TOP 5 *
        FROM p
        ORDER BY Claims DESC, InsPay DESC, PayerName
    )
    SELECT CAST(ROW_NUMBER() OVER (ORDER BY Claims DESC, InsPay DESC, PayerName) AS INT) AS PayerRank,
           PayerName,
           CAST(InsPay AS DECIMAL(18,2))                                     AS SumInsurancePayment,
           CAST(Charge AS DECIMAL(18,2))                                     AS SumChargeAmount,
           Claims                                                            AS UniqueVisitCount,
           CAST(ROUND(ISNULL(AvgPct, 0), 2) AS DECIMAL(9,2))                 AS AvgPaymentPct,
           CAST(ROUND(ISNULL(SUM(PctSum) OVER () / NULLIF(SUM(PctCnt) OVER (), 0), 0), 2)
                AS DECIMAL(9,2))                                             AS TotalPaymentPct
    FROM top5
    ORDER BY PayerRank;
END
GO

/* =============================================================================
   4. Top 5 Insurance by Payments (top 5 by claim count; Sum(InsurancePayment))
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_PNC_CS_Top5ReimbursementPay_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH p AS (
        SELECT PayerName,
               COUNT(DISTINCT ClaimKey) AS Claims,
               SUM(InsPay)              AS InsPay
        FROM dbo.fn_PNC_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
        GROUP BY PayerName
    ),
    top5 AS (
        SELECT TOP 5 *
        FROM p
        ORDER BY Claims DESC, InsPay DESC, PayerName
    )
    SELECT CAST(ROW_NUMBER() OVER (ORDER BY Claims DESC, InsPay DESC, PayerName) AS INT) AS PayerRank,
           PayerName,
           CAST(InsPay AS DECIMAL(18,2)) AS TotalPayments,
           Claims                        AS UniqueVisitCount
    FROM top5
    ORDER BY PayerRank;
END
GO

/* =============================================================================
   Panel Averages - by DOS / by Check Date (Average Payments tabs)
   Every claim (the client pivot has no billed filter).
     DOS        : DateofService in the @LastMonths months ending at Week End Date
                  (11.04.2026 - 11.10.2026 -> 2026-05-11 .. 2026-11-10)
     Check Date : CheckDate in the @LastMonths calendar months ending with the Week End
                  Date's month (Week End 2026-11-10 -> 2026-06-01 .. 2026-11-30)
   Returns every payer; the page shows panel totals plus the top 3 payers.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_GetPNC_CS_AvgPayments_ClientLogic
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL,
    @DateBasis       VARCHAR(10)   = 'DOS',
    @LastMonths      INT           = 6
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @UseCheckDate BIT = CASE WHEN @DateBasis = 'CheckDate' THEN 1 ELSE 0 END;
    IF @LastMonths IS NULL OR @LastMonths < 1 SET @LastMonths = 6;

    DECLARE @WeekEnd DATE = dbo.fn_PNC_CS_WeekEnd();

    SELECT PanelName, PayerName, ClaimKey, ChargeAmt, InsPay, FullyPaid, FullyPaidAmt,
           Adjudicated, AdjudicatedAmt, Bucket30, Bucket30Amt, Bucket60, Bucket60Amt,
           BasisDt = CASE WHEN @UseCheckDate = 1 THEN CheckDt ELSE Dos END
    INTO #b
    FROM dbo.fn_PNC_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                             @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo);

    DECLARE @WindowTo DATE, @WindowFrom DATE;
    IF @UseCheckDate = 1
    BEGIN
        SET @WindowTo   = EOMONTH(@WeekEnd);
        SET @WindowFrom = DATEADD(MONTH, 1 - @LastMonths, DATEFROMPARTS(YEAR(@WeekEnd), MONTH(@WeekEnd), 1));
    END
    ELSE
    BEGIN
        SET @WindowTo   = @WeekEnd;
        SET @WindowFrom = DATEADD(DAY, 1, DATEADD(MONTH, -@LastMonths, @WeekEnd));
    END;

    SELECT PanelName,
           PayerName,
           CAST(COUNT(DISTINCT ClaimKey) AS INT)                                                        AS NoOfClaims,
           CAST(ISNULL(SUM(ChargeAmt), 0) AS DECIMAL(18,2))                                             AS TotalCharges,
           CAST(ISNULL(SUM(InsPay), 0) AS DECIMAL(18,2))                                                AS CarrierPayment,
           CAST(COUNT(DISTINCT CASE WHEN FullyPaid = N'Fully Paid' THEN ClaimKey END) AS INT)           AS FullyPaidCount,
           CAST(ISNULL(SUM(CASE WHEN FullyPaid = N'Fully Paid' THEN FullyPaidAmt END), 0) AS DECIMAL(18,2)) AS FullyPaidAmount,
           CAST(COUNT(DISTINCT CASE WHEN Adjudicated IS NOT NULL THEN ClaimKey END) AS INT)             AS AdjudicatedCount,
           CAST(ISNULL(SUM(CASE WHEN Adjudicated IS NOT NULL THEN AdjudicatedAmt END), 0) AS DECIMAL(18,2)) AS AdjudicatedAmount,
           CAST(COUNT(DISTINCT CASE WHEN Bucket30 IS NOT NULL THEN ClaimKey END) AS INT)                AS Days30Count,
           CAST(ISNULL(SUM(CASE WHEN Bucket30 IS NOT NULL THEN Bucket30Amt END), 0) AS DECIMAL(18,2))   AS Days30Amount,
           CAST(COUNT(DISTINCT CASE WHEN Bucket60 IS NOT NULL THEN ClaimKey END) AS INT)                AS Days60Count,
           CAST(ISNULL(SUM(CASE WHEN Bucket60 IS NOT NULL THEN Bucket60Amt END), 0) AS DECIMAL(18,2))   AS Days60Amount,
           @WindowFrom                                                                                  AS WindowFrom,
           @WindowTo                                                                                    AS WindowTo
    FROM #b
    WHERE BasisDt BETWEEN @WindowFrom AND @WindowTo
    GROUP BY PanelName, PayerName
    ORDER BY PanelName, NoOfClaims DESC, PayerName;
END
GO

/* =============================================================================
   5. No Response Vs Aging (ClaimStatus = No Response; Aging, AgingDOS when Aging is blank)
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_PNC_CS_InsuranceVsAging_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH agg AS (
        SELECT PayerName,
               ISNULL(AgingDOS, N'(blank)') AS AgingBucket,
               COUNT(DISTINCT ClaimKey)     AS VisitCount,
               SUM(InsBalance)              AS InsuranceBalance
        FROM dbo.fn_PNC_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE ClaimStatus = N'No Response'
        GROUP BY PayerName, ISNULL(AgingDOS, N'(blank)')
    ),
    payer AS (
        SELECT PayerName,
               SUM(VisitCount)       AS PayerClaims,
               SUM(InsuranceBalance) AS PayerBalance
        FROM agg
        GROUP BY PayerName
    )
    SELECT a.PayerName,
           a.AgingBucket,
           a.VisitCount,
           CAST(a.InsuranceBalance AS DECIMAL(18,2)) AS InsuranceBalance,
           CAST(ROW_NUMBER() OVER (ORDER BY p.PayerClaims DESC, p.PayerBalance DESC, a.PayerName,
                CASE a.AgingBucket WHEN N'Current' THEN 1 WHEN N'30+' THEN 2 WHEN N'60+' THEN 3
                                   WHEN N'90+' THEN 4 WHEN N'120+' THEN 5 ELSE 6 END) AS INT) AS SortOrder
    FROM agg a
    JOIN payer p ON p.PayerName = a.PayerName
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   6. Insurance vs Payment % (InsurancePayment > 0; sorted by claim count)
      TotalPaymentPct = Average(Payment %) over every claim in the result.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_PNC_CS_InsuranceVsPaymentPct_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH p AS (
        SELECT PayerName,
               COUNT(DISTINCT ClaimKey) AS NoOfClaims,
               SUM(InsPay)              AS InsurancePayment,
               AVG(PaymentPct)          AS AvgPct,
               SUM(PaymentPct)          AS PctSum,
               COUNT(PaymentPct)        AS PctCnt
        FROM dbo.fn_PNC_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
        GROUP BY PayerName
    )
    SELECT PayerName,
           NoOfClaims,
           CAST(InsurancePayment AS DECIMAL(18,2))           AS InsurancePayment,
           CAST(ROUND(ISNULL(AvgPct, 0), 2) AS DECIMAL(9,2)) AS AvgPaymentPct,
           CAST(ROUND(ISNULL(SUM(PctSum) OVER () / NULLIF(SUM(PctCnt) OVER (), 0), 0), 2)
                AS DECIMAL(9,2))                             AS TotalPaymentPct,
           CAST(ROW_NUMBER() OVER (ORDER BY NoOfClaims DESC, InsurancePayment DESC, PayerName) AS INT) AS SortOrder
    FROM p
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   7. Panel Vs Payment (ChargeEnteredDate month)
      Filter: InsurancePayment > 0 AND CheckDate 2024-01-01 to Week End Date
      Billed: FirstBilledDate is a date -> claim count, Sum(ChargeAmount)
      Paid:   InsurancePayment > 0      -> claim count, Sum(InsurancePayment)
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_PNC_CS_PanelVsPayment_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CheckFrom DATE = '20240101';
    DECLARE @CheckTo   DATE = dbo.fn_PNC_CS_WeekEnd();

    WITH base AS (
        SELECT PanelName, ClaimKey, ChargeAmt, InsPay,
               IsBilledClaim = CASE WHEN IsBilled = 1 THEN 1 ELSE 0 END,
               IsPaidClaim   = CASE WHEN InsPay > 0 THEN 1 ELSE 0 END,
               BillYear      = YEAR(ChargeEnteredDt),
               BillMonth     = MONTH(ChargeEnteredDt)
        FROM dbo.fn_PNC_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE ChargeEnteredDt IS NOT NULL
          AND InsPay > 0
          AND CheckDt BETWEEN @CheckFrom AND @CheckTo
    ),
    agg AS (
        SELECT PanelName, BillYear, BillMonth,
               COUNT(DISTINCT CASE WHEN IsBilledClaim = 1 THEN ClaimKey END) AS BilledClaims,
               SUM(CASE WHEN IsBilledClaim = 1 THEN ChargeAmt ELSE 0 END)    AS BilledCharges,
               COUNT(DISTINCT CASE WHEN IsPaidClaim = 1 THEN ClaimKey END)   AS PaidClaims,
               SUM(CASE WHEN IsPaidClaim = 1 THEN InsPay ELSE 0 END)         AS InsurancePayments
        FROM base
        WHERE IsBilledClaim = 1 OR IsPaidClaim = 1
        GROUP BY PanelName, BillYear, BillMonth
    ),
    panel AS (
        SELECT PanelName,
               SUM(BilledClaims) AS PanelBilled,
               SUM(PaidClaims)   AS PanelPaid
        FROM agg
        GROUP BY PanelName
    )
    SELECT a.PanelName,
           a.BillYear,
           a.BillMonth,
           a.BilledClaims,
           CAST(a.BilledCharges AS DECIMAL(18,2))     AS BilledCharges,
           a.PaidClaims                               AS NoOfClaims,
           CAST(a.InsurancePayments AS DECIMAL(18,2)) AS InsurancePayments,
           CAST(ROW_NUMBER() OVER (ORDER BY p.PanelBilled DESC, p.PanelPaid DESC,
                                            a.PanelName, a.BillYear, a.BillMonth) AS INT) AS SortOrder
    FROM agg a
    JOIN panel p ON p.PanelName = a.PanelName
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   8. Insurance vs Payment (InsurancePayment > 0; payer totals; sorted by claim count)
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_PNC_CS_InsuranceVsPayment_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH p AS (
        SELECT PayerName,
               COUNT(DISTINCT ClaimKey) AS NoOfPaidClaims,
               SUM(InsPay)              AS InsurancePayment,
               AVG(PaymentPct)          AS AvgPct,
               SUM(PaymentPct)          AS PctSum,
               COUNT(PaymentPct)        AS PctCnt
        FROM dbo.fn_PNC_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
        GROUP BY PayerName
    )
    SELECT PayerName,
           0                                                 AS BillYear,
           0                                                 AS BillMonth,
           NoOfPaidClaims,
           CAST(InsurancePayment AS DECIMAL(18,2))           AS InsurancePayment,
           CAST(ROUND(ISNULL(AvgPct, 0), 2) AS DECIMAL(9,2)) AS PaymentPct,
           CAST(ROUND(ISNULL(SUM(PctSum) OVER () / NULLIF(SUM(PctCnt) OVER (), 0), 0), 2)
                AS DECIMAL(9,2))                             AS TotalPaymentPct,
           CAST(ROW_NUMBER() OVER (ORDER BY NoOfPaidClaims DESC, InsurancePayment DESC, PayerName) AS INT) AS SortOrder
    FROM p
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   9. CPT vs Payment (Line Level Data; line InsurancePayment > 0)
      Sum(Units), Sum(InsurancePayment); sorted by units. Dashboard filters apply
      through the line's claim.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_PNC_CS_CptVsPaymentPct_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT = dbo.fn_PNC_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                                    @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo);

    CREATE TABLE #k (ClaimKey NVARCHAR(450) NOT NULL PRIMARY KEY);
    IF @HasFilter = 1
        INSERT INTO #k (ClaimKey)
        SELECT DISTINCT LEFT(ClaimKey, 450)
        FROM dbo.fn_PNC_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE ClaimKey IS NOT NULL;

    WITH l AS (
        SELECT CPTCode   = LTRIM(RTRIM(l.CPTCode)),
               Units     = ISNULL(TRY_CAST(l.Units            AS DECIMAL(18,2)), 0),
               InsPay    = ISNULL(TRY_CAST(l.InsurancePayment AS DECIMAL(18,2)), 0),
               ChargeAmt = ISNULL(TRY_CAST(l.ChargeAmount     AS DECIMAL(18,2)), 0)
        FROM dbo.LineLevelData l
        WHERE NULLIF(LTRIM(RTRIM(l.CPTCode)), N'') IS NOT NULL
          AND (@HasFilter = 0
               OR EXISTS (SELECT 1 FROM #k k WHERE k.ClaimKey = LEFT(LTRIM(RTRIM(l.ClaimID)), 450)))
    )
    SELECT CAST(CPTCode AS NVARCHAR(500))                  AS CPTCode,
           CAST(SUM(Units) AS DECIMAL(18,2))               AS SumUnits,
           CAST(SUM(InsPay) AS DECIMAL(18,2))              AS PaidInsurancePayment,
           CAST(SUM(ChargeAmt) AS DECIMAL(18,2))           AS PaidChargeAmount,
           CAST(ROW_NUMBER() OVER (ORDER BY SUM(Units) DESC, SUM(InsPay) DESC, CPTCode) AS INT) AS SortOrder
    FROM l
    WHERE InsPay > 0
    GROUP BY CPTCode
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   Read SPs: snapshot when no filter and the snapshot has rows, else live compute.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_GetPNC_CS_MonthlyClaimVolume
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_PNC_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.PNC_CS2_MonthlyClaimVolume)
    BEGIN
        SELECT PanelName, PayerName, PayerRank, BillYear, BillMonth, NoOfClaims,
               InsurancePayment, AveragePaidAmount, SortOrder
        FROM dbo.PNC_CS2_MonthlyClaimVolume
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_PNC_CS_MonthlyClaimVolume_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPNC_CS_WeeklyClaimVolume
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_PNC_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.PNC_CS2_WeeklyClaimVolume)
    BEGIN
        SELECT PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims,
               InsurancePayment, AveragePaidAmount, SortOrder
        FROM dbo.PNC_CS2_WeeklyClaimVolume
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_PNC_CS_WeeklyClaimVolume_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPNC_CS_Top5ReimbursementPct
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_PNC_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.PNC_CS2_Top5ReimbursementPct)
    BEGIN
        SELECT PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount,
               AvgPaymentPct, TotalPaymentPct
        FROM dbo.PNC_CS2_Top5ReimbursementPct
        ORDER BY PayerRank;
        RETURN;
    END;

    EXEC dbo.usp_PNC_CS_Top5ReimbursementPct_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPNC_CS_Top5ReimbursementPay
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_PNC_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.PNC_CS2_Top5ReimbursementPay)
    BEGIN
        SELECT PayerRank, PayerName, TotalPayments, UniqueVisitCount
        FROM dbo.PNC_CS2_Top5ReimbursementPay
        ORDER BY PayerRank;
        RETURN;
    END;

    EXEC dbo.usp_PNC_CS_Top5ReimbursementPay_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPNC_CS_InsuranceVsAging
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_PNC_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.PNC_CS2_InsuranceVsAging)
    BEGIN
        SELECT PayerName, AgingBucket, VisitCount, InsuranceBalance, SortOrder
        FROM dbo.PNC_CS2_InsuranceVsAging
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_PNC_CS_InsuranceVsAging_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPNC_CS_InsuranceVsPaymentPct
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_PNC_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.PNC_CS2_InsuranceVsPaymentPct)
    BEGIN
        SELECT PayerName, NoOfClaims, InsurancePayment, AvgPaymentPct, TotalPaymentPct, SortOrder
        FROM dbo.PNC_CS2_InsuranceVsPaymentPct
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_PNC_CS_InsuranceVsPaymentPct_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPNC_CS_PanelVsPayment
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_PNC_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.PNC_CS2_PanelVsPayment)
    BEGIN
        SELECT PanelName, BillYear, BillMonth, BilledClaims, BilledCharges,
               NoOfClaims, InsurancePayments, SortOrder
        FROM dbo.PNC_CS2_PanelVsPayment
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_PNC_CS_PanelVsPayment_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPNC_CS_InsuranceVsPayment
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_PNC_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.PNC_CS2_InsuranceVsPayment)
    BEGIN
        SELECT PayerName, BillYear, BillMonth, NoOfPaidClaims, InsurancePayment, PaymentPct, TotalPaymentPct, SortOrder
        FROM dbo.PNC_CS2_InsuranceVsPayment
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_PNC_CS_InsuranceVsPayment_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPNC_CS_CptVsPaymentPct
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_PNC_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.PNC_CS2_CptVsPaymentPct)
    BEGIN
        SELECT CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, SortOrder
        FROM dbo.PNC_CS2_CptVsPaymentPct
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_PNC_CS_CptVsPaymentPct_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

/* =============================================================================
   Refresh SPs (run after claim-file ingest)
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPNC_CS_MonthlyClaimVolume
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.PNC_CS2_MonthlyClaimVolume;
    INSERT INTO dbo.PNC_CS2_MonthlyClaimVolume
        (PanelName, PayerName, PayerRank, BillYear, BillMonth, NoOfClaims, InsurancePayment, AveragePaidAmount, SortOrder)
    EXEC dbo.usp_PNC_CS_MonthlyClaimVolume_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPNC_CS_WeeklyClaimVolume
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.PNC_CS2_WeeklyClaimVolume;
    INSERT INTO dbo.PNC_CS2_WeeklyClaimVolume
        (PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment, AveragePaidAmount, SortOrder)
    EXEC dbo.usp_PNC_CS_WeeklyClaimVolume_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPNC_CS_Top5ReimbursementPct
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.PNC_CS2_Top5ReimbursementPct;
    INSERT INTO dbo.PNC_CS2_Top5ReimbursementPct
        (PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount, AvgPaymentPct, TotalPaymentPct)
    EXEC dbo.usp_PNC_CS_Top5ReimbursementPct_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPNC_CS_Top5ReimbursementPay
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.PNC_CS2_Top5ReimbursementPay;
    INSERT INTO dbo.PNC_CS2_Top5ReimbursementPay (PayerRank, PayerName, TotalPayments, UniqueVisitCount)
    EXEC dbo.usp_PNC_CS_Top5ReimbursementPay_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPNC_CS_InsuranceVsAging
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.PNC_CS2_InsuranceVsAging;
    INSERT INTO dbo.PNC_CS2_InsuranceVsAging (PayerName, AgingBucket, VisitCount, InsuranceBalance, SortOrder)
    EXEC dbo.usp_PNC_CS_InsuranceVsAging_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPNC_CS_InsuranceVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.PNC_CS2_InsuranceVsPaymentPct;
    INSERT INTO dbo.PNC_CS2_InsuranceVsPaymentPct
        (PayerName, NoOfClaims, InsurancePayment, AvgPaymentPct, TotalPaymentPct, SortOrder)
    EXEC dbo.usp_PNC_CS_InsuranceVsPaymentPct_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPNC_CS_PanelVsPayment
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.PNC_CS2_PanelVsPayment;
    INSERT INTO dbo.PNC_CS2_PanelVsPayment
        (PanelName, BillYear, BillMonth, BilledClaims, BilledCharges, NoOfClaims, InsurancePayments, SortOrder)
    EXEC dbo.usp_PNC_CS_PanelVsPayment_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPNC_CS_InsuranceVsPayment
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.PNC_CS2_InsuranceVsPayment;
    INSERT INTO dbo.PNC_CS2_InsuranceVsPayment
        (PayerName, BillYear, BillMonth, NoOfPaidClaims, InsurancePayment, PaymentPct, TotalPaymentPct, SortOrder)
    EXEC dbo.usp_PNC_CS_InsuranceVsPayment_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPNC_CS_CptVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.PNC_CS2_CptVsPaymentPct;
    INSERT INTO dbo.PNC_CS2_CptVsPaymentPct (CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, SortOrder)
    EXEC dbo.usp_PNC_CS_CptVsPaymentPct_Compute;
    COMMIT;
END
GO

/* =============================================================================
   Build the no-filter snapshots
   ============================================================================= */
EXEC dbo.usp_RefreshPNC_CS_MonthlyClaimVolume;
EXEC dbo.usp_RefreshPNC_CS_WeeklyClaimVolume;
EXEC dbo.usp_RefreshPNC_CS_Top5ReimbursementPct;
EXEC dbo.usp_RefreshPNC_CS_Top5ReimbursementPay;
EXEC dbo.usp_RefreshPNC_CS_InsuranceVsAging;
EXEC dbo.usp_RefreshPNC_CS_InsuranceVsPaymentPct;
EXEC dbo.usp_RefreshPNC_CS_PanelVsPayment;
EXEC dbo.usp_RefreshPNC_CS_InsuranceVsPayment;
EXEC dbo.usp_RefreshPNC_CS_CptVsPaymentPct;
GO

PRINT '12_PNC_CollectionSummary.sql completed.';
GO
