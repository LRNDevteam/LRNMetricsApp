/* =============================================================================
   WellHealth - Collection Summary (SP-only logic, Analyze Pathology pattern)

   Every calculation, ranking, total and row order is done here. The dashboard
   and Excel export read usp_GetWH_CS_* and keep the SP row order.

     fn_WH_CS_Claims        claim-level base + dashboard filters
     usp_WH_CS_{X}_Compute  the logic (live, honours filters)
     WH_CS2_{X}             no-filter snapshot
     usp_GetWH_CS_{X}       snapshot when unfiltered, else compute
     usp_RefreshWH_CS_{X}   rebuilds the snapshot (claim-file ingest)

   Client requirement (Claim Level Data unless noted):
     1  Monthly Summary        InsurancePayment <> 0; Panel + top 3 insurance by claim count;
                               Posted Date month; sorted by Insurance Payment
     2  Weekly Summary         same as Monthly; Posted Date Mon-Sun weeks
     3  Top 5 Reimbursement %  InsurancePayment > 0; top 5 insurance by claim count;
                               Average(Payment %); sorted by Insurance Payment
     4  Top 5 Insurance by Payments  InsurancePayment > 0; top 5 by Total Payment
     5  Panel Averages         by DOS / by Check Date: FirstBilledDate not blank; 6 months ending at
                               the billed week-range end date. The Panel Average tab is not shown.
     6  Insurance vs Payment % InsurancePayment > 0; sorted by Insurance Payment
     7  Total Insurance Payment InsurancePayment > 0; sorted by Total Payment
     8  Insurance vs Aging     Charge Balance Due Ins (InsuranceBalance) > 0; Aging DOS
     9  Panel Vs Payment       InsurancePayment > 0 AND CheckDate not blank; CheckDate month
    10  CPT vs Payment %       Line Level Data; no filter; sorted by claim count

   "Posted Date" = PaymentPostedDate (dashboard Check Date filter applies to it);
   "Check Date"  = CheckDate.
   ============================================================================= */
SET NOCOUNT ON;
GO

/* =============================================================================
   Helpers
   ============================================================================= */
CREATE OR ALTER FUNCTION dbo.fn_WH_CS_HasFilter
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

