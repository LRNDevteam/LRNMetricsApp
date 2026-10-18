/* =============================================================================
   NorthWest - Collection Summary on the client logic sheet
   File     : 39_NW_CollectionSummary_ClientLogic.sql
   Database : NWL_LRN

   Source Claim Level unless noted. Claim Count = Count of unique Claim ID.
   Payer = PayerName_Raw, Panel = PanelType, Check Date = CheckDate.

   Tab                                 Filter                       Rows / Columns / Values
   Monthly                             (15_..._ReadSPs - InsurancePayment > 0, CheckDate valid; PanelType + Top 5 payers
                                                                    / CheckDate month + year; the app keeps PayerRank 1-5)
   Weekly                              InsurancePayment > 0         PanelType + Top 5 payers / Thu-Wed Check Date weeks
                                                                    (Week 4 ends on the billed week-range end date)
   Top 5 Reimbursement % vs Billed     InsurancePayment > 0         Top 5 payers by Insurance Payment, listed by Claim Count;
                                                                    Average(Payment %)
   Top 5 Insurance by Payments         InsurancePayment > 0         Top 5 payers by Sum(InsurancePayment), listed by Claim Count
   Status Summary                      none                         ClaimStatus > CPTCodeXUnitsXModifier > Payer;
                                                                    Claims, Sum ChargeAmount / InsuranceBalance / PatientBalance
   By Provider                         none                         ReferringProvider; same values as Status Summary
   Insurance vs Aging                  ClaimStatus = No Response    Payer / Aging; Claims, Sum InsuranceBalance
   Insurance vs Payment %              InsurancePayment > 0         Payer; Claims, Average(Payment %)
   Panel Vs Payment                    see 42_NW_CollectionSummary_BilledUnbilled.sql
   Payer vs Payment                    InsurancePayment > 0         Payer / CheckDate (stored by month; the page shows year
                                                                    totals); Claims, Sum InsurancePayment
   Women's Health Panel breakdown      PanelType = Women's Health   ReferringProvider; Claims, Sum ChargeAmount /
                                                                    InsurancePayment / InsuranceBalance (live)
   CPT vs Payment %                    Line Level, CPT not blank    CPT Code; Claims, Average(line Payment %)
                                                                    (line Payment % = InsurancePayment / ChargeAmount)
   Panel Averages - by DOS / by        BilledUnbilled = Billed      PanelType + payers; last 6 months of DOS or CheckDate
   Check Date                                                       ending at the billed week-range end date (live)

   Payment % = ClaimLevelData.PaymentPercent (a fraction) x 100.
   Rows are sorted by Claim Count unless the tab ranks by Insurance Payment (Top 5).

   Each usp_GetNW_CS_* returns its snapshot table when no filter is passed; with filters
   (or @Live = 1) it computes the same result from ClaimLevelData / LineLevelData.
   Each usp_RefreshNW_CS_* stores the @Live = 1 result.
   ============================================================================= */

IF DB_NAME() <> N'NWL_LRN'
BEGIN
    RAISERROR(N'39_NW_CollectionSummary_ClientLogic.sql must run on NWL_LRN.', 16, 1);
    SET NOEXEC ON;
END;
GO

