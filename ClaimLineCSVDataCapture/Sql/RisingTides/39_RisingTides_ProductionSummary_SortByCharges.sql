/*
    Rising Tides Production Summary - Monthly / Weekly sorted by Total Charge amount (2026-10-06)

    PayerRank (top payers per panel) was DENSE_RANK by SUM(ClaimCount).
    It is now DENSE_RANK by SUM(TotalCharges) DESC, with SUM(ClaimCount) DESC as the tie-break.

    Weekly: the filtered read path used Thu–Wed weeks counted from today, while the stored
    (no-filter) path uses Fri–Thu weeks counted from the latest ChargeEnteredDate. Both now
    use the Fri–Thu weeks (e.g. 09/25/2026 - 10/01/2026), so filtered and unfiltered match.

    This script re-creates, from the deployed versions, with only the ranking changed:
      1. dbo.usp_RefreshRT_MonthlyBilledProductionSummary  - stored rows (no filter)
      2. dbo.usp_RefreshRT_WeeklyBilledProductionSummary   - stored rows (no filter)
      3. dbo.usp_GetRT_MonthlyBilledProductionSummary      - read SP (live rows with filters)
      4. dbo.usp_GetRT_WeeklyBilledProductionSummary       - read SP (live rows with filters)
    then rebuilds both stored tables.

    The dashboard (SqlLabProductionSummaryRepository, LabSummaryTableConfig.RisingTides
    SortByCharges = true) orders the panels and the top 3 payers by Total Charges as well.
    Rising Tides database only. Safe to run again.
*/
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_MonthlyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))                   AS Panelname,
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                   AS PayerName_Raw,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')           AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)          AS TotalCharges
    INTO #BilledRaw
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL  AND LTRIM(RTRIM(FirstBilledDate)) != ''
    GROUP BY
        LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))),
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

    SELECT
        Panelname,
        PayerName_Raw,
        DENSE_RANK() OVER (
            PARTITION BY Panelname
            ORDER BY SUM(TotalCharges) DESC, SUM(ClaimCount) DESC
        ) AS PayerRank
    INTO #PayerRanks
    FROM #BilledRaw
    GROUP BY Panelname, PayerName_Raw;

    SELECT
        b.Panelname, b.PayerName_Raw, CAST(r.PayerRank AS TINYINT) AS PayerRank,
        b.BilledYearMonth, b.ClaimCount, b.TotalCharges
    INTO #Top3
    FROM #BilledRaw b
    JOIN #PayerRanks r ON r.Panelname = b.Panelname AND r.PayerName_Raw = b.PayerName_Raw;
   -- WHERE r.PayerRank <= 3;

    TRUNCATE TABLE dbo.RT_MonthlyBilledProductionSummary;

    INSERT INTO dbo.RT_MonthlyBilledProductionSummary
        (PanelType, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, PayerName_Raw, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #Top3
    ORDER BY Panelname, PayerRank, BilledYearMonth;

    DROP TABLE IF EXISTS #BilledRaw;
    DROP TABLE IF EXISTS #PayerRanks;
    DROP TABLE IF EXISTS #Top3;

    PRINT 'usp_RefreshRT_MonthlyBilledProductionSummary completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_WeeklyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today            DATE = CAST(GETDATE() AS DATE);
    DECLARE @ThisWeekFriStart DATE;
    DECLARE @DateFromData     DATE;

    -- Fri–Thu week anchor: 1900-01-05 is a known Friday
    SELECT 
        @DateFromData     = MAX(TRY_CAST(ChargeEnteredDate AS DATE)),
        @ThisWeekFriStart = DATEADD(day,
            -(DATEDIFF(day, '1900-01-05', ISNULL(MAX(TRY_CAST(ChargeEnteredDate AS DATE)), @Today)) % 7),
            ISNULL(MAX(TRY_CAST(ChargeEnteredDate AS DATE)), @Today))
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
      AND TRY_CAST(ChargeEnteredDate AS DATE) <= @Today;

    -- If max date >= Thursday of current week → current week is complete → start from 0
    -- Otherwise current week is incomplete → start from 1 (last complete week)
    DECLARE @StartIndex INT = CASE
        WHEN @DateFromData >= DATEADD(day, 6, @ThisWeekFriStart) THEN 0   -- current week complete (Thu)
        ELSE 1                                                             -- current week incomplete
    END;

    DECLARE @i INT = @StartIndex;
    CREATE TABLE #Weeks
    (
        WeekIndex INT PRIMARY KEY,
        WeekStart DATE,
        WeekEnd   DATE,
        WeekLabel NVARCHAR(32)
    );

    WHILE @i <= @StartIndex + 3   -- always 4 weeks
    BEGIN
        DECLARE @ws DATE = DATEADD(week, -@i, @ThisWeekFriStart);
        DECLARE @we DATE = DATEADD(day, 6, @ws);   -- Fri + 6 = Thu
        INSERT INTO #Weeks (WeekIndex, WeekStart, WeekEnd, WeekLabel)
        VALUES (@i, @ws, @we, FORMAT(@ws, 'yyyy-MM-dd') + ' - ' + FORMAT(@we, 'yyyy-MM-dd'));
        SET @i = @i + 1;
    END

    SELECT
        LTRIM(RTRIM(ISNULL(cl.Panelname,     'Unknown')))              AS Panelname,
        LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown')))              AS PayerName_Raw,
        w.WeekStart, w.WeekEnd, w.WeekLabel,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(cl.ClaimID)), ''))           AS ClaimCount,
        ISNULL(SUM(TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2))), 0)     AS TotalCharges
    INTO #BilledRaw
    FROM #Weeks w
    LEFT JOIN dbo.ClaimLevelData cl
           ON TRY_CAST(cl.ChargeEnteredDate AS DATE) BETWEEN w.WeekStart AND w.WeekEnd
          AND TRY_CAST(cl.FirstBilledDate   AS DATE) IS NOT NULL
          AND LTRIM(RTRIM(cl.FirstBilledDate)) <> ''
    GROUP BY
        LTRIM(RTRIM(ISNULL(cl.Panelname,     'Unknown'))),
        LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown'))),
        w.WeekStart, w.WeekEnd, w.WeekLabel;

    SELECT
        Panelname, PayerName_Raw,
        DENSE_RANK() OVER (PARTITION BY Panelname ORDER BY SUM(TotalCharges) DESC, SUM(ClaimCount) DESC) AS PayerRank
    INTO #PayerRanks
    FROM #BilledRaw GROUP BY Panelname, PayerName_Raw;

    SELECT
        b.Panelname, b.PayerName_Raw, CAST(r.PayerRank AS TINYINT) AS PayerRank,
        b.WeekStart, b.WeekEnd, b.WeekLabel, b.ClaimCount, b.TotalCharges
    INTO #Top3
    FROM #BilledRaw b
    JOIN #PayerRanks r ON r.Panelname = b.Panelname AND r.PayerName_Raw = b.PayerName_Raw;

    TRUNCATE TABLE dbo.RT_WeeklyBilledProductionSummary;

    DECLARE @RowsInserted INT;

    INSERT INTO dbo.RT_WeeklyBilledProductionSummary
        (PanelType, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel,
         ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, PayerName_Raw, PayerRank,
           WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges, GETDATE()
    FROM #Top3 ORDER BY Panelname, PayerRank, WeekStart DESC;

    SET @RowsInserted = @@ROWCOUNT;

    DROP TABLE IF EXISTS #BilledRaw;
    DROP TABLE IF EXISTS #PayerRanks;
    DROP TABLE IF EXISTS #Top3;
    DROP TABLE IF EXISTS #Weeks;

    PRINT 'usp_RefreshRT_WeeklyBilledProductionSummary completed — ' + CAST(@RowsInserted AS NVARCHAR(20)) + ' rows.';
END
GO

-- ============================================================
-- Monthly Billed Production Summary
-- Output: PanelName, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
--   PayerRank = 0  -> panel-level totals across ALL payers.
--   PayerRank 1..N -> per-payer drill-down rows ranked by Total Charges (caller keeps Top 3).
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetRT_MonthlyBilledProductionSummary
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
        SELECT  PanelType        AS PanelName,
                PayerName,
                PayerRank,
                BilledYearMonth,
                ClaimCount,
                TotalCharges
        FROM    dbo.RT_MonthlyBilledProductionSummary
        ORDER BY PanelName, BilledYearMonth, PayerRank;
        RETURN;
    END

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|')
        WHERE  NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE  NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH Agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))         AS Panelname,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))         AS PayerName_Raw,
            FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM') AS BilledYearMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))      AS ClaimCount,
            ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0) AS TotalCharges
        FROM   dbo.ClaimLevelData
        WHERE  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
          AND  LTRIM(RTRIM(FirstBilledDate)) <> ''
          AND  PayerName_Raw   IS NOT NULL
          AND  LTRIM(RTRIM(PayerName_Raw)) <> ''
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
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))),
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
    ),
    Ranks AS (
        SELECT  Panelname, PayerName_Raw,
                DENSE_RANK() OVER (PARTITION BY Panelname ORDER BY SUM(TotalCharges) DESC, SUM(ClaimCount) DESC) AS PayerRank
        FROM    Agg
        GROUP BY Panelname, PayerName_Raw
    ),
    PanelTotal AS (
        SELECT  Panelname, BilledYearMonth,
                SUM(ClaimCount)   AS ClaimCount,
                SUM(TotalCharges) AS TotalCharges
        FROM    Agg
        GROUP BY Panelname, BilledYearMonth
    )
    SELECT  PanelName, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
    FROM (
        SELECT  pt.Panelname           AS PanelName,
                N''                    AS PayerName,
                CAST(0 AS TINYINT)     AS PayerRank,
                pt.BilledYearMonth, pt.ClaimCount, pt.TotalCharges
        FROM    PanelTotal pt
        UNION ALL
        SELECT  a.Panelname            AS PanelName,
                a.PayerName_Raw        AS PayerName,
                CAST(r.PayerRank AS TINYINT) AS PayerRank,
                a.BilledYearMonth, a.ClaimCount, a.TotalCharges
        FROM    Agg   a
        JOIN    Ranks r ON r.Panelname = a.Panelname AND r.PayerName_Raw = a.PayerName_Raw
    ) x
    ORDER BY PanelName, BilledYearMonth, PayerRank;
