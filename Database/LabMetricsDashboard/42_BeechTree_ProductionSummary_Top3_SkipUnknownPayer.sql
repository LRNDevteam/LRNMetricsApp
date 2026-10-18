/*
    42_BeechTree_ProductionSummary_Top3_SkipUnknownPayer.sql
    Database: BeechTree_LRN

    Production Summary (Monthly + Weekly) top-3 payer drill-down:
      - Blank / NULL / 'Unknown' payers are never shown as a top payer; the next
        highest real payer takes their place (display only).
      - Panel totals (PayerRank = 0 rows) include ALL payers, Unknown/blank included.
      - Filtered path no longer drops NULL/blank PayerName_Raw claims, so filtered
        totals include them too.

    Only the read SPs change (usp_GetBT_MonthlyBilledProductionSummary,
    usp_GetBT_WeeklyBilledProductionSummary). Snapshot tables and refresh SPs are untouched.
    No refresh is needed after deploy.
*/
SET NOCOUNT ON;
GO
-- ============================================================
-- Monthly Billed Production Summary
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetBT_MonthlyBilledProductionSummary
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom         IS NOT NULL OR @DosTo         IS NOT NULL THEN 1
            WHEN @FirstBillFrom   IS NOT NULL OR @FirstBillTo   IS NOT NULL THEN 1
            WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        ;WITH Snap AS (
            SELECT  PanelType AS PanelName,
                    COALESCE(NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unknown') AS PayerName,
                    BilledYearMonth, ClaimCount, TotalCharges
            FROM    dbo.BT_MonthlyBilledProductionSummary
        ),
        PanelTotal AS (
            SELECT  PanelName, BilledYearMonth, SUM(ClaimCount) AS ClaimCount, SUM(TotalCharges) AS TotalCharges
            FROM    Snap GROUP BY PanelName, BilledYearMonth
        ),
        Ranks AS (
            SELECT  PanelName, PayerName,
                    DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(ClaimCount) DESC) AS PayerRank
            FROM    Snap
            WHERE   PayerName <> N'Unknown'
            GROUP BY PanelName, PayerName
        )
        SELECT  PanelName, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
        FROM (
            SELECT  pt.PanelName, N'' AS PayerName, CAST(0 AS TINYINT) AS PayerRank,
                    pt.BilledYearMonth, pt.ClaimCount, pt.TotalCharges
            FROM    PanelTotal pt
            UNION ALL
            SELECT  s.PanelName, s.PayerName,
                    CAST(CASE WHEN r.PayerRank > 255 THEN 255 ELSE r.PayerRank END AS TINYINT) AS PayerRank,
                    s.BilledYearMonth, s.ClaimCount, s.TotalCharges
            FROM    Snap s JOIN Ranks r ON r.PanelName = s.PanelName AND r.PayerName = s.PayerName
        ) x
        ORDER BY PanelName, BilledYearMonth, PayerRank;
        RETURN;
    END

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH Agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname, 'Unknown')))                        AS Panelname,
            COALESCE(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), 'Unknown')      AS PayerName_Raw,
            FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')            AS BilledYearMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                 AS ClaimCount,
            ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)            AS TotalCharges
        FROM   dbo.ClaimLevelData
        WHERE  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
          AND  LTRIM(RTRIM(FirstBilledDate)) <> ''
          AND  TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
          AND  (@HasPayerFilter   = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND  (@HasPanelFilter   = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService    AS DATE) >= @DosFrom)
          AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService    AS DATE) <= @DosTo)
          AND  (@FirstBillFrom    IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBillFrom)
          AND  (@FirstBillTo      IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBillTo)
          AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBilledFrom)
          AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBilledTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(Panelname, 'Unknown'))),
            COALESCE(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), 'Unknown'),
            FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
    ),
    Ranks AS (
        SELECT  Panelname, PayerName_Raw,
                DENSE_RANK() OVER (PARTITION BY Panelname ORDER BY SUM(ClaimCount) DESC) AS PayerRank
        FROM    Agg
        WHERE   PayerName_Raw <> 'Unknown'
        GROUP BY Panelname, PayerName_Raw
    ),
    PanelTotal AS (
        SELECT  Panelname, BilledYearMonth, SUM(ClaimCount) AS ClaimCount, SUM(TotalCharges) AS TotalCharges
        FROM    Agg GROUP BY Panelname, BilledYearMonth
    )
    SELECT  PanelName, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
    FROM (
        SELECT  pt.Panelname AS PanelName, N'' AS PayerName, CAST(0 AS TINYINT) AS PayerRank,
                pt.BilledYearMonth, pt.ClaimCount, pt.TotalCharges
        FROM    PanelTotal pt
        UNION ALL
        SELECT  a.Panelname AS PanelName, a.PayerName_Raw AS PayerName,
                CAST(CASE WHEN r.PayerRank > 255 THEN 255 ELSE r.PayerRank END AS TINYINT) AS PayerRank,
                a.BilledYearMonth, a.ClaimCount, a.TotalCharges
        FROM    Agg a JOIN Ranks r ON r.Panelname = a.Panelname AND r.PayerName_Raw = a.PayerName_Raw
    ) x
    ORDER BY PanelName, BilledYearMonth, PayerRank;
