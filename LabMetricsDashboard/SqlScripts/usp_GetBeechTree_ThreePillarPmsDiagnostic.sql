/* =====================================================================
   dbo.usp_GetBeechTree_ThreePillarPmsDiagnostic
   ---------------------------------------------------------------------
   Beech_Tree Three-Pillar — Pillar 2 PMS / Revenue Realization.

   Comparable-window logic matches Insights + LIS diagnostic:
     @AsOfDate   = Billed WeekRange END date
     @DayWindow  = DAY(@AsOfDate)
     Monthly claim metrics use DOS day BETWEEN 1 AND @DayWindow
     (maturity curve uses full-month cohorts — not day-capped).

   Fully Adjusted aligns with ES/LisDrill when present:
     BillStatus='Billed' AND ClaimStatus IN ('Complete W/O','Fully Adjusted')

   Result sets
     1  Reconciliation Gap (PMS Billed vs LIS Billed to Insurance)
     2  Fully Adjusted % of Billed Claims (monthly)
     3  Fully Adjusted reason-code Pareto (YTD / window counts)
     4  Fully Paid % of Billed Claims (monthly)
     5  Insurance Balance % + composition (monthly)
     6  Panel Avg Allowed (DOS) vs Avg Paid (CheckDate) — Top 5 panels
     7  Panel × Top Payer MOM — Top 5 panels × top 10 payers
     8  DOS-cohort maturity curve (cumulative paid ≤ day N; censored by age)
     9  Denial rate by carrier — Top 10 by Allowed $ volume
    10  Top denial reasons by top payers (trailing months)
   ===================================================================== */
