/* =============================================================================
   VariantX - Denial Summary (Denial Analysis Report)
   Database : VariantX_LRN        Prefix : VarX_

   Client sheet (Claim Level Data):
     Denied claim = ClaimLevelDenialCode not blank
                    AND InsuranceBalance > 0
                    AND (DenialDate is a date
                         OR [Weekly] DeniedWeek / DenialWeek not blank)
     Rows         = PayerName_Raw, each drilled to its Top 3 ClaimLevelDenialCode
                    by claim count
     Monthly cols = DenialDate month, a year total per year, Grand Total
     Weekly cols  = last four completed Thursday-Wednesday weeks ending at the
                    newest WeekFolder (e.g. 11.05.2026 - 11.11.2026). When no
                    DenialDate / DeniedWeek falls in that window the Weekly tab
                    is empty ("no Weekly data found for this week range").
                    Bucket: DeniedWeek "Week 1".."Week 4" when filled, else DenialDate
     Values       = No. of Claims = COUNT(DISTINCT ClaimID),
                    Insurance Balance = SUM(InsuranceBalance)
     Sort         = claim count
     No Denial List / Plan Type tabs on the VariantX sheet.

   The read SPs aggregate live, so there is no snapshot table. The refresh
   SPs exist so claim-file ingest can call them.

   Monthly / Weekly result contract (same columns the dashboard reads):
     RowType P insurance, C its top-3 denial code, T grand total
     PeriodType M month / W week / Y year total / A grand total
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'VariantX_LRN'
BEGIN
    RAISERROR('Run 30_VariantX_DenialSummary.sql on the VariantX_LRN database.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_VarX_DenialPeriod
    @Weekly      BIT,
    @PayerNames  NVARCHAR(MAX) = NULL,
    @PayerTypes  NVARCHAR(MAX) = NULL,
    @DenialCodes NVARCHAR(MAX) = NULL,
    @DenialFrom  DATE = NULL,
    @DenialTo    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- 1900-01-04 is a Thursday → week = Thursday through Wednesday.
    DECLARE @Thursday DATE = CONVERT(date, '19000104');
    DECLARE @Today    DATE = CAST(GETDATE() AS DATE);
    -- Newest completed Thu week-start (set on weekly path; used to map DeniedWeek 1..4).
    DECLARE @W4       DATE = NULL;

    -- Client sheet: ClaimLevelDenialCode not blank. DeniedWeek covers weekly when
    -- DenialDate is missing ("recent week date not available" → was showing 0).
    SELECT NULLIF(LTRIM(RTRIM(c.ClaimID)), N'')                              AS ClaimKey,
           CAST(LTRIM(RTRIM(ISNULL(c.PayerName_Raw, N''))) AS NVARCHAR(500)) AS PayerName,
           CAST(LTRIM(RTRIM(CONVERT(NVARCHAR(400), c.ClaimLevelDenialCode)))
                AS NVARCHAR(400))                                            AS DenialCode,
           TRY_CAST(c.DenialDate AS DATE)                                    AS DenialDate,
           CAST(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.DeniedWeek))), N'')
                AS NVARCHAR(100))                                            AS DeniedWeek,
           TRY_CONVERT(DATE,
               REPLACE(RIGHT(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.WeekFolder))), 10), '.', '/'),
               101)                                                          AS WeekFolderEnd,
           ISNULL(TRY_CAST(c.InsuranceBalance AS DECIMAL(18,2)), 0)          AS Bal
    INTO #C
    FROM dbo.ClaimLevelData c
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(400), c.ClaimLevelDenialCode))), N'') IS NOT NULL
      AND ISNULL(TRY_CAST(c.InsuranceBalance AS DECIMAL(18,2)), 0) > 0
      AND NULLIF(LTRIM(RTRIM(c.ClaimID)), N'') IS NOT NULL
      AND (
            -- Monthly: DenialDate must be a date
            (@Weekly = 0 AND TRY_CAST(c.DenialDate AS DATE) IS NOT NULL)
            -- Weekly: DenialDate is a date OR DeniedWeek / DenialWeek not blank
         OR (@Weekly = 1 AND (
                TRY_CAST(c.DenialDate AS DATE) IS NOT NULL
             OR NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.DeniedWeek))), N'') IS NOT NULL
            ))
          )
      AND (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR LTRIM(RTRIM(c.PayerName_Raw)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@DenialCodes)), N'') IS NULL
           OR LTRIM(RTRIM(CONVERT(NVARCHAR(400), c.ClaimLevelDenialCode)))
              IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DenialCodes, N'|')))
      AND (@DenialFrom IS NULL OR TRY_CAST(c.DenialDate AS DATE) >= @DenialFrom)
      AND (@DenialTo   IS NULL OR TRY_CAST(c.DenialDate AS DATE) <= @DenialTo);

    DECLARE @MaxDate DATE = (SELECT MAX(DenialDate) FROM #C);
    DECLARE @LoadedThrough DATE = (SELECT MAX(WeekFolderEnd) FROM #C);

    CREATE TABLE #P
    (
        PeriodType  CHAR(1)       NOT NULL,
        PeriodKey   NVARCHAR(20)  NOT NULL,
        PeriodYear  INT           NULL,
        PeriodStart DATE          NULL,
        PeriodEnd   DATE          NULL,
        PeriodLabel NVARCHAR(40)  NOT NULL,
        PeriodOrder INT           NOT NULL
    );

    IF @Weekly = 0
    BEGIN
        ;WITH Months AS
        (
            SELECT DATEFROMPARTS(YEAR(MIN(DenialDate)), MONTH(MIN(DenialDate)), 1) AS MonthStart,
                   DATEFROMPARTS(YEAR(MAX(DenialDate)), MONTH(MAX(DenialDate)), 1) AS MonthEnd
            FROM #C
            WHERE DenialDate IS NOT NULL
            UNION ALL
            SELECT DATEADD(MONTH, 1, MonthStart), MonthEnd
            FROM Months
            WHERE MonthStart < MonthEnd
        )
        INSERT INTO #P (PeriodType, PeriodKey, PeriodYear, PeriodStart, PeriodEnd, PeriodLabel, PeriodOrder)
        SELECT 'M', CONVERT(NVARCHAR(10), MonthStart, 23), YEAR(MonthStart), MonthStart, EOMONTH(MonthStart),
               LEFT(DATENAME(MONTH, MonthStart), 3),
               ROW_NUMBER() OVER (ORDER BY MonthStart)
        FROM Months
        OPTION (MAXRECURSION 400);

        INSERT INTO #P (PeriodType, PeriodKey, PeriodYear, PeriodStart, PeriodEnd, PeriodLabel, PeriodOrder)
        SELECT 'Y', N'total-' + CONVERT(NVARCHAR(4), PeriodYear), PeriodYear,
               MIN(PeriodStart), MAX(PeriodEnd),
               CONVERT(NVARCHAR(4), PeriodYear) + N' | Total',
               MAX(PeriodOrder) + 1
        FROM #P
        WHERE PeriodType = 'M'
        GROUP BY PeriodYear;
    END
    ELSE
    BEGIN
        -- Always the last 4 completed Thu–Wed weeks of the newest WeekFolder
        -- (e.g. "01. Week 11.05.2026 - 11.11.2026" → W4 = Nov 05–11).
        -- Never fall back to older DenialDate weeks — if this window has no denials,
        -- Weekly returns empty so the UI can show "no Weekly data found for this week range".
        IF @LoadedThrough IS NULL
            SET @LoadedThrough =
            (
                SELECT MAX(TRY_CONVERT(DATE,
                            REPLACE(RIGHT(LTRIM(RTRIM(CONVERT(NVARCHAR(100), WeekFolder))), 10), '.', '/'),
                            101))
                FROM dbo.ClaimLevelData
                WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), WeekFolder))), N'') IS NOT NULL
            );

        -- Anchor ONLY on WeekFolder. Do not use MAX(DenialDate) — that was the wrong fix
        -- that re-surfaced Jul/Aug/Sep weeks for the Nov WeekFolder.
        DECLARE @Anchor DATE = COALESCE(@LoadedThrough, @Today);
        IF @Anchor > @Today SET @Anchor = @Today;

        SET @W4 = DATEADD(DAY, -((DATEDIFF(DAY, @Thursday, @Anchor) % 7 + 7) % 7), @Anchor);
        IF DATEADD(DAY, 6, @W4) > @Today
            SET @W4 = DATEADD(DAY, -7, @W4);

        INSERT INTO #P (PeriodType, PeriodKey, PeriodYear, PeriodStart, PeriodEnd, PeriodLabel, PeriodOrder)
        SELECT 'W', CONVERT(NVARCHAR(10), s.WeekStart, 23), YEAR(s.WeekStart), s.WeekStart, DATEADD(DAY, 6, s.WeekStart),
               CONVERT(NVARCHAR(6), s.WeekStart, 107) + N' - ' + CONVERT(NVARCHAR(6), DATEADD(DAY, 6, s.WeekStart), 107),
               n.i
        FROM (VALUES (1), (2), (3), (4)) n(i)
        CROSS APPLY (SELECT DATEADD(WEEK, n.i - 4, @W4) AS WeekStart) s
        WHERE @W4 IS NOT NULL;

        -- Keep only claims in the WeekFolder window:
        --   • DenialDate in one of the 4 weeks, OR
        --   • DeniedWeek "Week 1".."Week 4" on a claim whose WeekFolder is the newest folder
        --     (DeniedWeek is relative to that file week — never remap older folders).
        ;WITH keep AS
        (
            SELECT c.ClaimKey
            FROM #C c
            CROSS APPLY (
                SELECT CASE
                           WHEN c.DeniedWeek LIKE N'Week [1-4]'
                                AND @W4 IS NOT NULL
                                AND c.WeekFolderEnd IS NOT NULL
                                AND c.WeekFolderEnd = @LoadedThrough
                               THEN DATEADD(DAY, 7 * (CAST(RIGHT(c.DeniedWeek, 1) AS INT) - 4), @W4)
                           ELSE c.DenialDate
                       END AS BucketDate
            ) b
            JOIN #P p ON p.PeriodType = 'W' AND b.BucketDate BETWEEN p.PeriodStart AND p.PeriodEnd
        )
        DELETE c
        FROM #C c
        WHERE NOT EXISTS (SELECT 1 FROM keep k WHERE k.ClaimKey = c.ClaimKey);
    END

    INSERT INTO #P (PeriodType, PeriodKey, PeriodYear, PeriodStart, PeriodEnd, PeriodLabel, PeriodOrder)
    VALUES ('A', N'', NULL, NULL, NULL, N'Grand Total', 1000);

    ;WITH CodeTot AS
    (
        SELECT c.PayerName, c.DenialCode, COUNT(DISTINCT c.ClaimKey) AS Claims, SUM(c.Bal) AS Bal,
               ROW_NUMBER() OVER (PARTITION BY c.PayerName
                                  ORDER BY COUNT(DISTINCT c.ClaimKey) DESC, SUM(c.Bal) DESC, c.DenialCode) AS CodeRank
        FROM #C c
        WHERE c.DenialCode IS NOT NULL
        GROUP BY c.PayerName, c.DenialCode
    )
    SELECT * INTO #Code FROM CodeTot WHERE CodeRank <= 3;

    SELECT p.PeriodKey, c.PayerName, COUNT(DISTINCT c.ClaimKey) AS Claims, SUM(c.Bal) AS Bal
    INTO #PM
    FROM #C c
    JOIN #P p ON p.PeriodType = 'M'
             AND c.DenialDate BETWEEN p.PeriodStart AND p.PeriodEnd
    GROUP BY p.PeriodKey, c.PayerName;

    -- Weekly code cells: bucket by DeniedWeek "Week 1".."Week 4" only for the newest
    -- WeekFolder; otherwise DenialDate.
    SELECT p.PeriodKey, c.PayerName, c.DenialCode, COUNT(DISTINCT c.ClaimKey) AS Claims, SUM(c.Bal) AS Bal
    INTO #CM
    FROM #C c
    CROSS APPLY (
        SELECT CASE
                   WHEN @Weekly = 1
                        AND c.DeniedWeek LIKE N'Week [1-4]'
                        AND @W4 IS NOT NULL
                        AND @LoadedThrough IS NOT NULL
                        AND c.WeekFolderEnd = @LoadedThrough
                       THEN DATEADD(DAY, 7 * (CAST(RIGHT(c.DeniedWeek, 1) AS INT) - 4), @W4)
                   ELSE c.DenialDate
               END AS BucketDate
    ) b
    JOIN #P p ON p.PeriodType = CASE WHEN @Weekly = 1 THEN 'W' ELSE 'M' END
             AND b.BucketDate BETWEEN p.PeriodStart AND p.PeriodEnd
    GROUP BY p.PeriodKey, c.PayerName, c.DenialCode;

    CREATE TABLE #PW (PeriodKey NVARCHAR(20), PayerName NVARCHAR(500), Claims INT, Bal DECIMAL(18,2));
    IF @Weekly = 1
        INSERT INTO #PW (PeriodKey, PayerName, Claims, Bal)
        SELECT p.PeriodKey, c.PayerName, COUNT(DISTINCT c.ClaimKey), SUM(c.Bal)
        FROM #C c
        CROSS APPLY (
            SELECT CASE
                       WHEN c.DeniedWeek LIKE N'Week [1-4]'
                            AND @W4 IS NOT NULL
                            AND @LoadedThrough IS NOT NULL
                            AND c.WeekFolderEnd = @LoadedThrough
                           THEN DATEADD(DAY, 7 * (CAST(RIGHT(c.DeniedWeek, 1) AS INT) - 4), @W4)
                       ELSE c.DenialDate
                   END AS BucketDate
        ) b
        JOIN #P p ON p.PeriodType = 'W' AND b.BucketDate BETWEEN p.PeriodStart AND p.PeriodEnd
        GROUP BY p.PeriodKey, c.PayerName;

    CREATE TABLE #Out
    (
        RowType CHAR(1), PayerName NVARCHAR(500), DenialCode NVARCHAR(400),
        PayerRank INT, CodeRank INT, PeriodType CHAR(1), PeriodKey NVARCHAR(20),
        PeriodYear INT, PeriodStart DATE, PeriodEnd DATE, PeriodLabel NVARCHAR(40),
        ClaimCount INT, TotalInsuranceBalance DECIMAL(18,2),
        SortOrder INT, PeriodOrder INT, IndexLabel NVARCHAR(10), RowLabel NVARCHAR(400),
        CoveragePct DECIMAL(9,2)
    );

    DECLARE @GrandClaims INT = (SELECT COUNT(DISTINCT ClaimKey) FROM #C);
    DECLARE @GrandBal DECIMAL(18,2) = (SELECT ISNULL(SUM(Bal), 0) FROM #C);

    IF @Weekly = 0
    BEGIN
        INSERT INTO #Out
        SELECT 'P', r.PayerName, N'', r.PayerRank, 0, p.PeriodType, p.PeriodKey,
               p.PeriodYear, p.PeriodStart, p.PeriodEnd, p.PeriodLabel,
               CASE p.PeriodType
                   WHEN 'A' THEN r.Claims
                   WHEN 'Y' THEN ISNULL(y.Claims, 0)
                   ELSE ISNULL(m.Claims, 0) END,
               CASE p.PeriodType
                   WHEN 'A' THEN r.Bal
                   WHEN 'Y' THEN ISNULL(y.Bal, 0)
                   ELSE ISNULL(m.Bal, 0) END,
               r.PayerRank * 10, p.PeriodOrder, NCHAR(64 + r.PayerRank), r.PayerName, 100
        FROM (SELECT * FROM (SELECT PayerName, Claims, Bal, PayerRank FROM
                (SELECT PayerName, COUNT(DISTINCT ClaimKey) AS Claims, SUM(Bal) AS Bal,
                        ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT ClaimKey) DESC, SUM(Bal) DESC, PayerName) AS PayerRank
                 FROM #C GROUP BY PayerName) z) q) r
        CROSS JOIN #P p
        LEFT JOIN #PM m ON m.PayerName = r.PayerName AND m.PeriodKey = p.PeriodKey AND p.PeriodType = 'M'
        LEFT JOIN (SELECT m.PayerName, yp.PeriodYear, SUM(m.Claims) AS Claims, SUM(m.Bal) AS Bal
                   FROM #PM m JOIN #P yp ON yp.PeriodKey = m.PeriodKey AND yp.PeriodType = 'M'
                   GROUP BY m.PayerName, yp.PeriodYear) y
               ON y.PayerName = r.PayerName AND y.PeriodYear = p.PeriodYear AND p.PeriodType = 'Y';

        INSERT INTO #Out
        SELECT 'C', k.PayerName, k.DenialCode, r.PayerRank, k.CodeRank, p.PeriodType, p.PeriodKey,
               p.PeriodYear, p.PeriodStart, p.PeriodEnd, p.PeriodLabel,
               CASE p.PeriodType WHEN 'A' THEN k.Claims WHEN 'Y' THEN ISNULL(y.Claims, 0) ELSE ISNULL(m.Claims, 0) END,
               CASE p.PeriodType WHEN 'A' THEN k.Bal    WHEN 'Y' THEN ISNULL(y.Bal, 0)    ELSE ISNULL(m.Bal, 0) END,
               r.PayerRank * 10 + k.CodeRank, p.PeriodOrder, CONVERT(NVARCHAR(10), k.CodeRank), k.DenialCode, 100
        FROM #Code k
        JOIN (SELECT PayerName, PayerRank FROM (SELECT PayerName,
                     ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT ClaimKey) DESC, SUM(Bal) DESC, PayerName) AS PayerRank
              FROM #C GROUP BY PayerName) z) r ON r.PayerName = k.PayerName
        CROSS JOIN #P p
        LEFT JOIN #CM m ON m.PayerName = k.PayerName AND m.DenialCode = k.DenialCode AND m.PeriodKey = p.PeriodKey AND p.PeriodType = 'M'
        LEFT JOIN (SELECT m.PayerName, m.DenialCode, yp.PeriodYear, SUM(m.Claims) AS Claims, SUM(m.Bal) AS Bal
                   FROM #CM m JOIN #P yp ON yp.PeriodKey = m.PeriodKey AND yp.PeriodType = 'M'
                   GROUP BY m.PayerName, m.DenialCode, yp.PeriodYear) y
               ON y.PayerName = k.PayerName AND y.DenialCode = k.DenialCode AND y.PeriodYear = p.PeriodYear AND p.PeriodType = 'Y';
    END
    ELSE
    BEGIN
        INSERT INTO #Out
        SELECT 'P', r.PayerName, N'', r.PayerRank, 0, p.PeriodType, p.PeriodKey,
               p.PeriodYear, p.PeriodStart, p.PeriodEnd, p.PeriodLabel,
               CASE WHEN p.PeriodType = 'A' THEN r.Claims ELSE ISNULL(w.Claims, 0) END,
               CASE WHEN p.PeriodType = 'A' THEN r.Bal    ELSE ISNULL(w.Bal, 0) END,
               r.PayerRank * 10, p.PeriodOrder, NCHAR(64 + r.PayerRank), r.PayerName, 100
        FROM (SELECT PayerName, COUNT(DISTINCT ClaimKey) AS Claims, SUM(Bal) AS Bal,
                     ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT ClaimKey) DESC, SUM(Bal) DESC, PayerName) AS PayerRank
              FROM #C GROUP BY PayerName) r
        CROSS JOIN #P p
        LEFT JOIN #PW w ON w.PayerName = r.PayerName AND w.PeriodKey = p.PeriodKey
        WHERE p.PeriodType IN ('W', 'A');

        INSERT INTO #Out
        SELECT 'C', k.PayerName, k.DenialCode, r.PayerRank, k.CodeRank, p.PeriodType, p.PeriodKey,
               p.PeriodYear, p.PeriodStart, p.PeriodEnd, p.PeriodLabel,
               CASE WHEN p.PeriodType = 'A' THEN k.Claims ELSE ISNULL(m.Claims, 0) END,
               CASE WHEN p.PeriodType = 'A' THEN k.Bal    ELSE ISNULL(m.Bal, 0) END,
               r.PayerRank * 10 + k.CodeRank, p.PeriodOrder, CONVERT(NVARCHAR(10), k.CodeRank), k.DenialCode, 100
        FROM #Code k
        JOIN (SELECT PayerName, ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT ClaimKey) DESC, SUM(Bal) DESC, PayerName) AS PayerRank
              FROM #C GROUP BY PayerName) r ON r.PayerName = k.PayerName
        CROSS JOIN #P p
        LEFT JOIN #CM m ON m.PayerName = k.PayerName AND m.DenialCode = k.DenialCode AND m.PeriodKey = p.PeriodKey
        WHERE p.PeriodType IN ('W', 'A');
    END

    INSERT INTO #Out
    SELECT 'T', N'', N'', 0, 0, p.PeriodType, p.PeriodKey, p.PeriodYear, p.PeriodStart, p.PeriodEnd, p.PeriodLabel,
           ISNULL(SUM(o.ClaimCount), 0), ISNULL(SUM(o.TotalInsuranceBalance), 0),
           100000, p.PeriodOrder, N'', N'Grand Total', 100
    FROM #P p
    LEFT JOIN #Out o ON o.RowType = 'P' AND o.PeriodKey = p.PeriodKey
    GROUP BY p.PeriodType, p.PeriodKey, p.PeriodYear, p.PeriodStart, p.PeriodEnd, p.PeriodLabel, p.PeriodOrder;

    SELECT RowType, PayerName, DenialCode, PayerRank, CodeRank, PeriodType, PeriodKey,
           PeriodYear, PeriodStart, PeriodEnd, PeriodLabel, ClaimCount, TotalInsuranceBalance,
           SortOrder, PeriodOrder, IndexLabel, RowLabel, CoveragePct
    FROM #Out
    ORDER BY SortOrder, PeriodOrder;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetVarX_DenialMonthly
    @PayerNames NVARCHAR(MAX) = NULL, @PayerTypes NVARCHAR(MAX) = NULL, @DenialCodes NVARCHAR(MAX) = NULL,
    @DenialFrom DATE = NULL, @DenialTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_VarX_DenialPeriod 0, @PayerNames, @PayerTypes, @DenialCodes, @DenialFrom, @DenialTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetVarX_DenialWeekly
    @PayerNames NVARCHAR(MAX) = NULL, @PayerTypes NVARCHAR(MAX) = NULL, @DenialCodes NVARCHAR(MAX) = NULL,
    @DenialFrom DATE = NULL, @DenialTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_VarX_DenialPeriod 1, @PayerNames, @PayerTypes, @DenialCodes, @DenialFrom, @DenialTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetVarX_DenialSummaryTiles
AS
BEGIN
    SET NOCOUNT ON;
    SELECT COUNT(DISTINCT CASE WHEN d.DenialDate IS NOT NULL OR d.DeniedWeek IS NOT NULL THEN d.ClaimKey END) AS DeniedClaims,
           ISNULL(SUM(CASE WHEN d.DenialDate IS NOT NULL OR d.DeniedWeek IS NOT NULL THEN d.Bal END), 0) AS InsuranceBalance,
           COUNT(DISTINCT CASE WHEN d.DenialDate IS NOT NULL OR d.DeniedWeek IS NOT NULL THEN d.DenialCode END) AS DenialCodes,
           COUNT(DISTINCT CASE WHEN d.DenialDate IS NOT NULL OR d.DeniedWeek IS NOT NULL THEN d.PayerName END) AS Insurances,
           COUNT(DISTINCT CASE WHEN d.DenialDate IS NULL AND d.DeniedWeek IS NULL THEN d.ClaimKey END) AS UndatedGroups,
           COALESCE(
               (SELECT MAX(TRY_CONVERT(DATE,
                           REPLACE(RIGHT(LTRIM(RTRIM(CONVERT(NVARCHAR(100), WeekFolder))), 10), '.', '/'),
                           101))
                FROM dbo.ClaimLevelData
                WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), WeekFolder))), N'') IS NOT NULL),
               MAX(d.DenialDate)
           ) AS LoadedThrough,
           GETDATE() AS RefreshedAt
    FROM (
        SELECT NULLIF(LTRIM(RTRIM(ClaimID)), N'') AS ClaimKey,
               LTRIM(RTRIM(ISNULL(PayerName_Raw, N''))) AS PayerName,
               LTRIM(RTRIM(CONVERT(NVARCHAR(400), ClaimLevelDenialCode))) AS DenialCode,
               TRY_CAST(DenialDate AS DATE) AS DenialDate,
               NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), DeniedWeek))), N'') AS DeniedWeek,
               ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) AS Bal
        FROM dbo.ClaimLevelData
        WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(400), ClaimLevelDenialCode))), N'') IS NOT NULL
          AND ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) > 0
    ) d;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetVarX_DenialList
    @PayerNames NVARCHAR(MAX) = NULL, @PayerTypes NVARCHAR(MAX) = NULL, @DenialCodes NVARCHAR(MAX) = NULL,
    @DenialFrom DATE = NULL, @DenialTo DATE = NULL, @DenialCodeSearch NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT LTRIM(RTRIM(CONVERT(NVARCHAR(400), ClaimLevelDenialCode))) AS DenialCode,
           LTRIM(RTRIM(ISNULL(PayerName_Raw, N''))) AS PayerName,
           NULLIF(LTRIM(RTRIM(ClaimID)), N'') AS ClaimKey,
           ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) AS Bal
    INTO #C
    FROM dbo.ClaimLevelData
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(400), ClaimLevelDenialCode))), N'') IS NOT NULL
      AND ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST(DenialDate AS DATE) IS NOT NULL
      AND (@DenialCodeSearch IS NULL
           OR LTRIM(RTRIM(CONVERT(NVARCHAR(400), ClaimLevelDenialCode))) LIKE N'%' + @DenialCodeSearch + N'%')
      AND (@DenialFrom IS NULL OR TRY_CAST(DenialDate AS DATE) >= @DenialFrom)
      AND (@DenialTo   IS NULL OR TRY_CAST(DenialDate AS DATE) <= @DenialTo);

    ;WITH Code AS
    (
        SELECT DenialCode, COUNT(DISTINCT ClaimKey) AS Claims, SUM(Bal) AS Bal,
               ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT ClaimKey) DESC, SUM(Bal) DESC, DenialCode) AS CodeRank
        FROM #C GROUP BY DenialCode
    ),
    Payer AS
    (
        SELECT c.DenialCode, c.PayerName, COUNT(DISTINCT c.ClaimKey) AS Claims, SUM(c.Bal) AS Bal,
               ROW_NUMBER() OVER (PARTITION BY c.DenialCode ORDER BY COUNT(DISTINCT c.ClaimKey) DESC, c.PayerName) AS PayerRank
        FROM #C c GROUP BY c.DenialCode, c.PayerName
    )
    SELECT RowType, DenialCode, PayerName, CodeRank, PayerRank, ClaimCount, TotalInsuranceBalance, SortOrder
    FROM (
        SELECT N'D' AS RowType, DenialCode, N'' AS PayerName, CodeRank, 0 AS PayerRank, Claims AS ClaimCount, Bal AS TotalInsuranceBalance, CodeRank * 1000 AS SortOrder
        FROM Code
        UNION ALL
        SELECT N'P', p.DenialCode, p.PayerName, c.CodeRank, p.PayerRank, p.Claims, p.Bal, c.CodeRank * 1000 + p.PayerRank
        FROM Payer p JOIN Code c ON c.DenialCode = p.DenialCode
    ) x
    ORDER BY SortOrder;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetVarX_DenialFilterOptions
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DISTINCT LTRIM(RTRIM(PayerName_Raw)) AS PayerName
    FROM dbo.ClaimLevelData
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(400), ClaimLevelDenialCode))), N'') IS NOT NULL
      AND ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) > 0
      AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), N'') IS NOT NULL
    ORDER BY 1;

    SELECT CAST(NULL AS NVARCHAR(200)) AS PayerType WHERE 1 = 0;

    SELECT DISTINCT LTRIM(RTRIM(CONVERT(NVARCHAR(400), ClaimLevelDenialCode))) AS DenialCode
    FROM dbo.ClaimLevelData
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(400), ClaimLevelDenialCode))), N'') IS NOT NULL
      AND ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) > 0
    ORDER BY 1;

    SELECT MIN(TRY_CAST(DenialDate AS DATE)) AS MinDenialDate,
           MAX(TRY_CAST(DenialDate AS DATE)) AS MaxDenialDate,
           GETDATE() AS RefreshedAt
    FROM dbo.ClaimLevelData
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(400), ClaimLevelDenialCode))), N'') IS NOT NULL
      AND ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) > 0;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_DenialMonthly AS
BEGIN SET NOCOUNT ON; PRINT 'usp_RefreshVarX_DenialMonthly: usp_GetVarX_DenialMonthly aggregates live.'; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_DenialWeekly AS
BEGIN SET NOCOUNT ON; PRINT 'usp_RefreshVarX_DenialWeekly: usp_GetVarX_DenialWeekly aggregates live.'; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_DenialList AS
BEGIN SET NOCOUNT ON; PRINT 'usp_RefreshVarX_DenialList: usp_GetVarX_DenialList aggregates live.'; END
GO

PRINT '30_VariantX_DenialSummary.sql completed.';
GO
