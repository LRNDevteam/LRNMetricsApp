/* =====================================================================
   dbo.usp_GetBeechTree_ThreePillarDiagnosticDrill
   ---------------------------------------------------------------------
   Beech_Tree "Three-Pillar Framework & 7-Check Diagnostic" page
   (source: Beech_Tree_Three_Pillar_Diagnostic_2.docx).

   PERFORMANCE NOTES (why the prior version hung):
     - RS6 joined #Months × #Base × #Lis in one query. For a month with
       ~10k PMS rows and ~10k LIS rows that produced ~100M intermediate
       rows before GROUP BY. Fixed by pre-aggregating each side separately.
     - YEAR(TRY_CAST(DateofService)) = @Year forced full scans. Fixed with
       sargable date-range predicates.
     - @Year = 0 previously loaded ALL history. Now scopes to the trailing
       @TrailingMonths window ending at the latest DOS / collect month.
     - BTWOSummary join used LTRIM/RTRIM(CAST()) on both sides. Fixed by
       normalizing ClaimID once into #WO / #Base.

   Parameters
     @Year           0 = trailing window (default 19 months per source doc);
                     else that calendar year only
     @TrailingMonths used when @Year = 0 (default 19; clamp 1..36)
     @AsOfDate       "today" for backlog-age calculations (default GETDATE())

   Returns 17 result sets:
     1    LIS funnel (Collected -> Resulted -> Billed to Insurance)
     2a   Backlog age summary
     2b   Backlog age buckets
     3    % Billed of Resulted, monthly
     4    Self Pay % vs Client Bill %, monthly
     5    Not Resulted, monthly
     6    Cross-file reconciliation (pre-aggregated — no cartesian join)
     7a   Fully Adjusted % monthly
     7b   Fully Adjusted reason-code Pareto (latest month)
     8    Fully Paid % monthly
     9    Denial rate by carrier (top 10)
    10    Top denial reasons by payer (top 5 × codes, trailing 5 months)
    11    Aging decomposition of open Insurance Balance
    12    Patient collections reality check
    13    Panel-level Avg Allowed/Paid
    14    DOS-cohort maturity curve (last 6 cohorts × days 0..120)
    15    Insurance Balance % + No Response / Fully Denied / Partially Denied composition
    16    Cash headline: Total Billed $, Collection Rate, Patient WO vs Patient Balance
   ===================================================================== */
