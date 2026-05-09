-- PCRLabsofAmerica — Weekly Claim Production Billed Summary
-- Rule:
--   Filter  : TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--   Rows    : Panelname  x  Top 3 Payer (by COUNT(DISTINCT ClaimID), per Panelname)
--   Columns : ChargeEnteredDate week range Thu–Wed, last 4 complete weeks
--             | COUNT(DISTINCT ClaimID) | SUM(ChargeAmount)
--   Note    : PCRLabsofAmerica week runs Thursday through Wednesday.
--             Reference Thursday anchor: 1900-01-04.
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1: Aggregate table
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PCR_WeeklyBilledProductionSummary')
CREATE TABLE dbo.PCR_WeeklyBilledProductionSummary
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelType    NVARCHAR(MAX)   NOT NULL,   -- stores Panelname value
    PayerName    NVARCHAR(500)   NOT NULL,
    PayerRank    TINYINT         NOT NULL,   -- 1 / 2 / 3 within the Panelname
    WeekStart    DATE            NOT NULL,   -- Thursday
    WeekEnd      DATE            NOT NULL,   -- Wednesday
    WeekLabel    NVARCHAR(32)    NOT NULL,   -- 'yyyy-MM-dd - yyyy-MM-dd'
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2: Stored procedure
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_WeeklyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    -- Week boundary: Thu–Wed.
    -- Reference Thursday anchor: 1900-01-04 (a known Thursday).
    -- DATEDIFF(day, '1900-01-04', @Today) % 7 ? 0=Thu, 1=Fri, …, 6=Wed.
    DECLARE @Today            DATE = CAST(GETDATE() AS DATE);
    DECLARE @ThisWeekThuStart DATE = DATEADD(day, -(DATEDIFF(day, '1900-01-04', @Today) % 7), @Today);

    -- Build last 4 complete Thu–Wed weeks (index 1 = most recent complete week).
    DECLARE @i INT = 1;
    CREATE TABLE #Weeks
    (
        WeekIndex INT PRIMARY KEY,
        WeekStart DATE,
        WeekEnd   DATE,
        WeekLabel NVARCHAR(32)
    );

    WHILE @i <= 4
    BEGIN
        DECLARE @ws DATE = DATEADD(week, -@i, @ThisWeekThuStart);
        DECLARE @we DATE = DATEADD(day, 6, @ws);   -- Thu + 6 = Wed
        INSERT INTO #Weeks (WeekIndex, WeekStart, WeekEnd, WeekLabel)
        VALUES (@i, @ws, @we, FORMAT(@ws, 'yyyy-MM-dd') + ' - ' + FORMAT(@we, 'yyyy-MM-dd'));
        SET @i = @i + 1;
    END

    -- Aggregate by Panelname x PayerName_Raw x week, joined on ChargeEnteredDate.
    -- Drive the join from #Weeks (LEFT JOIN) so every one of the 4 weeks always
    -- produces at least one row in the snapshot table - even when the lab had
    -- zero billed claims that week. Empty weeks land as a single placeholder row
    -- (Panelname = PayerName_Raw = 'Unknown', ClaimCount = 0, TotalCharges = 0)
    -- so dbo.PCR_WeeklyBilledProductionSummary always has 4 distinct WeekStart
    -- values for the dashboard to render.
    SELECT
        LTRIM(RTRIM(ISNULL(cl.Panelname,     'Unknown')))              AS Panelname,
        LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown')))              AS PayerName_Raw,
        w.WeekStart,
        w.WeekEnd,
        w.WeekLabel,
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

    -- Rank payers within each Panelname (Top 3) across the 4-week window.
    SELECT
        Panelname,
        PayerName_Raw,
        DENSE_RANK() OVER (PARTITION BY Panelname ORDER BY SUM(ClaimCount) DESC) AS PayerRank
    INTO #PayerRanks
    FROM #BilledRaw
    GROUP BY Panelname, PayerName_Raw;

    SELECT
        b.Panelname,
        b.PayerName_Raw,
        CAST(r.PayerRank AS TINYINT) AS PayerRank,
        b.WeekStart, b.WeekEnd, b.WeekLabel,
        b.ClaimCount, b.TotalCharges
    INTO #Top3
    FROM #BilledRaw b
    JOIN #PayerRanks r ON r.Panelname = b.Panelname AND r.PayerName_Raw = b.PayerName_Raw;
   -- WHERE r.PayerRank <= 3;

    TRUNCATE TABLE dbo.PCR_WeeklyBilledProductionSummary;

    INSERT INTO dbo.PCR_WeeklyBilledProductionSummary
        (PanelType, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel,
         ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, PayerName_Raw, PayerRank,
           WeekStart, WeekEnd, WeekLabel,
           ClaimCount, TotalCharges, GETDATE()
    FROM #Top3
    ORDER BY Panelname, PayerRank, WeekStart DESC;

    DECLARE @RowsInserted INT = @@ROWCOUNT;

    DROP TABLE IF EXISTS #BilledRaw;
    DROP TABLE IF EXISTS #PayerRanks;
    DROP TABLE IF EXISTS #Top3;
    DROP TABLE IF EXISTS #Weeks;

    PRINT 'usp_RefreshPCR_WeeklyBilledProductionSummary completed — ' + CAST(@RowsInserted AS NVARCHAR(20)) + ' rows.';
END
GO

-- ============================================================
-- Step 3: Read stored procedure
-- Called by LabMetricsDashboard.SqlLabProductionSummaryRepository.
--
-- Two execution paths controlled by the input parameters:
--   1) NO filter parameters supplied  -> return rows from the pre-aggregated
--      dbo.PCR_WeeklyBilledProductionSummary table (fast path).
--   2) ANY filter parameter supplied  -> aggregate live from dbo.ClaimLevelData
--      for the last 4 complete Thu-Wed weeks (matching the Refresh SP's window),
--      using the same legacy filter semantics that the C# inline live query
--      used to apply (FirstBilledDate not blank, PayerName_Raw not blank,
--      Top-3 payer drill-down per Panelname by COUNT(DISTINCT ClaimID)).
--
-- Output schema (identical for both paths):
--   PanelName, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel,
--   ClaimCount, TotalCharges
--   PayerRank = 0  -> panel-level totals across ALL payers (panel row).
--   PayerRank 1..N -> per-payer drill-down rows (caller keeps Top 3).
--
-- List parameters use '|' as the delimiter so payer/panel names that contain
-- commas are passed safely.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_WeeklyBilledProductionSummary
    @PayerNames      NVARCHAR(MAX) = NULL,   -- '|'-separated list, NULL/empty = no filter
    @PanelNames      NVARCHAR(MAX) = NULL,   -- '|'-separated list, NULL/empty = no filter
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
        -- Fast path: pre-aggregated snapshot table.
        SELECT  PanelType    AS PanelName,
                PayerName,
                PayerRank,
                WeekStart,
                WeekEnd,
                WeekLabel,
                ClaimCount,
                TotalCharges
        FROM    dbo.PCR_WeeklyBilledProductionSummary
        ORDER BY WeekStart ASC, PanelName, PayerRank;
        RETURN;
    END

    -- Filtered path: aggregate live from ClaimLevelData over the last
    -- 4 complete Thu-Wed weeks (Reference Thursday anchor: 1900-01-04).
    DECLARE @Today            DATE = CAST(GETDATE() AS DATE);
    DECLARE @ThisWeekThuStart DATE = DATEADD(day, -(DATEDIFF(day, '1900-01-04', @Today) % 7), @Today);

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM   STRING_SPLIT(@PayerNames, '|')
        WHERE  NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM   STRING_SPLIT(@PanelNames, '|')
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
            LTRIM(RTRIM(ISNULL(cl.Panelname,     'Unknown')))      AS Panelname,
            LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown')))      AS PayerName_Raw,
            w.WeekStart, w.WeekEnd, w.WeekLabel,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(cl.ClaimID)), ''))   AS ClaimCount,
            ISNULL(SUM(TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2))),0) AS TotalCharges
        FROM    dbo.ClaimLevelData cl
        JOIN    @Weeks w
                  ON TRY_CAST(cl.ChargeEnteredDate AS DATE) BETWEEN w.WeekStart AND w.WeekEnd
        WHERE   TRY_CAST(cl.FirstBilledDate AS DATE) IS NOT NULL
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
                DENSE_RANK() OVER (PARTITION BY Panelname ORDER BY SUM(ClaimCount) DESC) AS PayerRank
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
                pt.ClaimCount,
                pt.TotalCharges
        FROM    PanelTotal pt
        UNION ALL
        SELECT  a.Panelname         AS PanelName,
                a.PayerName_Raw     AS PayerName,
                CAST(r.PayerRank AS TINYINT) AS PayerRank,
                a.WeekStart, a.WeekEnd, a.WeekLabel,
                a.ClaimCount,
                a.TotalCharges
        FROM    Agg   a
        JOIN    Ranks r ON r.Panelname = a.Panelname AND r.PayerName_Raw = a.PayerName_Raw
    ) x
    ORDER BY WeekStart ASC, PanelName, PayerRank;
END
GO

/*
SELECT PanelType, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges
FROM dbo.PCR_WeeklyBilledProductionSummary
ORDER BY PanelType, PayerRank, WeekStart DESC;
*/

PRINT '07_PCRLabsofAmerica_WeeklyBilledProductionSummary.sql completed.';
