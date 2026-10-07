/* =============================================================================
   Analyze Pathology (prefix AnP_) - Collection Summary client logic (new)
   Database: AnalyzePathology
   Source:   dbo.ClaimLevelData (Claim Level Data; ClaimID is unique per row)

   Every calculation, ranking and sort order lives here. The dashboard page,
   the filtered page and the Excel export all read usp_GetAnP_CS_<Tab>, which
   returns the refreshed snapshot (AnP_CS2_<Tab>) when no filter is set and
   otherwise runs usp_AnP_CS_<Tab>_Compute live with the same logic.
   usp_RefreshAnP_CS_<Tab> keeps its name, so the ingest refresh list and
   99_AnalyzePathology_ExecuteAllAggregates.sql need no change.

   Client logic (Sort By = Claim Count for every section):
     Monthly            ClaimStatus IN (Fully Paid, Partially Paid); Panel -> Top 3 payers
                        by claim count; columns = Posted Date (CheckDate) month;
                        Count of unique ClaimID, Sum of InsurancePayment.
     Weekly             Same as Monthly; Posted Date weeks Monday-Sunday, last 4 completed.
     Top 5 Reimb. %     Fully/Partially Paid; Top 5 payers by Insurance Payment;
                        Payment % = Average(PaymentPercent).
     Top 5 Payments     Fully/Partially Paid; Top 5 payers by Sum(Insurance Payment).
     Ins vs Payment %   InsurancePayment > 0; payer; Count ClaimID, Sum InsurancePayment,
                        Average PaymentPercent.
     Ins vs Payment     InsurancePayment > 0; payer; Count ClaimID, Sum InsurancePayment.
     Ins vs Aging       TotalInsuranceBalance > 0; payer x AgingDOS; Count ClaimID,
                        Sum InsuranceBalance.
     Panel vs Payment   InsurancePayment > 0 AND CheckDate in the current year;
                        panel x CheckDate month; Count ClaimID, Sum InsurancePayment.
     CPT vs Payment %   All claims; Panel -> CPTCodeList; Count ClaimID, Average PaymentPercent.
     Panel Average      BilledStatus IN (Billed, Billed - Self Pay); Panel -> Top 3 payers by
                        claim count. Five column groups (Count ClaimID, Sum, Average):
                          Billed       all rows                 -> ChargeAmount
                          Fully Paid   ClaimStatus = Fully Paid -> InsurancePayment
                          Adjudicated  Adjudicated flag set     -> InsurancePayment
                          > 30         Bucket30 = '30 Bucket'   -> InsurancePayment
                          > 60         Bucket60 = '60 Bucket'   -> InsurancePayment
                        The file spells the adjudicated flag 'Adjucticated'; both spellings count.

   PaymentPercent is stored as a ratio (0.25 = 25%); outputs are percent points.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'AnalyzePathology'
    THROW 50000, 'Run 28_AnalyzePathology_CollectionSummary_NewLogic.sql on the AnalyzePathology database.', 1;
GO

/* -----------------------------------------------------------------------------
   Shared: filtered, normalised claim rows
   ----------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_AnP_CS_Claims
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
        BilledStatus    = LTRIM(RTRIM(c.BilledStatus)),
        Adjudicated     = LTRIM(RTRIM(c.Adjudicated)),
        Bucket30        = LTRIM(RTRIM(c.Bucket30)),
        Bucket60        = LTRIM(RTRIM(c.Bucket60)),
        CheckDt         = n.CheckDt,
        InsPay          = ISNULL(TRY_CAST(c.InsurancePayment      AS DECIMAL(18,2)), 0),
        ChargeAmt       = ISNULL(TRY_CAST(c.ChargeAmount          AS DECIMAL(18,2)), 0),
        PaymentPct      = TRY_CAST(c.PaymentPercent AS DECIMAL(18,6)) * 100,
        InsBalance      = ISNULL(TRY_CAST(c.InsuranceBalance      AS DECIMAL(18,2)), 0),
        TotalInsBalance = ISNULL(TRY_CAST(c.TotalInsuranceBalance AS DECIMAL(18,2)), 0),
        AgingDOS        = NULLIF(LTRIM(RTRIM(c.AgingDOS)), N''),
        CPTCode         = ISNULL(NULLIF(LTRIM(RTRIM(c.CPTCodeList)), N''), N'(blank)')
    FROM dbo.ClaimLevelData c
    CROSS APPLY (SELECT
        PayerName = ISNULL(NULLIF(LTRIM(RTRIM(c.PayerName_Raw)), N''), N'Unknown'),
        PanelName = ISNULL(NULLIF(LTRIM(RTRIM(c.Panelname)),     N''), N'Unknown'),
        CheckDt   = COALESCE(TRY_CONVERT(DATE, c.CheckDate, 101), TRY_CAST(c.CheckDate AS DATE)),
        Dos       = TRY_CAST(c.DateOfService   AS DATE),
        FirstBill = TRY_CAST(c.FirstBilledDate AS DATE)) n
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

CREATE OR ALTER FUNCTION dbo.fn_AnP_CS_HasFilter
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

/* -----------------------------------------------------------------------------
   Snapshot tables
   ----------------------------------------------------------------------------- */
