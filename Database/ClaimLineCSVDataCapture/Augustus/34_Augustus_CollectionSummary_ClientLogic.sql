/* =============================================================================
   Augustus - Collection Summary on the client logic sheet (2026-10-21)
   File     : 34_Augustus_CollectionSummary_ClientLogic.sql
   Database : Augustus_LRN

   NEW SP names only (*_v3, plus usp_GetAug_CS_AvgPayments_ClientLogic). The existing
   usp_GetAug_CS_* / *_v2 SPs and Aug_CS_* snapshot tables are not changed, so a
   dashboard build that still calls them keeps working. Every SP here reads
   ClaimLevelData live (about 40k claims).

   Source Claim Level. Claim Count = Count of unique ClaimID.
   Payer = PayerName_Raw, Panel = PanelCategory, Check Date = CheckDate.
   Rows sorted by Claim Count.

   S.No Tab                                 Filter                          Rows / Columns / Values
   1    Monthly                             InsurancePayment > 0            PanelCategory + Top 3 payers / CheckDate month + year
   2    Weekly                              InsurancePayment > 0,           PanelCategory + Top 3 payers / PostedWeek (Week 1..4;
                                            PostedWeek not blank            range = that week's CheckDate span)
   3    Top 5 Reimbursement % vs Billed     InsurancePayment > 0            Top 5 payers by Claim Count; Average(Payment %)
   4    Top 5 Insurance by Payments         InsurancePayment > 0            Top 5 payers by Claim Count; Sum(InsurancePayment)
   5    No Response vs Aging                ClaimStatus = No Response       Source > PayerName_Raw / Aging; Claims, Sum InsuranceBalance
   6    Insurance vs Payment %              InsurancePayment > 0            PayerName_Raw; Claims, Average(Payment %)
   7    Panel Vs Payment (Cove logic)       Billed: BillingStatus = Billed /  PanelCategory / FirstBilledDate month + year;
                                                    Client Billing          Billed Claims, Sum ChargeAmount (billed),
                                            Paid  : InsurancePayment > 0,   Paid Claims, Sum InsurancePayment (paid)
                                                    CheckDate not blank
   8    Payer vs Payment                    InsurancePayment > 0            PayerName_Raw / CheckDate month + year;
                                                                            Claims, Sum InsurancePayment
        Panel Averages - by DOS /           BillingStatus = Billed,         PanelCategory + Top 3 payers;
        by Check Date                       last 6 months of DOS / CheckDate Billed, Fully Paid, Adjudicated,
                                            ending at the billed week end   30 Bucket, 60 Bucket (count, sum, average)

   Payment % = ClaimLevelData.PaymentPercent (a fraction) x 100.
   Page filters: @PayerNames = PayerName_Raw, @PanelNames = PanelCategory ('Unknown' = blank),
   @DosFrom/To = DateofService, @FirstBillFrom/To = FirstBilledDate, @CheckDateFrom/To = CheckDate.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'Augustus_LRN'
BEGIN
    RAISERROR(N'Run 34_Augustus_CollectionSummary_ClientLogic.sql on the Augustus_LRN database.', 16, 1);
    SET NOEXEC ON;
END;
GO

/* -----------------------------------------------------------------------------
   Shared claim rows + dashboard filters
   ----------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_Aug_CS_Claims
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
        ClaimKey      = NULLIF(LTRIM(RTRIM(c.ClaimID)), N''),
        n.PayerName,
        n.PanelName,
        Source        = ISNULL(NULLIF(LTRIM(RTRIM(c.Source)), N''), N'(blank)'),
        ClaimStatus   = ISNULL(NULLIF(LTRIM(RTRIM(c.ClaimStatus)), N''), N'(blank)'),
        BillingStatus = LTRIM(RTRIM(ISNULL(c.BillingStatus, N''))),
        Adjudicated   = LTRIM(RTRIM(c.Adjudicated)),
        Bucket30      = LTRIM(RTRIM(c.Bucket30)),
        Bucket60      = LTRIM(RTRIM(c.Bucket60)),
        Aging         = NULLIF(LTRIM(RTRIM(c.Aging)), N''),
        PostedWeek    = NULLIF(LTRIM(RTRIM(c.PostedWeek)), N''),
        d.Dos,
        d.CheckDt,
        d.FirstBill,
        InsPay        = ISNULL(TRY_CAST(c.InsurancePayment AS DECIMAL(18,2)), 0),
        ChargeAmt     = ISNULL(TRY_CAST(c.ChargeAmount     AS DECIMAL(18,2)), 0),
        PaymentPct    = TRY_CAST(c.PaymentPercent AS DECIMAL(18,6)) * 100,
        InsBalance    = ISNULL(TRY_CAST(c.InsuranceBalance AS DECIMAL(18,2)), 0)
    FROM dbo.ClaimLevelData c
    CROSS APPLY (SELECT
        PayerName = ISNULL(NULLIF(LTRIM(RTRIM(c.PayerName_Raw)), N''), N'Unknown'),
        PanelName = ISNULL(NULLIF(LTRIM(RTRIM(c.PanelCategory)), N''), N'Unknown')) n
    CROSS APPLY (SELECT
        Dos       = COALESCE(TRY_CONVERT(DATE, c.DateofService,   101), TRY_CAST(c.DateofService   AS DATE)),
        CheckDt   = COALESCE(TRY_CONVERT(DATE, c.CheckDate,       101), TRY_CAST(c.CheckDate       AS DATE)),
        FirstBill = COALESCE(TRY_CONVERT(DATE, c.FirstBilledDate, 101), TRY_CAST(c.FirstBilledDate AS DATE))) p
    CROSS APPLY (SELECT
        Dos       = CASE WHEN p.Dos       >= '19010101' THEN p.Dos       END,
        CheckDt   = CASE WHEN p.CheckDt   >= '19010101' THEN p.CheckDt   END,
        FirstBill = CASE WHEN p.FirstBill >= '19010101' THEN p.FirstBill END) d
    WHERE (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR n.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
           OR n.PanelName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|')))
      AND (@DosFrom       IS NULL OR d.Dos       >= @DosFrom)
      AND (@DosTo         IS NULL OR d.Dos       <= @DosTo)
      AND (@FirstBillFrom IS NULL OR d.FirstBill >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR d.FirstBill <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR d.CheckDt   >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR d.CheckDt   <= @CheckDateTo);
GO

/* Billed week-range end date: end of the latest LineClaimFileLogs.WeekFolder ("MM.dd.yyyy - MM.dd.yyyy"). */
CREATE OR ALTER FUNCTION dbo.fn_Aug_CS_LatestWeekFolderEnd()
RETURNS DATE
AS
BEGIN
    DECLARE @WeekFolder NVARCHAR(200);

    SELECT TOP 1 @WeekFolder = LTRIM(RTRIM(CAST(WeekFolder AS NVARCHAR(200))))
    FROM dbo.LineClaimFileLogs
    WHERE NULLIF(LTRIM(RTRIM(CAST(WeekFolder AS NVARCHAR(200)))), N'') IS NOT NULL
    ORDER BY FileLogId DESC;

    IF CHARINDEX(N'-', ISNULL(@WeekFolder, N'')) = 0
        RETURN NULL;

    RETURN TRY_CONVERT(DATE,
        REPLACE(LTRIM(RTRIM(RIGHT(@WeekFolder, CHARINDEX(N'-', REVERSE(@WeekFolder)) - 1))), N'.', N'/'), 101);