END
GO
-- ============================================================
-- Weekly Billed Production Summary (last 4 complete Thu-Wed weeks)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetBT_WeeklyBilledProductionSummary
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom         IS NOT NULL OR @DosTo         IS NOT NULL THEN 1
            WHEN @FirstBillFrom   IS NOT NULL OR @FirstBillTo   IS NOT NULL THEN 1
            WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        ;WITH Snap AS (
            SELECT  PanelType AS PanelName,
                    COALESCE(NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unknown') AS PayerName,
                    WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges
            FROM    dbo.BT_WeeklyBilledProductionSummary
        ),
        PanelTotal AS (
            SELECT  PanelName, WeekStart, WeekEnd, WeekLabel, SUM(ClaimCount) AS ClaimCount, SUM(TotalCharges) AS TotalCharges
            FROM    Snap GROUP BY PanelName, WeekStart, WeekEnd, WeekLabel
        ),
        Ranks AS (
            SELECT  PanelName, PayerName,
                    DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(ClaimCount) DESC) AS PayerRank
            FROM    Snap
            WHERE   PayerName <> N'Unknown'
            GROUP BY PanelName, PayerName
        )
        SELECT  PanelName, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges
        FROM (
            SELECT  pt.PanelName, N'' AS PayerName, CAST(0 AS TINYINT) AS PayerRank,
                    pt.WeekStart, pt.WeekEnd, pt.WeekLabel, pt.ClaimCount, pt.TotalCharges
            FROM    PanelTotal pt
            UNION ALL
            SELECT  s.PanelName, s.PayerName,
                    CAST(CASE WHEN r.PayerRank > 255 THEN 255 ELSE r.PayerRank END AS TINYINT) AS PayerRank,
                    s.WeekStart, s.WeekEnd, s.WeekLabel, s.ClaimCount, s.TotalCharges
            FROM    Snap s JOIN Ranks r ON r.PanelName = s.PanelName AND r.PayerName = s.PayerName
        ) x
        ORDER BY WeekStart ASC, PanelName, PayerRank;
        RETURN;
    END

    DECLARE @Today            DATE = CAST(GETDATE() AS DATE);
    DECLARE @ThisWeekThuStart DATE = DATEADD(day, -(DATEDIFF(day, '1900-01-04', @Today) % 7), @Today);

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    DECLARE @Weeks TABLE (WeekIndex INT NOT NULL PRIMARY KEY, WeekStart DATE NOT NULL, WeekEnd DATE NOT NULL, WeekLabel NVARCHAR(32) NOT NULL);
    DECLARE @i INT = 1;
    WHILE @i <= 4
    BEGIN
        DECLARE @ws DATE = DATEADD(week, -@i, @ThisWeekThuStart);
        DECLARE @we DATE = DATEADD(day, 6, @ws);
        INSERT INTO @Weeks (WeekIndex, WeekStart, WeekEnd, WeekLabel)
        VALUES (@i, @ws, @we, FORMAT(@ws, 'yyyy-MM-dd') + ' - ' + FORMAT(@we, 'yyyy-MM-dd'));
        SET @i += 1;
    END

    ;WITH Agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(cl.Panelname, 'Unknown')))                     AS Panelname,
            COALESCE(NULLIF(LTRIM(RTRIM(cl.PayerName_Raw)), ''), 'Unknown')   AS PayerName_Raw,
            w.WeekStart, w.WeekEnd, w.WeekLabel,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(cl.ClaimID)), ''))              AS ClaimCount,
            ISNULL(SUM(TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2))),0)         AS TotalCharges
        FROM   dbo.ClaimLevelData cl
        JOIN   @Weeks w ON TRY_CAST(cl.ChargeEnteredDate AS DATE) BETWEEN w.WeekStart AND w.WeekEnd
        WHERE  TRY_CAST(cl.FirstBilledDate AS DATE) IS NOT NULL
          AND  LTRIM(RTRIM(cl.FirstBilledDate)) <> ''
          AND  (@HasPayerFilter   = 0 OR LTRIM(RTRIM(cl.PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND  (@HasPanelFilter   = 0 OR LTRIM(RTRIM(ISNULL(cl.Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND  (@DosFrom          IS NULL OR TRY_CAST(cl.DateOfService    AS DATE) >= @DosFrom)
          AND  (@DosTo            IS NULL OR TRY_CAST(cl.DateOfService    AS DATE) <= @DosTo)
          AND  (@FirstBillFrom    IS NULL OR TRY_CAST(cl.FirstBilledDate  AS DATE) >= @FirstBillFrom)
          AND  (@FirstBillTo      IS NULL OR TRY_CAST(cl.FirstBilledDate  AS DATE) <= @FirstBillTo)
          AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(cl.FirstBilledDate  AS DATE) >= @FirstBilledFrom)
          AND  (@FirstBilledTo    IS NULL OR TRY_CAST(cl.FirstBilledDate  AS DATE) <= @FirstBilledTo)
        GROUP BY LTRIM(RTRIM(ISNULL(cl.Panelname,'Unknown'))),
                 COALESCE(NULLIF(LTRIM(RTRIM(cl.PayerName_Raw)), ''), 'Unknown'),
                 w.WeekStart, w.WeekEnd, w.WeekLabel
    ),
    Ranks AS (
        SELECT  Panelname, PayerName_Raw,
                DENSE_RANK() OVER (PARTITION BY Panelname ORDER BY SUM(ClaimCount) DESC) AS PayerRank
        FROM    Agg
        WHERE   PayerName_Raw <> 'Unknown'
        GROUP BY Panelname, PayerName_Raw
    ),
    PanelTotal AS (
        SELECT  Panelname, WeekStart, WeekEnd, WeekLabel, SUM(ClaimCount) AS ClaimCount, SUM(TotalCharges) AS TotalCharges
        FROM    Agg GROUP BY Panelname, WeekStart, WeekEnd, WeekLabel
    )
    SELECT  PanelName, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges
    FROM (
        SELECT  pt.Panelname AS PanelName, N'' AS PayerName, CAST(0 AS TINYINT) AS PayerRank,
                pt.WeekStart, pt.WeekEnd, pt.WeekLabel, pt.ClaimCount, pt.TotalCharges
        FROM    PanelTotal pt
        UNION ALL
        SELECT  a.Panelname AS PanelName, a.PayerName_Raw AS PayerName,
                CAST(CASE WHEN r.PayerRank > 255 THEN 255 ELSE r.PayerRank END AS TINYINT) AS PayerRank,
                a.WeekStart, a.WeekEnd, a.WeekLabel, a.ClaimCount, a.TotalCharges
        FROM    Agg a JOIN Ranks r ON r.Panelname = a.Panelname AND r.PayerName_Raw = a.PayerName_Raw
    ) x
    ORDER BY WeekStart ASC, PanelName, PayerRank;
END
GO
PRINT '42_BeechTree_ProductionSummary_Top3_SkipUnknownPayer.sql completed.';
GO
