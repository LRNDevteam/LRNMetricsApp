/* =====================================================================
   Augustus Production Summary — REVIEW SPs (do not replace LIVE)

   Safe to deploy on LIVE. These are NEW names only:
     dbo.usp_GetAug_WeeklyBilledProductionSummary_Review
     dbo.usp_GetAug_CPTBreakdown_Review
     dbo.usp_GetAug_CodingBreakdown_Review
     dbo.usp_GetAug_PanelBreakdown_Review

   They always query ClaimLevelData / LineLevelData (no Aug_* snapshot).
   Existing usp_GetAug_* / usp_RefreshAug_* are not changed.

   Compare on LIVE:
     EXEC dbo.usp_GetAug_WeeklyBilledProductionSummary;          -- current (snapshot)
     EXEC dbo.usp_GetAug_WeeklyBilledProductionSummary_Review;   -- proposed

     EXEC dbo.usp_GetAug_CPTBreakdown;
     EXEC dbo.usp_GetAug_CPTBreakdown_Review;

     EXEC dbo.usp_GetAug_CodingBreakdown;
     EXEC dbo.usp_GetAug_CodingBreakdown_Review;

     EXEC dbo.usp_GetAug_PanelBreakdown_Review;                  -- no LIVE counterpart
   ===================================================================== */
SET NOCOUNT ON;
GO

-- ============================================================
-- 1) Weekly — Mon–Sun, newest week = latest WeekFolder (banner range)
--
-- LIVE issue: banner "08.10.2026 - 08.16.2026" vs grid "8/6/2026 – 8/12/2026".
-- Current snapshot SP anchors to MAX(ChargeEnteredDate) and can skip the
-- billed WeekFolder week; LIVE may also be using a Thu–Wed week (8/6–8/12).
-- Augustus WeekRange is "Mon to Sun". Banner WeekFolder is Mon–Sun.
--
-- This SP:
--   * Parses latest LineClaimFileLogs.WeekFolder (MM.dd.yyyy - MM.dd.yyyy)
--   * Uses that Monday as week 0 (always included — it is the ingest week)
--   * Builds 4 Mon–Sun weeks backward
--   * Falls back to MAX(ChargeEnteredDate) Monday if WeekFolder is missing
-- Result shape matches usp_GetAug_WeeklyBilledProductionSummary
--   (includes PayerRank = 0 panel totals, same as the filtered LIVE path)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_WeeklyBilledProductionSummary_Review
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
    DECLARE @FolderEnd   DATE;
    DECLARE @AnchorMon   DATE;
    DECLARE @DateFromData DATE;

    SELECT TOP (1) @WeekFolder = LTRIM(RTRIM(WeekFolder))
    FROM dbo.LineClaimFileLogs
    WHERE NULLIF(LTRIM(RTRIM(WeekFolder)), '') IS NOT NULL
    ORDER BY InsertedDateTime DESC, FileLogId DESC;

    -- WeekFolder e.g. "08.10.2026 - 08.16.2026"  (style 101 = mm/dd/yyyy)
    IF @WeekFolder IS NOT NULL AND CHARINDEX(' - ', @WeekFolder) > 0
    BEGIN
        SET @FolderStart = TRY_CONVERT(DATE, REPLACE(LEFT(@WeekFolder, 10), '.', '/'), 101);
        SET @FolderEnd   = TRY_CONVERT(DATE, REPLACE(LTRIM(RIGHT(@WeekFolder, 10)), '.', '/'), 101);
    END

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

    PRINT 'Weekly_Review WeekFolder = ' + ISNULL(@WeekFolder, '(none)');
    PRINT 'Weekly_Review AnchorMon  = ' + CONVERT(VARCHAR(10), @AnchorMon, 120)
        + '  FolderStart = ' + ISNULL(CONVERT(VARCHAR(10), @FolderStart, 120), '(null)')
        + '  FolderEnd = ' + ISNULL(CONVERT(VARCHAR(10), @FolderEnd, 120), '(null)');

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

    -- Always include the WeekFolder week (index 0), then 3 prior Mon–Sun weeks.
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
-- 2) CPT Breakdown — month + billed filter aligned to monthly / payer tabs
--
-- LIVE issue: unfiltered page uses C# GetCptBreakdownAsync (Rule3):
--   month = FirstBilledDate, Units = COUNT(DISTINCT CPTCode)  [always 1 per CPT/month]
--   UI "Count of Units" actually binds ClaimCount = COUNT(*) line rows
-- Current usp_GetAug_CPTBreakdown:
--   month = ChargeEnteredDate, CPTCount = COUNT(*), BilledUnits = SUM(Units)
-- Monthly / Payer tabs use ChargeEnteredDate + billed FirstBilledDate.
--
-- This SP (same columns as usp_GetAug_CPTBreakdown):
--   month        = ChargeEnteredDate  (matches billed production months)
--   CPTCount     = COUNT(*) line rows (what the UI currently shows as Count of Units)
--   BilledUnits  = SUM(Units)
--   TotalCharges = SUM(ChargeAmount)
-- Note: CPTCount is LINE grain. It will not equal monthly claim COUNT(*).
--       Compare TotalCharges / months to monthly billed, not claim counts.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CPTBreakdown_Review
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

    SELECT
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown')))                 AS CPTCode,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')   AS BilledYearMonth,
        COUNT(*)                                                 AS CPTCount,
        ISNULL(SUM(TRY_CAST(Units        AS DECIMAL(18,2))), 0)  AS BilledUnits,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)  AS TotalCharges
    FROM dbo.LineLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND LTRIM(RTRIM(FirstBilledDate)) <> ''
      AND NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
      AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@FirstBillFrom   IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo     IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
    GROUP BY
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
    ORDER BY CPTCode, BilledYearMonth;