END
GO

-- ============================================================
-- Weekly Billed Production Summary (last 4 complete Fri-Thu weeks)
--   PayerRank 1..N -> per-payer drill-down rows ranked by Total Charges.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetRT_WeeklyBilledProductionSummary
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
        SELECT  PanelType    AS PanelName,
                PayerName,
                PayerRank,
                WeekStart,
                WeekEnd,
                WeekLabel,
                ClaimCount,
                TotalCharges
        FROM    dbo.RT_WeeklyBilledProductionSummary
        ORDER BY WeekStart ASC, PanelName, PayerRank;
        RETURN;
    END

    -- Same weeks as usp_RefreshRT_WeeklyBilledProductionSummary (no-filter path):
    -- Fri–Thu weeks (1900-01-05 is a Friday), last 4 complete weeks counted from the
    -- latest ChargeEnteredDate in the data; the current week counts once it reaches Thursday.
    DECLARE @Today            DATE = CAST(GETDATE() AS DATE);
    DECLARE @ThisWeekFriStart DATE;
    DECLARE @DateFromData     DATE;

    SELECT
        @DateFromData     = MAX(TRY_CAST(ChargeEnteredDate AS DATE)),
        @ThisWeekFriStart = DATEADD(day,
            -(DATEDIFF(day, '1900-01-05', ISNULL(MAX(TRY_CAST(ChargeEnteredDate AS DATE)), @Today)) % 7),
            ISNULL(MAX(TRY_CAST(ChargeEnteredDate AS DATE)), @Today))
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
      AND TRY_CAST(ChargeEnteredDate AS DATE) <= @Today;

    DECLARE @StartIndex INT = CASE
        WHEN @DateFromData >= DATEADD(day, 6, @ThisWeekFriStart) THEN 0
        ELSE 1
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|')
        WHERE  NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE  NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    DECLARE @Weeks TABLE
    (
        WeekIndex INT          NOT NULL PRIMARY KEY,
        WeekStart DATE         NOT NULL,
        WeekEnd   DATE         NOT NULL,
        WeekLabel NVARCHAR(32) NOT NULL
    );

    DECLARE @i INT = @StartIndex;
    WHILE @i <= @StartIndex + 3
    BEGIN
        DECLARE @ws DATE = DATEADD(week, -@i, @ThisWeekFriStart);
        DECLARE @we DATE = DATEADD(day, 6, @ws);   -- Fri + 6 = Thu
        INSERT INTO @Weeks (WeekIndex, WeekStart, WeekEnd, WeekLabel)
        VALUES (@i, @ws, @we, FORMAT(@ws, 'yyyy-MM-dd') + ' - ' + FORMAT(@we, 'yyyy-MM-dd'));
        SET @i += 1;
    END

    ;WITH Agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(cl.Panelname,     'Unknown')))      AS Panelname,
            LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown')))      AS PayerName_Raw,
            w.WeekStart, w.WeekEnd, w.WeekLabel,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(cl.ClaimID)), ''))   AS ClaimCount,
            ISNULL(SUM(TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2))),0) AS TotalCharges
        FROM    dbo.ClaimLevelData cl
        JOIN    @Weeks w
                  ON TRY_CAST(cl.ChargeEnteredDate AS DATE) BETWEEN w.WeekStart AND w.WeekEnd
        WHERE   TRY_CAST(cl.FirstBilledDate AS DATE) IS NOT NULL
          AND   LTRIM(RTRIM(cl.FirstBilledDate)) <> ''
          AND   cl.PayerName_Raw IS NOT NULL
          AND   LTRIM(RTRIM(cl.PayerName_Raw)) <> ''
          AND   (@HasPayerFilter   = 0 OR LTRIM(RTRIM(cl.PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND   (@HasPanelFilter   = 0 OR LTRIM(RTRIM(ISNULL(cl.Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND   (@DosFrom          IS NULL OR TRY_CAST(cl.DateOfService    AS DATE) >= @DosFrom)
          AND   (@DosTo            IS NULL OR TRY_CAST(cl.DateOfService    AS DATE) <= @DosTo)
          AND   (@FirstBillFrom    IS NULL OR TRY_CAST(cl.FirstBilledDate  AS DATE) >= @FirstBillFrom)
          AND   (@FirstBillTo      IS NULL OR TRY_CAST(cl.FirstBilledDate  AS DATE) <= @FirstBillTo)
          AND   (@FirstBilledFrom  IS NULL OR TRY_CAST(cl.FirstBilledDate  AS DATE) >= @FirstBilledFrom)
          AND   (@FirstBilledTo    IS NULL OR TRY_CAST(cl.FirstBilledDate  AS DATE) <= @FirstBilledTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(cl.Panelname,     'Unknown'))),
            LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown'))),
            w.WeekStart, w.WeekEnd, w.WeekLabel
    ),
    Ranks AS (
        SELECT  Panelname, PayerName_Raw,
                DENSE_RANK() OVER (PARTITION BY Panelname ORDER BY SUM(TotalCharges) DESC, SUM(ClaimCount) DESC) AS PayerRank
        FROM    Agg
        GROUP BY Panelname, PayerName_Raw
    ),
    PanelTotal AS (
        SELECT  Panelname, WeekStart, WeekEnd, WeekLabel,
                SUM(ClaimCount)   AS ClaimCount,
                SUM(TotalCharges) AS TotalCharges
        FROM    Agg
        GROUP BY Panelname, WeekStart, WeekEnd, WeekLabel
    )
    SELECT  PanelName, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges
    FROM (
        SELECT  pt.Panelname        AS PanelName,
                N''                 AS PayerName,
                CAST(0 AS TINYINT)  AS PayerRank,
                pt.WeekStart, pt.WeekEnd, pt.WeekLabel,
                pt.ClaimCount, pt.TotalCharges
        FROM    PanelTotal pt
        UNION ALL
        SELECT  a.Panelname         AS PanelName,
                a.PayerName_Raw     AS PayerName,
                CAST(r.PayerRank AS TINYINT) AS PayerRank,
                a.WeekStart, a.WeekEnd, a.WeekLabel,
                a.ClaimCount, a.TotalCharges
        FROM    Agg   a
        JOIN    Ranks r ON r.Panelname = a.Panelname AND r.PayerName_Raw = a.PayerName_Raw
    ) x
    ORDER BY WeekStart ASC, PanelName, PayerRank;
END
GO

-- Rebuild the stored tables with the new ranking.
EXEC dbo.usp_RefreshRT_MonthlyBilledProductionSummary;
GO
EXEC dbo.usp_RefreshRT_WeeklyBilledProductionSummary;
GO

-- Check: top 3 payers per panel by charges (monthly stored table)
SELECT PanelType, PayerRank, PayerName, SUM(TotalCharges) AS TotalCharges, SUM(ClaimCount) AS ClaimCount
FROM dbo.RT_MonthlyBilledProductionSummary
WHERE PayerRank BETWEEN 1 AND 3
GROUP BY PanelType, PayerRank, PayerName
ORDER BY PanelType, PayerRank;
GO