/* -----------------------------------------------------------------------------
   Shared claim rows + dashboard filters
   ----------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_NW_CS_Claims
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
        n.PayerName,
        n.PanelName,
        ClaimStatus       = ISNULL(NULLIF(LTRIM(RTRIM(c.ClaimStatus)), N''), N'(blank)'),
        Adjudicated       = LTRIM(RTRIM(c.Adjudicated)),
        Bucket30          = LTRIM(RTRIM(c.Bucket30)),
        Bucket60          = LTRIM(RTRIM(c.Bucket60)),
        Aging             = NULLIF(LTRIM(RTRIM(c.Aging)), N''),
        d.Dos,
        d.CheckDt,
        d.FirstBill,
        d.ChargeEntered,
        BilledUnbilled    = LTRIM(RTRIM(c.BilledUnbilled)),
        InsPay            = ISNULL(TRY_CAST(c.InsurancePayment AS DECIMAL(18,2)), 0),
        ChargeAmt         = ISNULL(TRY_CAST(c.ChargeAmount     AS DECIMAL(18,2)), 0),
        PaymentPct        = TRY_CAST(c.PaymentPercent AS DECIMAL(18,6)) * 100,
        InsBalance        = ISNULL(TRY_CAST(c.InsuranceBalance AS DECIMAL(18,2)), 0),
        PatientBalance    = ISNULL(TRY_CAST(c.PatientBalance   AS DECIMAL(18,2)), 0),
        CptCode           = ISNULL(NULLIF(LTRIM(RTRIM(c.CPTCodeXUnitsXModifier)), N''), N'(blank)'),
        ReferringProvider = NULLIF(LTRIM(RTRIM(c.ReferringProvider)), N'')
    FROM dbo.ClaimLevelData c
    CROSS APPLY (SELECT
        PayerName = ISNULL(NULLIF(LTRIM(RTRIM(c.PayerName_Raw)), N''), N'Unknown'),
        PanelName = ISNULL(NULLIF(LTRIM(RTRIM(c.PanelType)),     N''), N'Unknown')) n
    CROSS APPLY (SELECT
        Dos       = COALESCE(TRY_CONVERT(DATE, c.DateOfService,   101), TRY_CAST(c.DateOfService   AS DATE)),
        CheckDt   = COALESCE(TRY_CONVERT(DATE, c.CheckDate,       101), TRY_CAST(c.CheckDate       AS DATE)),
        FirstBill = COALESCE(TRY_CONVERT(DATE, c.FirstBilledDate, 101), TRY_CAST(c.FirstBilledDate AS DATE)),
        ChargeEntered = COALESCE(TRY_CONVERT(DATE, c.ChargeEnteredDate, 101), TRY_CAST(c.ChargeEnteredDate AS DATE))) p
    -- 12/31/1899 is the file's blank-date placeholder.
    CROSS APPLY (SELECT
        Dos       = CASE WHEN p.Dos       >= '19010101' THEN p.Dos       END,
        CheckDt   = CASE WHEN p.CheckDt   >= '19010101' THEN p.CheckDt   END,
        FirstBill = CASE WHEN p.FirstBill >= '19010101' THEN p.FirstBill END,
        ChargeEntered = CASE WHEN p.ChargeEntered >= '19010101' THEN p.ChargeEntered END) d
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
CREATE OR ALTER FUNCTION dbo.fn_NW_CS_LatestWeekFolderEnd()
RETURNS DATE
AS
BEGIN
    DECLARE @WeekFolder NVARCHAR(200);

    SELECT TOP 1 @WeekFolder = LTRIM(RTRIM(CAST(WeekFolder AS NVARCHAR(200))))
    FROM dbo.LineClaimFileLogs
    WHERE NULLIF(LTRIM(RTRIM(CAST(RunId AS NVARCHAR(50)))), N'') IS NOT NULL
    ORDER BY FileLogId DESC;

    IF CHARINDEX(N'-', ISNULL(@WeekFolder, N'')) = 0
        RETURN NULL;

    RETURN TRY_CONVERT(DATE,
        REPLACE(LTRIM(RTRIM(RIGHT(@WeekFolder, CHARINDEX(N'-', REVERSE(@WeekFolder)) - 1))), N'.', N'/'), 101);
END;
GO

/* -----------------------------------------------------------------------------
   Snapshot tables whose columns change
   ----------------------------------------------------------------------------- */
DROP TABLE IF EXISTS dbo.NW_CS_Top5ReimbursementPct;
CREATE TABLE dbo.NW_CS_Top5ReimbursementPct
(
    SummaryId           INT IDENTITY(1,1) PRIMARY KEY,
    PayerRank           TINYINT        NOT NULL,
    PayerName           NVARCHAR(500)  NOT NULL,
    SumInsurancePayment DECIMAL(18,2)  NOT NULL DEFAULT 0,
    SumChargeAmount     DECIMAL(18,2)  NOT NULL DEFAULT 0,
    UniqueVisitCount    INT            NOT NULL DEFAULT 0,
    PaymentPct          DECIMAL(9,2)   NOT NULL DEFAULT 0,
    TotalPaymentPct     DECIMAL(9,2)   NOT NULL DEFAULT 0,
    RefreshedAt         DATETIME       NOT NULL DEFAULT GETDATE()
);

DROP TABLE IF EXISTS dbo.NW_CS_InsuranceVsAging;
CREATE TABLE dbo.NW_CS_InsuranceVsAging
(
    SummaryId        INT IDENTITY(1,1) PRIMARY KEY,
    PayerName        NVARCHAR(500)  NOT NULL,
    AgingBucket      NVARCHAR(200)  NOT NULL,
    VisitCount       INT            NOT NULL DEFAULT 0,
    InsuranceBalance DECIMAL(18,2)  NOT NULL DEFAULT 0,
    SortOrder        INT            NOT NULL,
    RefreshedAt      DATETIME       NOT NULL DEFAULT GETDATE()
);

DROP TABLE IF EXISTS dbo.NW_CS_InsuranceVsPaymentPct;
CREATE TABLE dbo.NW_CS_InsuranceVsPaymentPct
(
    SummaryId        INT IDENTITY(1,1) PRIMARY KEY,
    PayerName        NVARCHAR(500)  NOT NULL,
    NoOfClaims       INT            NOT NULL DEFAULT 0,
    InsurancePayment DECIMAL(18,2)  NOT NULL DEFAULT 0,
    AvgPaymentPct    DECIMAL(9,2)   NOT NULL DEFAULT 0,
    TotalPaymentPct  DECIMAL(9,2)   NOT NULL DEFAULT 0,
    SortOrder        INT            NOT NULL,
    RefreshedAt      DATETIME       NOT NULL DEFAULT GETDATE()
);