END;
GO

/* -----------------------------------------------------------------------------
   1. Monthly - PanelCategory x CheckDate month. Every payer is returned with its rank
      in the panel (claim count); the page shows the panel total plus PayerRank 1-3.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_MonthlyClaimVolume_v3
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT PanelName, PayerName,
           BillYear  = YEAR(CheckDt),
           BillMonth = MONTH(CheckDt),
           NoOfClaims       = COUNT(DISTINCT ClaimKey),
           InsurancePayment = SUM(InsPay)
    INTO #a
    FROM dbo.fn_Aug_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    WHERE InsPay > 0
      AND CheckDt IS NOT NULL
    GROUP BY PanelName, PayerName, YEAR(CheckDt), MONTH(CheckDt)
    OPTION (RECOMPILE);

    SELECT PanelName, PayerName,
           PayerRank = ROW_NUMBER() OVER (PARTITION BY PanelName
                                          ORDER BY SUM(NoOfClaims) DESC, SUM(InsurancePayment) DESC, PayerName)
    INTO #r
    FROM #a
    GROUP BY PanelName, PayerName;

    SELECT a.PanelName,
           a.PayerName,
           PayerRank        = CAST(CASE WHEN r.PayerRank > 255 THEN 255 ELSE r.PayerRank END AS TINYINT),
           BillYear         = CAST(a.BillYear  AS INT),
           BillMonth        = CAST(a.BillMonth AS TINYINT),
           a.NoOfClaims,
           InsurancePayment = CAST(a.InsurancePayment AS DECIMAL(18,2))
    FROM #a a
    JOIN #r r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY a.PanelName, r.PayerRank, a.BillYear, a.BillMonth;
END;
GO

/* -----------------------------------------------------------------------------
   2. Weekly - one column per PostedWeek label (Week 1..4, the lab's posted week).
      WeekStart / WeekEnd = first / last CheckDate of that PostedWeek across all claims.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_WeeklyClaimVolume_v3
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #Weeks
    (
        WeekLabel NVARCHAR(64) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
        WeekStart DATE NOT NULL,
        WeekEnd   DATE NOT NULL,
        WeekKey   TINYINT NOT NULL
    );

    INSERT INTO #Weeks (WeekLabel, WeekStart, WeekEnd, WeekKey)
    SELECT PostedWeek, MIN(CheckDt), MAX(CheckDt),
           CAST(ROW_NUMBER() OVER (ORDER BY MIN(CheckDt), PostedWeek) AS TINYINT)
    FROM dbo.fn_Aug_CS_Claims(NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
    WHERE PostedWeek IS NOT NULL
      AND CheckDt IS NOT NULL
    GROUP BY PostedWeek;

    SELECT c.PanelName, c.PayerName, w.WeekKey, w.WeekStart, w.WeekEnd,
           NoOfClaims       = COUNT(DISTINCT c.ClaimKey),
           InsurancePayment = SUM(c.InsPay)
    INTO #a
    FROM dbo.fn_Aug_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) c
    JOIN #Weeks w ON w.WeekLabel = c.PostedWeek
    WHERE c.InsPay > 0
    GROUP BY c.PanelName, c.PayerName, w.WeekKey, w.WeekStart, w.WeekEnd
    OPTION (RECOMPILE);

    SELECT PanelName, PayerName,
           PayerRank = ROW_NUMBER() OVER (PARTITION BY PanelName
                                          ORDER BY SUM(NoOfClaims) DESC, SUM(InsurancePayment) DESC, PayerName)
    INTO #r
    FROM #a
    GROUP BY PanelName, PayerName;

    SELECT a.PanelName,
           a.PayerName,
           PayerRank         = CAST(CASE WHEN r.PayerRank > 255 THEN 255 ELSE r.PayerRank END AS TINYINT),
           a.WeekKey,
           a.WeekStart,
           a.WeekEnd,
           a.NoOfClaims,
           InsurancePayment  = CAST(a.InsurancePayment AS DECIMAL(18,2)),
           AveragePaidAmount = CAST(a.InsurancePayment / NULLIF(a.NoOfClaims, 0) AS DECIMAL(18,2))
    FROM #a a
    JOIN #r r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY a.PanelName, r.PayerRank, a.WeekKey;
END;
GO

/* -----------------------------------------------------------------------------
   3. Top 5 Reimbursement % vs Billed Charges - top 5 payers by Claim Count.
      PaymentPct = Average(Payment %) of the payer's claims;
      TotalPaymentPct = over every claim of the 5 payers.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_Top5ReimbursementPct_v3
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH p AS (
        SELECT PayerName,
               Claims = COUNT(DISTINCT ClaimKey),
               InsPay = SUM(InsPay),
               Charge = SUM(ChargeAmt),
               AvgPct = AVG(PaymentPct),
               PctSum = SUM(PaymentPct),
               PctCnt = COUNT(PaymentPct)
        FROM dbo.fn_Aug_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                  @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
        GROUP BY PayerName
    ),
    top5 AS (
        SELECT TOP 5 *
        FROM p
        ORDER BY Claims DESC, InsPay DESC, PayerName
    )
    SELECT PayerRank           = CAST(ROW_NUMBER() OVER (ORDER BY Claims DESC, InsPay DESC, PayerName) AS TINYINT),
           PayerName,
           SumInsurancePayment = CAST(InsPay AS DECIMAL(18,2)),
           SumChargeAmount     = CAST(Charge AS DECIMAL(18,2)),
           UniqueVisitCount    = Claims,
           PaymentPct          = CAST(ROUND(ISNULL(AvgPct, 0), 2) AS DECIMAL(9,2)),
           TotalPaymentPct     = CAST(ROUND(ISNULL(SUM(PctSum) OVER () / NULLIF(SUM(PctCnt) OVER (), 0), 0), 2) AS DECIMAL(9,2))
    FROM top5
    ORDER BY PayerRank
    OPTION (RECOMPILE);
END;
GO

/* -----------------------------------------------------------------------------
   4. Top 5 Insurance by Payments - top 5 payers by Claim Count; Sum(InsurancePayment).
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_Top5ReimbursementPay_v3
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH p AS (
        SELECT PayerName,
               Claims = COUNT(DISTINCT ClaimKey),
               InsPay = SUM(InsPay)
        FROM dbo.fn_Aug_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                  @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
        GROUP BY PayerName
    ),
    top5 AS (
        SELECT TOP 5 *
        FROM p
        ORDER BY Claims DESC, InsPay DESC, PayerName
    )
    SELECT PayerRank        = CAST(ROW_NUMBER() OVER (ORDER BY Claims DESC, InsPay DESC, PayerName) AS TINYINT),
           PayerName,
           TotalPayments    = CAST(InsPay AS DECIMAL(18,2)),
           UniqueVisitCount = Claims
    FROM top5
    ORDER BY PayerRank
    OPTION (RECOMPILE);
END;
GO

/* -----------------------------------------------------------------------------
   5. No Response vs Aging - ClaimStatus = No Response; Source > PayerName_Raw x Aging.
      Sources and their payers sorted by claim count.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_InsuranceVsAging_v3
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH b AS (
        SELECT Source,
               PayerName,
               AgingBucket = CASE Aging
                                 WHEN N'Current' THEN N'Current'
                                 WHEN N'30+'     THEN N'30 Days'
                                 WHEN N'60+'     THEN N'60 Days'
                                 WHEN N'90+'     THEN N'90 Days'
                                 WHEN N'120+'    THEN N'120+ Days'
                                 ELSE ISNULL(Aging, N'(blank)')
                             END,
               ClaimKey,
               InsBalance
        FROM dbo.fn_Aug_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                  @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE ClaimStatus = N'No Response'
    ),
    a AS (
        SELECT Source, PayerName, AgingBucket,
               VisitCount       = COUNT(DISTINCT ClaimKey),
               InsuranceBalance = SUM(InsBalance)
        FROM b
        GROUP BY Source, PayerName, AgingBucket
    ),
    s AS (
        SELECT Source,
               SourceOrder = ROW_NUMBER() OVER (ORDER BY SUM(VisitCount) DESC, SUM(InsuranceBalance) DESC, Source)
        FROM a
        GROUP BY Source
    ),
    p AS (
        SELECT Source, PayerName,
               PayerOrder = ROW_NUMBER() OVER (PARTITION BY Source
                                               ORDER BY SUM(VisitCount) DESC, SUM(InsuranceBalance) DESC, PayerName)
        FROM a
        GROUP BY Source, PayerName
    )
    SELECT a.Source,
           a.PayerName,
           a.AgingBucket,
           a.VisitCount,
           InsuranceBalance = CAST(a.InsuranceBalance AS DECIMAL(18,2)),
           SortOrder        = CAST(ROW_NUMBER() OVER (ORDER BY s.SourceOrder, p.PayerOrder,
                                   CASE a.AgingBucket WHEN N'Current' THEN 1 WHEN N'30 Days' THEN 2 WHEN N'60 Days' THEN 3
                                                      WHEN N'90 Days' THEN 4 WHEN N'120+ Days' THEN 5 ELSE 6 END) AS INT)
    FROM a
    JOIN s ON s.Source = a.Source
    JOIN p ON p.Source = a.Source AND p.PayerName = a.PayerName
    ORDER BY SortOrder
    OPTION (RECOMPILE);
END;
GO

/* -----------------------------------------------------------------------------
   6. Insurance vs Payment % - PayerName_Raw; Claims + Average(Payment %).
      TotalPaymentPct = Average(Payment %) over every claim in the result.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_InsuranceVsPaymentPct_v3
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH p AS (
        SELECT PayerName,
               NoOfClaims       = COUNT(DISTINCT ClaimKey),
               InsurancePayment = SUM(InsPay),
               AvgPct           = AVG(PaymentPct),
               PctSum           = SUM(PaymentPct),
               PctCnt           = COUNT(PaymentPct)
        FROM dbo.fn_Aug_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                  @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
        GROUP BY PayerName
    )
    SELECT PayerName,
           NoOfClaims,
           InsurancePayment = CAST(InsurancePayment AS DECIMAL(18,2)),
           AvgPaymentPct    = CAST(ROUND(ISNULL(AvgPct, 0), 2) AS DECIMAL(9,2)),
           TotalPaymentPct  = CAST(ROUND(ISNULL(SUM(PctSum) OVER () / NULLIF(SUM(PctCnt) OVER (), 0), 0), 2) AS DECIMAL(9,2)),
           SortOrder        = CAST(ROW_NUMBER() OVER (ORDER BY NoOfClaims DESC, InsurancePayment DESC, PayerName) AS INT)
    FROM p
    ORDER BY SortOrder
    OPTION (RECOMPILE);
END;
GO

/* -----------------------------------------------------------------------------
   7. Panel Vs Payment - PanelCategory x FirstBilledDate year / month, Cove's billed / paid
      logic (24_Cove_CS_PanelVsPayment_BilledPaid.sql). Augustus has no BillStatus column:
      BillingStatus "Client Billing" is its "Billed - Client Bill".
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_PanelVsPayment_v3
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH c AS (
        SELECT PanelName, ClaimKey, FirstBill, ChargeAmt, InsPay,
               IsBilled = CASE WHEN BillingStatus IN (N'Billed', N'Client Billing') THEN 1 ELSE 0 END,
               IsPaid   = CASE WHEN InsPay > 0 AND CheckDt IS NOT NULL THEN 1 ELSE 0 END
        FROM dbo.fn_Aug_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                  @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    )
    SELECT PanelName,
           BilledYear        = CAST(YEAR(FirstBill)  AS SMALLINT),
           BilledMonth       = CAST(MONTH(FirstBill) AS TINYINT),
           BilledClaims      = CAST(COUNT(DISTINCT CASE WHEN IsBilled = 1 THEN ClaimKey END) AS INT),
           BilledCharges     = CAST(ISNULL(SUM(CASE WHEN IsBilled = 1 THEN ChargeAmt END), 0) AS DECIMAL(18,2)),
           NoOfClaims        = CAST(COUNT(DISTINCT CASE WHEN IsPaid = 1 THEN ClaimKey END) AS INT),
           InsurancePayments = CAST(ISNULL(SUM(CASE WHEN IsPaid = 1 THEN InsPay END), 0) AS DECIMAL(18,2))
    FROM c
    WHERE FirstBill IS NOT NULL
      AND (IsBilled = 1 OR IsPaid = 1)
    GROUP BY PanelName, YEAR(FirstBill), MONTH(FirstBill)
    ORDER BY PanelName, BilledYear, BilledMonth
    OPTION (RECOMPILE);
END;
GO

/* -----------------------------------------------------------------------------
   8. Payer vs Payment - PayerName_Raw x CheckDate year / month;
      Claims + Sum(InsurancePayment). PaymentPct = payer share of the month.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_InsuranceVsPayment_v3
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH agg AS (
        SELECT PayerName,
               BillYear         = YEAR(CheckDt),
               BillMonth        = MONTH(CheckDt),
               NoOfPaidClaims   = COUNT(DISTINCT ClaimKey),
               InsurancePayment = SUM(InsPay)
        FROM dbo.fn_Aug_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                  @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
          AND CheckDt IS NOT NULL
        GROUP BY PayerName, YEAR(CheckDt), MONTH(CheckDt)
    ),
    grand AS (
        SELECT BillYear, BillMonth, TotalInsurancePayment = NULLIF(SUM(InsurancePayment), 0)
        FROM agg
        GROUP BY BillYear, BillMonth
    )
    SELECT a.PayerName,
           BillYear         = CAST(a.BillYear  AS INT),
           BillMonth        = CAST(a.BillMonth AS TINYINT),
           a.NoOfPaidClaims,
           InsurancePayment = CAST(a.InsurancePayment AS DECIMAL(18,2)),
           PaymentPct       = CAST(a.InsurancePayment * 100.0 / ISNULL(g.TotalInsurancePayment, 1) AS DECIMAL(9,4))
    FROM agg a
    JOIN grand g ON g.BillYear = a.BillYear AND g.BillMonth = a.BillMonth
    ORDER BY a.BillYear, a.BillMonth, a.NoOfPaidClaims DESC
    OPTION (RECOMPILE);
END;
GO

/* -----------------------------------------------------------------------------
   Panel Averages - by DOS / by Check Date.
   BillingStatus = Billed; @LastMonths months of DateofService or CheckDate ending at
   the billed week-range end date (latest date in that column when there is no week
   folder). Returns every payer; the page shows panel totals plus the top 3 payers.
     Billed       Count unique ClaimID, Sum ChargeAmount
     Fully Paid   ClaimStatus = Fully Paid,       Sum InsurancePayment
     Adjudicated  Adjudicated = Adjudicated,      Sum InsurancePayment
     30 Days      Bucket30    = 30 Bucket,        Sum InsurancePayment
     60 Days      Bucket60    = 60 Bucket,        Sum InsurancePayment
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_AvgPayments_ClientLogic
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL,
    @DateBasis     VARCHAR(10)   = 'DOS',
    @LastMonths    INT           = 6
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @UseCheckDate BIT = CASE WHEN @DateBasis = 'CheckDate' THEN 1 ELSE 0 END;
    IF @LastMonths IS NULL OR @LastMonths < 1 SET @LastMonths = 6;

    SELECT PanelName, PayerName, ClaimKey, ChargeAmt, InsPay, ClaimStatus, Adjudicated, Bucket30, Bucket60,
           BasisDt = CASE WHEN @UseCheckDate = 1 THEN CheckDt ELSE Dos END
    INTO #b
    FROM dbo.fn_Aug_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    WHERE BillingStatus = N'Billed'
    OPTION (RECOMPILE);

    DECLARE @WindowTo   DATE = ISNULL(dbo.fn_Aug_CS_LatestWeekFolderEnd(), (SELECT MAX(BasisDt) FROM #b));
    DECLARE @WindowFrom DATE = DATEADD(DAY, 1, DATEADD(MONTH, -@LastMonths, @WindowTo));

    SELECT PanelName,
           PayerName,
           NoOfClaims        = CAST(COUNT(DISTINCT ClaimKey) AS INT),
           TotalCharges      = CAST(ISNULL(SUM(ChargeAmt), 0) AS DECIMAL(18,2)),
           CarrierPayment    = CAST(ISNULL(SUM(InsPay), 0) AS DECIMAL(18,2)),
           FullyPaidCount    = CAST(COUNT(DISTINCT CASE WHEN ClaimStatus = N'Fully Paid' THEN ClaimKey END) AS INT),
           FullyPaidAmount   = CAST(ISNULL(SUM(CASE WHEN ClaimStatus = N'Fully Paid' THEN InsPay END), 0) AS DECIMAL(18,2)),
           AdjudicatedCount  = CAST(COUNT(DISTINCT CASE WHEN Adjudicated = N'Adjudicated' THEN ClaimKey END) AS INT),
           AdjudicatedAmount = CAST(ISNULL(SUM(CASE WHEN Adjudicated = N'Adjudicated' THEN InsPay END), 0) AS DECIMAL(18,2)),
           Days30Count       = CAST(COUNT(DISTINCT CASE WHEN Bucket30 = N'30 Bucket' THEN ClaimKey END) AS INT),
           Days30Amount      = CAST(ISNULL(SUM(CASE WHEN Bucket30 = N'30 Bucket' THEN InsPay END), 0) AS DECIMAL(18,2)),
           Days60Count       = CAST(COUNT(DISTINCT CASE WHEN Bucket60 = N'60 Bucket' THEN ClaimKey END) AS INT),
           Days60Amount      = CAST(ISNULL(SUM(CASE WHEN Bucket60 = N'60 Bucket' THEN InsPay END), 0) AS DECIMAL(18,2)),
           WindowFrom        = @WindowFrom,
           WindowTo          = @WindowTo
    FROM #b
    WHERE BasisDt BETWEEN @WindowFrom AND @WindowTo
    GROUP BY PanelName, PayerName
    ORDER BY PanelName, NoOfClaims DESC, PayerName;
END;
GO

/* Filter dropdowns: PayerName_Raw and PanelCategory, the values the tabs group by. */
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_FilterOptions_v3
AS
BEGIN
    SET NOCOUNT ON;

    SELECT DISTINCT PayerName FROM dbo.fn_Aug_CS_Claims(NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ORDER BY PayerName;
    SELECT DISTINCT PanelName FROM dbo.fn_Aug_CS_Claims(NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) ORDER BY PanelName;
END;
GO

SET NOEXEC OFF;
GO

PRINT '34_Augustus_CollectionSummary_ClientLogic.sql completed.';
GO