DROP TABLE IF EXISTS dbo.AnP_CS2_MonthlyClaimVolume;
CREATE TABLE dbo.AnP_CS2_MonthlyClaimVolume
(
    PanelName         NVARCHAR(500) NOT NULL,
    PayerName         NVARCHAR(500) NOT NULL,
    PayerRank         INT           NOT NULL,
    BillYear          INT           NOT NULL,
    BillMonth         INT           NOT NULL,
    NoOfClaims        INT           NOT NULL,
    InsurancePayment  DECIMAL(18,2) NOT NULL,
    AveragePaidAmount DECIMAL(18,2) NULL,
    SortOrder         INT           NOT NULL,
    RefreshedAt       DATETIME2(0)  NOT NULL CONSTRAINT DF_AnP_CS2_MCV_RefreshedAt DEFAULT SYSDATETIME()
);

DROP TABLE IF EXISTS dbo.AnP_CS2_WeeklyClaimVolume;
CREATE TABLE dbo.AnP_CS2_WeeklyClaimVolume
(
    PanelName         NVARCHAR(500) NOT NULL,
    PayerName         NVARCHAR(500) NOT NULL,
    PayerRank         INT           NOT NULL,
    WeekKey           INT           NOT NULL,
    WeekStart         DATE          NOT NULL,
    WeekEnd           DATE          NOT NULL,
    NoOfClaims        INT           NOT NULL,
    InsurancePayment  DECIMAL(18,2) NOT NULL,
    AveragePaidAmount DECIMAL(18,2) NULL,
    SortOrder         INT           NOT NULL,
    RefreshedAt       DATETIME2(0)  NOT NULL CONSTRAINT DF_AnP_CS2_WCV_RefreshedAt DEFAULT SYSDATETIME()
);

DROP TABLE IF EXISTS dbo.AnP_CS2_Top5ReimbursementPct;
CREATE TABLE dbo.AnP_CS2_Top5ReimbursementPct
(
    PayerRank           INT           NOT NULL,
    PayerName           NVARCHAR(500) NOT NULL,
    SumInsurancePayment DECIMAL(18,2) NOT NULL,
    SumChargeAmount     DECIMAL(18,2) NOT NULL,
    UniqueVisitCount    INT           NOT NULL,
    AvgPaymentPct       DECIMAL(9,2)  NOT NULL,
    TotalPaymentPct     DECIMAL(9,2)  NOT NULL,
    RefreshedAt         DATETIME2(0)  NOT NULL CONSTRAINT DF_AnP_CS2_T5Pct_RefreshedAt DEFAULT SYSDATETIME()
);

DROP TABLE IF EXISTS dbo.AnP_CS2_Top5ReimbursementPay;
CREATE TABLE dbo.AnP_CS2_Top5ReimbursementPay
(
    PayerRank        INT           NOT NULL,
    PayerName        NVARCHAR(500) NOT NULL,
    TotalPayments    DECIMAL(18,2) NOT NULL,
    UniqueVisitCount INT           NOT NULL,
    RefreshedAt      DATETIME2(0)  NOT NULL CONSTRAINT DF_AnP_CS2_T5Pay_RefreshedAt DEFAULT SYSDATETIME()
);

