/* =====================================================================
   dbo.usp_GetBeechTree_ThreePillarLisDiagnostic
   ---------------------------------------------------------------------
   Beech_Tree Three-Pillar Diagnostic — LIS Breakdown ONLY.

   Comparable-window logic matches Executive Summary Insight drills:
     @AsOfDate   = Billed WeekRange END date (e.g. 2026-07-23)
     @DayWindow  = DAY(@AsOfDate)  (e.g. 23)
     Each month counts only CollectDay BETWEEN 1 AND @DayWindow
     so every month uses the same day-cutoff (1–23 of Jan, 1–23 of Feb, …).

   Parameters
     @TrailingMonths  3 / 6 / 9 / 12 / 19 … (default 12; clamp 1..36)
     @DayWindow       1–31; default DAY(@AsOfDate) or 9
     @AsOfDate        WeekRange end; anchors latest month + backlog age
     @Year            LEGACY — ignored when @TrailingMonths > 0 (kept for
                      older callers; pass 0)

   Result sets
     1  Monthly LIS breakdown (DayWindow-capped)
         PctBilledOfResulted denominator = Resulted – Insurance (BillTo LIKE '%Insurance%')
     2  Backlog age summary as of @AsOfDate
         Backlog n = Resulted – Insurance − Billed to Insurance (DayWindow, DISTINCT Accession)
     3  Backlog age buckets (0-7 / 8-14 / 15-30 / 31-60 / 60+)
     4  Full-period Sample-to-Claim Funnel (DayWindow-capped)
         Collected / Resulted (Insurance) / ResultedSelfPay / ResultedClientBill / BilledToInsurance
         Bill to Insurance % = Billed to Insurance / Resulted – Insurance
     5  Payer-wise collected (DayWindow) — all payers per month (UI rolls Top 5)
     6  Panel-wise collected (DayWindow) — all panels per month (UI rolls Top 5)
   ===================================================================== */