IF OBJECT_ID('dbo.usp_GetBeechTree_ThreePillarDiagnosticDrill', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_GetBeechTree_ThreePillarDiagnosticDrill;
GO
CREATE PROCEDURE dbo.usp_GetBeechTree_ThreePillarDiagnosticDrill
    @Year           INT  = 0,
    @TrailingMonths INT  = 19,
    @AsOfDate       DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @t0 DATETIME2 = SYSDATETIME();
    DECLARE @msg NVARCHAR(400);
    RAISERROR(N'[Start] usp_GetBeechTree_ThreePillarDiagnosticDrill @Year=%d', 0, 1, @Year) WITH NOWAIT;

    IF @AsOfDate IS NULL SET @AsOfDate = CAST(GETDATE() AS date);
    IF @TrailingMonths NOT BETWEEN 1 AND 36 SET @TrailingMonths = 19;

    DECLARE @HasLims BIT = CASE WHEN OBJECT_ID('dbo.LIMSMaster','U') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasWO   BIT = CASE WHEN OBJECT_ID('dbo.BTWOSummary','U') IS NOT NULL THEN 1 ELSE 0 END;

    /* ── Resolve date window (sargable) ── */
    DECLARE @MaxDos DATE =
    (
        SELECT MAX(TRY_CAST(DateofService AS DATE))
        FROM dbo.ClaimLevelData WITH (NOLOCK)
        WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
    );
    DECLARE @MaxCollect DATE = NULL;
    IF @HasLims = 1
        SELECT @MaxCollect = MAX(RequestCollectDate)
        FROM dbo.LIMSMaster WITH (NOLOCK)
        WHERE RequestCollectDate IS NOT NULL;

    DECLARE @Anchor DATE = ISNULL(@MaxDos, ISNULL(@MaxCollect, @AsOfDate));
    DECLARE @StartDate DATE, @EndDate DATE;

    IF @Year > 0
    BEGIN
        SET @StartDate = DATEFROMPARTS(@Year, 1, 1);
        SET @EndDate   = DATEFROMPARTS(@Year, 12, 31);
    END
    ELSE
    BEGIN
        -- Trailing N months ending at the latest month that has data.
        SET @EndDate   = EOMONTH(@Anchor);
        SET @StartDate = DATEFROMPARTS(
            YEAR(DATEADD(MONTH, -(@TrailingMonths - 1), @Anchor)),
            MONTH(DATEADD(MONTH, -(@TrailingMonths - 1), @Anchor)),
            1);
    END

    SET @msg = CONCAT(N'[Window] ', CONVERT(varchar(10), @StartDate, 23), N' .. ', CONVERT(varchar(10), @EndDate, 23),
                      N' ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ── #Lis ──
       COLLATE DATABASE_DEFAULT on every string column: BeechTree_LRN uses
       Latin1_General_CI_AS while tempdb is often SQL_Latin1_General_CP1_CI_AS.
       Without this, equality vs N'…' literals (and #WO↔#Base joins) fail. */
    IF OBJECT_ID('tempdb..#Lis') IS NOT NULL DROP TABLE #Lis;
    CREATE TABLE #Lis (
        Accession    NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        ESYear       INT NOT NULL,
        ESMonth      INT NOT NULL,
        CollectDate  DATE NULL,
        Resulted     NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        ClaimStatus  NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        BilledorNot  NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        ClientStatus NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL
    );

    IF @HasLims = 1
    BEGIN
        INSERT INTO #Lis (Accession, ESYear, ESMonth, CollectDate, Resulted, ClaimStatus, BilledorNot, ClientStatus)
        SELECT
            LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))) COLLATE DATABASE_DEFAULT,
            YEAR(RequestCollectDate), MONTH(RequestCollectDate), RequestCollectDate,
            LTRIM(RTRIM(ISNULL(RessultedStatus, N''))) COLLATE DATABASE_DEFAULT,
            LTRIM(RTRIM(ISNULL(ClaimStatus, N''))) COLLATE DATABASE_DEFAULT,
            LTRIM(RTRIM(ISNULL(BilledorNot, N''))) COLLATE DATABASE_DEFAULT,
            LTRIM(RTRIM(ISNULL(ClientStatus, N''))) COLLATE DATABASE_DEFAULT
        FROM dbo.LIMSMaster WITH (NOLOCK)
        WHERE RequestCollectDate >= @StartDate
          AND RequestCollectDate <  DATEADD(DAY, 1, @EndDate);
    END

    IF EXISTS (SELECT 1 FROM #Lis)
        CREATE CLUSTERED INDEX IX_Lis_YM ON #Lis (ESYear, ESMonth);

    SET @msg = CONCAT(N'[#Lis] rows=', (SELECT COUNT(*) FROM #Lis), N' ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ── #Base ── */
    IF OBJECT_ID('tempdb..#Base') IS NOT NULL DROP TABLE #Base;
    CREATE TABLE #Base (
        ClaimIDKey           NVARCHAR(50)  COLLATE DATABASE_DEFAULT NOT NULL,
        ESYear               INT NOT NULL,
        ESMonth              INT NOT NULL,
        DOS                  DATE NOT NULL,
        PaidDate             DATE NULL,
        BillStatus           NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        ClaimStatus          NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        PayerName            NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        Panelname            NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        DenialCode           NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        ChargeAmount         DECIMAL(18,2) NOT NULL,
        AllowedAmount        DECIMAL(18,2) NOT NULL,
        InsurancePayment     DECIMAL(18,2) NOT NULL,
        PatientPayment       DECIMAL(18,2) NOT NULL,
        InsuranceBalance     DECIMAL(18,2) NOT NULL,
        PatientBalance       DECIMAL(18,2) NOT NULL,
        PatientAdjustments   DECIMAL(18,2) NOT NULL,
        InsuranceAdjustments DECIMAL(18,2) NOT NULL,
        AgingDays            INT NULL
    );

    INSERT INTO #Base (
        ClaimIDKey, ESYear, ESMonth, DOS, PaidDate, BillStatus, ClaimStatus,
        PayerName, Panelname, DenialCode,
        ChargeAmount, AllowedAmount, InsurancePayment, PatientPayment,
        InsuranceBalance, PatientBalance, PatientAdjustments, InsuranceAdjustments, AgingDays)
    SELECT
        ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), ClaimID))), N''), N'?') COLLATE DATABASE_DEFAULT,
        YEAR(d.DOS), MONTH(d.DOS), d.DOS,
        TRY_CAST(CheckDate AS DATE),
        ISNULL(LTRIM(RTRIM(BilledUnbilled)), N'') COLLATE DATABASE_DEFAULT,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), N'') COLLATE DATABASE_DEFAULT,
        ISNULL(NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unspecified') COLLATE DATABASE_DEFAULT,
        ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), N''), N'Unspecified') COLLATE DATABASE_DEFAULT,
        ISNULL(LTRIM(RTRIM(DenialCode)), N'') COLLATE DATABASE_DEFAULT,
        ISNULL(TRY_CAST(ChargeAmount AS DECIMAL(18,2)), 0),
        ISNULL(TRY_CAST(AllowedAmount AS DECIMAL(18,2)), 0),
        ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0),
        ISNULL(TRY_CAST(PatientPayment AS DECIMAL(18,2)), 0),
        ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0),
        ISNULL(TRY_CAST(PatientBalance AS DECIMAL(18,2)), 0),
        ISNULL(TRY_CAST(PatientAdjustments AS DECIMAL(18,2)), 0),
        ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0),
        TRY_CAST(Aging AS INT)
    FROM dbo.ClaimLevelData WITH (NOLOCK)
    CROSS APPLY (SELECT TRY_CAST(DateofService AS DATE) AS DOS) d
    WHERE d.DOS IS NOT NULL
      AND d.DOS >= @StartDate
      AND d.DOS <  DATEADD(DAY, 1, @EndDate);

    IF EXISTS (SELECT 1 FROM #Base)
    BEGIN
        CREATE CLUSTERED INDEX IX_Base_YM ON #Base (ESYear, ESMonth);
        CREATE NONCLUSTERED INDEX IX_Base_Claim ON #Base (ClaimIDKey);
        CREATE NONCLUSTERED INDEX IX_Base_Status ON #Base (BillStatus, ClaimStatus) INCLUDE (AllowedAmount, InsuranceBalance, ChargeAmount);
    END

    SET @msg = CONCAT(N'[#Base] rows=', (SELECT COUNT(*) FROM #Base), N' ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    DECLARE @LatestY INT, @LatestM INT;
    SELECT TOP (1) @LatestY = ESYear, @LatestM = ESMonth
    FROM #Base
    ORDER BY ESYear DESC, ESMonth DESC;

    IF @LatestY IS NULL
        SELECT TOP (1) @LatestY = ESYear, @LatestM = ESMonth
        FROM #Lis
        ORDER BY ESYear DESC, ESMonth DESC;

    IF @LatestY IS NULL
    BEGIN
        SET @LatestY = YEAR(@AsOfDate);
        SET @LatestM = MONTH(@AsOfDate);
    END

    /* ── #Months scaffold from Start..Latest (inclusive) ── */
    IF OBJECT_ID('tempdb..#Months') IS NOT NULL DROP TABLE #Months;
    ;WITH n AS (
        SELECT TOP (36) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS rn
        FROM sys.all_objects
    )
    SELECT
        MY        = DATEADD(MONTH, rn, DATEFROMPARTS(YEAR(@StartDate), MONTH(@StartDate), 1)),
        CollYear  = YEAR(DATEADD(MONTH, rn, DATEFROMPARTS(YEAR(@StartDate), MONTH(@StartDate), 1))),
        CollMonth = MONTH(DATEADD(MONTH, rn, DATEFROMPARTS(YEAR(@StartDate), MONTH(@StartDate), 1)))
    INTO #Months
    FROM n
    WHERE DATEADD(MONTH, rn, DATEFROMPARTS(YEAR(@StartDate), MONTH(@StartDate), 1))
          <= DATEFROMPARTS(@LatestY, @LatestM, 1);

    CREATE CLUSTERED INDEX IX_Months ON #Months (CollYear, CollMonth);

    SET @msg = CONCAT(N'[#Months] rows=', (SELECT COUNT(*) FROM #Months), N' latest=', @LatestY, N'-', @LatestM,
                      N' ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       1) LIS funnel
       =================================================================== */
    SELECT
        MonthLabel = LEFT(DATENAME(MONTH, m.MY), 3) + ' ' + CONVERT(varchar(4), YEAR(m.MY)),
        Collected  = COUNT(DISTINCT l.Accession),
        Resulted   = COUNT(DISTINCT CASE WHEN l.Resulted = N'Resulted' THEN l.Accession END),
        BilledToInsurance = COUNT(DISTINCT CASE WHEN l.Resulted = N'Resulted' AND l.ClaimStatus = N'Billed'
                                                  AND l.BilledorNot = N'Billed' AND l.ClientStatus = N'' THEN l.Accession END)
    FROM #Months m
    LEFT JOIN #Lis l ON l.ESYear = m.CollYear AND l.ESMonth = m.CollMonth
    GROUP BY m.MY
    ORDER BY m.MY;

    SET @msg = CONCAT(N'[RS1] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       2a / 2b) Backlog age — Resulted AND Not Entered in AMD
       =================================================================== */
    IF OBJECT_ID('tempdb..#Backlog') IS NOT NULL DROP TABLE #Backlog;
    SELECT Accession, CollectDate, DATEDIFF(DAY, CollectDate, @AsOfDate) AS AgeDays
    INTO #Backlog
    FROM #Lis
    WHERE Resulted = N'Resulted' AND ClaimStatus = N'Not Entered in AMD'
      AND BilledorNot = N'UnBilled' AND ClientStatus IN (N'', N'Billing Review Required');

    ;WITH Ordered AS (
        SELECT AgeDays,
               rn = ROW_NUMBER() OVER (ORDER BY AgeDays),
               cnt = COUNT(*) OVER ()
        FROM #Backlog
    )
    SELECT
        TotalBacklog = ISNULL((SELECT COUNT(*) FROM #Backlog), 0),
        MedianAgeDays = (
            SELECT CAST(AVG(CAST(AgeDays AS float)) AS decimal(18,1))
            FROM Ordered
            WHERE rn IN ((cnt + 1) / 2, (cnt + 2) / 2)
        ),
        PctOver60Days = CASE WHEN NOT EXISTS (SELECT 1 FROM #Backlog) THEN NULL
            ELSE CAST((SELECT COUNT(*) FROM #Backlog WHERE AgeDays > 60) * 100.0
                      / (SELECT COUNT(*) FROM #Backlog) AS decimal(18,2)) END;

    SELECT
        AgeBucket = CASE
            WHEN AgeDays <= 30  THEN N'0-30 days'
            WHEN AgeDays <= 60  THEN N'31-60 days'
            WHEN AgeDays <= 90  THEN N'61-90 days'
            WHEN AgeDays <= 120 THEN N'91-120 days'
            ELSE N'120+ days' END,
        SortOrder = CASE
            WHEN AgeDays <= 30 THEN 1 WHEN AgeDays <= 60 THEN 2
            WHEN AgeDays <= 90 THEN 3 WHEN AgeDays <= 120 THEN 4 ELSE 5 END,
        SampleCount = COUNT(*)
    FROM #Backlog
    GROUP BY CASE
            WHEN AgeDays <= 30  THEN N'0-30 days'
            WHEN AgeDays <= 60  THEN N'31-60 days'
            WHEN AgeDays <= 90  THEN N'61-90 days'
            WHEN AgeDays <= 120 THEN N'91-120 days'
            ELSE N'120+ days' END,
        CASE WHEN AgeDays <= 30 THEN 1 WHEN AgeDays <= 60 THEN 2
             WHEN AgeDays <= 90 THEN 3 WHEN AgeDays <= 120 THEN 4 ELSE 5 END
    ORDER BY SortOrder;

    IF OBJECT_ID('tempdb..#Backlog') IS NOT NULL DROP TABLE #Backlog;

    SET @msg = CONCAT(N'[RS2] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       3) % Billed of Resulted
       =================================================================== */
    SELECT
        MonthLabel = LEFT(DATENAME(MONTH, m.MY), 3) + ' ' + CONVERT(varchar(4), YEAR(m.MY)),
        Resulted   = COUNT(DISTINCT CASE WHEN l.Resulted = N'Resulted' THEN l.Accession END),
        BilledToInsurance = COUNT(DISTINCT CASE WHEN l.Resulted = N'Resulted' AND l.ClaimStatus = N'Billed'
                                                  AND l.BilledorNot = N'Billed' AND l.ClientStatus = N'' THEN l.Accession END),
        PctBilledOfResulted = CASE WHEN COUNT(DISTINCT CASE WHEN l.Resulted = N'Resulted' THEN l.Accession END) = 0 THEN NULL
            ELSE CAST(COUNT(DISTINCT CASE WHEN l.Resulted = N'Resulted' AND l.ClaimStatus = N'Billed'
                                            AND l.BilledorNot = N'Billed' AND l.ClientStatus = N'' THEN l.Accession END) * 100.0
                     / COUNT(DISTINCT CASE WHEN l.Resulted = N'Resulted' THEN l.Accession END) AS decimal(18,2)) END
    FROM #Months m
    LEFT JOIN #Lis l ON l.ESYear = m.CollYear AND l.ESMonth = m.CollMonth
    GROUP BY m.MY
    ORDER BY m.MY;

    SET @msg = CONCAT(N'[RS3] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       4) Self Pay % vs Client Bill %
       =================================================================== */
    SELECT
        MonthLabel = LEFT(DATENAME(MONTH, m.MY), 3) + ' ' + CONVERT(varchar(4), YEAR(m.MY)),
        TotalSamples = COUNT(DISTINCT l.Accession),
        SelfPay    = COUNT(DISTINCT CASE WHEN l.Resulted = N'Resulted' AND l.ClientStatus = N'Self Pay' THEN l.Accession END),
        ClientBill = COUNT(DISTINCT CASE WHEN l.Resulted = N'Resulted' AND l.ClientStatus = N'Client Bill' THEN l.Accession END),
        SelfPayPct = CASE WHEN COUNT(DISTINCT l.Accession) = 0 THEN NULL ELSE CAST(
            COUNT(DISTINCT CASE WHEN l.Resulted = N'Resulted' AND l.ClientStatus = N'Self Pay' THEN l.Accession END) * 100.0
            / COUNT(DISTINCT l.Accession) AS decimal(18,2)) END,
        ClientBillPct = CASE WHEN COUNT(DISTINCT l.Accession) = 0 THEN NULL ELSE CAST(
            COUNT(DISTINCT CASE WHEN l.Resulted = N'Resulted' AND l.ClientStatus = N'Client Bill' THEN l.Accession END) * 100.0
            / COUNT(DISTINCT l.Accession) AS decimal(18,2)) END
    FROM #Months m
    LEFT JOIN #Lis l ON l.ESYear = m.CollYear AND l.ESMonth = m.CollMonth
    GROUP BY m.MY
    ORDER BY m.MY;

    SET @msg = CONCAT(N'[RS4] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       5) Not Resulted
       =================================================================== */
    SELECT
        MonthLabel = LEFT(DATENAME(MONTH, m.MY), 3) + ' ' + CONVERT(varchar(4), YEAR(m.MY)),
        NotResulted = COUNT(DISTINCT CASE WHEN l.Resulted = N'Not Resulted' THEN l.Accession END)
    FROM #Months m
    LEFT JOIN #Lis l ON l.ESYear = m.CollYear AND l.ESMonth = m.CollMonth
    GROUP BY m.MY
    ORDER BY m.MY;

    SET @msg = CONCAT(N'[RS5] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       6) Cross-file reconciliation — PRE-AGGREGATE each side (no cartesian)
       =================================================================== */
    IF OBJECT_ID('tempdb..#PmsAgg') IS NOT NULL DROP TABLE #PmsAgg;
    IF OBJECT_ID('tempdb..#LisAgg') IS NOT NULL DROP TABLE #LisAgg;

    SELECT ESYear, ESMonth,
           PmsBilled = COUNT(DISTINCT CASE WHEN BillStatus = N'Billed' THEN ClaimIDKey END)
    INTO #PmsAgg
    FROM #Base
    GROUP BY ESYear, ESMonth;

    SELECT ESYear, ESMonth,
           LisBilledToInsurance = COUNT(DISTINCT CASE WHEN Resulted = N'Resulted' AND ClaimStatus = N'Billed'
                                                        AND BilledorNot = N'Billed' AND ClientStatus = N'' THEN Accession END)
    INTO #LisAgg
    FROM #Lis
    GROUP BY ESYear, ESMonth;

    SELECT
        MonthLabel = LEFT(DATENAME(MONTH, m.MY), 3) + ' ' + CONVERT(varchar(4), YEAR(m.MY)),
        PmsBilled  = ISNULL(p.PmsBilled, 0),
        LisBilledToInsurance = ISNULL(l.LisBilledToInsurance, 0),
        Gap = ISNULL(p.PmsBilled, 0) - ISNULL(l.LisBilledToInsurance, 0)
    FROM #Months m
    LEFT JOIN #PmsAgg p ON p.ESYear = m.CollYear AND p.ESMonth = m.CollMonth
    LEFT JOIN #LisAgg l ON l.ESYear = m.CollYear AND l.ESMonth = m.CollMonth
    ORDER BY m.MY;

    IF OBJECT_ID('tempdb..#PmsAgg') IS NOT NULL DROP TABLE #PmsAgg;
    IF OBJECT_ID('tempdb..#LisAgg') IS NOT NULL DROP TABLE #LisAgg;

    SET @msg = CONCAT(N'[RS6] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       7a) Fully Adjusted %
       =================================================================== */
    SELECT
        MonthLabel = LEFT(DATENAME(MONTH, m.MY), 3) + ' ' + CONVERT(varchar(4), YEAR(m.MY)),
        BilledClaims = COUNT(DISTINCT CASE WHEN b.BillStatus = N'Billed' THEN b.ClaimIDKey END),
        FullyAdjusted = COUNT(DISTINCT CASE WHEN b.ClaimStatus = N'Fully Adjusted' THEN b.ClaimIDKey END),
        PctFullyAdjusted = CASE WHEN COUNT(DISTINCT CASE WHEN b.BillStatus = N'Billed' THEN b.ClaimIDKey END) = 0 THEN NULL
            ELSE CAST(COUNT(DISTINCT CASE WHEN b.ClaimStatus = N'Fully Adjusted' THEN b.ClaimIDKey END) * 100.0
                     / COUNT(DISTINCT CASE WHEN b.BillStatus = N'Billed' THEN b.ClaimIDKey END) AS decimal(18,2)) END
    FROM #Months m
    LEFT JOIN #Base b ON b.ESYear = m.CollYear AND b.ESMonth = m.CollMonth
    GROUP BY m.MY
    ORDER BY m.MY;

    SET @msg = CONCAT(N'[RS7a] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       7b) Fully Adjusted reason-code Pareto (latest month) — counts only
       =================================================================== */
    IF @HasWO = 1
    BEGIN
        IF OBJECT_ID('tempdb..#WO') IS NOT NULL DROP TABLE #WO;
        CREATE TABLE #WO (
            ClaimIDKey              NVARCHAR(50)  COLLATE DATABASE_DEFAULT NOT NULL,
            TransactionCodeCombined NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
            MatchingCount           INT NOT NULL
        );

        INSERT INTO #WO (ClaimIDKey, TransactionCodeCombined, MatchingCount)
        SELECT
            ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), ClaimID))), N''), N'?') COLLATE DATABASE_DEFAULT,
            LTRIM(RTRIM(CONVERT(NVARCHAR(200), TransactionCodeCombined))) COLLATE DATABASE_DEFAULT,
            ISNULL(MatchingCount, 0)
        FROM dbo.BTWOSummary WITH (NOLOCK)
        WHERE TransactionCodeCombined IS NOT NULL
          AND TRY_CAST(DateofService AS DATE) >= DATEFROMPARTS(@LatestY, @LatestM, 1)
          AND TRY_CAST(DateofService AS DATE) <  DATEADD(MONTH, 1, DATEFROMPARTS(@LatestY, @LatestM, 1));

        CREATE CLUSTERED INDEX IX_WO_Claim ON #WO (ClaimIDKey);

        SELECT
            ws.TransactionCodeCombined,
            MatchingCount = SUM(ws.MatchingCount)
        FROM #WO ws
        INNER JOIN #Base b
            ON b.ClaimIDKey = ws.ClaimIDKey
           AND b.ESYear = @LatestY
           AND b.ESMonth = @LatestM
           AND b.ClaimStatus = N'Fully Adjusted'
        GROUP BY ws.TransactionCodeCombined
        ORDER BY SUM(ws.MatchingCount) DESC;

        IF OBJECT_ID('tempdb..#WO') IS NOT NULL DROP TABLE #WO;
    END
    ELSE
        SELECT TransactionCodeCombined = N'', MatchingCount = CAST(0 AS int) WHERE 1 = 0;

    SET @msg = CONCAT(N'[RS7b] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       8) Fully Paid %
       =================================================================== */
    SELECT
        MonthLabel = LEFT(DATENAME(MONTH, m.MY), 3) + ' ' + CONVERT(varchar(4), YEAR(m.MY)),
        BilledClaims = COUNT(DISTINCT CASE WHEN b.BillStatus = N'Billed' THEN b.ClaimIDKey END),
        FullyPaid = COUNT(DISTINCT CASE WHEN b.ClaimStatus = N'Fully Paid' THEN b.ClaimIDKey END),
        PctFullyPaid = CASE WHEN COUNT(DISTINCT CASE WHEN b.BillStatus = N'Billed' THEN b.ClaimIDKey END) = 0 THEN NULL
            ELSE CAST(COUNT(DISTINCT CASE WHEN b.ClaimStatus = N'Fully Paid' THEN b.ClaimIDKey END) * 100.0
                     / COUNT(DISTINCT CASE WHEN b.BillStatus = N'Billed' THEN b.ClaimIDKey END) AS decimal(18,2)) END
    FROM #Months m
    LEFT JOIN #Base b ON b.ESYear = m.CollYear AND b.ESMonth = m.CollMonth
    GROUP BY m.MY
    ORDER BY m.MY;

    SET @msg = CONCAT(N'[RS8] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       9) Denial rate by carrier (Fully Denied + Partially Denied)
       =================================================================== */
    ;WITH PayerTotals AS (
        SELECT PayerName,
               TotalAllowed = SUM(AllowedAmount),
               DeniedAllowed = SUM(CASE WHEN ClaimStatus IN (N'Fully Denied', N'Partially Denied')
                                        THEN AllowedAmount ELSE 0 END)
        FROM #Base
        WHERE BillStatus = N'Billed'
        GROUP BY PayerName
    )
    SELECT TOP (10)
        PayerName, TotalAllowed, DeniedAllowed,
        DenialRatePct = CASE WHEN TotalAllowed = 0 THEN NULL ELSE CAST(DeniedAllowed * 100.0 / TotalAllowed AS decimal(18,2)) END
    FROM PayerTotals
    ORDER BY TotalAllowed DESC;

    SET @msg = CONCAT(N'[RS9] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       10) Top denial reasons by payer (top 5 payers × codes, trailing 5 mo)
       =================================================================== */
    ;WITH TopPayers AS (
        SELECT TOP (5) PayerName, SUM(AllowedAmount) AS TotalAllowed
        FROM #Base WHERE BillStatus = N'Billed'
        GROUP BY PayerName ORDER BY SUM(AllowedAmount) DESC
    ),
    Trail5 AS (SELECT TOP (5) MY, CollYear, CollMonth FROM #Months ORDER BY MY DESC)
    SELECT
        b.PayerName,
        b.DenialCode,
        MonthLabel = LEFT(DATENAME(MONTH, t.MY), 3) + ' ' + CONVERT(varchar(4), YEAR(t.MY)),
        DenialCount = COUNT(*)
    FROM #Base b
    INNER JOIN TopPayers tp ON tp.PayerName = b.PayerName
    INNER JOIN Trail5 t ON t.CollYear = b.ESYear AND t.CollMonth = b.ESMonth
    WHERE b.ClaimStatus IN (N'Fully Denied', N'Partially Denied') AND b.DenialCode <> N''
    GROUP BY b.PayerName, b.DenialCode, t.MY
    ORDER BY b.PayerName, t.MY, DenialCount DESC;

    SET @msg = CONCAT(N'[RS10] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       11) Aging decomposition of open Insurance Balance
       =================================================================== */
    ;WITH OpenBal AS (
        SELECT
            AgeDays = ISNULL(AgingDays, DATEDIFF(DAY, DOS, @AsOfDate)),
            InsuranceBalance
        FROM #Base
        WHERE ClaimStatus IN (N'Fully Denied', N'No Response', N'Partially Denied')
          AND InsuranceBalance > 0
    )
    SELECT
        AgeBucket = CASE
            WHEN AgeDays <= 30  THEN N'0-30 days'
            WHEN AgeDays <= 60  THEN N'31-60 days'
            WHEN AgeDays <= 90  THEN N'61-90 days'
            WHEN AgeDays <= 120 THEN N'91-120 days'
            ELSE N'120+ days' END,
        SortOrder = CASE
            WHEN AgeDays <= 30 THEN 1 WHEN AgeDays <= 60 THEN 2
            WHEN AgeDays <= 90 THEN 3 WHEN AgeDays <= 120 THEN 4 ELSE 5 END,
        ClaimCount = COUNT(*),
        BalanceTotal = SUM(InsuranceBalance)
    FROM OpenBal
    GROUP BY CASE
            WHEN AgeDays <= 30  THEN N'0-30 days'
            WHEN AgeDays <= 60  THEN N'31-60 days'
            WHEN AgeDays <= 90  THEN N'61-90 days'
            WHEN AgeDays <= 120 THEN N'91-120 days'
            ELSE N'120+ days' END,
        CASE WHEN AgeDays <= 30 THEN 1 WHEN AgeDays <= 60 THEN 2
             WHEN AgeDays <= 90 THEN 3 WHEN AgeDays <= 120 THEN 4 ELSE 5 END
    ORDER BY SortOrder;

    SET @msg = CONCAT(N'[RS11] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       12) Patient collections reality check
       =================================================================== */
    SELECT
        OpenPatientBalanceClaims = COUNT(*),
        OpenBalanceTotal = SUM(PatientBalance),
        ClaimsWithAnyPayment = SUM(CASE WHEN PatientPayment > 0 THEN 1 ELSE 0 END),
        CollectionsRealityPct = CASE WHEN COUNT(*) = 0 THEN NULL
            ELSE CAST(SUM(CASE WHEN PatientPayment > 0 THEN 1 ELSE 0 END) * 100.0 / COUNT(*) AS decimal(18,2)) END
    FROM #Base
    WHERE PatientBalance > 0;

    SET @msg = CONCAT(N'[RS12] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       13) Panel-level Avg Allowed/Paid (top 5 panels)
       =================================================================== */
    ;WITH Eligible AS (
        SELECT Panelname, DOS, PaidDate, AllowedAmount, InsurancePayment
        FROM #Base WHERE BillStatus = N'Billed' AND ClaimStatus <> N'No Response'
    ),
    TopPanels AS (
        SELECT TOP (5) Panelname, SUM(AllowedAmount) AS TotalAllowed
        FROM Eligible GROUP BY Panelname ORDER BY SUM(AllowedAmount) DESC
    ),
    ByDosMonth AS (
        SELECT Panelname, DOSYear = YEAR(DOS), DOSMonth = MONTH(DOS),
               AvgAllowed = AVG(AllowedAmount), AllowedClaimCount = COUNT(*)
        FROM Eligible
        GROUP BY Panelname, YEAR(DOS), MONTH(DOS)
    ),
    ByPaidMonth AS (
        SELECT Panelname, PaidYear = YEAR(PaidDate), PaidMonth = MONTH(PaidDate),
               AvgPaid = AVG(InsurancePayment), PaidClaimCount = COUNT(*)
        FROM Eligible WHERE PaidDate IS NOT NULL
        GROUP BY Panelname, YEAR(PaidDate), MONTH(PaidDate)
    )
    SELECT
        dm.Panelname,
        MonthLabel_DOS = LEFT(DATENAME(MONTH, DATEFROMPARTS(dm.DOSYear, dm.DOSMonth, 1)), 3) + ' ' + CONVERT(varchar(4), dm.DOSYear),
        AvgAllowed = CAST(dm.AvgAllowed AS decimal(18,2)),
        dm.AllowedClaimCount,
        AvgPaidByPaymentDate = CAST(pm.AvgPaid AS decimal(18,2)),
        PaidClaimCount = ISNULL(pm.PaidClaimCount, 0)
    FROM ByDosMonth dm
    INNER JOIN TopPanels tp ON tp.Panelname = dm.Panelname
    LEFT JOIN ByPaidMonth pm ON pm.Panelname = dm.Panelname AND pm.PaidYear = dm.DOSYear AND pm.PaidMonth = dm.DOSMonth
    ORDER BY dm.Panelname, dm.DOSYear, dm.DOSMonth;

    SET @msg = CONCAT(N'[RS13] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       14) DOS-cohort maturity curve — last 6 cohorts only (keeps output small)
       =================================================================== */
    IF OBJECT_ID('tempdb..#Paid') IS NOT NULL DROP TABLE #Paid;
    SELECT
        DOSMonth = DATEFROMPARTS(YEAR(DOS), MONTH(DOS), 1),
        AllowedAmount,
        InsurancePayment,
        DaysToPayment = CASE WHEN PaidDate IS NOT NULL AND InsurancePayment > 0
                              THEN DATEDIFF(DAY, DOS, PaidDate) END
    INTO #Paid
    FROM #Base
    WHERE BillStatus = N'Billed' AND ClaimStatus <> N'No Response';

    IF EXISTS (SELECT 1 FROM #Paid)
        CREATE CLUSTERED INDEX IX_Paid_DOSMonth ON #Paid (DOSMonth, DaysToPayment);

    ;WITH CohortTotal AS (
        SELECT TOP (6) DOSMonth, TotalAllowed = SUM(AllowedAmount), ClaimCount = COUNT(*)
        FROM #Paid
        GROUP BY DOSMonth
        HAVING COUNT(*) >= 30
        ORDER BY DOSMonth DESC
    ),
    DailyPaid AS (
        SELECT p.DOSMonth, p.DaysToPayment, DayPaid = SUM(p.InsurancePayment)
        FROM #Paid p
        INNER JOIN CohortTotal ct ON ct.DOSMonth = p.DOSMonth
        WHERE p.DaysToPayment BETWEEN 0 AND 120
        GROUP BY p.DOSMonth, p.DaysToPayment
    ),
    Days AS (
        SELECT TOP (121) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS N
        FROM sys.all_objects
    ),
    Grid AS (
        SELECT ct.DOSMonth, ct.TotalAllowed, d.N,
               CumulativePaid = SUM(ISNULL(dp.DayPaid, 0))
                   OVER (PARTITION BY ct.DOSMonth ORDER BY d.N ROWS UNBOUNDED PRECEDING)
        FROM CohortTotal ct
        CROSS JOIN Days d
        LEFT JOIN DailyPaid dp ON dp.DOSMonth = ct.DOSMonth AND dp.DaysToPayment = d.N
    )
    SELECT
        DOSMonthLabel = LEFT(DATENAME(MONTH, DOSMonth), 3) + ' ' + CONVERT(varchar(4), YEAR(DOSMonth)),
        DaySinceDOS = N,
        PctAllowedPaid = CASE WHEN TotalAllowed = 0 THEN NULL
            ELSE CAST(CumulativePaid * 100.0 / TotalAllowed AS decimal(18,2)) END
    FROM Grid
    ORDER BY DOSMonth, N;

    IF OBJECT_ID('tempdb..#Paid') IS NOT NULL DROP TABLE #Paid;

    SET @msg = CONCAT(N'[RS14] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       15) Insurance Balance % + composition (headline PMS finding from doc)
       =================================================================== */
    SELECT
        MonthLabel = LEFT(DATENAME(MONTH, m.MY), 3) + ' ' + CONVERT(varchar(4), YEAR(m.MY)),
        BilledClaims = COUNT(DISTINCT CASE WHEN b.BillStatus = N'Billed' THEN b.ClaimIDKey END),
        InsuranceBalanceClaims = COUNT(DISTINCT CASE WHEN b.ClaimStatus IN (N'Fully Denied', N'No Response', N'Partially Denied')
                                                     THEN b.ClaimIDKey END),
        PctInsuranceBalance = CASE WHEN COUNT(DISTINCT CASE WHEN b.BillStatus = N'Billed' THEN b.ClaimIDKey END) = 0 THEN NULL
            ELSE CAST(COUNT(DISTINCT CASE WHEN b.ClaimStatus IN (N'Fully Denied', N'No Response', N'Partially Denied')
                                          THEN b.ClaimIDKey END) * 100.0
                     / COUNT(DISTINCT CASE WHEN b.BillStatus = N'Billed' THEN b.ClaimIDKey END) AS decimal(18,2)) END,
        FullyDeniedClaims = COUNT(DISTINCT CASE WHEN b.ClaimStatus = N'Fully Denied' THEN b.ClaimIDKey END),
        NoResponseClaims = COUNT(DISTINCT CASE WHEN b.ClaimStatus = N'No Response' THEN b.ClaimIDKey END),
        PartiallyDeniedClaims = COUNT(DISTINCT CASE WHEN b.ClaimStatus = N'Partially Denied' THEN b.ClaimIDKey END),
        InsuranceBalanceAmt = SUM(CASE WHEN b.ClaimStatus IN (N'Fully Denied', N'No Response', N'Partially Denied')
                                       THEN b.InsuranceBalance ELSE 0 END)
    FROM #Months m
    LEFT JOIN #Base b ON b.ESYear = m.CollYear AND b.ESMonth = m.CollMonth
    GROUP BY m.MY
    ORDER BY m.MY;

    SET @msg = CONCAT(N'[RS15] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       16) Cash headline metrics (doc Cash Breakdown)
           Collection Rate = Insurance Payment (Fully Paid) $ ÷ Total Billed $
       =================================================================== */
    SELECT
        MonthLabel = LEFT(DATENAME(MONTH, m.MY), 3) + ' ' + CONVERT(varchar(4), YEAR(m.MY)),
        TotalBilledAmt = SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.ChargeAmount ELSE 0 END),
        InsurancePaymentFullyPaid = SUM(CASE WHEN b.ClaimStatus = N'Fully Paid' AND b.InsurancePayment > 0
                                              THEN b.InsurancePayment ELSE 0 END),
        CollectionRatePct = CASE WHEN SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.ChargeAmount ELSE 0 END) = 0 THEN NULL
            ELSE CAST(SUM(CASE WHEN b.ClaimStatus = N'Fully Paid' AND b.InsurancePayment > 0
                               THEN b.InsurancePayment ELSE 0 END) * 100.0
                     / SUM(CASE WHEN b.BillStatus = N'Billed' THEN b.ChargeAmount ELSE 0 END) AS decimal(18,2)) END,
        PatientWOAmt = SUM(CASE WHEN b.PatientAdjustments > 0 THEN b.PatientAdjustments ELSE 0 END),
        PatientBalanceAmt = SUM(b.PatientBalance),
        PatientPaymentAmt = SUM(CASE WHEN b.PatientPayment > 0 THEN b.PatientPayment ELSE 0 END),
        FullyAdjustedAmt = SUM(CASE WHEN b.ClaimStatus = N'Fully Adjusted'
                                    THEN b.InsuranceAdjustments + b.PatientAdjustments ELSE 0 END)
    FROM #Months m
    LEFT JOIN #Base b ON b.ESYear = m.CollYear AND b.ESMonth = m.CollMonth
    GROUP BY m.MY
    ORDER BY m.MY;

    SET @msg = CONCAT(N'[RS16] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    IF OBJECT_ID('tempdb..#Lis')    IS NOT NULL DROP TABLE #Lis;
    IF OBJECT_ID('tempdb..#Base')   IS NOT NULL DROP TABLE #Base;
    IF OBJECT_ID('tempdb..#Months') IS NOT NULL DROP TABLE #Months;

    RAISERROR(N'[Done]', 0, 1) WITH NOWAIT;
END
GO

PRINT 'usp_GetBeechTree_ThreePillarDiagnosticDrill created.';
GO