DROP TABLE IF EXISTS dbo.AnP_CS2_InsuranceVsPaymentPct;
CREATE TABLE dbo.AnP_CS2_InsuranceVsPaymentPct
(
    PayerName        NVARCHAR(500) NOT NULL,
    NoOfClaims       INT           NOT NULL,
    InsurancePayment DECIMAL(18,2) NOT NULL,
    AvgPaymentPct    DECIMAL(9,2)  NOT NULL,
    TotalPaymentPct  DECIMAL(9,2)  NOT NULL,
    SortOrder        INT           NOT NULL,
    RefreshedAt      DATETIME2(0)  NOT NULL CONSTRAINT DF_AnP_CS2_IPP_RefreshedAt DEFAULT SYSDATETIME()
);

DROP TABLE IF EXISTS dbo.AnP_CS2_InsuranceVsPayment;
CREATE TABLE dbo.AnP_CS2_InsuranceVsPayment
(
    PayerName        NVARCHAR(500) NOT NULL,
    BillYear         INT           NOT NULL,
    BillMonth        INT           NOT NULL,
    NoOfPaidClaims   INT           NOT NULL,
    InsurancePayment DECIMAL(18,2) NOT NULL,
    PaymentPct       DECIMAL(9,2)  NOT NULL,
    SortOrder        INT           NOT NULL,
    RefreshedAt      DATETIME2(0)  NOT NULL CONSTRAINT DF_AnP_CS2_IVP_RefreshedAt DEFAULT SYSDATETIME()
);

DROP TABLE IF EXISTS dbo.AnP_CS2_InsuranceVsAging;
CREATE TABLE dbo.AnP_CS2_InsuranceVsAging
(
    PayerName        NVARCHAR(500) NOT NULL,
    AgingBucket      NVARCHAR(50)  NOT NULL,
    VisitCount       INT           NOT NULL,
    InsuranceBalance DECIMAL(18,2) NOT NULL,
    SortOrder        INT           NOT NULL,
    RefreshedAt      DATETIME2(0)  NOT NULL CONSTRAINT DF_AnP_CS2_IVA_RefreshedAt DEFAULT SYSDATETIME()
);

DROP TABLE IF EXISTS dbo.AnP_CS2_PanelVsPayment;
CREATE TABLE dbo.AnP_CS2_PanelVsPayment
(
    PanelName         NVARCHAR(500) NOT NULL,
    BillYear          INT           NOT NULL,
    BillMonth         INT           NOT NULL,
    NoOfClaims        INT           NOT NULL,
    InsurancePayments DECIMAL(18,2) NOT NULL,
    SortOrder         INT           NOT NULL,
    RefreshedAt       DATETIME2(0)  NOT NULL CONSTRAINT DF_AnP_CS2_PVP_RefreshedAt DEFAULT SYSDATETIME()
);

DROP TABLE IF EXISTS dbo.AnP_CS2_CptVsPaymentPct;
CREATE TABLE dbo.AnP_CS2_CptVsPaymentPct
(
    RowType         CHAR(1)       NOT NULL,   -- P = panel row, C = CPT row under the panel
    PanelName       NVARCHAR(500) NOT NULL,
    CPTCode         NVARCHAR(500) NULL,
    NoOfClaims      INT           NOT NULL,
    AvgPaymentPct   DECIMAL(9,2)  NOT NULL,
    TotalPaymentPct DECIMAL(9,2)  NOT NULL,
    SortOrder       INT           NOT NULL,
    RefreshedAt     DATETIME2(0)  NOT NULL CONSTRAINT DF_AnP_CS2_CPT_RefreshedAt DEFAULT SYSDATETIME()
);