END
GO

-- ============================================================
-- 3) Coding Review (unbilled) — COUNT(DISTINCT VisitKey)
--
-- LIVE issue: comments say distinct visits but both refresh + Get SPs use
-- COUNT(VisitKey). Unbilled Aging already uses COUNT(DISTINCT VisitKey),
-- so Coding vs Unbilled Aging totals mismatch. CPT drilldown also skips
-- blank CPTCodeXUnitsXModifier, so panel total can exceed sum of CPT rows.
--
-- This SP:
--   COUNT(DISTINCT VisitKey) at panel and CPT grain
--   blank CPT detail stored as '(No CPT)' so panel total = sum of CPT rows
--     when each unbilled claim has one VisitKey / one CPT string
-- Two result sets, same shape as usp_GetAug_CodingBreakdown.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CodingBreakdown_Review
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

    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)), ''), '(No PanelNew)'))) AS PanelNew,
        CASE
            WHEN NULLIF(LTRIM(RTRIM(CPTCodeXUnitsXModifier)), '') IS NULL THEN N'(No CPT)'
            ELSE LTRIM(RTRIM(CPTCodeXUnitsXModifier))
        END AS CPTDetail,
        COALESCE(
            NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
            NULLIF(LTRIM(RTRIM(ClaimID)), '')
        ) AS VisitKey,
        TRY_CAST(ChargeAmount AS DECIMAL(18,2)) AS Charge
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
      AND (@HasPanelFilter  = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)), ''), '(No PanelNew)'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@FirstBillFrom   IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo     IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo);

    -- RS1 panel summary
    SELECT
        PanelNew AS PanelName,
        COUNT(DISTINCT VisitKey) AS ClaimCount,
        ISNULL(SUM(Charge), 0)   AS TotalCharges
    FROM #Raw
    GROUP BY PanelNew
    ORDER BY TotalCharges DESC;

    -- RS2 CPT detail (includes '(No CPT)')
    SELECT
        PanelNew AS PanelName,
        CPTDetail AS CPTCodeXUnitsXModifier,
        COUNT(DISTINCT VisitKey) AS ClaimCount,
        ISNULL(SUM(Charge), 0)   AS TotalCharges
    FROM #Raw
    GROUP BY PanelNew, CPTDetail
    ORDER BY PanelName, TotalCharges DESC;

    DROP TABLE IF EXISTS #Raw;
END
GO

-- ============================================================
-- 4) Panel Breakdown — NEW (no LIVE Augustus SP; tab is NorthWest-only today)
--
-- LIVE issue: Production Summary Panel Breakdown tab is empty for Augustus
-- because C# never calls a panel SP. This SP is the SQL side only.
-- Showing data in the UI still needs the app to call this SP.
--
-- Shape matches usp_GetNW_PanelBreakdownWithPayers:
--   PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges
-- Augustus rules (same as monthly billed):
--   PanelNew, billed FirstBilledDate, month = ChargeEnteredDate, COUNT(*)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_PanelBreakdown_Review
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

PRINT '14b_Augustus_ReadSPs_Review.sql completed.';
PRINT 'Created: usp_GetAug_WeeklyBilledProductionSummary_Review';
PRINT '         usp_GetAug_CPTBreakdown_Review';
PRINT '         usp_GetAug_CodingBreakdown_Review';
PRINT '         usp_GetAug_PanelBreakdown_Review';
GO

/*
-- Quick LIVE compare (run after deploying this file)

-- Weeks currently on the page (snapshot)
SELECT DISTINCT WeekStart, WeekEnd, WeekLabel
FROM dbo.Aug_WeeklyBilledProductionSummary
ORDER BY WeekStart;

-- Proposed weeks (should include WeekFolder Mon–Sun, e.g. 2026-08-10 – 2026-08-16)
EXEC dbo.usp_GetAug_WeeklyBilledProductionSummary_Review;

-- CPT month + grand charges: current snapshot vs review
SELECT BilledYearMonth, SUM(CPTCount) AS LineRows, SUM(BilledUnits) AS Units, SUM(TotalCharges) AS Charges
FROM dbo.Aug_CPTBreakdown
GROUP BY BilledYearMonth ORDER BY BilledYearMonth;

SELECT BilledYearMonth, SUM(CPTCount) AS LineRows, SUM(BilledUnits) AS Units, SUM(TotalCharges) AS Charges
FROM (
    -- capture review output into a temp table if needed
    SELECT CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges
    FROM dbo.Aug_CPTBreakdown WHERE 1 = 0
) x;

-- Coding: current COUNT vs proposed DISTINCT
SELECT 'snapshot' AS Src, SUM(ClaimCount) AS PanelClaims FROM dbo.Aug_CodingPanelSummary
UNION ALL
SELECT 'unbilled aging DISTINCT', SUM(ClaimCount) FROM dbo.Aug_UnbilledAging;

EXEC dbo.usp_GetAug_CodingBreakdown_Review;
EXEC dbo.usp_GetAug_PanelBreakdown_Review;
*/
