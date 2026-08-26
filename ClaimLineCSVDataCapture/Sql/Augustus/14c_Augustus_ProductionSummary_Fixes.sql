/* =====================================================================
   Augustus Production Summary — client fixes (NEW SPs, do not drop LIVE)

   Deploy on Augustus_Labs. Existing usp_GetAug_* / usp_RefreshAug_* stay.

     dbo.usp_GetAug_WeeklyBilledProductionSummary_v2
     dbo.usp_GetAug_CPTBreakdown_v2
     dbo.usp_GetAug_PanelBreakdown          -- new (no LIVE counterpart)
     dbo.usp_GetAug_PayerBreakdown_v2

   All four always query ClaimLevelData / LineLevelData (no snapshot).

   1) Weekly: Mon–Sun, newest week = latest WeekFolder (banner range)
   2) CPT: COUNT of CPT rows (not SUM(Units)); month = ChargeEnteredDate
   3) Panel: FirstBilledDate not blank, row = PanelNew, col = CED month,
             COUNT(*) + SUM(ChargeAmount); payer children like NorthWest
   4) Payer: same billed filter + CED month; includes TotalCharges
   ===================================================================== */
SET NOCOUNT ON;
GO

-- ============================================================
-- 1) Weekly billed production — WeekFolder-anchored Mon–Sun
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_WeeklyBilledProductionSummary_v2
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

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @WeekFolder NVARCHAR(500);
    DECLARE @FolderStart DATE;
    DECLARE @AnchorMon   DATE;
    DECLARE @DateFromData DATE;

    SELECT TOP (1) @WeekFolder = LTRIM(RTRIM(WeekFolder))
    FROM dbo.LineClaimFileLogs
    WHERE NULLIF(LTRIM(RTRIM(WeekFolder)), '') IS NOT NULL
    ORDER BY InsertedDateTime DESC, FileLogId DESC;

    -- WeekFolder e.g. "08.10.2026 - 08.16.2026" (style 101 = mm/dd/yyyy)
    IF @WeekFolder IS NOT NULL AND CHARINDEX(' - ', @WeekFolder) > 0
        SET @FolderStart = TRY_CONVERT(DATE, REPLACE(LEFT(@WeekFolder, 10), '.', '/'), 101);

    IF @FolderStart IS NOT NULL
        SET @AnchorMon = DATEADD(DAY, -(DATEDIFF(DAY, '19000101', @FolderStart) % 7), @FolderStart);
    ELSE
    BEGIN
        SELECT @DateFromData = MAX(TRY_CAST(ChargeEnteredDate AS DATE))
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
          AND TRY_CAST(ChargeEnteredDate AS DATE) <= @Today;

        SET @AnchorMon = DATEADD(DAY,
            -(DATEDIFF(DAY, '19000101', ISNULL(@DateFromData, @Today)) % 7),
            ISNULL(@DateFromData, @Today));
    END

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    DECLARE @Weeks TABLE (
        WeekIndex INT NOT NULL PRIMARY KEY,
        WeekStart DATE NOT NULL,
        WeekEnd   DATE NOT NULL,
        WeekLabel NVARCHAR(32) NOT NULL
    );

    DECLARE @i INT = 0;
    WHILE @i <= 3
    BEGIN
        INSERT INTO @Weeks (WeekIndex, WeekStart, WeekEnd, WeekLabel)
        SELECT
            @i,
            DATEADD(WEEK, -@i, @AnchorMon),
            DATEADD(DAY, 6, DATEADD(WEEK, -@i, @AnchorMon)),
            FORMAT(DATEADD(WEEK, -@i, @AnchorMon), 'yyyy-MM-dd')
                + ' - '
                + FORMAT(DATEADD(DAY, 6, DATEADD(WEEK, -@i, @AnchorMon)), 'yyyy-MM-dd');
        SET @i += 1;
    END

    ;WITH Agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(cl.PanelNew,      'Unknown')))        AS PanelNew,
            LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown')))        AS PayerName_Raw,
            w.WeekStart, w.WeekEnd, w.WeekLabel,
            COUNT(*)                                                 AS ClaimCount,
            ISNULL(SUM(TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2))),0) AS TotalCharges
        FROM dbo.ClaimLevelData cl
        JOIN @Weeks w ON TRY_CAST(cl.ChargeEnteredDate AS DATE) BETWEEN w.WeekStart AND w.WeekEnd
        WHERE TRY_CAST(cl.FirstBilledDate AS DATE) IS NOT NULL
          AND LTRIM(RTRIM(cl.FirstBilledDate)) <> ''
          AND (@HasPayerFilter  = 0 OR LTRIM(RTRIM(ISNULL(cl.PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter  = 0 OR LTRIM(RTRIM(ISNULL(cl.PanelNew,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom         IS NULL OR TRY_CAST(cl.DateOfService     AS DATE) >= @DosFrom)
          AND (@DosTo           IS NULL OR TRY_CAST(cl.DateOfService     AS DATE) <= @DosTo)
          AND (@FirstBillFrom   IS NULL OR TRY_CAST(cl.ChargeEnteredDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo     IS NULL OR TRY_CAST(cl.ChargeEnteredDate AS DATE) <= @FirstBillTo)
          AND (@FirstBilledFrom IS NULL OR TRY_CAST(cl.FirstBilledDate   AS DATE) >= @FirstBilledFrom)
          AND (@FirstBilledTo   IS NULL OR TRY_CAST(cl.FirstBilledDate   AS DATE) <= @FirstBilledTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(cl.PanelNew,      'Unknown'))),
            LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown'))),
            w.WeekStart, w.WeekEnd, w.WeekLabel
    ),
    Ranks AS (
        SELECT PanelNew, PayerName_Raw,
               DENSE_RANK() OVER (PARTITION BY PanelNew ORDER BY SUM(ClaimCount) DESC) AS PayerRank
        FROM Agg
        GROUP BY PanelNew, PayerName_Raw
    ),
    PanelTotal AS (
        SELECT PanelNew, WeekStart, WeekEnd, WeekLabel,
               SUM(ClaimCount) AS ClaimCount, SUM(TotalCharges) AS TotalCharges
        FROM Agg
        GROUP BY PanelNew, WeekStart, WeekEnd, WeekLabel
    )
    SELECT PanelName, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges
    FROM (
        SELECT pt.PanelNew AS PanelName, N'' AS PayerName, CAST(0 AS TINYINT) AS PayerRank,
               pt.WeekStart, pt.WeekEnd, pt.WeekLabel, pt.ClaimCount, pt.TotalCharges
        FROM PanelTotal pt
        UNION ALL
        SELECT a.PanelNew, a.PayerName_Raw, CAST(r.PayerRank AS TINYINT),
               a.WeekStart, a.WeekEnd, a.WeekLabel, a.ClaimCount, a.TotalCharges
        FROM Agg a
        JOIN Ranks r ON r.PanelNew = a.PanelNew AND r.PayerName_Raw = a.PayerName_Raw
    ) x
    ORDER BY WeekStart ASC, PanelName, PayerRank;
END
GO

-- ============================================================
-- 2) CPT Breakdown — client Excel (Line Level)
--    Filter = FirstBilledDate not blank
--    Row    = CPT
--    Column = ChargeEnteredDate month/year
--    Values = COUNT(CPT) , SUM(ChargeAmount)
--
--    LineLevelData.ChargeEnteredDate is empty on Augustus line CSVs.
--    Month is resolved as:
--      1) Line ChargeEnteredDate (if ingest ever fills it)
--      2) Claim ChargeEnteredDate  (populated; matches client Excel)
--      3) Line [Date]              (ISO datetime on every line row)
--    CPT 80048 / Jan 2025 = 148 / 3130.20 using (2) or (3).
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CPTBreakdown_v2
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

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH Lined AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(ll.CPTCode, 'Unknown'))) AS CPTCode,
            CAST(ced.CedDateTime AS DATE)               AS CedDate,
            TRY_CAST(ll.ChargeAmount AS DECIMAL(18,2))  AS ChargeAmount,
            TRY_CAST(ll.DateOfService AS DATE)          AS DosDate,
            TRY_CAST(ll.FirstBilledDate AS DATE)        AS FbdDate
        FROM dbo.LineLevelData ll
        INNER JOIN dbo.ClaimLevelData cl
            ON cl.ClaimID = ll.ClaimID
        CROSS APPLY (
            SELECT COALESCE(
                       src.Parsed,
                       TRY_CAST(NULLIF(LTRIM(RTRIM(ll.[Date])), '') AS datetime)
                   ) AS CedDateTime
            FROM (SELECT NULLIF(LTRIM(RTRIM(ll.ChargeEnteredDate)), '') AS LineCed,
                         NULLIF(LTRIM(RTRIM(cl.ChargeEnteredDate)), '') AS ClaimCed) v
            CROSS APPLY (
                SELECT COALESCE(
                           TRY_CONVERT(datetime, v.LineCed),
                           TRY_CONVERT(datetime, v.LineCed, 101),
                           TRY_CONVERT(datetime, v.LineCed, 103),
                           TRY_CONVERT(datetime, v.LineCed, 120),
                           TRY_CONVERT(datetime, v.LineCed, 110),
                           TRY_CONVERT(datetime, REPLACE(LEFT(v.LineCed + '          ', 10), '.', '/'), 101),
                           TRY_CONVERT(datetime, v.ClaimCed),
                           TRY_CONVERT(datetime, v.ClaimCed, 101),
                           TRY_CONVERT(datetime, v.ClaimCed, 103),
                           TRY_CONVERT(datetime, v.ClaimCed, 120),
                           TRY_CONVERT(datetime, v.ClaimCed, 110)
                       ) AS Parsed
            ) src
        ) ced
        WHERE NULLIF(LTRIM(RTRIM(ll.FirstBilledDate)), '') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(ll.CPTCode)), '') IS NOT NULL
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(ll.PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(ll.PanelNew)), ''), 'Unknown'))) IN (SELECT Value FROM @PanelList))
    )
    SELECT
        CPTCode,
        CONVERT(CHAR(7), CedDate, 126)                          AS BilledYearMonth,
        CAST(COUNT(*) AS INT)                                   AS CPTCount,
        CAST(COUNT(*) AS DECIMAL(18,2))                         AS BilledUnits,
        ISNULL(SUM(ChargeAmount), 0)                            AS TotalCharges
    FROM Lined
    WHERE CedDate IS NOT NULL
      AND YEAR(CedDate) > 1900
      AND (@DosFrom         IS NULL OR DosDate >= @DosFrom)
      AND (@DosTo           IS NULL OR DosDate <= @DosTo)
      AND (@FirstBillFrom   IS NULL OR CedDate >= @FirstBillFrom)
      AND (@FirstBillTo     IS NULL OR CedDate <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR FbdDate >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR FbdDate <= @FirstBilledTo)
    GROUP BY CPTCode, CONVERT(CHAR(7), CedDate, 126)
    ORDER BY CPTCode, BilledYearMonth;