IF OBJECT_ID('dbo.usp_GetBeechTree_ThreePillarPmsDiagnostic', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_GetBeechTree_ThreePillarPmsDiagnostic;
GO
CREATE PROCEDURE dbo.usp_GetBeechTree_ThreePillarPmsDiagnostic
    @TrailingMonths INT  = 12,
    @DayWindow      INT  = 0,
    @AsOfDate       DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @t0 DATETIME2 = SYSDATETIME();
    DECLARE @msg NVARCHAR(400);

    IF @AsOfDate IS NULL SET @AsOfDate = CAST(GETDATE() AS date);
    IF @TrailingMonths NOT BETWEEN 1 AND 36 SET @TrailingMonths = 12;
    IF @DayWindow NOT BETWEEN 1 AND 31
        SET @DayWindow = CASE WHEN DAY(@AsOfDate) BETWEEN 1 AND 31 THEN DAY(@AsOfDate) ELSE 9 END;

    DECLARE @AsOfStr VARCHAR(10) = CONVERT(varchar(10), @AsOfDate, 23);
    RAISERROR(N'[Start] ThreePillarPms months=%d dayWindow=%d asOf=%s', 0, 1,
              @TrailingMonths, @DayWindow, @AsOfStr) WITH NOWAIT;

    IF OBJECT_ID('dbo.ClaimLevelData', 'U') IS NULL
    BEGIN
        RAISERROR(N'ClaimLevelData not found — PMS diagnostic cannot run.', 16, 1);
        RETURN;
    END

    DECLARE @HasLims BIT = CASE WHEN OBJECT_ID('dbo.LIMSMaster','U') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasWO   BIT = CASE WHEN OBJECT_ID('dbo.BTWOSummary','U') IS NOT NULL THEN 1 ELSE 0 END;

    DECLARE @LatestY INT = YEAR(@AsOfDate);
    DECLARE @LatestM INT = MONTH(@AsOfDate);
    DECLARE @PriorDate DATE = DATEADD(MONTH, -1, @AsOfDate);
    DECLARE @PriorY INT = YEAR(@PriorDate);
    DECLARE @PriorM INT = MONTH(@PriorDate);

    DECLARE @StartDate DATE = DATEFROMPARTS(
        YEAR(DATEADD(MONTH, -(@TrailingMonths - 1), @AsOfDate)),
        MONTH(DATEADD(MONTH, -(@TrailingMonths - 1), @AsOfDate)),
        1);
    DECLARE @EndDate DATE = @AsOfDate;

    SET @msg = CONCAT(N'[Window] ', CONVERT(varchar(10), @StartDate, 23), N' .. ',
                      CONVERT(varchar(10), @EndDate, 23), N' dayWindow=1..', @DayWindow);
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    /* ── #Base (ClaimLevelData) ── */
    IF OBJECT_ID('tempdb..#Base') IS NOT NULL DROP TABLE #Base;
    CREATE TABLE #Base (
        ClaimIDKey          NVARCHAR(50)  COLLATE DATABASE_DEFAULT NOT NULL,
        ESYear              INT NOT NULL,
        ESMonth             INT NOT NULL,
        DosDay              INT NOT NULL,
        DOS                 DATE NOT NULL,
        PaidDate            DATE NULL,
        BillStatus          NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        ClaimStatus         NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        PayerName           NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        Panelname           NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        DenialCode          NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        ChargeAmount        DECIMAL(18,2) NOT NULL,
        AllowedAmount       DECIMAL(18,2) NOT NULL,
        InsurancePayment    DECIMAL(18,2) NOT NULL,
        PatientPayment      DECIMAL(18,2) NOT NULL,
        InsuranceBalance    DECIMAL(18,2) NOT NULL,
        PatientBalance      DECIMAL(18,2) NOT NULL,
        PatientAdjustments  DECIMAL(18,2) NOT NULL,
        InsuranceAdjustments DECIMAL(18,2) NOT NULL,
        AgingDays           INT NULL
    );

    INSERT INTO #Base (
        ClaimIDKey, ESYear, ESMonth, DosDay, DOS, PaidDate,
        BillStatus, ClaimStatus, PayerName, Panelname, DenialCode,
        ChargeAmount, AllowedAmount, InsurancePayment, PatientPayment,
        InsuranceBalance, PatientBalance, PatientAdjustments, InsuranceAdjustments, AgingDays)
    SELECT
        ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), ClaimID))), N''), N'?') COLLATE DATABASE_DEFAULT,
        YEAR(d.DOS), MONTH(d.DOS), DAY(d.DOS), d.DOS,
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
        CREATE CLUSTERED INDEX IX_Base_YM ON #Base (ESYear, ESMonth, DosDay);
        CREATE NONCLUSTERED INDEX IX_Base_Claim ON #Base (ClaimIDKey);
        CREATE NONCLUSTERED INDEX IX_Base_Status ON #Base (BillStatus, ClaimStatus)
            INCLUDE (AllowedAmount, InsuranceBalance, ChargeAmount, InsurancePayment);
    END

    SET @msg = CONCAT(N'[#Base] rows=', (SELECT COUNT(*) FROM #Base),
                      N' ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* DayWindow-comparable claims */
    IF OBJECT_ID('tempdb..#Cmp') IS NOT NULL DROP TABLE #Cmp;
    SELECT * INTO #Cmp FROM #Base WHERE DosDay BETWEEN 1 AND @DayWindow;
    IF EXISTS (SELECT 1 FROM #Cmp)
        CREATE CLUSTERED INDEX IX_Cmp_YM ON #Cmp (ESYear, ESMonth);

    /* Month scaffold */
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

    /* Optional LIS for reconciliation */
    IF OBJECT_ID('tempdb..#Lis') IS NOT NULL DROP TABLE #Lis;
    CREATE TABLE #Lis (
        Accession    NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        ESYear       INT NOT NULL,
        ESMonth      INT NOT NULL,
        CollectDay   INT NOT NULL,
        Resulted     NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        ClaimStatus  NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        BilledorNot  NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        ClientStatus NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL
    );
    IF @HasLims = 1
    BEGIN
        INSERT INTO #Lis (Accession, ESYear, ESMonth, CollectDay, Resulted, ClaimStatus, BilledorNot, ClientStatus)
        SELECT
            LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))) COLLATE DATABASE_DEFAULT,
            YEAR(RequestCollectDate), MONTH(RequestCollectDate), DAY(RequestCollectDate),
            LTRIM(RTRIM(ISNULL(RessultedStatus, N''))) COLLATE DATABASE_DEFAULT,
            LTRIM(RTRIM(ISNULL(ClaimStatus, N''))) COLLATE DATABASE_DEFAULT,
            LTRIM(RTRIM(ISNULL(BilledorNot, N''))) COLLATE DATABASE_DEFAULT,
            LTRIM(RTRIM(ISNULL(ClientStatus, N''))) COLLATE DATABASE_DEFAULT
        FROM dbo.LIMSMaster WITH (NOLOCK)
        WHERE RequestCollectDate IS NOT NULL
          AND RequestCollectDate >= @StartDate
          AND RequestCollectDate <  DATEADD(DAY, 1, @EndDate)
          AND DAY(RequestCollectDate) BETWEEN 1 AND @DayWindow;
        IF EXISTS (SELECT 1 FROM #Lis)
            CREATE CLUSTERED INDEX IX_Lis_YM ON #Lis (ESYear, ESMonth);
    END

    /* ===================================================================
       1) Reconciliation Gap
       =================================================================== */
    IF OBJECT_ID('tempdb..#PmsAgg') IS NOT NULL DROP TABLE #PmsAgg;
    IF OBJECT_ID('tempdb..#LisAgg') IS NOT NULL DROP TABLE #LisAgg;

    SELECT ESYear, ESMonth,
           PmsBilled = COUNT(DISTINCT CASE WHEN BillStatus = N'Billed' THEN ClaimIDKey END)
    INTO #PmsAgg FROM #Cmp GROUP BY ESYear, ESMonth;

    SELECT ESYear, ESMonth,
           LisBilledToInsurance = COUNT(DISTINCT CASE
               WHEN Resulted = N'Resulted' AND ClaimStatus = N'Billed'
                AND BilledorNot = N'Billed' AND ClientStatus = N'' THEN Accession END)
    INTO #LisAgg FROM #Lis GROUP BY ESYear, ESMonth;

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

    SET @msg = CONCAT(N'[RS1 recon] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       2) Fully Adjusted %
       =================================================================== */
    SELECT
        MonthLabel = LEFT(DATENAME(MONTH, m.MY), 3) + ' ' + CONVERT(varchar(4), YEAR(m.MY)),
        BilledClaims = COUNT(DISTINCT CASE WHEN b.BillStatus = N'Billed' THEN b.ClaimIDKey END),
        FullyAdjusted = COUNT(DISTINCT CASE
            WHEN b.BillStatus = N'Billed'
             AND b.ClaimStatus IN (N'Complete W/O', N'Fully Adjusted') THEN b.ClaimIDKey END),
        PctFullyAdjusted = CASE WHEN COUNT(DISTINCT CASE WHEN b.BillStatus = N'Billed' THEN b.ClaimIDKey END) = 0 THEN NULL
            ELSE CAST(COUNT(DISTINCT CASE
                    WHEN b.BillStatus = N'Billed'
                     AND b.ClaimStatus IN (N'Complete W/O', N'Fully Adjusted') THEN b.ClaimIDKey END) * 100.0
                 / COUNT(DISTINCT CASE WHEN b.BillStatus = N'Billed' THEN b.ClaimIDKey END) AS decimal(18,2)) END
    FROM #Months m
    LEFT JOIN #Cmp b ON b.ESYear = m.CollYear AND b.ESMonth = m.CollMonth
    GROUP BY m.MY
    ORDER BY m.MY;

    SET @msg = CONCAT(N'[RS2 fullyAdj] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       3) Reason-code Pareto (full window / YTD-style)
       =================================================================== */
    IF @HasWO = 1
    BEGIN
        IF OBJECT_ID('tempdb..#WO') IS NOT NULL DROP TABLE #WO;
        SELECT
            ClaimIDKey = ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), ClaimID))), N''), N'?') COLLATE DATABASE_DEFAULT,
            TransactionCodeCombined = LTRIM(RTRIM(CONVERT(NVARCHAR(200), TransactionCodeCombined))) COLLATE DATABASE_DEFAULT,
            MatchingCount = ISNULL(MatchingCount, 0)
        INTO #WO
        FROM dbo.BTWOSummary WITH (NOLOCK)
        WHERE TransactionCodeCombined IS NOT NULL
          AND TRY_CAST(DateofService AS DATE) >= @StartDate
          AND TRY_CAST(DateofService AS DATE) <  DATEADD(DAY, 1, @EndDate);

        SELECT TOP (15)
            ws.TransactionCodeCombined,
            MatchingCount = SUM(ws.MatchingCount)
        FROM #WO ws
        INNER JOIN #Cmp b ON b.ClaimIDKey = ws.ClaimIDKey
         AND b.BillStatus = N'Billed'
         AND b.ClaimStatus IN (N'Complete W/O', N'Fully Adjusted')
        GROUP BY ws.TransactionCodeCombined
        ORDER BY SUM(ws.MatchingCount) DESC;

        IF OBJECT_ID('tempdb..#WO') IS NOT NULL DROP TABLE #WO;
    END
    ELSE
        SELECT TransactionCodeCombined = CAST(N'' AS NVARCHAR(200)), MatchingCount = CAST(0 AS int) WHERE 1 = 0;

    SET @msg = CONCAT(N'[RS3 reasons] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       4) Fully Paid %
       =================================================================== */
    SELECT
        MonthLabel = LEFT(DATENAME(MONTH, m.MY), 3) + ' ' + CONVERT(varchar(4), YEAR(m.MY)),
        BilledClaims = COUNT(DISTINCT CASE WHEN b.BillStatus = N'Billed' THEN b.ClaimIDKey END),
        FullyPaid = COUNT(DISTINCT CASE WHEN b.ClaimStatus = N'Fully Paid' THEN b.ClaimIDKey END),
        PctFullyPaid = CASE WHEN COUNT(DISTINCT CASE WHEN b.BillStatus = N'Billed' THEN b.ClaimIDKey END) = 0 THEN NULL
            ELSE CAST(COUNT(DISTINCT CASE WHEN b.ClaimStatus = N'Fully Paid' THEN b.ClaimIDKey END) * 100.0
                     / COUNT(DISTINCT CASE WHEN b.BillStatus = N'Billed' THEN b.ClaimIDKey END) AS decimal(18,2)) END
    FROM #Months m
    LEFT JOIN #Cmp b ON b.ESYear = m.CollYear AND b.ESMonth = m.CollMonth
    GROUP BY m.MY
    ORDER BY m.MY;

    SET @msg = CONCAT(N'[RS4 fullyPaid] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       5) Insurance Balance % + composition
       =================================================================== */
    SELECT
        MonthLabel = LEFT(DATENAME(MONTH, m.MY), 3) + ' ' + CONVERT(varchar(4), YEAR(m.MY)),
        BilledClaims = COUNT(DISTINCT CASE WHEN b.BillStatus = N'Billed' THEN b.ClaimIDKey END),
        InsuranceBalanceClaims = COUNT(DISTINCT CASE
            WHEN b.ClaimStatus IN (N'Fully Denied', N'No Response', N'Partially Denied') THEN b.ClaimIDKey END),
        PctInsuranceBalance = CASE WHEN COUNT(DISTINCT CASE WHEN b.BillStatus = N'Billed' THEN b.ClaimIDKey END) = 0 THEN NULL
            ELSE CAST(COUNT(DISTINCT CASE
                    WHEN b.ClaimStatus IN (N'Fully Denied', N'No Response', N'Partially Denied') THEN b.ClaimIDKey END) * 100.0
                 / COUNT(DISTINCT CASE WHEN b.BillStatus = N'Billed' THEN b.ClaimIDKey END) AS decimal(18,2)) END,
        FullyDeniedClaims = COUNT(DISTINCT CASE WHEN b.ClaimStatus = N'Fully Denied' THEN b.ClaimIDKey END),
        NoResponseClaims = COUNT(DISTINCT CASE WHEN b.ClaimStatus = N'No Response' THEN b.ClaimIDKey END),
        PartiallyDeniedClaims = COUNT(DISTINCT CASE WHEN b.ClaimStatus = N'Partially Denied' THEN b.ClaimIDKey END),
        InsuranceBalanceAmt = SUM(CASE
            WHEN b.ClaimStatus IN (N'Fully Denied', N'No Response', N'Partially Denied')
            THEN b.InsuranceBalance ELSE 0 END)
    FROM #Months m
    LEFT JOIN #Cmp b ON b.ESYear = m.CollYear AND b.ESMonth = m.CollMonth
    GROUP BY m.MY
    ORDER BY m.MY;

    SET @msg = CONCAT(N'[RS5 insBal] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       6) Panel Avg Allowed / Paid (Top 5 panels by Allowed $; no hardcodes)
       =================================================================== */
    ;WITH Eligible AS (
        SELECT Panelname, DOS, PaidDate, AllowedAmount, InsurancePayment
        FROM #Cmp
        WHERE BillStatus = N'Billed' AND ClaimStatus <> N'No Response'
    ),
    TopPanels AS (
        SELECT TOP (5) Panelname, SUM(AllowedAmount) AS TotalAllowed
        FROM Eligible GROUP BY Panelname ORDER BY SUM(AllowedAmount) DESC
    ),
    ByDosMonth AS (
        SELECT e.Panelname, DOSYear = YEAR(e.DOS), DOSMonth = MONTH(e.DOS),
               AvgAllowed = AVG(e.AllowedAmount), AllowedClaimCount = COUNT(*)
        FROM Eligible e
        INNER JOIN TopPanels tp ON tp.Panelname = e.Panelname
        GROUP BY e.Panelname, YEAR(e.DOS), MONTH(e.DOS)
    ),
    ByPaidMonth AS (
        SELECT e.Panelname, PaidYear = YEAR(e.PaidDate), PaidMonth = MONTH(e.PaidDate),
               AvgPaid = AVG(e.InsurancePayment), PaidClaimCount = COUNT(*)
        FROM Eligible e
        INNER JOIN TopPanels tp ON tp.Panelname = e.Panelname
        WHERE e.PaidDate IS NOT NULL
        GROUP BY e.Panelname, YEAR(e.PaidDate), MONTH(e.PaidDate)
    )
    SELECT
        dm.Panelname,
        MonthLabel_DOS = LEFT(DATENAME(MONTH, DATEFROMPARTS(dm.DOSYear, dm.DOSMonth, 1)), 3)
                         + ' ' + CONVERT(varchar(4), dm.DOSYear),
        AvgAllowed = CAST(dm.AvgAllowed AS decimal(18,2)),
        dm.AllowedClaimCount,
        AvgPaidByPaymentDate = CAST(pm.AvgPaid AS decimal(18,2)),
        PaidClaimCount = ISNULL(pm.PaidClaimCount, 0)
    FROM ByDosMonth dm
    INNER JOIN TopPanels tp ON tp.Panelname = dm.Panelname
    LEFT JOIN ByPaidMonth pm
        ON pm.Panelname = dm.Panelname AND pm.PaidYear = dm.DOSYear AND pm.PaidMonth = dm.DOSMonth
    ORDER BY tp.TotalAllowed DESC, dm.Panelname, dm.DOSYear, dm.DOSMonth;

    SET @msg = CONCAT(N'[RS6 panelAvg] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       7) Panel × Top Payer MOM — Top 5 panels × top 10 payers each
       =================================================================== */
    ;WITH Elig AS (
        SELECT Panelname, PayerName, ESYear, ESMonth,
               AllowedAmount, InsurancePayment, ClaimIDKey
        FROM #Cmp
        WHERE BillStatus = N'Billed' AND ClaimStatus <> N'No Response'
          AND ((ESYear = @PriorY AND ESMonth = @PriorM) OR (ESYear = @LatestY AND ESMonth = @LatestM))
    ),
    TopPanels2 AS (
        SELECT TOP (5) Panelname, SUM(AllowedAmount) AS TotalAllowed
        FROM #Cmp
        WHERE BillStatus = N'Billed' AND ClaimStatus <> N'No Response'
        GROUP BY Panelname ORDER BY SUM(AllowedAmount) DESC
    ),
    Agg AS (
        SELECT e.Panelname, e.PayerName,
               PriorAllowed = AVG(CASE WHEN e.ESYear = @PriorY AND e.ESMonth = @PriorM THEN e.AllowedAmount END),
               PriorPaid    = AVG(CASE WHEN e.ESYear = @PriorY AND e.ESMonth = @PriorM THEN e.InsurancePayment END),
               PriorN       = COUNT(DISTINCT CASE WHEN e.ESYear = @PriorY AND e.ESMonth = @PriorM THEN e.ClaimIDKey END),
               LatestAllowed = AVG(CASE WHEN e.ESYear = @LatestY AND e.ESMonth = @LatestM THEN e.AllowedAmount END),
               LatestPaid    = AVG(CASE WHEN e.ESYear = @LatestY AND e.ESMonth = @LatestM THEN e.InsurancePayment END),
               LatestN       = COUNT(DISTINCT CASE WHEN e.ESYear = @LatestY AND e.ESMonth = @LatestM THEN e.ClaimIDKey END),
               DollarRank    = SUM(e.AllowedAmount)
        FROM Elig e
        INNER JOIN TopPanels2 tp ON tp.Panelname = e.Panelname
        GROUP BY e.Panelname, e.PayerName
    ),
    Ranked AS (
        SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY Panelname ORDER BY DollarRank DESC)
        FROM Agg
    )
    SELECT
        Panelname,
        PayerName,
        PriorMonthLabel  = LEFT(DATENAME(MONTH, DATEFROMPARTS(@PriorY, @PriorM, 1)), 3)
                           + ' ' + CONVERT(varchar(4), @PriorY),
        LatestMonthLabel = LEFT(DATENAME(MONTH, DATEFROMPARTS(@LatestY, @LatestM, 1)), 3)
                           + ' ' + CONVERT(varchar(4), @LatestY),
        PriorAllowed  = CAST(ISNULL(PriorAllowed, 0) AS decimal(18,2)),
        PriorPaid     = CAST(ISNULL(PriorPaid, 0) AS decimal(18,2)),
        PriorN        = ISNULL(PriorN, 0),
        LatestAllowed = CAST(ISNULL(LatestAllowed, 0) AS decimal(18,2)),
        LatestPaid    = CAST(ISNULL(LatestPaid, 0) AS decimal(18,2)),
        LatestN       = ISNULL(LatestN, 0),
        MomPctPaid = CASE WHEN ISNULL(PriorPaid, 0) = 0 THEN NULL
            ELSE CAST((ISNULL(LatestPaid, 0) - PriorPaid) * 100.0 / NULLIF(PriorPaid, 0) AS decimal(18,2)) END
    FROM Ranked
    WHERE rn <= 10
    ORDER BY Panelname, rn;

    SET @msg = CONCAT(N'[RS7 panelPayer] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       8) DOS-cohort maturity curve (full #Base — not DayWindow-capped)
       % Allowed Paid (Day N) =
         Cumulative CarrierPayment with DaysToPayment <= N
         ÷ Cohort TotalAllowed × 100
       TotalAllowed uses Allowed when > 0 else Charge (Allowed often blank
       until adjudication — otherwise immature months look "best").
       Each cohort is censored at age vs @AsOfDate so Jul only plots days
       that have elapsed (immature, not underperforming).
       =================================================================== */
    IF OBJECT_ID('tempdb..#Paid') IS NOT NULL DROP TABLE #Paid;
    SELECT
        DOSMonth = DATEFROMPARTS(YEAR(DOS), MONTH(DOS), 1),
        CohortAllowed = CASE WHEN AllowedAmount > 0 THEN AllowedAmount ELSE ChargeAmount END,
        InsurancePayment,
        DaysToPayment = CASE
            WHEN PaidDate IS NOT NULL AND InsurancePayment > 0
             AND PaidDate >= DOS
            THEN DATEDIFF(DAY, DOS, PaidDate) END
    INTO #Paid
    FROM #Base
    WHERE BillStatus = N'Billed'
      AND ClaimStatus NOT IN (N'No Response', N'Unbilled', N'UnBilled');

    IF EXISTS (SELECT 1 FROM #Paid)
        CREATE CLUSTERED INDEX IX_Paid_DOSMonth ON #Paid (DOSMonth, DaysToPayment);

    ;WITH CohortTotal AS (
        SELECT TOP (6)
            DOSMonth,
            TotalAllowed = SUM(CohortAllowed),
            ClaimCount = COUNT(*),
            -- Age available for this cohort as of AsOf (from month start)
            MaxAgeDays = CASE
                WHEN DATEDIFF(DAY, DOSMonth, @AsOfDate) < 0 THEN 0
                WHEN DATEDIFF(DAY, DOSMonth, @AsOfDate) > 120 THEN 120
                ELSE DATEDIFF(DAY, DOSMonth, @AsOfDate)
            END
        FROM #Paid
        GROUP BY DOSMonth
        HAVING SUM(CohortAllowed) > 0 AND COUNT(*) >= 20
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
    -- Full daily cumulative 0..120, THEN sample + censor (not sample-then-sum)
    CumDaily AS (
        SELECT
            ct.DOSMonth,
            ct.TotalAllowed,
            ct.MaxAgeDays,
            d.N,
            CumulativePaid = SUM(ISNULL(dp.DayPaid, 0))
                OVER (PARTITION BY ct.DOSMonth ORDER BY d.N ROWS UNBOUNDED PRECEDING)
        FROM CohortTotal ct
        CROSS JOIN Days d
        LEFT JOIN DailyPaid dp ON dp.DOSMonth = ct.DOSMonth AND dp.DaysToPayment = d.N
        WHERE d.N BETWEEN 0 AND 120
    )
    SELECT
        DOSMonthLabel = LEFT(DATENAME(MONTH, DOSMonth), 3) + ' ' + CONVERT(varchar(4), YEAR(DOSMonth)),
        DaySinceDOS = N,
        PctAllowedPaid = CASE WHEN TotalAllowed = 0 THEN NULL
            ELSE CAST(CumulativePaid * 100.0 / TotalAllowed AS decimal(18,4)) END
    FROM CumDaily
    WHERE N IN (0, 7, 15, 30, 45, 60, 90, 120)
      AND N <= MaxAgeDays   -- stop immature cohorts early
    ORDER BY DOSMonth, N;

    IF OBJECT_ID('tempdb..#Paid') IS NOT NULL DROP TABLE #Paid;

    SET @msg = CONCAT(N'[RS8 maturity] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       9) Denial rate by carrier — Top 10 by Allowed $ volume
       Denial Rate = SUM(Allowed where Fully/Partially Denied)
                     ÷ SUM(Allowed), by PayerName
       No Response excluded from numerator (not a denial).
       Rank by TotalAllowed (not DenialRate) so tiny 100% payers don't dominate.
       =================================================================== */
    ;WITH PayerTotals AS (
        SELECT PayerName,
               TotalAllowed = SUM(CASE WHEN AllowedAmount > 0 THEN AllowedAmount ELSE ChargeAmount END),
               DeniedAllowed = SUM(CASE
                    WHEN ClaimStatus IN (N'Fully Denied', N'Partially Denied')
                    THEN CASE WHEN AllowedAmount > 0 THEN AllowedAmount ELSE ChargeAmount END
                    ELSE 0 END)
        FROM #Cmp
        WHERE BillStatus = N'Billed'
        GROUP BY PayerName
        HAVING SUM(CASE WHEN AllowedAmount > 0 THEN AllowedAmount ELSE ChargeAmount END) > 0
    )
    SELECT TOP (10)
        PayerName, TotalAllowed, DeniedAllowed,
        DenialRatePct = CASE WHEN TotalAllowed = 0 THEN NULL
            ELSE CAST(DeniedAllowed * 100.0 / TotalAllowed AS decimal(18,2)) END
    FROM PayerTotals
    ORDER BY TotalAllowed DESC;

    SET @msg = CONCAT(N'[RS9 denialCarrier] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       10) Top denial reasons × top payers (trailing months)
       =================================================================== */
    ;WITH TopPayers AS (
        SELECT TOP (5) PayerName, SUM(AllowedAmount) AS TotalAllowed
        FROM #Cmp WHERE BillStatus = N'Billed'
        GROUP BY PayerName ORDER BY SUM(AllowedAmount) DESC
    ),
    Trail AS (SELECT TOP (5) MY, CollYear, CollMonth FROM #Months ORDER BY MY DESC)
    SELECT
        b.PayerName,
        b.DenialCode,
        MonthLabel = LEFT(DATENAME(MONTH, t.MY), 3) + ' ' + CONVERT(varchar(4), YEAR(t.MY)),
        DenialCount = COUNT(*)
    FROM #Cmp b
    INNER JOIN TopPayers tp ON tp.PayerName = b.PayerName
    INNER JOIN Trail t ON t.CollYear = b.ESYear AND t.CollMonth = b.ESMonth
    WHERE b.ClaimStatus IN (N'Fully Denied', N'Partially Denied') AND b.DenialCode <> N''
    GROUP BY b.PayerName, b.DenialCode, t.MY
    ORDER BY b.PayerName, t.MY, DenialCount DESC;

    SET @msg = CONCAT(N'[RS10 denialReasons] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    IF OBJECT_ID('tempdb..#Lis')    IS NOT NULL DROP TABLE #Lis;
    IF OBJECT_ID('tempdb..#Cmp')    IS NOT NULL DROP TABLE #Cmp;
    IF OBJECT_ID('tempdb..#Base')   IS NOT NULL DROP TABLE #Base;
    IF OBJECT_ID('tempdb..#Months') IS NOT NULL DROP TABLE #Months;

    RAISERROR(N'[Done] ThreePillarPms', 0, 1) WITH NOWAIT;
END
GO

PRINT 'usp_GetBeechTree_ThreePillarPmsDiagnostic created.';
GO