DROP TABLE IF EXISTS dbo.NW_CS_CptVsPaymentPct;
CREATE TABLE dbo.NW_CS_CptVsPaymentPct
(
    SummaryId       INT IDENTITY(1,1) PRIMARY KEY,
    CPTCode         NVARCHAR(200)  NOT NULL,
    NoOfClaims      INT            NOT NULL DEFAULT 0,
    AvgPaymentPct   DECIMAL(9,2)   NOT NULL DEFAULT 0,
    TotalPaymentPct DECIMAL(9,2)   NOT NULL DEFAULT 0,
    SortOrder       INT            NOT NULL,
    RefreshedAt     DATETIME       NOT NULL DEFAULT GETDATE()
);

DROP TABLE IF EXISTS dbo.NW_CS_StatusSummary;
CREATE TABLE dbo.NW_CS_StatusSummary
(
    SummaryId        INT IDENTITY(1,1) PRIMARY KEY,
    ClaimStatus      NVARCHAR(200)  NOT NULL,
    CptCode          NVARCHAR(MAX)  NOT NULL,
    PayerName        NVARCHAR(500)  NOT NULL,
    NoOfClaims       INT            NOT NULL DEFAULT 0,
    ChargeAmount     DECIMAL(18,2)  NOT NULL DEFAULT 0,
    InsurancePayment DECIMAL(18,2)  NOT NULL DEFAULT 0,
    InsuranceBalance DECIMAL(18,2)  NOT NULL DEFAULT 0,
    PatientBalance   DECIMAL(18,2)  NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME       NOT NULL DEFAULT GETDATE()
);

