/*
    Elixir Production Summary - Weekly Summary

    Root cause:
      The deployed procedures anchor the four Wednesday-Tuesday weeks to
      GETDATE(). When the newest FirstBilledDate is older than the current
      week, an empty future week replaces the oldest week containing data.

    Fix:
      Anchor the window to MAX(FirstBilledDate):
        latest data week + three preceding Wednesday-Tuesday weeks.

    No application deployment is required.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF DB_NAME() <> N'Elixir_LRN'
    THROW 53000, 'Run this script against the Elixir_LRN database.', 1;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshElix_WeeklyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @MaxFirstBilledDate DATE =
    (
        SELECT MAX(TRY_CAST(FirstBilledDate AS DATE))
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
    );

    IF @MaxFirstBilledDate IS NULL
    BEGIN
        TRUNCATE TABLE dbo.Elix_WeeklyBilledProductionSummary;
        RETURN;
    END;

    -- Wednesday-Tuesday week; 1900-01-03 is a known Wednesday.
    DECLARE @LatestWeekWedStart DATE =
        DATEADD(
            DAY,
            -(DATEDIFF(DAY, '19000103', @MaxFirstBilledDate) % 7),
            @MaxFirstBilledDate
        );

    CREATE TABLE #Weeks
    (
        WeekIndex INT NOT NULL PRIMARY KEY,
        WeekStart DATE NOT NULL,
        WeekEnd   DATE NOT NULL,
        WeekLabel NVARCHAR(32) NOT NULL
    );

    DECLARE @i INT = 0;
    WHILE @i < 4
    BEGIN
        DECLARE @WeekStart DATE = DATEADD(WEEK, -@i, @LatestWeekWedStart);
        DECLARE @WeekEnd DATE = DATEADD(DAY, 6, @WeekStart);

        INSERT INTO #Weeks (WeekIndex, WeekStart, WeekEnd, WeekLabel)
        VALUES
        (
            @i,
            @WeekStart,
            @WeekEnd,
            CONVERT(CHAR(10), @WeekStart, 23) + ' - ' + CONVERT(CHAR(10), @WeekEnd, 23)
        );

        SET @i += 1;
    END;

    SELECT
        LTRIM(RTRIM(ISNULL(cl.Panelname, 'Unknown'))) AS PanelName,
        LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown'))) AS PayerName,
        w.WeekStart,
        w.WeekEnd,
        w.WeekLabel,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(cl.ClaimID)), '')) AS ClaimCount,
        ISNULL(SUM(TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    INTO #Raw
    FROM #Weeks w
    INNER JOIN dbo.ClaimLevelData cl
        ON TRY_CAST(cl.FirstBilledDate AS DATE) BETWEEN w.WeekStart AND w.WeekEnd
    WHERE NULLIF(LTRIM(RTRIM(cl.FirstBilledDate)), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(cl.Panelname, 'Unknown'))),
        LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown'))),
        w.WeekStart,
        w.WeekEnd,
        w.WeekLabel;

    SELECT
        PanelName,
        PayerName,
        DENSE_RANK() OVER
        (
            PARTITION BY PanelName
            ORDER BY SUM(ClaimCount) DESC
        ) AS PayerRank
    INTO #Ranks
    FROM #Raw
    GROUP BY PanelName, PayerName;

    TRUNCATE TABLE dbo.Elix_WeeklyBilledProductionSummary;

    INSERT INTO dbo.Elix_WeeklyBilledProductionSummary
    (
        PanelType,
        PayerName,
        PayerRank,
        WeekStart,
        WeekEnd,
        WeekLabel,
        ClaimCount,
        TotalCharges,
        RefreshedAt
    )
    SELECT
        r.PanelName,
        r.PayerName,
        CAST(k.PayerRank AS TINYINT),
        r.WeekStart,
        r.WeekEnd,
        r.WeekLabel,
        r.ClaimCount,
        r.TotalCharges,
        GETDATE()
    FROM #Raw r
    INNER JOIN #Ranks k
        ON k.PanelName = r.PanelName
        AND k.PayerName = r.PayerName;

    DROP TABLE IF EXISTS #Ranks;
    DROP TABLE IF EXISTS #Raw;
    DROP TABLE IF EXISTS #Weeks;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetElix_WeeklyBilledProductionSummary
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
            WHEN @DosFrom IS NOT NULL OR @DosTo IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT
            PanelType AS PanelName,
            PayerName,
            PayerRank,
            WeekStart,
            WeekEnd,
            WeekLabel,
            ClaimCount,
            TotalCharges
        FROM dbo.Elix_WeeklyBilledProductionSummary
        ORDER BY WeekStart, PanelName, PayerRank;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT =
        CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT =
        CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    DECLARE @MaxFirstBilledDate DATE;

    SELECT @MaxFirstBilledDate = MAX(TRY_CAST(cl.FirstBilledDate AS DATE))
    FROM dbo.ClaimLevelData cl
    WHERE TRY_CAST(cl.FirstBilledDate AS DATE) IS NOT NULL
      AND (@HasPayerFilter = 0
           OR LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0
           OR LTRIM(RTRIM(ISNULL(cl.Panelname, 'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom IS NULL OR TRY_CAST(cl.DateOfService AS DATE) >= @DosFrom)
      AND (@DosTo IS NULL OR TRY_CAST(cl.DateOfService AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(cl.FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo IS NULL OR TRY_CAST(cl.FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(cl.FirstBilledDate AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo IS NULL OR TRY_CAST(cl.FirstBilledDate AS DATE) <= @FirstBilledTo);

    IF @MaxFirstBilledDate IS NULL
    BEGIN
        SELECT
            CAST(NULL AS NVARCHAR(500)) AS PanelName,
            CAST(NULL AS NVARCHAR(500)) AS PayerName,
            CAST(NULL AS TINYINT) AS PayerRank,
            CAST(NULL AS DATE) AS WeekStart,
            CAST(NULL AS DATE) AS WeekEnd,
            CAST(NULL AS NVARCHAR(32)) AS WeekLabel,
            CAST(NULL AS INT) AS ClaimCount,
            CAST(NULL AS DECIMAL(18,2)) AS TotalCharges
        WHERE 1 = 0;
        RETURN;
    END;

    DECLARE @LatestWeekWedStart DATE =
        DATEADD(
            DAY,
            -(DATEDIFF(DAY, '19000103', @MaxFirstBilledDate) % 7),
            @MaxFirstBilledDate
        );

    DECLARE @Weeks TABLE
    (
        WeekIndex INT NOT NULL PRIMARY KEY,
        WeekStart DATE NOT NULL,
        WeekEnd   DATE NOT NULL,
        WeekLabel NVARCHAR(32) NOT NULL
    );

    DECLARE @i INT = 0;
    WHILE @i < 4
    BEGIN
        DECLARE @WeekStart DATE = DATEADD(WEEK, -@i, @LatestWeekWedStart);
        DECLARE @WeekEnd DATE = DATEADD(DAY, 6, @WeekStart);

        INSERT INTO @Weeks (WeekIndex, WeekStart, WeekEnd, WeekLabel)
        VALUES
        (
            @i,
            @WeekStart,
            @WeekEnd,
            CONVERT(CHAR(10), @WeekStart, 23) + ' - ' + CONVERT(CHAR(10), @WeekEnd, 23)
        );

        SET @i += 1;
    END;

    ;WITH Agg AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(cl.Panelname, 'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown'))) AS PayerName,
            w.WeekStart,
            w.WeekEnd,
            w.WeekLabel,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(cl.ClaimID)), '')) AS ClaimCount,
            ISNULL(SUM(TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
        FROM dbo.ClaimLevelData cl
        INNER JOIN @Weeks w
            ON TRY_CAST(cl.FirstBilledDate AS DATE) BETWEEN w.WeekStart AND w.WeekEnd
        WHERE TRY_CAST(cl.FirstBilledDate AS DATE) IS NOT NULL
          AND (@HasPayerFilter = 0
               OR LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0
               OR LTRIM(RTRIM(ISNULL(cl.Panelname, 'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom IS NULL OR TRY_CAST(cl.DateOfService AS DATE) >= @DosFrom)
          AND (@DosTo IS NULL OR TRY_CAST(cl.DateOfService AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(cl.FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo IS NULL OR TRY_CAST(cl.FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@FirstBilledFrom IS NULL OR TRY_CAST(cl.FirstBilledDate AS DATE) >= @FirstBilledFrom)
          AND (@FirstBilledTo IS NULL OR TRY_CAST(cl.FirstBilledDate AS DATE) <= @FirstBilledTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(cl.Panelname, 'Unknown'))),
            LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown'))),
            w.WeekStart,
            w.WeekEnd,
            w.WeekLabel
    ),
    Ranks AS
    (
        SELECT
            PanelName,
            PayerName,
            DENSE_RANK() OVER
            (
                PARTITION BY PanelName
                ORDER BY SUM(ClaimCount) DESC
            ) AS PayerRank
        FROM Agg
        GROUP BY PanelName, PayerName
    ),
    PanelTotal AS
    (
        SELECT
            PanelName,
            WeekStart,
            WeekEnd,
            WeekLabel,
            SUM(ClaimCount) AS ClaimCount,
            SUM(TotalCharges) AS TotalCharges
        FROM Agg
        GROUP BY PanelName, WeekStart, WeekEnd, WeekLabel
    )
    SELECT
        PanelName,
        PayerName,
        PayerRank,
        WeekStart,
        WeekEnd,
        WeekLabel,
        ClaimCount,
        TotalCharges
    FROM
    (
        SELECT
            pt.PanelName,
            N'' AS PayerName,
            CAST(0 AS TINYINT) AS PayerRank,
            pt.WeekStart,
            pt.WeekEnd,
            pt.WeekLabel,
            pt.ClaimCount,
            pt.TotalCharges
        FROM PanelTotal pt

        UNION ALL

        SELECT
            a.PanelName,
            a.PayerName,
            CAST(r.PayerRank AS TINYINT),
            a.WeekStart,
            a.WeekEnd,
            a.WeekLabel,
            a.ClaimCount,
            a.TotalCharges
        FROM Agg a
        INNER JOIN Ranks r
            ON r.PanelName = a.PanelName
            AND r.PayerName = a.PayerName
    ) x
    ORDER BY WeekStart, PanelName, PayerRank;
END;
GO

-- Refresh the current snapshot immediately.
EXEC dbo.usp_RefreshElix_WeeklyBilledProductionSummary;
GO

IF (SELECT COUNT(DISTINCT WeekStart)
    FROM dbo.Elix_WeeklyBilledProductionSummary) <> 4
    THROW 53001, 'Weekly snapshot verification failed: expected exactly four weeks.', 1;
GO

-- Verification: exactly four data-anchored Wednesday-Tuesday weeks.
SELECT
    WeekStart,
    WeekEnd,
    SUM(ClaimCount) AS ClaimCount,
    SUM(TotalCharges) AS TotalCharges,
    MAX(RefreshedAt) AS RefreshedAt
FROM dbo.Elix_WeeklyBilledProductionSummary
GROUP BY WeekStart, WeekEnd
ORDER BY WeekStart;
GO