IF OBJECT_ID('dbo.usp_GetBeechTree_ThreePillarLisDiagnostic', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_GetBeechTree_ThreePillarLisDiagnostic;
GO
CREATE PROCEDURE dbo.usp_GetBeechTree_ThreePillarLisDiagnostic
    @Year           INT  = 0,
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

    /* RAISERROR substitution args must be variables/literals — not expressions. */
    DECLARE @AsOfStr VARCHAR(10) = CONVERT(varchar(10), @AsOfDate, 23);
    RAISERROR(N'[Start] ThreePillarLis months=%d dayWindow=%d asOf=%s', 0, 1,
              @TrailingMonths, @DayWindow, @AsOfStr) WITH NOWAIT;

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
    BEGIN
        RAISERROR(N'LIMSMaster not found — LIS diagnostic cannot run.', 16, 1);
        RETURN;
    END

    /* Anchor on WeekRange end month; trailing N months inclusive. */
    DECLARE @LatestY INT = YEAR(@AsOfDate);
    DECLARE @LatestM INT = MONTH(@AsOfDate);
    DECLARE @StartDate DATE = DATEFROMPARTS(
        YEAR(DATEADD(MONTH, -(@TrailingMonths - 1), @AsOfDate)),
        MONTH(DATEADD(MONTH, -(@TrailingMonths - 1), @AsOfDate)),
        1);
    /* Load through AsOfDate (not EOM) — latest month only has days 1..DayWindow. */
    DECLARE @EndDate DATE = @AsOfDate;

    SET @msg = CONCAT(N'[Window] ', CONVERT(varchar(10), @StartDate, 23), N' .. ',
                      CONVERT(varchar(10), @EndDate, 23), N' dayWindow=1..', @DayWindow);
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    DECLARE @PayerCol SYSNAME = (
        SELECT TOP (1) name FROM sys.columns
        WHERE object_id = OBJECT_ID(N'dbo.LIMSMaster')
          AND name IN (N'PrimaryInsurance', N'PayerName', N'PayerName_Raw', N'InsuranceName',
                       N'PrimaryPayer', N'VisitPrimaryCarrier', N'PayorName', N'Payor')
        ORDER BY CASE name
            WHEN N'PrimaryInsurance' THEN 0 WHEN N'PayerName' THEN 1 WHEN N'PayerName_Raw' THEN 2
            WHEN N'InsuranceName' THEN 3 WHEN N'PrimaryPayer' THEN 4
            WHEN N'VisitPrimaryCarrier' THEN 5 ELSE 6 END);

    DECLARE @PanelCol SYSNAME = (
        SELECT TOP (1) name FROM sys.columns
        WHERE object_id = OBJECT_ID(N'dbo.LIMSMaster')
          AND name IN (N'PanelCategory', N'PanelType', N'PanelName', N'Panelname',
                       N'Panel', N'TestPanel', N'TestPanelName', N'Tests')
        ORDER BY CASE name
            WHEN N'PanelCategory' THEN 0 WHEN N'PanelType' THEN 1 WHEN N'PanelName' THEN 2
            WHEN N'Panelname' THEN 3 WHEN N'Panel' THEN 4 WHEN N'TestPanel' THEN 5
            WHEN N'TestPanelName' THEN 6 ELSE 7 END);

    DECLARE @PayerExpr NVARCHAR(400) = CASE WHEN @PayerCol IS NOT NULL
        THEN N'ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), ' + QUOTENAME(@PayerCol) + N'), N''''))), N''''), N''Unspecified'')'
        ELSE N'N''Unspecified''' END;
    DECLARE @PanelExpr NVARCHAR(400) = CASE WHEN @PanelCol IS NOT NULL
        THEN N'ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), ' + QUOTENAME(@PanelCol) + N'), N''''))), N''''), N''Unspecified'')'
        ELSE N'N''Unspecified''' END;

    DECLARE @BillToCol SYSNAME = (
        SELECT TOP (1) name FROM sys.columns
        WHERE object_id = OBJECT_ID(N'dbo.LIMSMaster')
          AND name IN (N'BillTo', N'BillCategory', N'Bill_Category', N'BillingCategory')
        ORDER BY CASE name
            WHEN N'BillTo' THEN 0 WHEN N'BillCategory' THEN 1
            WHEN N'Bill_Category' THEN 2 ELSE 3 END);

    /* Prefer LIMS BillTo; if the column is absent, treat non-Self-Pay / non-Client-Bill as Insurance. */
    DECLARE @BillToExpr NVARCHAR(800) = CASE WHEN @BillToCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), ' + QUOTENAME(@BillToCol) + N'), N'''')))'
        ELSE N'CASE WHEN LTRIM(RTRIM(ISNULL(ClientStatus, N''''))) IN (N''Self Pay'', N''Client Bill'')
                    THEN LTRIM(RTRIM(ISNULL(ClientStatus, N'''')))
                    ELSE N''Insurance'' END' END;

    SET @msg = CONCAT(N'[Cols] payer=', ISNULL(@PayerCol, N'(none)'),
                      N' panel=', ISNULL(@PanelCol, N'(none)'),
                      N' billTo=', ISNULL(@BillToCol, N'(ClientStatus fallback)'));
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    IF OBJECT_ID('tempdb..#Lis') IS NOT NULL DROP TABLE #Lis;
    CREATE TABLE #Lis (
        Accession    NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        ESYear       INT NOT NULL,
        ESMonth      INT NOT NULL,
        CollectDay   INT NOT NULL,
        CollectDate  DATE NULL,
        Resulted     NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        ClaimStatus  NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        BilledorNot  NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        ClientStatus NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        BillTo       NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        PayerName    NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        PanelName    NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL
    );

    DECLARE @ins NVARCHAR(MAX) = N'
    INSERT INTO #Lis (Accession, ESYear, ESMonth, CollectDay, CollectDate, Resulted, ClaimStatus, BilledorNot, ClientStatus, BillTo, PayerName, PanelName)
    SELECT
        LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))) COLLATE DATABASE_DEFAULT,
        YEAR(RequestCollectDate), MONTH(RequestCollectDate), DAY(RequestCollectDate),
        RequestCollectDate,
        LTRIM(RTRIM(ISNULL(RessultedStatus, N''''))) COLLATE DATABASE_DEFAULT,
        LTRIM(RTRIM(ISNULL(ClaimStatus, N''''))) COLLATE DATABASE_DEFAULT,
        LTRIM(RTRIM(ISNULL(BilledorNot, N''''))) COLLATE DATABASE_DEFAULT,
        LTRIM(RTRIM(ISNULL(ClientStatus, N''''))) COLLATE DATABASE_DEFAULT,
        ' + @BillToExpr + N' COLLATE DATABASE_DEFAULT,
        ' + @PayerExpr + N' COLLATE DATABASE_DEFAULT,
        ' + @PanelExpr + N' COLLATE DATABASE_DEFAULT
    FROM dbo.LIMSMaster WITH (NOLOCK)
    WHERE RequestCollectDate IS NOT NULL
      AND RequestCollectDate >= @StartDate
      AND RequestCollectDate <  DATEADD(DAY, 1, @EndDate);';

    EXEC sys.sp_executesql @ins,
        N'@StartDate date, @EndDate date',
        @StartDate = @StartDate, @EndDate = @EndDate;

    IF EXISTS (SELECT 1 FROM #Lis)
        CREATE CLUSTERED INDEX IX_Lis_YM_Day ON #Lis (ESYear, ESMonth, CollectDay);

    SET @msg = CONCAT(N'[#Lis] rows=', (SELECT COUNT(*) FROM #Lis),
                      N' ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* Comparable rows: days 1..@DayWindow of every month (Insights parity). */
    IF OBJECT_ID('tempdb..#Cmp') IS NOT NULL DROP TABLE #Cmp;
    SELECT *
    INTO #Cmp
    FROM #Lis
    WHERE CollectDay BETWEEN 1 AND @DayWindow;

    IF EXISTS (SELECT 1 FROM #Cmp)
        CREATE CLUSTERED INDEX IX_Cmp_YM ON #Cmp (ESYear, ESMonth);

    /* Month scaffold: StartDate month .. AsOf month */
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

    /* ===================================================================
       1) Monthly LIS breakdown — DayWindow comparable counts
       =================================================================== */
    SELECT
        MonthLabel = LEFT(DATENAME(MONTH, m.MY), 3) + ' ' + CONVERT(varchar(4), YEAR(m.MY)),
        SortYear   = m.CollYear,
        SortMonth  = m.CollMonth,
        TotalSamples = COUNT(DISTINCT l.Accession),
        Resulted = COUNT(DISTINCT CASE WHEN l.Resulted = N'Resulted' THEN l.Accession END),
        PctResulted = CASE WHEN COUNT(DISTINCT l.Accession) = 0 THEN NULL
            ELSE CAST(COUNT(DISTINCT CASE WHEN l.Resulted = N'Resulted' THEN l.Accession END) * 100.0
                     / COUNT(DISTINCT l.Accession) AS decimal(18,2)) END,
        BilledToInsurance = COUNT(DISTINCT CASE
            WHEN l.Resulted = N'Resulted' AND l.ClaimStatus = N'Billed'
             AND l.BilledorNot = N'Billed' AND l.ClientStatus = N'' THEN l.Accession END),
        /* Resulted – Insurance: RessultedStatus = Resulted AND BillTo contains Insurance. */
        ResultedInsurance = COUNT(DISTINCT CASE
            WHEN l.Resulted = N'Resulted' AND l.BillTo LIKE N'%Insurance%' THEN l.Accession END),
        PctBilledOfResulted = CASE
            WHEN COUNT(DISTINCT CASE
                    WHEN l.Resulted = N'Resulted' AND l.BillTo LIKE N'%Insurance%' THEN l.Accession END) = 0 THEN NULL
            ELSE CAST(COUNT(DISTINCT CASE
                    WHEN l.Resulted = N'Resulted' AND l.ClaimStatus = N'Billed'
                     AND l.BilledorNot = N'Billed' AND l.ClientStatus = N'' THEN l.Accession END) * 100.0
                 / COUNT(DISTINCT CASE
                    WHEN l.Resulted = N'Resulted' AND l.BillTo LIKE N'%Insurance%' THEN l.Accession END) AS decimal(18,2)) END,
        SelfPay = COUNT(DISTINCT CASE
            WHEN l.Resulted = N'Resulted' AND l.ClientStatus = N'Self Pay' THEN l.Accession END),
        SelfPayPct = CASE WHEN COUNT(DISTINCT l.Accession) = 0 THEN NULL
            ELSE CAST(COUNT(DISTINCT CASE
                    WHEN l.Resulted = N'Resulted' AND l.ClientStatus = N'Self Pay' THEN l.Accession END) * 100.0
                 / COUNT(DISTINCT l.Accession) AS decimal(18,2)) END,
        ClientBill = COUNT(DISTINCT CASE
            WHEN l.Resulted = N'Resulted' AND l.ClientStatus = N'Client Bill' THEN l.Accession END),
        ClientBillPct = CASE WHEN COUNT(DISTINCT l.Accession) = 0 THEN NULL
            ELSE CAST(COUNT(DISTINCT CASE
                    WHEN l.Resulted = N'Resulted' AND l.ClientStatus = N'Client Bill' THEN l.Accession END) * 100.0
                 / COUNT(DISTINCT l.Accession) AS decimal(18,2)) END,
        NotResulted = COUNT(DISTINCT CASE WHEN l.Resulted = N'Not Resulted' THEN l.Accession END),
        IsPartialMonth = CASE WHEN m.CollYear = @LatestY AND m.CollMonth = @LatestM THEN 1 ELSE 0 END
    FROM #Months m
    LEFT JOIN #Cmp l ON l.ESYear = m.CollYear AND l.ESMonth = m.CollMonth
    GROUP BY m.MY, m.CollYear, m.CollMonth
    ORDER BY m.MY;

    SET @msg = CONCAT(N'[RS1 monthly] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       2–3) Backlog age as of @AsOfDate (DayWindow, DISTINCT Accession)
            Backlog = Resulted – Insurance − Billed to Insurance
       =================================================================== */
    IF OBJECT_ID('tempdb..#Backlog') IS NOT NULL DROP TABLE #Backlog;
    SELECT
        Accession,
        CollectDate = MIN(CollectDate),
        AgeDays = DATEDIFF(DAY, MIN(CollectDate), @AsOfDate)
    INTO #Backlog
    FROM #Cmp
    WHERE Resulted = N'Resulted'
      AND BillTo LIKE N'%Insurance%'
      AND NOT (ClaimStatus = N'Billed' AND BilledorNot = N'Billed' AND ClientStatus = N'')
    GROUP BY Accession;

    ;WITH Ordered AS (
        SELECT AgeDays,
               rn  = ROW_NUMBER() OVER (ORDER BY AgeDays),
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
                      / NULLIF((SELECT COUNT(*) FROM #Backlog), 0) AS decimal(18,2)) END;

    SELECT
        AgeBucket = CASE
            WHEN AgeDays <= 7  THEN N'0-7d'
            WHEN AgeDays <= 14 THEN N'8-14d'
            WHEN AgeDays <= 30 THEN N'15-30d'
            WHEN AgeDays <= 60 THEN N'31-60d'
            ELSE N'60+d' END,
        SortOrder = CASE
            WHEN AgeDays <= 7 THEN 1 WHEN AgeDays <= 14 THEN 2
            WHEN AgeDays <= 30 THEN 3 WHEN AgeDays <= 60 THEN 4 ELSE 5 END,
        SampleCount = COUNT(*)
    FROM #Backlog
    GROUP BY CASE
            WHEN AgeDays <= 7  THEN N'0-7d'
            WHEN AgeDays <= 14 THEN N'8-14d'
            WHEN AgeDays <= 30 THEN N'15-30d'
            WHEN AgeDays <= 60 THEN N'31-60d'
            ELSE N'60+d' END,
        CASE WHEN AgeDays <= 7 THEN 1 WHEN AgeDays <= 14 THEN 2
             WHEN AgeDays <= 30 THEN 3 WHEN AgeDays <= 60 THEN 4 ELSE 5 END
    ORDER BY SortOrder;

    SET @msg = CONCAT(N'[RS2-3 backlog] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       4) Full-period funnel — DayWindow comparable
       =================================================================== */
    SELECT
        Collected = COUNT(DISTINCT Accession),
        /* Funnel "Resulted" bar = Resulted – Insurance (BillTo LIKE '%Insurance%'). */
        Resulted  = COUNT(DISTINCT CASE
            WHEN Resulted = N'Resulted' AND BillTo LIKE N'%Insurance%' THEN Accession END),
        ResultedSelfPay = COUNT(DISTINCT CASE
            WHEN Resulted = N'Resulted' AND ClientStatus = N'Self Pay' THEN Accession END),
        ResultedClientBill = COUNT(DISTINCT CASE
            WHEN Resulted = N'Resulted' AND ClientStatus = N'Client Bill' THEN Accession END),
        BilledToInsurance = COUNT(DISTINCT CASE
            WHEN Resulted = N'Resulted' AND ClaimStatus = N'Billed'
             AND BilledorNot = N'Billed' AND ClientStatus = N'' THEN Accession END),
        PctResulted = CASE WHEN COUNT(DISTINCT Accession) = 0 THEN NULL
            ELSE CAST(COUNT(DISTINCT CASE
                    WHEN Resulted = N'Resulted' AND BillTo LIKE N'%Insurance%' THEN Accession END) * 100.0
                     / COUNT(DISTINCT Accession) AS decimal(18,2)) END,
        PctSelfPayOfCollected = CASE WHEN COUNT(DISTINCT Accession) = 0 THEN NULL
            ELSE CAST(COUNT(DISTINCT CASE
                    WHEN Resulted = N'Resulted' AND ClientStatus = N'Self Pay' THEN Accession END) * 100.0
                 / COUNT(DISTINCT Accession) AS decimal(18,2)) END,
        PctClientBillOfCollected = CASE WHEN COUNT(DISTINCT Accession) = 0 THEN NULL
            ELSE CAST(COUNT(DISTINCT CASE
                    WHEN Resulted = N'Resulted' AND ClientStatus = N'Client Bill' THEN Accession END) * 100.0
                 / COUNT(DISTINCT Accession) AS decimal(18,2)) END,
        PctBilledOfCollected = CASE WHEN COUNT(DISTINCT Accession) = 0 THEN NULL
            ELSE CAST(COUNT(DISTINCT CASE
                    WHEN Resulted = N'Resulted' AND ClaimStatus = N'Billed'
                     AND BilledorNot = N'Billed' AND ClientStatus = N'' THEN Accession END) * 100.0
                 / COUNT(DISTINCT Accession) AS decimal(18,2)) END,
        PctBilledOfResulted = CASE
            WHEN COUNT(DISTINCT CASE
                    WHEN Resulted = N'Resulted' AND BillTo LIKE N'%Insurance%' THEN Accession END) = 0 THEN NULL
            ELSE CAST(COUNT(DISTINCT CASE
                    WHEN Resulted = N'Resulted' AND ClaimStatus = N'Billed'
                     AND BilledorNot = N'Billed' AND ClientStatus = N'' THEN Accession END) * 100.0
                 / COUNT(DISTINCT CASE
                    WHEN Resulted = N'Resulted' AND BillTo LIKE N'%Insurance%' THEN Accession END) AS decimal(18,2)) END
    FROM #Cmp;

    SET @msg = CONCAT(N'[RS4 funnel] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       5) Payer-wise collected — every payer, every volume month
          (page shows Top 5 + Other by default; click a month for all)
       =================================================================== */
    SELECT
        MonthLabel = LEFT(DATENAME(MONTH, m.MY), 3) + ' ' + CONVERT(varchar(4), YEAR(m.MY)),
        SortYear   = m.CollYear,
        SortMonth  = m.CollMonth,
        Kind       = N'Payer',
        Name       = p.PayerName,
        SampleCount = p.SampleCount,
        SortOrder  = ROW_NUMBER() OVER (
            PARTITION BY m.CollYear, m.CollMonth
            ORDER BY p.SampleCount DESC, p.PayerName)
    FROM #Months m
    INNER JOIN (
        SELECT ESYear, ESMonth, PayerName, SampleCount = COUNT(DISTINCT Accession)
        FROM #Cmp
        GROUP BY ESYear, ESMonth, PayerName
    ) p ON p.ESYear = m.CollYear AND p.ESMonth = m.CollMonth
    ORDER BY m.MY, p.SampleCount DESC, p.PayerName;

    SET @msg = CONCAT(N'[RS5 payer] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT; SET @t0 = SYSDATETIME();

    /* ===================================================================
       6) Panel-wise collected — every panel, every volume month
       =================================================================== */
    SELECT
        MonthLabel = LEFT(DATENAME(MONTH, m.MY), 3) + ' ' + CONVERT(varchar(4), YEAR(m.MY)),
        SortYear   = m.CollYear,
        SortMonth  = m.CollMonth,
        Kind       = N'Panel',
        Name       = p.PanelName,
        SampleCount = p.SampleCount,
        SortOrder  = ROW_NUMBER() OVER (
            PARTITION BY m.CollYear, m.CollMonth
            ORDER BY p.SampleCount DESC, p.PanelName)
    FROM #Months m
    INNER JOIN (
        SELECT ESYear, ESMonth, PanelName, SampleCount = COUNT(DISTINCT Accession)
        FROM #Cmp
        GROUP BY ESYear, ESMonth, PanelName
    ) p ON p.ESYear = m.CollYear AND p.ESMonth = m.CollMonth
    ORDER BY m.MY, p.SampleCount DESC, p.PanelName;

    SET @msg = CONCAT(N'[RS6 panel] ms=', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    IF OBJECT_ID('tempdb..#Lis')     IS NOT NULL DROP TABLE #Lis;
    IF OBJECT_ID('tempdb..#Cmp')     IS NOT NULL DROP TABLE #Cmp;
    IF OBJECT_ID('tempdb..#Months')  IS NOT NULL DROP TABLE #Months;
    IF OBJECT_ID('tempdb..#Backlog') IS NOT NULL DROP TABLE #Backlog;

    RAISERROR(N'[Done] usp_GetBeechTree_ThreePillarLisDiagnostic', 0, 1) WITH NOWAIT;
END
GO

PRINT 'usp_GetBeechTree_ThreePillarLisDiagnostic created.';
GO