DROP TABLE IF EXISTS dbo.NW_CS_ProviderSummary;
CREATE TABLE dbo.NW_CS_ProviderSummary
(
    SummaryId         INT IDENTITY(1,1) PRIMARY KEY,
    ProviderRank      INT            NOT NULL,
    ReferringProvider NVARCHAR(500)  NOT NULL,
    NoOfClaims        INT            NOT NULL DEFAULT 0,
    ChargeAmount      DECIMAL(18,2)  NOT NULL DEFAULT 0,
    InsurancePayment  DECIMAL(18,2)  NOT NULL DEFAULT 0,
    InsuranceBalance  DECIMAL(18,2)  NOT NULL DEFAULT 0,
    PatientBalance    DECIMAL(18,2)  NOT NULL DEFAULT 0,
    RefreshedAt       DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

/* -----------------------------------------------------------------------------
   2. Weekly - PanelType + Top 5 payers; four Thursday-Wednesday Check Date weeks,
      Week 4 ending on the Wednesday on/after the billed week-range end date
      (latest CheckDate when there is no week folder). Every payer is returned so
      panel totals include all payers; the app shows PayerRank 1-5 (by claim count).
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CS_WeeklyClaimVolume
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL,
    @Live          BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) IS NULL
    BEGIN
        SELECT PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment,
               AveragePaidAmount = CAST(InsurancePayment / NULLIF(NoOfClaims, 0) AS DECIMAL(18,2))
        FROM dbo.NW_CS_WeeklyClaimVolume
        ORDER BY PanelName, PayerRank, WeekKey;
        RETURN;
    END;

    DECLARE @Anchor DATE = dbo.fn_NW_CS_LatestWeekFolderEnd();
    IF @Anchor IS NULL
        SELECT @Anchor = MAX(CheckDt)
        FROM dbo.fn_NW_CS_Claims(NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
        WHERE InsPay > 0 AND CheckDt <= CAST(GETDATE() AS DATE);

    -- 1900-01-03 was a Wednesday.
    DECLARE @W4End   DATE = DATEADD(DAY, (7 - DATEDIFF(DAY, '19000103', @Anchor) % 7) % 7, @Anchor);
    DECLARE @W1Start DATE = DATEADD(DAY, -27, @W4End);

    SELECT c.PanelName, c.PayerName,
           WeekKey = 4 - DATEDIFF(DAY, c.CheckDt, @W4End) / 7,
           c.ClaimKey, c.InsPay
    INTO #w
    FROM dbo.fn_NW_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                             @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) c
    WHERE c.InsPay > 0
      AND c.CheckDt BETWEEN @W1Start AND @W4End
    OPTION (RECOMPILE);

    SELECT PanelName, PayerName, WeekKey,
           NoOfClaims       = COUNT(DISTINCT ClaimKey),
           InsurancePayment = SUM(InsPay)
    INTO #a
    FROM #w
    GROUP BY PanelName, PayerName, WeekKey;

    SELECT PanelName, PayerName,
           PayerRank = ROW_NUMBER() OVER (PARTITION BY PanelName
                                          ORDER BY SUM(NoOfClaims) DESC, SUM(InsurancePayment) DESC, PayerName)
    INTO #r
    FROM #a
    GROUP BY PanelName, PayerName;

    SELECT a.PanelName,
           a.PayerName,
           PayerRank         = CAST(CASE WHEN r.PayerRank > 255 THEN 255 ELSE r.PayerRank END AS TINYINT),
           WeekKey           = CAST(a.WeekKey AS TINYINT),
           WeekStart         = DATEADD(DAY, -6 - 7 * (4 - a.WeekKey), @W4End),
           WeekEnd           = DATEADD(DAY,     -7 * (4 - a.WeekKey), @W4End),
           a.NoOfClaims,
           InsurancePayment  = CAST(a.InsurancePayment AS DECIMAL(18,2)),
           AveragePaidAmount = CAST(a.InsurancePayment / NULLIF(a.NoOfClaims, 0) AS DECIMAL(18,2))
    FROM #a a
    JOIN #r r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY a.PanelName, r.PayerRank, a.WeekKey;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CS_WeeklyClaimVolume
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        PanelName         NVARCHAR(500),
        PayerName         NVARCHAR(500),
        PayerRank         TINYINT,
        WeekKey           TINYINT,
        WeekStart         DATE,
        WeekEnd           DATE,
        NoOfClaims        INT,
        InsurancePayment  DECIMAL(18,2),
        AveragePaidAmount DECIMAL(18,2)
    );

    INSERT INTO #R
    EXEC dbo.usp_GetNW_CS_WeeklyClaimVolume @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_CS_WeeklyClaimVolume;
        INSERT INTO dbo.NW_CS_WeeklyClaimVolume
            (PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment, RefreshedAt)
        SELECT PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

/* -----------------------------------------------------------------------------
   3. Top 5 Reimbursement % vs Billed Charges - top 5 payers by Insurance Payment,
      listed by Claim Count. PaymentPct = Average(Payment %) of the payer's claims;
      TotalPaymentPct = over every claim of the 5 payers.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CS_Top5ReimbursementPct
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL,
    @Live          BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) IS NULL
    BEGIN
        SELECT PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount,
               PaymentPct, TotalPaymentPct
        FROM dbo.NW_CS_Top5ReimbursementPct
        ORDER BY PayerRank;
        RETURN;
    END;

    WITH p AS (
        SELECT PayerName,
               Claims = COUNT(ClaimKey),
               InsPay = SUM(InsPay),
               Charge = SUM(ChargeAmt),
               AvgPct = AVG(PaymentPct),
               PctSum = SUM(PaymentPct),
               PctCnt = COUNT(PaymentPct)
        FROM dbo.fn_NW_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
        GROUP BY PayerName
    ),
    top5 AS (
        SELECT TOP 5 *
        FROM p
        ORDER BY InsPay DESC, Claims DESC, PayerName
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

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CS_Top5ReimbursementPct
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        PayerRank           TINYINT,
        PayerName           NVARCHAR(500),
        SumInsurancePayment DECIMAL(18,2),
        SumChargeAmount     DECIMAL(18,2),
        UniqueVisitCount    INT,
        PaymentPct          DECIMAL(9,2),
        TotalPaymentPct     DECIMAL(9,2)
    );

    INSERT INTO #R
    EXEC dbo.usp_GetNW_CS_Top5ReimbursementPct @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_CS_Top5ReimbursementPct;
        INSERT INTO dbo.NW_CS_Top5ReimbursementPct
            (PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount, PaymentPct, TotalPaymentPct, RefreshedAt)
        SELECT PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount, PaymentPct, TotalPaymentPct, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

/* -----------------------------------------------------------------------------
   4. Top 5 Insurance by Payments - top 5 payers by Sum(InsurancePayment), listed by Claim Count.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CS_Top5ReimbursementPay
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL,
    @Live          BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) IS NULL
    BEGIN
        SELECT PayerRank, PayerName, TotalPayments, UniqueVisitCount
        FROM dbo.NW_CS_Top5ReimbursementPay
        ORDER BY PayerRank;
        RETURN;
    END;

    WITH p AS (
        SELECT PayerName,
               Claims = COUNT(ClaimKey),
               InsPay = SUM(InsPay)
        FROM dbo.fn_NW_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
        GROUP BY PayerName
    ),
    top5 AS (
        SELECT TOP 5 *
        FROM p
        ORDER BY InsPay DESC, Claims DESC, PayerName
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

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CS_Top5ReimbursementPay
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        PayerRank        TINYINT,
        PayerName        NVARCHAR(500),
        TotalPayments    DECIMAL(18,2),
        UniqueVisitCount INT
    );

    INSERT INTO #R
    EXEC dbo.usp_GetNW_CS_Top5ReimbursementPay @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_CS_Top5ReimbursementPay;
        INSERT INTO dbo.NW_CS_Top5ReimbursementPay (PayerRank, PayerName, TotalPayments, UniqueVisitCount, RefreshedAt)
        SELECT PayerRank, PayerName, TotalPayments, UniqueVisitCount, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

/* -----------------------------------------------------------------------------
   5. Status Summary - ClaimStatus > CPTCodeXUnitsXModifier > PayerName_Raw (no panel
      level: PanelName is blank). ChargeAmount is the money column on the page;
      InsurancePayment is kept for older readers.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CS_StatusSummary
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL,
    @Live          BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) IS NULL
    BEGIN
        SELECT ClaimStatus, PanelName = CAST(N'' AS NVARCHAR(500)), CptCode, PayerName,
               NoOfClaims, ChargeAmount, InsurancePayment, InsuranceBalance, PatientBalance
        FROM dbo.NW_CS_StatusSummary;
        RETURN;
    END;

    SELECT ClaimStatus,
           PanelName        = CAST(N'' AS NVARCHAR(500)),
           CptCode,
           PayerName,
           NoOfClaims       = COUNT(ClaimKey),
           ChargeAmount     = CAST(SUM(ChargeAmt)      AS DECIMAL(18,2)),
           InsurancePayment = CAST(SUM(InsPay)         AS DECIMAL(18,2)),
           InsuranceBalance = CAST(SUM(InsBalance)     AS DECIMAL(18,2)),
           PatientBalance   = CAST(SUM(PatientBalance) AS DECIMAL(18,2))
    FROM dbo.fn_NW_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                             @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    GROUP BY ClaimStatus, CptCode, PayerName
    OPTION (RECOMPILE);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CS_StatusSummary
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        ClaimStatus      NVARCHAR(200),
        PanelName        NVARCHAR(500),
        CptCode          NVARCHAR(MAX),
        PayerName        NVARCHAR(500),
        NoOfClaims       INT,
        ChargeAmount     DECIMAL(18,2),
        InsurancePayment DECIMAL(18,2),
        InsuranceBalance DECIMAL(18,2),
        PatientBalance   DECIMAL(18,2)
    );

    INSERT INTO #R
    EXEC dbo.usp_GetNW_CS_StatusSummary @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_CS_StatusSummary;
        INSERT INTO dbo.NW_CS_StatusSummary
            (ClaimStatus, CptCode, PayerName, NoOfClaims, ChargeAmount, InsurancePayment, InsuranceBalance, PatientBalance, RefreshedAt)
        SELECT ClaimStatus, CptCode, PayerName, NoOfClaims, ChargeAmount, InsurancePayment, InsuranceBalance, PatientBalance, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

/* -----------------------------------------------------------------------------
   6. By Provider - ReferringProvider ranked by claim count.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CS_ProviderSummary
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL,
    @Live          BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) IS NULL
    BEGIN
        SELECT ProviderRank, ReferringProvider, NoOfClaims, ChargeAmount,
               InsurancePayments = InsurancePayment, InsuranceBalance, PatientBalance
        FROM dbo.NW_CS_ProviderSummary
        ORDER BY ProviderRank;
        RETURN;
    END;

    WITH a AS (
        SELECT ReferringProvider = ISNULL(ReferringProvider, N'(blank)'),
               NoOfClaims       = COUNT(ClaimKey),
               ChargeAmount     = SUM(ChargeAmt),
               InsurancePayment = SUM(InsPay),
               InsuranceBalance = SUM(InsBalance),
               PatientBalance   = SUM(PatientBalance)
        FROM dbo.fn_NW_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        GROUP BY ISNULL(ReferringProvider, N'(blank)')
    )
    SELECT ProviderRank      = CAST(ROW_NUMBER() OVER (ORDER BY NoOfClaims DESC, ChargeAmount DESC, ReferringProvider) AS INT),
           ReferringProvider,
           NoOfClaims,
           ChargeAmount      = CAST(ChargeAmount     AS DECIMAL(18,2)),
           InsurancePayments = CAST(InsurancePayment AS DECIMAL(18,2)),
           InsuranceBalance  = CAST(InsuranceBalance AS DECIMAL(18,2)),
           PatientBalance    = CAST(PatientBalance   AS DECIMAL(18,2))
    FROM a
    ORDER BY ProviderRank
    OPTION (RECOMPILE);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CS_ProviderSummary
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        ProviderRank      INT,
        ReferringProvider NVARCHAR(500),
        NoOfClaims        INT,
        ChargeAmount      DECIMAL(18,2),
        InsurancePayments DECIMAL(18,2),
        InsuranceBalance  DECIMAL(18,2),
        PatientBalance    DECIMAL(18,2)
    );

    INSERT INTO #R
    EXEC dbo.usp_GetNW_CS_ProviderSummary @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_CS_ProviderSummary;
        INSERT INTO dbo.NW_CS_ProviderSummary
            (ProviderRank, ReferringProvider, NoOfClaims, ChargeAmount, InsurancePayment, InsuranceBalance, PatientBalance, RefreshedAt)
        SELECT ProviderRank, ReferringProvider, NoOfClaims, ChargeAmount, InsurancePayments, InsuranceBalance, PatientBalance, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

/* -----------------------------------------------------------------------------
   7. Insurance vs Aging - ClaimStatus = No Response; PayerName_Raw x Aging column
      (Current / 30+ / 60+ / 90+ / 120+). Payers sorted by claim count.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CS_InsuranceVsAging
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL,
    @Live          BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) IS NULL
    BEGIN
        SELECT PayerName, AgingBucket, VisitCount, InsuranceBalance, SortOrder
        FROM dbo.NW_CS_InsuranceVsAging
        ORDER BY SortOrder;
        RETURN;
    END;

    WITH b AS (
        SELECT PayerName,
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
        FROM dbo.fn_NW_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE ClaimStatus = N'No Response'
    ),
    a AS (
        SELECT PayerName, AgingBucket,
               VisitCount       = COUNT(ClaimKey),
               InsuranceBalance = SUM(InsBalance)
        FROM b
        GROUP BY PayerName, AgingBucket
    ),
    p AS (
        SELECT PayerName,
               PayerOrder = ROW_NUMBER() OVER (ORDER BY SUM(VisitCount) DESC, SUM(InsuranceBalance) DESC, PayerName)
        FROM a
        GROUP BY PayerName
    )
    SELECT a.PayerName,
           a.AgingBucket,
           a.VisitCount,
           InsuranceBalance = CAST(a.InsuranceBalance AS DECIMAL(18,2)),
           SortOrder        = CAST(ROW_NUMBER() OVER (ORDER BY p.PayerOrder,
                                   CASE a.AgingBucket WHEN N'Current' THEN 1 WHEN N'30 Days' THEN 2 WHEN N'60 Days' THEN 3
                                                      WHEN N'90 Days' THEN 4 WHEN N'120+ Days' THEN 5 ELSE 6 END) AS INT)
    FROM a
    JOIN p ON p.PayerName = a.PayerName
    ORDER BY SortOrder
    OPTION (RECOMPILE);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CS_InsuranceVsAging
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        PayerName        NVARCHAR(500),
        AgingBucket      NVARCHAR(200),
        VisitCount       INT,
        InsuranceBalance DECIMAL(18,2),
        SortOrder        INT
    );

    INSERT INTO #R
    EXEC dbo.usp_GetNW_CS_InsuranceVsAging @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_CS_InsuranceVsAging;
        INSERT INTO dbo.NW_CS_InsuranceVsAging (PayerName, AgingBucket, VisitCount, InsuranceBalance, SortOrder, RefreshedAt)
        SELECT PayerName, AgingBucket, VisitCount, InsuranceBalance, SortOrder, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

/* -----------------------------------------------------------------------------
   8. Insurance vs Payment % - PayerName_Raw; Claims + Average(Payment %).
      TotalPaymentPct = Average(Payment %) over every claim in the result.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CS_InsuranceVsPaymentPct
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL,
    @Live          BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) IS NULL
    BEGIN
        SELECT PayerName, NoOfClaims, InsurancePayment, AvgPaymentPct, TotalPaymentPct, SortOrder
        FROM dbo.NW_CS_InsuranceVsPaymentPct
        ORDER BY SortOrder;
        RETURN;
    END;

    WITH p AS (
        SELECT PayerName,
               NoOfClaims       = COUNT(ClaimKey),
               InsurancePayment = SUM(InsPay),
               AvgPct           = AVG(PaymentPct),
               PctSum           = SUM(PaymentPct),
               PctCnt           = COUNT(PaymentPct)
        FROM dbo.fn_NW_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
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

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CS_InsuranceVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        PayerName        NVARCHAR(500),
        NoOfClaims       INT,
        InsurancePayment DECIMAL(18,2),
        AvgPaymentPct    DECIMAL(9,2),
        TotalPaymentPct  DECIMAL(9,2),
        SortOrder        INT
    );

    INSERT INTO #R
    EXEC dbo.usp_GetNW_CS_InsuranceVsPaymentPct @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_CS_InsuranceVsPaymentPct;
        INSERT INTO dbo.NW_CS_InsuranceVsPaymentPct
            (PayerName, NoOfClaims, InsurancePayment, AvgPaymentPct, TotalPaymentPct, SortOrder, RefreshedAt)
        SELECT PayerName, NoOfClaims, InsurancePayment, AvgPaymentPct, TotalPaymentPct, SortOrder, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

/* -----------------------------------------------------------------------------
   10. Payer vs Payment - PayerName_Raw x CheckDate year / month;
       Claims + Sum(InsurancePayment). PaymentPct = payer share of the month.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CS_InsuranceVsPayment
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL,
    @Live          BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) IS NULL
    BEGIN
        SELECT PayerName, BillYear, BillMonth, NoOfPaidClaims, InsurancePayment, PaymentPct
        FROM dbo.NW_CS_InsuranceVsPayment
        ORDER BY BillYear, BillMonth, NoOfPaidClaims DESC;
        RETURN;
    END;

    WITH agg AS (
        SELECT PayerName,
               BillYear         = YEAR(CheckDt),
               BillMonth        = MONTH(CheckDt),
               NoOfPaidClaims   = COUNT(ClaimKey),
               InsurancePayment = SUM(InsPay)
        FROM dbo.fn_NW_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
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
           BillYear         = CAST(a.BillYear  AS SMALLINT),
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

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CS_InsuranceVsPayment
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        PayerName        NVARCHAR(500),
        BillYear         SMALLINT,
        BillMonth        TINYINT,
        NoOfPaidClaims   INT,
        InsurancePayment DECIMAL(18,2),
        PaymentPct       DECIMAL(9,4)
    );

    INSERT INTO #R
    EXEC dbo.usp_GetNW_CS_InsuranceVsPayment @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_CS_InsuranceVsPayment;
        INSERT INTO dbo.NW_CS_InsuranceVsPayment
            (PayerName, BillYear, BillMonth, NoOfPaidClaims, InsurancePayment, PaymentPct, RefreshedAt)
        SELECT PayerName, BillYear, BillMonth, NoOfPaidClaims, InsurancePayment, PaymentPct, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

/* -----------------------------------------------------------------------------
   11. Women's Health Panel breakdown - PanelType = Women's Health; ClaimStatus rows.
       PanelType is matched with spaces and apostrophes removed, so Women's Health,
       Women'sHealth, Womens Health and Women’s Health all qualify.
       Computed live (small slice of ClaimLevelData).
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CS_WomensHealthBreakdown
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

    SELECT ClaimStatus,
           NoOfClaims        = COUNT(ClaimKey),
           ChargeAmount      = CAST(SUM(ChargeAmt)  AS DECIMAL(18,2)),
           InsurancePayment  = CAST(SUM(InsPay)     AS DECIMAL(18,2)),
           InsuranceBalance  = CAST(SUM(InsBalance) AS DECIMAL(18,2)),
           SortOrder         = CAST(ROW_NUMBER() OVER (ORDER BY COUNT(ClaimKey) DESC, ClaimStatus) AS INT)
    FROM dbo.fn_NW_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                             @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    WHERE UPPER(REPLACE(REPLACE(REPLACE(PanelName, N' ', N''), N'''', N''), NCHAR(8217), N'')) = N'WOMENSHEALTH'
    GROUP BY ClaimStatus
    ORDER BY SortOrder
    OPTION (RECOMPILE);
END;
GO

/* -----------------------------------------------------------------------------
   12. CPT vs Payment % - Line Level Data, CPT Code not blank. Claims = unique ClaimID;
       AvgPaymentPct = Average of line Payment % (InsurancePayment / ChargeAmount x 100,
       lines with ChargeAmount > 0). Dashboard filters apply through the line's claim.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CS_CptVsPaymentPct
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL,
    @Live          BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
                  AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
                  AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) IS NULL
             THEN 0 ELSE 1 END;

    IF @Live = 0 AND @HasFilter = 0
    BEGIN
        SELECT RowType = CAST('C' AS CHAR(1)), PanelName = CAST(NULL AS NVARCHAR(500)),
               CPTCode, NoOfClaims, AvgPaymentPct, TotalPaymentPct, SortOrder
        FROM dbo.NW_CS_CptVsPaymentPct
        ORDER BY SortOrder;
        RETURN;
    END;

    CREATE TABLE #k (ClaimKey NVARCHAR(450) NOT NULL PRIMARY KEY);
    IF @HasFilter = 1
        INSERT INTO #k (ClaimKey)
        SELECT DISTINCT LEFT(ClaimKey, 450)
        FROM dbo.fn_NW_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE ClaimKey IS NOT NULL
        OPTION (RECOMPILE);

    SELECT ClaimKey = NULLIF(LTRIM(RTRIM(l.ClaimID)), N''),
           CPTCode  = LTRIM(RTRIM(l.CPTCode)),
           LinePct  = CASE WHEN v.Chg > 0 THEN v.InsPay / v.Chg * 100 END
    INTO #l
    FROM dbo.LineLevelData l
    CROSS APPLY (SELECT InsPay = ISNULL(TRY_CAST(l.InsurancePayment AS DECIMAL(18,2)), 0),
                        Chg    = TRY_CAST(l.ChargeAmount AS DECIMAL(18,2))) v
    WHERE NULLIF(LTRIM(RTRIM(l.CPTCode)), N'') IS NOT NULL
      AND (@HasFilter = 0
           OR EXISTS (SELECT 1 FROM #k k WHERE k.ClaimKey = LEFT(LTRIM(RTRIM(l.ClaimID)), 450)));

    DECLARE @TotalPct DECIMAL(38,6) = (SELECT AVG(LinePct) FROM #l);

    SELECT RowType         = CAST('C' AS CHAR(1)),
           PanelName       = CAST(NULL AS NVARCHAR(500)),
           CPTCode,
           NoOfClaims      = COUNT(DISTINCT ClaimKey),
           AvgPaymentPct   = CAST(ROUND(ISNULL(AVG(LinePct), 0), 2) AS DECIMAL(9,2)),
           TotalPaymentPct = CAST(ROUND(ISNULL(@TotalPct, 0), 2) AS DECIMAL(9,2)),
           SortOrder       = CAST(ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT ClaimKey) DESC, CPTCode) AS INT)
    FROM #l
    GROUP BY CPTCode
    ORDER BY SortOrder;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CS_CptVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        RowType         CHAR(1),
        PanelName       NVARCHAR(500),
        CPTCode         NVARCHAR(200),
        NoOfClaims      INT,
        AvgPaymentPct   DECIMAL(9,2),
        TotalPaymentPct DECIMAL(9,2),
        SortOrder       INT
    );

    INSERT INTO #R
    EXEC dbo.usp_GetNW_CS_CptVsPaymentPct @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_CS_CptVsPaymentPct;
        INSERT INTO dbo.NW_CS_CptVsPaymentPct (CPTCode, NoOfClaims, AvgPaymentPct, TotalPaymentPct, SortOrder, RefreshedAt)
        SELECT CPTCode, NoOfClaims, AvgPaymentPct, TotalPaymentPct, SortOrder, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

/* -----------------------------------------------------------------------------
   Panel Averages - by DOS / by Check Date (Average Payments tabs).
   BilledUnbilled = Billed; @LastMonths months of DateOfService or CheckDate ending at
   the billed week-range end date (latest date in that column when there is no week
   folder). Returns every payer; the page shows panel totals plus the top 3 payers.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CS_AvgPayments_ClientLogic
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
    FROM dbo.fn_NW_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                             @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    WHERE BilledUnbilled = N'Billed'
    OPTION (RECOMPILE);

    DECLARE @WindowTo   DATE = ISNULL(dbo.fn_NW_CS_LatestWeekFolderEnd(), (SELECT MAX(BasisDt) FROM #b));
    DECLARE @WindowFrom DATE = DATEADD(DAY, 1, DATEADD(MONTH, -@LastMonths, @WindowTo));

    SELECT PanelName,
           PayerName,
           NoOfClaims        = CAST(COUNT(ClaimKey) AS INT),
           TotalCharges      = CAST(ISNULL(SUM(ChargeAmt), 0) AS DECIMAL(18,2)),
           CarrierPayment    = CAST(ISNULL(SUM(InsPay), 0) AS DECIMAL(18,2)),
           FullyPaidCount    = CAST(COUNT(CASE WHEN ClaimStatus = N'Fully Paid' THEN ClaimKey END) AS INT),
           FullyPaidAmount   = CAST(ISNULL(SUM(CASE WHEN ClaimStatus = N'Fully Paid' THEN InsPay END), 0) AS DECIMAL(18,2)),
           AdjudicatedCount  = CAST(COUNT(CASE WHEN Adjudicated = N'Adjudicated' THEN ClaimKey END) AS INT),
           AdjudicatedAmount = CAST(ISNULL(SUM(CASE WHEN Adjudicated = N'Adjudicated' THEN InsPay END), 0) AS DECIMAL(18,2)),
           Days30Count       = CAST(COUNT(CASE WHEN Bucket30 = N'30 Bucket' THEN ClaimKey END) AS INT),
           Days30Amount      = CAST(ISNULL(SUM(CASE WHEN Bucket30 = N'30 Bucket' THEN InsPay END), 0) AS DECIMAL(18,2)),
           Days60Count       = CAST(COUNT(CASE WHEN Bucket60 = N'60 Bucket' THEN ClaimKey END) AS INT),
           Days60Amount      = CAST(ISNULL(SUM(CASE WHEN Bucket60 = N'60 Bucket' THEN InsPay END), 0) AS DECIMAL(18,2)),
           WindowFrom        = @WindowFrom,
           WindowTo          = @WindowTo
    FROM #b
    WHERE BasisDt BETWEEN @WindowFrom AND @WindowTo
    GROUP BY PanelName, PayerName
    ORDER BY PanelName, NoOfClaims DESC, PayerName;
END;
GO

/* -----------------------------------------------------------------------------
   Rebuild the snapshots
   ----------------------------------------------------------------------------- */
EXEC dbo.usp_RefreshNW_CS_WeeklyClaimVolume;
EXEC dbo.usp_RefreshNW_CS_Top5ReimbursementPct;
EXEC dbo.usp_RefreshNW_CS_Top5ReimbursementPay;
EXEC dbo.usp_RefreshNW_CS_StatusSummary;
EXEC dbo.usp_RefreshNW_CS_ProviderSummary;
EXEC dbo.usp_RefreshNW_CS_InsuranceVsAging;
EXEC dbo.usp_RefreshNW_CS_InsuranceVsPaymentPct;
EXEC dbo.usp_RefreshNW_CS_InsuranceVsPayment;
EXEC dbo.usp_RefreshNW_CS_CptVsPaymentPct;
GO