CREATE OR ALTER FUNCTION dbo.fn_WH_CS_Claims
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
        ClaimKey          = NULLIF(LTRIM(RTRIM(c.ClaimID)), N''),
        PayerName         = n.PayerName,
        PanelName         = n.PanelName,
        ClaimStatus       = LTRIM(RTRIM(c.ClaimStatus)),
        BilledStatus      = LTRIM(RTRIM(c.BilledStatus)),
        FirstBilledDate   = NULLIF(LTRIM(RTRIM(c.FirstBilledDate)), N''),
        Adjudicated       = LTRIM(RTRIM(c.Adjudicated)),
        Bucket30          = LTRIM(RTRIM(c.Bucket30)),
        Bucket60          = LTRIM(RTRIM(c.Bucket60)),
        Dos               = n.Dos,
        PostedDt          = n.PostedDt,
        CheckDt           = n.CheckDt,
        InsPay            = ISNULL(TRY_CAST(c.InsurancePayment AS DECIMAL(18,2)), 0),
        TotalPay          = ISNULL(TRY_CAST(c.TotalPayments    AS DECIMAL(18,2)), 0),
        ChargeAmt         = ISNULL(TRY_CAST(c.ChargeAmount     AS DECIMAL(18,2)), 0),
        PaymentPct        = TRY_CAST(c.PaymentPercent AS DECIMAL(18,6)) * 100,
        InsBalance        = ISNULL(TRY_CAST(c.InsuranceBalance AS DECIMAL(18,2)), 0),
        PatientBalance    = ISNULL(TRY_CAST(c.PatientBalance   AS DECIMAL(18,2)), 0),
        AgingDOS          = NULLIF(LTRIM(RTRIM(c.AgingDOS)), N''),
        CptCode           = ISNULL(NULLIF(LTRIM(RTRIM(c.CPTCodeXUnitsXModifier)), N''), N'(blank)'),
        ReferringProvider = NULLIF(LTRIM(RTRIM(c.ReferringProvider)), N''),
        SalesRep          = NULLIF(LTRIM(RTRIM(c.SalesRepname)), N'')
    FROM dbo.ClaimLevelData c
    CROSS APPLY (SELECT
        PayerName = ISNULL(NULLIF(LTRIM(RTRIM(c.PayerName_Raw)), N''), N'Unknown'),
        PanelName = ISNULL(NULLIF(LTRIM(RTRIM(c.Panelname)),     N''), N'Unknown'),
        PostedDt  = COALESCE(TRY_CONVERT(DATE, c.PaymentPostedDate, 101), TRY_CAST(c.PaymentPostedDate AS DATE)),
        CheckDt   = COALESCE(TRY_CONVERT(DATE, c.CheckDate,         101), TRY_CAST(c.CheckDate         AS DATE)),
        Dos       = COALESCE(TRY_CONVERT(DATE, c.DateofService,     101), TRY_CAST(c.DateofService     AS DATE)),
        FirstBill = COALESCE(TRY_CONVERT(DATE, c.FirstBilledDate,   101), TRY_CAST(c.FirstBilledDate   AS DATE))) n
    WHERE (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR n.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
           OR n.PanelName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|')))
      AND (@DosFrom       IS NULL OR n.Dos       >= @DosFrom)
      AND (@DosTo         IS NULL OR n.Dos       <= @DosTo)
      AND (@FirstBillFrom IS NULL OR n.FirstBill >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR n.FirstBill <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR n.PostedDt  >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR n.PostedDt  <= @CheckDateTo);
GO

/* =============================================================================
   Snapshot tables
   ============================================================================= */
DROP TABLE IF EXISTS dbo.WH_CS2_MonthlyClaimVolume;
CREATE TABLE dbo.WH_CS2_MonthlyClaimVolume (
    PanelName NVARCHAR(500) NOT NULL, PayerName NVARCHAR(500) NOT NULL, PayerRank INT NOT NULL,
    BillYear INT NOT NULL, BillMonth INT NOT NULL, NoOfClaims INT NOT NULL,
    InsurancePayment DECIMAL(18,2) NOT NULL, AveragePaidAmount DECIMAL(18,2) NULL, SortOrder INT NOT NULL);

DROP TABLE IF EXISTS dbo.WH_CS2_WeeklyClaimVolume;
CREATE TABLE dbo.WH_CS2_WeeklyClaimVolume (
    PanelName NVARCHAR(500) NOT NULL, PayerName NVARCHAR(500) NOT NULL, PayerRank INT NOT NULL,
    WeekKey INT NOT NULL, WeekStart DATE NOT NULL, WeekEnd DATE NOT NULL, NoOfClaims INT NOT NULL,
    InsurancePayment DECIMAL(18,2) NOT NULL, AveragePaidAmount DECIMAL(18,2) NULL, SortOrder INT NOT NULL);

DROP TABLE IF EXISTS dbo.WH_CS2_Top5ReimbursementPct;
CREATE TABLE dbo.WH_CS2_Top5ReimbursementPct (
    PayerRank INT NOT NULL, PayerName NVARCHAR(500) NOT NULL,
    SumInsurancePayment DECIMAL(18,2) NOT NULL, SumChargeAmount DECIMAL(18,2) NOT NULL,
    UniqueVisitCount INT NOT NULL, AvgPaymentPct DECIMAL(9,2) NOT NULL, TotalPaymentPct DECIMAL(9,2) NOT NULL);

DROP TABLE IF EXISTS dbo.WH_CS2_Top5ReimbursementPay;
CREATE TABLE dbo.WH_CS2_Top5ReimbursementPay (
    PayerRank INT NOT NULL, PayerName NVARCHAR(500) NOT NULL,
    TotalPayments DECIMAL(18,2) NOT NULL, UniqueVisitCount INT NOT NULL);

DROP TABLE IF EXISTS dbo.WH_CS2_PanelAverages;
CREATE TABLE dbo.WH_CS2_PanelAverages (
    RowType CHAR(1) NOT NULL, PanelName NVARCHAR(500) NOT NULL, PayerName NVARCHAR(500) NOT NULL, PayerRank INT NOT NULL,
    NoOfClaims INT NOT NULL, TotalCharges DECIMAL(18,2) NOT NULL, AvgBilled DECIMAL(18,2) NOT NULL, CarrierPayment DECIMAL(18,2) NOT NULL,
    FullyPaidCount INT NOT NULL, FullyPaidAmount DECIMAL(18,2) NOT NULL, AvgFullyPaid DECIMAL(18,2) NOT NULL,
    AdjudicatedCount INT NOT NULL, AdjudicatedAmount DECIMAL(18,2) NOT NULL, AvgAdjudicated DECIMAL(18,2) NOT NULL,
    Days30Count INT NOT NULL, Days30Amount DECIMAL(18,2) NOT NULL, AvgDays30 DECIMAL(18,2) NOT NULL,
    Days60Count INT NOT NULL, Days60Amount DECIMAL(18,2) NOT NULL, AvgDays60 DECIMAL(18,2) NOT NULL,
    SortOrder INT NOT NULL);

DROP TABLE IF EXISTS dbo.WH_CS2_InsuranceVsPaymentPct;
CREATE TABLE dbo.WH_CS2_InsuranceVsPaymentPct (
    PayerName NVARCHAR(500) NOT NULL, NoOfClaims INT NOT NULL, InsurancePayment DECIMAL(18,2) NOT NULL,
    AvgPaymentPct DECIMAL(9,2) NOT NULL, TotalPaymentPct DECIMAL(9,2) NOT NULL, SortOrder INT NOT NULL);

DROP TABLE IF EXISTS dbo.WH_CS2_InsuranceVsPayment;
CREATE TABLE dbo.WH_CS2_InsuranceVsPayment (
    PayerName NVARCHAR(500) NOT NULL, BillYear INT NOT NULL, BillMonth INT NOT NULL,
    NoOfPaidClaims INT NOT NULL, InsurancePayment DECIMAL(18,2) NOT NULL, PaymentPct DECIMAL(9,2) NOT NULL,
    TotalPaymentPct DECIMAL(9,2) NOT NULL, SortOrder INT NOT NULL);

DROP TABLE IF EXISTS dbo.WH_CS2_InsuranceVsAging;
CREATE TABLE dbo.WH_CS2_InsuranceVsAging (
    PayerName NVARCHAR(500) NOT NULL, AgingBucket NVARCHAR(50) NOT NULL, VisitCount INT NOT NULL,
    InsuranceBalance DECIMAL(18,2) NOT NULL, SortOrder INT NOT NULL);

DROP TABLE IF EXISTS dbo.WH_CS2_PanelVsPayment;
CREATE TABLE dbo.WH_CS2_PanelVsPayment (
    PanelName NVARCHAR(500) NOT NULL, BillYear INT NOT NULL, BillMonth INT NOT NULL,
    NoOfClaims INT NOT NULL, InsurancePayments DECIMAL(18,2) NOT NULL, SortOrder INT NOT NULL);

DROP TABLE IF EXISTS dbo.WH_CS2_CptVsPaymentPct;
CREATE TABLE dbo.WH_CS2_CptVsPaymentPct (
    RowType CHAR(1) NOT NULL, PanelName NVARCHAR(500) NULL, CPTCode NVARCHAR(500) NULL, NoOfClaims INT NOT NULL,
    AvgPaymentPct DECIMAL(9,2) NOT NULL, TotalPaymentPct DECIMAL(9,2) NOT NULL, SortOrder INT NOT NULL);

DROP TABLE IF EXISTS dbo.WH_CS2_StatusSummary;
CREATE TABLE dbo.WH_CS2_StatusSummary (
    ClaimStatus NVARCHAR(200) NOT NULL, PanelName NVARCHAR(500) NOT NULL, CptCode NVARCHAR(1000) NOT NULL,
    PayerName NVARCHAR(500) NOT NULL, NoOfClaims INT NOT NULL, InsurancePayment DECIMAL(18,2) NOT NULL,
    InsuranceBalance DECIMAL(18,2) NOT NULL, PatientBalance DECIMAL(18,2) NOT NULL, SortOrder INT NOT NULL);

DROP TABLE IF EXISTS dbo.WH_CS2_ProviderSummary;
CREATE TABLE dbo.WH_CS2_ProviderSummary (
    ProviderRank INT NOT NULL, ReferringProvider NVARCHAR(500) NOT NULL, NoOfClaims INT NOT NULL,
    InsurancePayments DECIMAL(18,2) NOT NULL, InsuranceBalance DECIMAL(18,2) NOT NULL, PatientBalance DECIMAL(18,2) NOT NULL);

DROP TABLE IF EXISTS dbo.WH_CS2_RepVsPayment;
CREATE TABLE dbo.WH_CS2_RepVsPayment (
    SalesRepName NVARCHAR(500) NOT NULL, CheckYear INT NOT NULL, CheckMonth INT NOT NULL,
    NoOfClaims INT NOT NULL, InsurancePayment DECIMAL(18,2) NOT NULL, SortOrder INT NOT NULL);
GO

/* =============================================================================
   1. Monthly Summary (Posted Date month)
      Panels sorted by Insurance Payment; payers ranked by claim count (top 3 shown).
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_WH_CS_MonthlyClaimVolume_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH agg AS (
        SELECT PanelName, PayerName,
               YEAR(PostedDt)           AS BillYear,
               MONTH(PostedDt)          AS BillMonth,
               COUNT(DISTINCT ClaimKey) AS NoOfClaims,
               SUM(InsPay)              AS InsurancePayment
        FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay <> 0
          AND PostedDt IS NOT NULL
        GROUP BY PanelName, PayerName, YEAR(PostedDt), MONTH(PostedDt)
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
           CAST(ROW_NUMBER() OVER (ORDER BY r.PanelPay DESC, r.PanelClaims DESC, a.PanelName,
                                            r.PayerRank, a.BillYear, a.BillMonth) AS INT) AS SortOrder
    FROM agg a
    JOIN ranked r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   2. Weekly Summary (Posted Date, Monday-Sunday weeks,
      last 4 completed weeks up to the latest Posted Date on or before today)
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_WH_CS_WeeklyClaimVolume_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);

    SELECT PanelName, PayerName, ClaimKey, PostedDt, InsPay
    INTO #paid
    FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                             @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    WHERE InsPay <> 0
      AND PostedDt IS NOT NULL
      AND PostedDt <= @Today;

    -- A week counts as completed when it ends on or before today and the Posted Date-To filter.
    DECLARE @Cutoff DATE = CASE WHEN @CheckDateTo < @Today THEN @CheckDateTo ELSE @Today END;
    DECLARE @MaxPosted DATE = (SELECT MAX(PostedDt) FROM #paid);
    -- 1900-01-01 was a Monday.
    DECLARE @LastStart DATE = DATEADD(DAY, -(DATEDIFF(DAY, '19000101', @MaxPosted) % 7), @MaxPosted);
    IF DATEADD(DAY, 6, @LastStart) > @Cutoff
        SET @LastStart = DATEADD(DAY, -7, @LastStart);
    DECLARE @FirstStart DATE = DATEADD(DAY, -21, @LastStart);
    DECLARE @LastEnd    DATE = DATEADD(DAY, 6, @LastStart);

    WITH wk AS (
        SELECT PanelName, PayerName, ClaimKey, InsPay,
               DATEDIFF(DAY, @FirstStart, PostedDt) / 7 + 1 AS WeekKey
        FROM #paid
        WHERE PostedDt BETWEEN @FirstStart AND @LastEnd
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
           CAST(ROW_NUMBER() OVER (ORDER BY r.PanelPay DESC, r.PanelClaims DESC, a.PanelName,
                                            r.PayerRank, a.WeekKey) AS INT)    AS SortOrder
    FROM agg a
    JOIN ranked r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   3. Top 5 Reimbursement % vs Billed Charges
      Top 5 insurance by claim count (InsurancePayment > 0), listed by Insurance Payment.
      TotalPaymentPct = Average(Payment %) over every claim of the 5 payers.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_WH_CS_Top5ReimbursementPct_Compute
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
        FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
        GROUP BY PayerName
    ),
    top5 AS (
        SELECT TOP 5 *
        FROM p
        ORDER BY Claims DESC, InsPay DESC, PayerName
    )
    SELECT CAST(ROW_NUMBER() OVER (ORDER BY InsPay DESC, Claims DESC, PayerName) AS INT) AS PayerRank,
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
   4. Top 5 Insurance by Payments (InsurancePayment > 0; top 5 by Total Payment)
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_WH_CS_Top5ReimbursementPay_Compute
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
               SUM(TotalPay)            AS TotalPay
        FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
        GROUP BY PayerName
    ),
    top5 AS (
        SELECT TOP 5 *
        FROM p
        ORDER BY TotalPay DESC, Claims DESC, PayerName
    )
    SELECT CAST(ROW_NUMBER() OVER (ORDER BY TotalPay DESC, Claims DESC, PayerName) AS INT) AS PayerRank,
           PayerName,
           CAST(TotalPay AS DECIMAL(18,2)) AS TotalPayments,
           Claims                          AS UniqueVisitCount
    FROM top5
    ORDER BY PayerRank;
END
GO

/* =============================================================================
   5. Panel Averages (Bill Status = Billed)
      Panel rows (P) carry every payer; drill-down rows (D) are the top 3 payers by
      claim count; Grand Total (T, blank names) is last and covers every billed claim.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_WH_CS_PanelAverages_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT PanelName, PayerName, ClaimKey, ChargeAmt, InsPay,
           CAST(CASE WHEN ClaimStatus = N'Fully Paid'                       THEN 1 ELSE 0 END AS BIT) AS IsFullyPaid,
           CAST(CASE WHEN Adjudicated IN (N'Adjudicated', N'Adjucticated') THEN 1 ELSE 0 END AS BIT) AS IsAdj,
           CAST(CASE WHEN Bucket30 = N'30 Bucket'                          THEN 1 ELSE 0 END AS BIT) AS Is30,
           CAST(CASE WHEN Bucket60 = N'60 Bucket'                          THEN 1 ELSE 0 END AS BIT) AS Is60
    INTO #pa
    FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                             @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    WHERE BilledStatus IN (N'Billed', N'Billed - Self Pay');

    WITH grp AS (
        SELECT PanelName = ISNULL(PanelName, N''),
               PayerName = ISNULL(PayerName, N''),
               IsGrand   = GROUPING(PanelName),
               IsPanel   = GROUPING(PayerName),
               NoOfClaims        = COUNT(DISTINCT ClaimKey),
               TotalCharges      = SUM(ChargeAmt),
               AvgBilled         = AVG(ChargeAmt),
               CarrierPayment    = SUM(InsPay),
               FullyPaidCount    = COUNT(DISTINCT CASE WHEN IsFullyPaid = 1 THEN ClaimKey END),
               FullyPaidAmount   = SUM(CASE WHEN IsFullyPaid = 1 THEN InsPay END),
               AvgFullyPaid      = AVG(CASE WHEN IsFullyPaid = 1 THEN InsPay END),
               AdjudicatedCount  = COUNT(DISTINCT CASE WHEN IsAdj = 1 THEN ClaimKey END),
               AdjudicatedAmount = SUM(CASE WHEN IsAdj = 1 THEN InsPay END),
               AvgAdjudicated    = AVG(CASE WHEN IsAdj = 1 THEN InsPay END),
               Days30Count       = COUNT(DISTINCT CASE WHEN Is30 = 1 THEN ClaimKey END),
               Days30Amount      = SUM(CASE WHEN Is30 = 1 THEN InsPay END),
               AvgDays30         = AVG(CASE WHEN Is30 = 1 THEN InsPay END),
               Days60Count       = COUNT(DISTINCT CASE WHEN Is60 = 1 THEN ClaimKey END),
               Days60Amount      = SUM(CASE WHEN Is60 = 1 THEN InsPay END),
               AvgDays60         = AVG(CASE WHEN Is60 = 1 THEN InsPay END)
        FROM #pa
        GROUP BY GROUPING SETS ((PanelName), (PanelName, PayerName), ())
    ),
    ranked AS (
        SELECT g.*,
               PayerRank = CASE WHEN IsPanel = 1 THEN 0
                                ELSE ROW_NUMBER() OVER (PARTITION BY IsGrand, PanelName, IsPanel
                                                        ORDER BY NoOfClaims DESC, CarrierPayment DESC, PayerName) END,
               PanelClaims = MAX(CASE WHEN IsPanel = 1 THEN NoOfClaims END) OVER (PARTITION BY IsGrand, PanelName)
        FROM grp g
    )
    SELECT CAST(CASE WHEN IsGrand = 1 THEN 'T' WHEN IsPanel = 1 THEN 'P' ELSE 'D' END AS CHAR(1)) AS RowType,
           PanelName,
           PayerName,
           CAST(PayerRank AS INT)                                   AS PayerRank,
           NoOfClaims,
           CAST(ISNULL(TotalCharges, 0)      AS DECIMAL(18,2))      AS TotalCharges,
           CAST(ISNULL(AvgBilled, 0)         AS DECIMAL(18,2))      AS AvgBilled,
           CAST(ISNULL(CarrierPayment, 0)    AS DECIMAL(18,2))      AS CarrierPayment,
           FullyPaidCount,
           CAST(ISNULL(FullyPaidAmount, 0)   AS DECIMAL(18,2))      AS FullyPaidAmount,
           CAST(ISNULL(AvgFullyPaid, 0)      AS DECIMAL(18,2))      AS AvgFullyPaid,
           AdjudicatedCount,
           CAST(ISNULL(AdjudicatedAmount, 0) AS DECIMAL(18,2))      AS AdjudicatedAmount,
           CAST(ISNULL(AvgAdjudicated, 0)    AS DECIMAL(18,2))      AS AvgAdjudicated,
           Days30Count,
           CAST(ISNULL(Days30Amount, 0)      AS DECIMAL(18,2))      AS Days30Amount,
           CAST(ISNULL(AvgDays30, 0)         AS DECIMAL(18,2))      AS AvgDays30,
           Days60Count,
           CAST(ISNULL(Days60Amount, 0)      AS DECIMAL(18,2))      AS Days60Amount,
           CAST(ISNULL(AvgDays60, 0)         AS DECIMAL(18,2))      AS AvgDays60,
           CAST(ROW_NUMBER() OVER (ORDER BY IsGrand, PanelClaims DESC, PanelName, PayerRank) AS INT) AS SortOrder
    FROM ranked
    WHERE PayerRank <= 3
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   5b. Panel Averages - by DOS / by Check Date (Average Payments tabs)
       FirstBilledDate not blank (no Bill Status filter).
       Same measures as Panel Averages over @LastMonths months of DateofService or
       CheckDate ending at the billed week-range end date (latest
       LineClaimFileLogs.WeekFolder); latest date in that column when no week folder.
       Returns every payer; the page shows panel totals plus the top 3 payers.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_GetWH_CS_AvgPayments_ClientLogic
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

    DECLARE @WeekFolder NVARCHAR(200), @WeekEnd DATE;
    IF OBJECT_ID(N'dbo.LineClaimFileLogs', N'U') IS NOT NULL
        SELECT TOP 1 @WeekFolder = LTRIM(RTRIM(CAST(WeekFolder AS NVARCHAR(200))))
        FROM dbo.LineClaimFileLogs
        WHERE NULLIF(LTRIM(RTRIM(CAST(RunId AS NVARCHAR(50)))), '') IS NOT NULL
        ORDER BY FileLogId DESC;

    IF CHARINDEX('-', ISNULL(@WeekFolder, '')) > 0
        SET @WeekEnd = TRY_CONVERT(DATE,
            REPLACE(LTRIM(RTRIM(RIGHT(@WeekFolder, CHARINDEX('-', REVERSE(@WeekFolder)) - 1))), '.', '/'), 101);

    SELECT PanelName, PayerName, ClaimKey, ChargeAmt, InsPay, ClaimStatus, Adjudicated, Bucket30, Bucket60,
           BasisDt = CASE WHEN @UseCheckDate = 1 THEN CheckDt ELSE Dos END
    INTO #b
    FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                             @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    WHERE FirstBilledDate IS NOT NULL;

    DECLARE @WindowTo DATE = ISNULL(@WeekEnd, (SELECT MAX(BasisDt) FROM #b));
    DECLARE @WindowFrom DATE = DATEADD(DAY, 1, DATEADD(MONTH, -@LastMonths, @WindowTo));

    SELECT PanelName,
           PayerName,
           CAST(COUNT(DISTINCT ClaimKey) AS INT)                                                        AS NoOfClaims,
           CAST(ISNULL(SUM(ChargeAmt), 0) AS DECIMAL(18,2))                                             AS TotalCharges,
           CAST(ISNULL(SUM(InsPay), 0) AS DECIMAL(18,2))                                                AS CarrierPayment,
           CAST(COUNT(DISTINCT CASE WHEN ClaimStatus = N'Fully Paid' THEN ClaimKey END) AS INT)          AS FullyPaidCount,
           CAST(ISNULL(SUM(CASE WHEN ClaimStatus = N'Fully Paid' THEN InsPay END), 0) AS DECIMAL(18,2)) AS FullyPaidAmount,
           CAST(COUNT(DISTINCT CASE WHEN Adjudicated IN (N'Adjudicated', N'Adjucticated') THEN ClaimKey END) AS INT) AS AdjudicatedCount,
           CAST(ISNULL(SUM(CASE WHEN Adjudicated IN (N'Adjudicated', N'Adjucticated') THEN InsPay END), 0) AS DECIMAL(18,2)) AS AdjudicatedAmount,
           CAST(COUNT(DISTINCT CASE WHEN Bucket30 = N'30 Bucket' THEN ClaimKey END) AS INT)             AS Days30Count,
           CAST(ISNULL(SUM(CASE WHEN Bucket30 = N'30 Bucket' THEN InsPay END), 0) AS DECIMAL(18,2))     AS Days30Amount,
           CAST(COUNT(DISTINCT CASE WHEN Bucket60 = N'60 Bucket' THEN ClaimKey END) AS INT)             AS Days60Count,
           CAST(ISNULL(SUM(CASE WHEN Bucket60 = N'60 Bucket' THEN InsPay END), 0) AS DECIMAL(18,2))     AS Days60Amount,
           @WindowFrom                                                                                  AS WindowFrom,
           @WindowTo                                                                                    AS WindowTo
    FROM #b
    WHERE BasisDt BETWEEN @WindowFrom AND @WindowTo
    GROUP BY PanelName, PayerName
    ORDER BY PanelName, NoOfClaims DESC, PayerName;
END
GO

/* =============================================================================
   6. Insurance vs Payment % (InsurancePayment > 0; sorted by Insurance Payment)
      TotalPaymentPct = Average(Payment %) over every claim in the result.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_WH_CS_InsuranceVsPaymentPct_Compute
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
        FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
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
           CAST(ROW_NUMBER() OVER (ORDER BY InsurancePayment DESC, NoOfClaims DESC, PayerName) AS INT) AS SortOrder
    FROM p
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   7. Total Insurance Payment (InsurancePayment > 0; sorted by Total Payment)
      InsurancePayment carries Sum(TotalPayments); PaymentPct = Average(Payment %).
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_WH_CS_InsuranceVsPayment_Compute
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
               SUM(TotalPay)            AS TotalPayment,
               AVG(PaymentPct)          AS AvgPct,
               SUM(PaymentPct)          AS PctSum,
               COUNT(PaymentPct)        AS PctCnt
        FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
        GROUP BY PayerName
    )
    SELECT PayerName,
           0                                                 AS BillYear,
           0                                                 AS BillMonth,
           NoOfPaidClaims,
           CAST(TotalPayment AS DECIMAL(18,2))               AS InsurancePayment,
           CAST(ROUND(ISNULL(AvgPct, 0), 2) AS DECIMAL(9,2)) AS PaymentPct,
           CAST(ROUND(ISNULL(SUM(PctSum) OVER () / NULLIF(SUM(PctCnt) OVER (), 0), 0), 2)
                AS DECIMAL(9,2))                             AS TotalPaymentPct,
           CAST(ROW_NUMBER() OVER (ORDER BY TotalPayment DESC, NoOfPaidClaims DESC, PayerName) AS INT) AS SortOrder
    FROM p
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   8. Insurance vs Aging (Charge Balance Due Ins = InsuranceBalance > 0; Aging DOS)
      Payers sorted by Insurance Balance, buckets Current -> 120+.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_WH_CS_InsuranceVsAging_Compute
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
        FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsBalance > 0
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
           CAST(ROW_NUMBER() OVER (ORDER BY p.PayerBalance DESC, p.PayerClaims DESC, a.PayerName,
                CASE a.AgingBucket WHEN N'Current' THEN 1 WHEN N'30+' THEN 2 WHEN N'60+' THEN 3
                                   WHEN N'90+' THEN 4 WHEN N'120+' THEN 5 ELSE 6 END) AS INT) AS SortOrder
    FROM agg a
    JOIN payer p ON p.PayerName = a.PayerName
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   9. Panel Vs Payment (InsurancePayment > 0 AND CheckDate not blank; CheckDate month)
      InsurancePayments carries Sum(TotalPayments); panels sorted by Insurance Payment.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_WH_CS_PanelVsPayment_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH agg AS (
        SELECT PanelName,
               YEAR(CheckDt)            AS BillYear,
               MONTH(CheckDt)           AS BillMonth,
               COUNT(DISTINCT ClaimKey) AS NoOfClaims,
               SUM(TotalPay)            AS TotalPayments,
               SUM(InsPay)              AS InsurancePayment
        FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
          AND CheckDt IS NOT NULL
        GROUP BY PanelName, YEAR(CheckDt), MONTH(CheckDt)
    ),
    panel AS (
        SELECT PanelName,
               SUM(InsurancePayment) AS PanelInsPay,
               SUM(TotalPayments)    AS PanelTotalPay,
               SUM(NoOfClaims)       AS PanelClaims
        FROM agg
        GROUP BY PanelName
    )
    SELECT a.PanelName,
           a.BillYear,
           a.BillMonth,
           a.NoOfClaims,
           CAST(a.TotalPayments AS DECIMAL(18,2)) AS InsurancePayments,
           CAST(ROW_NUMBER() OVER (ORDER BY p.PanelInsPay DESC, p.PanelTotalPay DESC, p.PanelClaims DESC,
                                            a.PanelName, a.BillYear, a.BillMonth) AS INT) AS SortOrder
    FROM agg a
    JOIN panel p ON p.PanelName = a.PanelName
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   10. CPT vs Payment % (Line Level Data; no filter)
       Rows CPT Code (RowType C); Count of unique ClaimID; Average of line Payment %
       (AdditionalFields "Payment %"). TotalPaymentPct = average over every line.
       Dashboard filters apply through the line's claim.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_WH_CS_CptVsPaymentPct_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT = dbo.fn_WH_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                                    @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo);

    CREATE TABLE #k (ClaimKey NVARCHAR(450) NOT NULL PRIMARY KEY);
    IF @HasFilter = 1
        INSERT INTO #k (ClaimKey)
        SELECT DISTINCT LEFT(ClaimKey, 450)
        FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE ClaimKey IS NOT NULL;

    SELECT ClaimKey = NULLIF(LTRIM(RTRIM(l.ClaimID)), N''),
           CPTCode  = ISNULL(NULLIF(LTRIM(RTRIM(l.CPTCode)), N''), N'(blank)'),
           LinePct  = CASE WHEN ISJSON(l.AdditionalFields) = 1
                           THEN TRY_CAST(JSON_VALUE(l.AdditionalFields, N'$."Payment %"') AS DECIMAL(18,6)) * 100 END
    INTO #l
    FROM dbo.LineLevelData l
    WHERE @HasFilter = 0
       OR EXISTS (SELECT 1 FROM #k k WHERE k.ClaimKey = LEFT(LTRIM(RTRIM(l.ClaimID)), 450));

    DECLARE @TotalPct DECIMAL(38,6) = (SELECT AVG(LinePct) FROM #l);

    SELECT CAST('C' AS CHAR(1))                                  AS RowType,
           CAST(NULL AS NVARCHAR(500))                           AS PanelName,
           CPTCode,
           COUNT(DISTINCT ClaimKey)                              AS NoOfClaims,
           CAST(ROUND(ISNULL(AVG(LinePct), 0), 2) AS DECIMAL(9,2)) AS AvgPaymentPct,
           CAST(ROUND(ISNULL(@TotalPct, 0), 2) AS DECIMAL(9,2))  AS TotalPaymentPct,
           CAST(ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT ClaimKey) DESC, CPTCode) AS INT) AS SortOrder
    FROM #l
    GROUP BY CPTCode
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   11. Status Summary (ClaimStatus -> Panel -> CPT -> Payer)
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_WH_CS_StatusSummary_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT ClaimStatus = ISNULL(NULLIF(ClaimStatus, N''), N'(blank)'),
           PanelName, CptCode, PayerName,
           NoOfClaims       = COUNT(DISTINCT ClaimKey),
           InsurancePayment = CAST(SUM(InsPay)         AS DECIMAL(18,2)),
           InsuranceBalance = CAST(SUM(InsBalance)     AS DECIMAL(18,2)),
           PatientBalance   = CAST(SUM(PatientBalance) AS DECIMAL(18,2)),
           SortOrder        = CAST(ROW_NUMBER() OVER (ORDER BY ISNULL(NULLIF(ClaimStatus, N''), N'(blank)'), PanelName,
                                                               COUNT(DISTINCT ClaimKey) DESC, CptCode, PayerName) AS INT)
    FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                             @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    GROUP BY ISNULL(NULLIF(ClaimStatus, N''), N'(blank)'), PanelName, CptCode, PayerName
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   12. Provider Summary (ReferringProvider; ranked by claim count)
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_WH_CS_ProviderSummary_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH agg AS (
        SELECT ReferringProvider,
               NoOfClaims        = COUNT(DISTINCT ClaimKey),
               InsurancePayments = SUM(InsPay),
               InsuranceBalance  = SUM(InsBalance),
               PatientBalance    = SUM(PatientBalance)
        FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE ReferringProvider IS NOT NULL
        GROUP BY ReferringProvider
    )
    SELECT CAST(ROW_NUMBER() OVER (ORDER BY NoOfClaims DESC, InsurancePayments DESC, ReferringProvider) AS INT) AS ProviderRank,
           ReferringProvider,
           NoOfClaims,
           CAST(InsurancePayments AS DECIMAL(18,2)) AS InsurancePayments,
           CAST(InsuranceBalance  AS DECIMAL(18,2)) AS InsuranceBalance,
           CAST(PatientBalance    AS DECIMAL(18,2)) AS PatientBalance
    FROM agg
    ORDER BY ProviderRank;
END
GO

/* =============================================================================
   13. Rep Vs Payment (InsurancePayment <> 0; Sales Rep x Posted Date month)
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_WH_CS_RepVsPayment_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT SalesRepName     = SalesRep,
           CheckYear        = YEAR(PostedDt),
           CheckMonth       = MONTH(PostedDt),
           NoOfClaims       = COUNT(DISTINCT ClaimKey),
           InsurancePayment = CAST(SUM(InsPay) AS DECIMAL(18,2)),
           SortOrder        = CAST(ROW_NUMBER() OVER (ORDER BY SalesRep, YEAR(PostedDt), MONTH(PostedDt)) AS INT)
    FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                             @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    WHERE InsPay <> 0
      AND PostedDt IS NOT NULL
      AND SalesRep IS NOT NULL
    GROUP BY SalesRep, YEAR(PostedDt), MONTH(PostedDt)
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   Read SPs: snapshot when no filter and the snapshot has rows, else live compute.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_GetWH_CS_RepVsPayment
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_WH_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.WH_CS2_RepVsPayment)
    BEGIN
        SELECT SalesRepName, CheckYear, CheckMonth, NoOfClaims, InsurancePayment, SortOrder
        FROM dbo.WH_CS2_RepVsPayment
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_WH_CS_RepVsPayment_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetWH_CS_MonthlyClaimVolume
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_WH_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.WH_CS2_MonthlyClaimVolume)
    BEGIN
        SELECT PanelName, PayerName, PayerRank, BillYear, BillMonth, NoOfClaims,
               InsurancePayment, AveragePaidAmount, SortOrder
        FROM dbo.WH_CS2_MonthlyClaimVolume
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_WH_CS_MonthlyClaimVolume_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetWH_CS_WeeklyClaimVolume
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_WH_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.WH_CS2_WeeklyClaimVolume)
    BEGIN
        SELECT PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims,
               InsurancePayment, AveragePaidAmount, SortOrder
        FROM dbo.WH_CS2_WeeklyClaimVolume
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_WH_CS_WeeklyClaimVolume_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetWH_CS_Top5ReimbursementPct
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_WH_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.WH_CS2_Top5ReimbursementPct)
    BEGIN
        SELECT PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount,
               AvgPaymentPct, TotalPaymentPct
        FROM dbo.WH_CS2_Top5ReimbursementPct
        ORDER BY PayerRank;
        RETURN;
    END;

    EXEC dbo.usp_WH_CS_Top5ReimbursementPct_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetWH_CS_Top5ReimbursementPay
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_WH_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.WH_CS2_Top5ReimbursementPay)
    BEGIN
        SELECT PayerRank, PayerName, TotalPayments, UniqueVisitCount
        FROM dbo.WH_CS2_Top5ReimbursementPay
        ORDER BY PayerRank;
        RETURN;
    END;

    EXEC dbo.usp_WH_CS_Top5ReimbursementPay_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetWH_CS_PanelAverages
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_WH_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.WH_CS2_PanelAverages)
    BEGIN
        SELECT RowType, PanelName, PayerName, PayerRank, NoOfClaims, TotalCharges, AvgBilled, CarrierPayment,
               FullyPaidCount, FullyPaidAmount, AvgFullyPaid, AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,
               Days30Count, Days30Amount, AvgDays30, Days60Count, Days60Amount, AvgDays60, SortOrder
        FROM dbo.WH_CS2_PanelAverages
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_WH_CS_PanelAverages_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetWH_CS_InsuranceVsPaymentPct
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_WH_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.WH_CS2_InsuranceVsPaymentPct)
    BEGIN
        SELECT PayerName, NoOfClaims, InsurancePayment, AvgPaymentPct, TotalPaymentPct, SortOrder
        FROM dbo.WH_CS2_InsuranceVsPaymentPct
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_WH_CS_InsuranceVsPaymentPct_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetWH_CS_InsuranceVsPayment
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_WH_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.WH_CS2_InsuranceVsPayment)
    BEGIN
        SELECT PayerName, BillYear, BillMonth, NoOfPaidClaims, InsurancePayment, PaymentPct, TotalPaymentPct, SortOrder
        FROM dbo.WH_CS2_InsuranceVsPayment
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_WH_CS_InsuranceVsPayment_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetWH_CS_InsuranceVsAging
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_WH_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.WH_CS2_InsuranceVsAging)
    BEGIN
        SELECT PayerName, AgingBucket, VisitCount, InsuranceBalance, SortOrder
        FROM dbo.WH_CS2_InsuranceVsAging
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_WH_CS_InsuranceVsAging_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetWH_CS_PanelVsPayment
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_WH_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.WH_CS2_PanelVsPayment)
    BEGIN
        SELECT PanelName, BillYear, BillMonth, NoOfClaims, InsurancePayments, SortOrder
        FROM dbo.WH_CS2_PanelVsPayment
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_WH_CS_PanelVsPayment_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetWH_CS_CptVsPaymentPct
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_WH_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.WH_CS2_CptVsPaymentPct)
    BEGIN
        SELECT RowType, PanelName, CPTCode, NoOfClaims, AvgPaymentPct, TotalPaymentPct, SortOrder
        FROM dbo.WH_CS2_CptVsPaymentPct
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_WH_CS_CptVsPaymentPct_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetWH_CS_StatusSummary
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_WH_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.WH_CS2_StatusSummary)
    BEGIN
        SELECT ClaimStatus, PanelName, CptCode, PayerName, NoOfClaims,
               InsurancePayment, InsuranceBalance, PatientBalance, SortOrder
        FROM dbo.WH_CS2_StatusSummary
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_WH_CS_StatusSummary_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetWH_CS_ProviderSummary
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_WH_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.WH_CS2_ProviderSummary)
    BEGIN
        SELECT ProviderRank, ReferringProvider, NoOfClaims, InsurancePayments, InsuranceBalance, PatientBalance
        FROM dbo.WH_CS2_ProviderSummary
        ORDER BY ProviderRank;
        RETURN;
    END;

    EXEC dbo.usp_WH_CS_ProviderSummary_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

/* =============================================================================
   Refresh SPs (run after claim-file ingest)
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_CS_MonthlyClaimVolume
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.WH_CS2_MonthlyClaimVolume;
    INSERT INTO dbo.WH_CS2_MonthlyClaimVolume
        (PanelName, PayerName, PayerRank, BillYear, BillMonth, NoOfClaims, InsurancePayment, AveragePaidAmount, SortOrder)
    EXEC dbo.usp_WH_CS_MonthlyClaimVolume_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_CS_WeeklyClaimVolume
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.WH_CS2_WeeklyClaimVolume;
    INSERT INTO dbo.WH_CS2_WeeklyClaimVolume
        (PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment, AveragePaidAmount, SortOrder)
    EXEC dbo.usp_WH_CS_WeeklyClaimVolume_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_CS_Top5ReimbursementPct
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.WH_CS2_Top5ReimbursementPct;
    INSERT INTO dbo.WH_CS2_Top5ReimbursementPct
        (PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount, AvgPaymentPct, TotalPaymentPct)
    EXEC dbo.usp_WH_CS_Top5ReimbursementPct_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_CS_Top5ReimbursementPay
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.WH_CS2_Top5ReimbursementPay;
    INSERT INTO dbo.WH_CS2_Top5ReimbursementPay (PayerRank, PayerName, TotalPayments, UniqueVisitCount)
    EXEC dbo.usp_WH_CS_Top5ReimbursementPay_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_CS_PanelAverages
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.WH_CS2_PanelAverages;
    INSERT INTO dbo.WH_CS2_PanelAverages
        (RowType, PanelName, PayerName, PayerRank, NoOfClaims, TotalCharges, AvgBilled, CarrierPayment,
         FullyPaidCount, FullyPaidAmount, AvgFullyPaid, AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,
         Days30Count, Days30Amount, AvgDays30, Days60Count, Days60Amount, AvgDays60, SortOrder)
    EXEC dbo.usp_WH_CS_PanelAverages_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_CS_InsuranceVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.WH_CS2_InsuranceVsPaymentPct;
    INSERT INTO dbo.WH_CS2_InsuranceVsPaymentPct
        (PayerName, NoOfClaims, InsurancePayment, AvgPaymentPct, TotalPaymentPct, SortOrder)
    EXEC dbo.usp_WH_CS_InsuranceVsPaymentPct_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_CS_InsuranceVsPayment
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.WH_CS2_InsuranceVsPayment;
    INSERT INTO dbo.WH_CS2_InsuranceVsPayment
        (PayerName, BillYear, BillMonth, NoOfPaidClaims, InsurancePayment, PaymentPct, TotalPaymentPct, SortOrder)
    EXEC dbo.usp_WH_CS_InsuranceVsPayment_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_CS_InsuranceVsAging
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.WH_CS2_InsuranceVsAging;
    INSERT INTO dbo.WH_CS2_InsuranceVsAging (PayerName, AgingBucket, VisitCount, InsuranceBalance, SortOrder)
    EXEC dbo.usp_WH_CS_InsuranceVsAging_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_CS_PanelVsPayment
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.WH_CS2_PanelVsPayment;
    INSERT INTO dbo.WH_CS2_PanelVsPayment (PanelName, BillYear, BillMonth, NoOfClaims, InsurancePayments, SortOrder)
    EXEC dbo.usp_WH_CS_PanelVsPayment_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_CS_CptVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.WH_CS2_CptVsPaymentPct;
    INSERT INTO dbo.WH_CS2_CptVsPaymentPct (RowType, PanelName, CPTCode, NoOfClaims, AvgPaymentPct, TotalPaymentPct, SortOrder)
    EXEC dbo.usp_WH_CS_CptVsPaymentPct_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_CS_StatusSummary
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.WH_CS2_StatusSummary;
    INSERT INTO dbo.WH_CS2_StatusSummary
        (ClaimStatus, PanelName, CptCode, PayerName, NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance, SortOrder)
    EXEC dbo.usp_WH_CS_StatusSummary_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_CS_ProviderSummary
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.WH_CS2_ProviderSummary;
    INSERT INTO dbo.WH_CS2_ProviderSummary
        (ProviderRank, ReferringProvider, NoOfClaims, InsurancePayments, InsuranceBalance, PatientBalance)
    EXEC dbo.usp_WH_CS_ProviderSummary_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_CS_RepVsPayment
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.WH_CS2_RepVsPayment;
    INSERT INTO dbo.WH_CS2_RepVsPayment (SalesRepName, CheckYear, CheckMonth, NoOfClaims, InsurancePayment, SortOrder)
    EXEC dbo.usp_WH_CS_RepVsPayment_Compute;
    COMMIT;
END
GO

/* =============================================================================
   Build the no-filter snapshots
   ============================================================================= */
EXEC dbo.usp_RefreshWH_CS_MonthlyClaimVolume;
EXEC dbo.usp_RefreshWH_CS_WeeklyClaimVolume;
EXEC dbo.usp_RefreshWH_CS_Top5ReimbursementPct;
EXEC dbo.usp_RefreshWH_CS_Top5ReimbursementPay;
EXEC dbo.usp_RefreshWH_CS_PanelAverages;
EXEC dbo.usp_RefreshWH_CS_InsuranceVsPaymentPct;
EXEC dbo.usp_RefreshWH_CS_InsuranceVsPayment;
EXEC dbo.usp_RefreshWH_CS_InsuranceVsAging;
EXEC dbo.usp_RefreshWH_CS_PanelVsPayment;
EXEC dbo.usp_RefreshWH_CS_CptVsPaymentPct;
EXEC dbo.usp_RefreshWH_CS_StatusSummary;
EXEC dbo.usp_RefreshWH_CS_ProviderSummary;
EXEC dbo.usp_RefreshWH_CS_RepVsPayment;
GO