END
GO

-- ============================================================
-- 3) Panel Breakdown — same layout as NorthWest
--    Filter = FirstBilledDate not blank
--    Row    = PanelNew  (payer children = PayerName_Raw)
--    Column = ChargeEnteredDate month/year
--    Values = COUNT(*)  [Count of PanelNew], SUM(ChargeAmount)
--    Shape  = PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_PanelBreakdown
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

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)), ''), 'Unknown'))) AS PanelName,
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                      AS PayerName,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')              AS BilledYearMonth,
        COUNT(*)                                                            AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)             AS TotalCharges
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND LTRIM(RTRIM(FirstBilledDate)) <> ''
      AND (@HasPayerFilter  = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter  = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)), ''), 'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@FirstBillFrom   IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo     IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
    GROUP BY
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)), ''), 'Unknown'))),
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
    ORDER BY PanelName, PayerName, BilledYearMonth;
END
GO

-- ============================================================
-- 4) Payer Breakdown — includes Charge Amount (TotalCharges)
--    Filter = FirstBilledDate not blank
--    Row    = PayerName_Raw
--    Column = ChargeEnteredDate month
--    Values = COUNT(*), SUM(ChargeAmount)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_PayerBreakdown_v2
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

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))         AS PayerName,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM') AS BilledYearMonth,
        COUNT(*)                                               AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0) AS TotalCharges
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND LTRIM(RTRIM(FirstBilledDate)) <> ''
      AND (@HasPayerFilter  = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter  = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@FirstBillFrom   IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo     IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
    ORDER BY PayerName, BilledYearMonth;
END
GO

PRINT '14c_Augustus_ProductionSummary_Fixes.sql completed.';
PRINT '  usp_GetAug_WeeklyBilledProductionSummary_v2';
PRINT '  usp_GetAug_CPTBreakdown_v2';
PRINT '  usp_GetAug_PanelBreakdown';
PRINT '  usp_GetAug_PayerBreakdown_v2';
GO