DROP TABLE IF EXISTS dbo.AnP_CS2_PanelAverages;
CREATE TABLE dbo.AnP_CS2_PanelAverages
(
    RowType           CHAR(1)       NOT NULL,   -- P = panel total (PayerName = ''), D = top-3 payer drill-down, T = Grand Total
    PanelName         NVARCHAR(500) NOT NULL,
    PayerName         NVARCHAR(500) NOT NULL,
    PayerRank         INT           NOT NULL,
    NoOfClaims        INT           NOT NULL,
    TotalCharges      DECIMAL(18,2) NOT NULL,
    AvgBilled         DECIMAL(18,2) NOT NULL,
    CarrierPayment    DECIMAL(18,2) NOT NULL,
    FullyPaidCount    INT           NOT NULL,
    FullyPaidAmount   DECIMAL(18,2) NOT NULL,
    AvgFullyPaid      DECIMAL(18,2) NOT NULL,
    AdjudicatedCount  INT           NOT NULL,
    AdjudicatedAmount DECIMAL(18,2) NOT NULL,
    AvgAdjudicated    DECIMAL(18,2) NOT NULL,
    Days30Count       INT           NOT NULL,
    Days30Amount      DECIMAL(18,2) NOT NULL,
    AvgDays30         DECIMAL(18,2) NOT NULL,
    Days60Count       INT           NOT NULL,
    Days60Amount      DECIMAL(18,2) NOT NULL,
    AvgDays60         DECIMAL(18,2) NOT NULL,
    SortOrder         INT           NOT NULL,
    RefreshedAt       DATETIME2(0)  NOT NULL CONSTRAINT DF_AnP_CS2_PA_RefreshedAt DEFAULT SYSDATETIME()
);
GO

/* =============================================================================
   1. Monthly Claim Volume
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_AnP_CS_MonthlyClaimVolume_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH agg AS (
        SELECT PanelName, PayerName,
               YEAR(CheckDt)            AS BillYear,
               MONTH(CheckDt)           AS BillMonth,
               COUNT(DISTINCT ClaimKey) AS NoOfClaims,
               SUM(InsPay)              AS InsurancePayment
        FROM dbo.fn_AnP_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                  @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE ClaimStatus IN (N'Fully Paid', N'Partially Paid')
          AND CheckDt IS NOT NULL
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
               SUM(PayerClaims) OVER (PARTITION BY PanelName)                         AS PanelClaims
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
           CAST(ROW_NUMBER() OVER (ORDER BY r.PanelClaims DESC, a.PanelName, r.PayerRank,
                                            a.BillYear, a.BillMonth) AS INT)   AS SortOrder
    FROM agg a
    JOIN ranked r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY SortOrder;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_CS_MonthlyClaimVolume
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.AnP_CS2_MonthlyClaimVolume;
    INSERT INTO dbo.AnP_CS2_MonthlyClaimVolume
        (PanelName, PayerName, PayerRank, BillYear, BillMonth, NoOfClaims, InsurancePayment, AveragePaidAmount, SortOrder)
    EXEC dbo.usp_AnP_CS_MonthlyClaimVolume_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_CS_MonthlyClaimVolume
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_AnP_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                               @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.AnP_CS2_MonthlyClaimVolume)
    BEGIN
        SELECT PanelName, PayerName, PayerRank, BillYear, BillMonth, NoOfClaims, InsurancePayment, AveragePaidAmount, SortOrder
        FROM dbo.AnP_CS2_MonthlyClaimVolume
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_AnP_CS_MonthlyClaimVolume_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames,
        @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

/* =============================================================================
   2. Weekly Claim Volume (Posted Date = CheckDate, Monday-Sunday weeks,
      last 4 completed weeks up to the latest CheckDate on or before today)
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_AnP_CS_WeeklyClaimVolume_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);

    SELECT PanelName, PayerName, ClaimKey, CheckDt, InsPay
    INTO #paid
    FROM dbo.fn_AnP_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    WHERE ClaimStatus IN (N'Fully Paid', N'Partially Paid')
      AND CheckDt IS NOT NULL
      AND CheckDt <= @Today;

    -- A week counts as completed when it ends on or before today and the CheckDate-To filter.
    DECLARE @Cutoff DATE = CASE WHEN @CheckDateTo < @Today THEN @CheckDateTo ELSE @Today END;
    DECLARE @MaxCheck DATE = (SELECT MAX(CheckDt) FROM #paid);
    -- 1900-01-01 was a Monday.
    DECLARE @LastStart DATE = DATEADD(DAY, -(DATEDIFF(DAY, '19000101', @MaxCheck) % 7), @MaxCheck);
    IF DATEADD(DAY, 6, @LastStart) > @Cutoff
        SET @LastStart = DATEADD(DAY, -7, @LastStart);
    DECLARE @FirstStart DATE = DATEADD(DAY, -21, @LastStart);
    DECLARE @LastEnd    DATE = DATEADD(DAY, 6, @LastStart);

    WITH wk AS (
        SELECT PanelName, PayerName, ClaimKey, InsPay,
               DATEDIFF(DAY, @FirstStart, CheckDt) / 7 + 1 AS WeekKey
        FROM #paid
        WHERE CheckDt BETWEEN @FirstStart AND @LastEnd
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
               SUM(PayerClaims) OVER (PARTITION BY PanelName)                         AS PanelClaims
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
           CAST(ROW_NUMBER() OVER (ORDER BY r.PanelClaims DESC, a.PanelName, r.PayerRank,
                                            a.WeekKey) AS INT)                 AS SortOrder
    FROM agg a
    JOIN ranked r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY SortOrder;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_CS_WeeklyClaimVolume
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.AnP_CS2_WeeklyClaimVolume;
    INSERT INTO dbo.AnP_CS2_WeeklyClaimVolume
        (PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment, AveragePaidAmount, SortOrder)
    EXEC dbo.usp_AnP_CS_WeeklyClaimVolume_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_CS_WeeklyClaimVolume
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_AnP_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                               @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.AnP_CS2_WeeklyClaimVolume)
    BEGIN
        SELECT PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment, AveragePaidAmount, SortOrder
        FROM dbo.AnP_CS2_WeeklyClaimVolume
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_AnP_CS_WeeklyClaimVolume_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames,
        @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

/* =============================================================================
   3. Top 5 Insurance Reimbursement %
      Top 5 payers by Sum(InsurancePayment), listed by claim count.
      AvgPaymentPct = Average(PaymentPercent) per payer;
      TotalPaymentPct = Average(PaymentPercent) over all claims of the 5 payers.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_AnP_CS_Top5ReimbursementPct_Compute
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
        FROM dbo.fn_AnP_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                  @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE ClaimStatus IN (N'Fully Paid', N'Partially Paid')
        GROUP BY PayerName
    ),
    top5 AS (
        SELECT TOP 5 *
        FROM p
        ORDER BY InsPay DESC, Claims DESC, PayerName
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

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_CS_Top5ReimbursementPct
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.AnP_CS2_Top5ReimbursementPct;
    INSERT INTO dbo.AnP_CS2_Top5ReimbursementPct
        (PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount, AvgPaymentPct, TotalPaymentPct)
    EXEC dbo.usp_AnP_CS_Top5ReimbursementPct_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_CS_Top5ReimbursementPct
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_AnP_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                               @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.AnP_CS2_Top5ReimbursementPct)
    BEGIN
        SELECT PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount, AvgPaymentPct, TotalPaymentPct
        FROM dbo.AnP_CS2_Top5ReimbursementPct
        ORDER BY PayerRank;
        RETURN;
    END;

    EXEC dbo.usp_AnP_CS_Top5ReimbursementPct_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames,
        @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

/* =============================================================================
   4. Top 5 Insurance Total Payments (Top 5 by Sum(InsurancePayment), listed by claim count)
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_AnP_CS_Top5ReimbursementPay_Compute
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
        FROM dbo.fn_AnP_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                  @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE ClaimStatus IN (N'Fully Paid', N'Partially Paid')
        GROUP BY PayerName
    ),
    top5 AS (
        SELECT TOP 5 *
        FROM p
        ORDER BY InsPay DESC, Claims DESC, PayerName
    )
    SELECT CAST(ROW_NUMBER() OVER (ORDER BY Claims DESC, InsPay DESC, PayerName) AS INT) AS PayerRank,
           PayerName,
           CAST(InsPay AS DECIMAL(18,2)) AS TotalPayments,
           Claims                        AS UniqueVisitCount
    FROM top5
    ORDER BY PayerRank;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_CS_Top5ReimbursementPay
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.AnP_CS2_Top5ReimbursementPay;
    INSERT INTO dbo.AnP_CS2_Top5ReimbursementPay (PayerRank, PayerName, TotalPayments, UniqueVisitCount)
    EXEC dbo.usp_AnP_CS_Top5ReimbursementPay_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_CS_Top5ReimbursementPay
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_AnP_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                               @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.AnP_CS2_Top5ReimbursementPay)
    BEGIN
        SELECT PayerRank, PayerName, TotalPayments, UniqueVisitCount
        FROM dbo.AnP_CS2_Top5ReimbursementPay
        ORDER BY PayerRank;
        RETURN;
    END;

    EXEC dbo.usp_AnP_CS_Top5ReimbursementPay_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames,
        @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

/* =============================================================================
   6. Insurance vs Payment % (InsurancePayment > 0)
      TotalPaymentPct = Average(PaymentPercent) over every claim in the result.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_AnP_CS_InsuranceVsPaymentPct_Compute
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
        FROM dbo.fn_AnP_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
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

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_CS_InsuranceVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.AnP_CS2_InsuranceVsPaymentPct;
    INSERT INTO dbo.AnP_CS2_InsuranceVsPaymentPct
        (PayerName, NoOfClaims, InsurancePayment, AvgPaymentPct, TotalPaymentPct, SortOrder)
    EXEC dbo.usp_AnP_CS_InsuranceVsPaymentPct_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_CS_InsuranceVsPaymentPct
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_AnP_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                               @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.AnP_CS2_InsuranceVsPaymentPct)
    BEGIN
        SELECT PayerName, NoOfClaims, InsurancePayment, AvgPaymentPct, TotalPaymentPct, SortOrder
        FROM dbo.AnP_CS2_InsuranceVsPaymentPct
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_AnP_CS_InsuranceVsPaymentPct_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames,
        @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

/* =============================================================================
   7. Insurance vs Payment (InsurancePayment > 0; payer totals, no month columns)
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_AnP_CS_InsuranceVsPayment_Compute
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
               AVG(PaymentPct)          AS AvgPct
        FROM dbo.fn_AnP_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
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
           CAST(ROW_NUMBER() OVER (ORDER BY NoOfPaidClaims DESC, InsurancePayment DESC, PayerName) AS INT) AS SortOrder
    FROM p
    ORDER BY SortOrder;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_CS_InsuranceVsPayment
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.AnP_CS2_InsuranceVsPayment;
    INSERT INTO dbo.AnP_CS2_InsuranceVsPayment
        (PayerName, BillYear, BillMonth, NoOfPaidClaims, InsurancePayment, PaymentPct, SortOrder)
    EXEC dbo.usp_AnP_CS_InsuranceVsPayment_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_CS_InsuranceVsPayment
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_AnP_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                               @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.AnP_CS2_InsuranceVsPayment)
    BEGIN
        SELECT PayerName, BillYear, BillMonth, NoOfPaidClaims, InsurancePayment, PaymentPct, SortOrder
        FROM dbo.AnP_CS2_InsuranceVsPayment
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_AnP_CS_InsuranceVsPayment_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames,
        @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

/* =============================================================================
   8. Insurance vs Aging (TotalInsuranceBalance > 0; buckets from AgingDOS;
      balance = Sum(InsuranceBalance))
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_AnP_CS_InsuranceVsAging_Compute
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
        FROM dbo.fn_AnP_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                  @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE TotalInsBalance > 0
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

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_CS_InsuranceVsAging
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.AnP_CS2_InsuranceVsAging;
    INSERT INTO dbo.AnP_CS2_InsuranceVsAging (PayerName, AgingBucket, VisitCount, InsuranceBalance, SortOrder)
    EXEC dbo.usp_AnP_CS_InsuranceVsAging_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_CS_InsuranceVsAging
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_AnP_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                               @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.AnP_CS2_InsuranceVsAging)
    BEGIN
        SELECT PayerName, AgingBucket, VisitCount, InsuranceBalance, SortOrder
        FROM dbo.AnP_CS2_InsuranceVsAging
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_AnP_CS_InsuranceVsAging_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames,
        @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

/* =============================================================================
   9. Panel vs Payment (InsurancePayment > 0 AND CheckDate in the current year;
      panel x CheckDate month)
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_AnP_CS_PanelVsPayment_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Year INT = YEAR(GETDATE());

    WITH agg AS (
        SELECT PanelName,
               YEAR(CheckDt)            AS BillYear,
               MONTH(CheckDt)           AS BillMonth,
               COUNT(DISTINCT ClaimKey) AS NoOfClaims,
               SUM(InsPay)              AS InsurancePayments
        FROM dbo.fn_AnP_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                  @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
          AND YEAR(CheckDt) = @Year
        GROUP BY PanelName, YEAR(CheckDt), MONTH(CheckDt)
    ),
    panel AS (
        SELECT PanelName,
               SUM(NoOfClaims)        AS PanelClaims,
               SUM(InsurancePayments) AS PanelPay
        FROM agg
        GROUP BY PanelName
    )
    SELECT a.PanelName,
           a.BillYear,
           a.BillMonth,
           a.NoOfClaims,
           CAST(a.InsurancePayments AS DECIMAL(18,2)) AS InsurancePayments,
           CAST(ROW_NUMBER() OVER (ORDER BY p.PanelClaims DESC, p.PanelPay DESC, a.PanelName,
                                            a.BillYear, a.BillMonth) AS INT) AS SortOrder
    FROM agg a
    JOIN panel p ON p.PanelName = a.PanelName
    ORDER BY SortOrder;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_CS_PanelVsPayment
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.AnP_CS2_PanelVsPayment;
    INSERT INTO dbo.AnP_CS2_PanelVsPayment (PanelName, BillYear, BillMonth, NoOfClaims, InsurancePayments, SortOrder)
    EXEC dbo.usp_AnP_CS_PanelVsPayment_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_CS_PanelVsPayment
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_AnP_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                               @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.AnP_CS2_PanelVsPayment)
    BEGIN
        SELECT PanelName, BillYear, BillMonth, NoOfClaims, InsurancePayments, SortOrder
        FROM dbo.AnP_CS2_PanelVsPayment
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_AnP_CS_PanelVsPayment_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames,
        @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

/* =============================================================================
   10. CPT vs Payment % (all claims; Panel -> CPTCodeList)
       RowType P = panel subtotal, C = CPT under that panel.
       TotalPaymentPct = Average(PaymentPercent) over every claim in the result.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_AnP_CS_CptVsPaymentPct_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT PanelName, CPTCode, ClaimKey, PaymentPct
    INTO #b
    FROM dbo.fn_AnP_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo);

    DECLARE @TotalPct DECIMAL(38,6) = (SELECT AVG(PaymentPct) FROM #b);

    WITH panel AS (
        SELECT PanelName,
               COUNT(DISTINCT ClaimKey) AS NoOfClaims,
               AVG(PaymentPct)          AS AvgPct,
               ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT ClaimKey) DESC, PanelName) AS PanelOrd
        FROM #b
        GROUP BY PanelName
    ),
    cpt AS (
        SELECT PanelName, CPTCode,
               COUNT(DISTINCT ClaimKey) AS NoOfClaims,
               AVG(PaymentPct)          AS AvgPct,
               ROW_NUMBER() OVER (PARTITION BY PanelName
                                  ORDER BY COUNT(DISTINCT ClaimKey) DESC, CPTCode) AS CptOrd
        FROM #b
        GROUP BY PanelName, CPTCode
    ),
    rowsOut AS (
        SELECT CAST('P' AS CHAR(1)) AS RowType, p.PanelName, CAST(NULL AS NVARCHAR(500)) AS CPTCode,
               p.NoOfClaims, p.AvgPct, p.PanelOrd, CAST(0 AS BIGINT) AS CptOrd
        FROM panel p
        UNION ALL
        SELECT CAST('C' AS CHAR(1)), c.PanelName, c.CPTCode,
               c.NoOfClaims, c.AvgPct, p.PanelOrd, c.CptOrd
        FROM cpt c
        JOIN panel p ON p.PanelName = c.PanelName
    )
    SELECT RowType,
           PanelName,
           CPTCode,
           NoOfClaims,
           CAST(ROUND(ISNULL(AvgPct, 0), 2) AS DECIMAL(9,2))    AS AvgPaymentPct,
           CAST(ROUND(ISNULL(@TotalPct, 0), 2) AS DECIMAL(9,2)) AS TotalPaymentPct,
           CAST(ROW_NUMBER() OVER (ORDER BY PanelOrd, CptOrd) AS INT) AS SortOrder
    FROM rowsOut
    ORDER BY SortOrder;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_CS_CptVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.AnP_CS2_CptVsPaymentPct;
    INSERT INTO dbo.AnP_CS2_CptVsPaymentPct (RowType, PanelName, CPTCode, NoOfClaims, AvgPaymentPct, TotalPaymentPct, SortOrder)
    EXEC dbo.usp_AnP_CS_CptVsPaymentPct_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_CS_CptVsPaymentPct
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_AnP_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                               @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.AnP_CS2_CptVsPaymentPct)
    BEGIN
        SELECT RowType, PanelName, CPTCode, NoOfClaims, AvgPaymentPct, TotalPaymentPct, SortOrder
        FROM dbo.AnP_CS2_CptVsPaymentPct
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_AnP_CS_CptVsPaymentPct_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames,
        @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

/* =============================================================================
   11. Panel Average
       Panel rows (RowType P) carry the panel totals over every payer; the
       drill-down rows (RowType D) are the top 3 payers by claim count; the
       Grand Total row (RowType T, blank PanelName/PayerName) is last and is
       computed over every billed claim (not a sum of the panel rows).
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_AnP_CS_PanelAverages_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT PanelName, PayerName, ClaimKey, ChargeAmt, InsPay,
           CAST(CASE WHEN ClaimStatus = N'Fully Paid'                         THEN 1 ELSE 0 END AS BIT) AS IsFullyPaid,
           CAST(CASE WHEN Adjudicated IN (N'Adjudicated', N'Adjucticated')   THEN 1 ELSE 0 END AS BIT) AS IsAdj,
           CAST(CASE WHEN Bucket30 = N'30 Bucket'                            THEN 1 ELSE 0 END AS BIT) AS Is30,
           CAST(CASE WHEN Bucket60 = N'60 Bucket'                            THEN 1 ELSE 0 END AS BIT) AS Is60
    INTO #pa
    FROM dbo.fn_AnP_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
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

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_CS_PanelAverages
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.AnP_CS2_PanelAverages;
    INSERT INTO dbo.AnP_CS2_PanelAverages
        (RowType, PanelName, PayerName, PayerRank, NoOfClaims, TotalCharges, AvgBilled, CarrierPayment,
         FullyPaidCount, FullyPaidAmount, AvgFullyPaid, AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,
         Days30Count, Days30Amount, AvgDays30, Days60Count, Days60Amount, AvgDays60, SortOrder)
    EXEC dbo.usp_AnP_CS_PanelAverages_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_CS_PanelAverages
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_AnP_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                               @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.AnP_CS2_PanelAverages)
    BEGIN
        SELECT RowType, PanelName, PayerName, PayerRank, NoOfClaims, TotalCharges, AvgBilled, CarrierPayment,
               FullyPaidCount, FullyPaidAmount, AvgFullyPaid, AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,
               Days30Count, Days30Amount, AvgDays30, Days60Count, Days60Amount, AvgDays60, SortOrder
        FROM dbo.AnP_CS2_PanelAverages
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_AnP_CS_PanelAverages_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames,
        @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

/* -----------------------------------------------------------------------------
   Initial snapshot load
   ----------------------------------------------------------------------------- */
EXEC dbo.usp_RefreshAnP_CS_MonthlyClaimVolume;
EXEC dbo.usp_RefreshAnP_CS_WeeklyClaimVolume;
EXEC dbo.usp_RefreshAnP_CS_Top5ReimbursementPct;
EXEC dbo.usp_RefreshAnP_CS_Top5ReimbursementPay;
EXEC dbo.usp_RefreshAnP_CS_InsuranceVsPaymentPct;
EXEC dbo.usp_RefreshAnP_CS_InsuranceVsPayment;
EXEC dbo.usp_RefreshAnP_CS_InsuranceVsAging;
EXEC dbo.usp_RefreshAnP_CS_PanelVsPayment;
EXEC dbo.usp_RefreshAnP_CS_CptVsPaymentPct;
EXEC dbo.usp_RefreshAnP_CS_PanelAverages;
GO
