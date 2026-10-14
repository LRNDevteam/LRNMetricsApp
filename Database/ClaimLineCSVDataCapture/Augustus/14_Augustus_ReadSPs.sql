-- ============================================================
-- Augustus Labs - UI Display (READ) Stored Procedures
-- Called by LabMetricsDashboard.SqlAugustusProductionSummaryRepository /
-- SqlLabProductionSummaryRepository ("Aug_" prefix).
--
-- Each SP supports two execution paths (mirrors 13_BeechTree_ReadSPs.sql):
--   1) NO filter parameters supplied  -> return rows from the pre-aggregated
--      snapshot table (Aug_*) populated by the 06-12 refresh SPs.
--   2) ANY filter parameter supplied  -> aggregate live from
--      dbo.ClaimLevelData / dbo.LineLevelData using the same Augustus
--      filter semantics (PanelNew, blank-payer treated as 'Unknown',
--      ChargeEnteredDate-based monthly/weekly groupings).
--
-- List parameters use '|' as the delimiter so payer/panel names that contain
-- commas are passed safely.
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Monthly Billed Production Summary (PanelNew x Top-N Payer x Month)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_MonthlyBilledProductionSummary
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
                PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
        FROM    dbo.Aug_MonthlyBilledProductionSummary
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
            LTRIM(RTRIM(ISNULL(PanelNew,      'Unknown')))         AS PanelNew,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))         AS PayerName_Raw,
            FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM') AS BilledYearMonth,
            COUNT(*)                                               AS ClaimCount,
            ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0) AS TotalCharges
        FROM   dbo.ClaimLevelData
        WHERE  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
          AND  LTRIM(RTRIM(FirstBilledDate)) <> ''
          AND  (@HasPayerFilter   = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND  (@HasPanelFilter   = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService      AS DATE) >= @DosFrom)
          AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService      AS DATE) <= @DosTo)
          AND  (@FirstBillFrom    IS NULL OR TRY_CAST(ChargeEnteredDate  AS DATE) >= @FirstBillFrom)
          AND  (@FirstBillTo      IS NULL OR TRY_CAST(ChargeEnteredDate  AS DATE) <= @FirstBillTo)
          AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate    AS DATE) >= @FirstBilledFrom)
          AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate    AS DATE) <= @FirstBilledTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(PanelNew,      'Unknown'))),
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
    ),
    Ranks AS (
        SELECT  PanelNew, PayerName_Raw,
                DENSE_RANK() OVER (PARTITION BY PanelNew ORDER BY SUM(ClaimCount) DESC) AS PayerRank
        FROM    Agg GROUP BY PanelNew, PayerName_Raw
    ),
    PanelTotal AS (
        SELECT  PanelNew, BilledYearMonth, SUM(ClaimCount) AS ClaimCount, SUM(TotalCharges) AS TotalCharges
        FROM    Agg GROUP BY PanelNew, BilledYearMonth
    )
    SELECT  PanelName, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
    FROM (
        SELECT  pt.PanelNew AS PanelName, N'' AS PayerName, CAST(0 AS TINYINT) AS PayerRank,
                pt.BilledYearMonth, pt.ClaimCount, pt.TotalCharges
        FROM    PanelTotal pt
        UNION ALL
        SELECT  a.PanelNew AS PanelName, a.PayerName_Raw AS PayerName, CAST(r.PayerRank AS TINYINT) AS PayerRank,
                a.BilledYearMonth, a.ClaimCount, a.TotalCharges
        FROM    Agg a JOIN Ranks r ON r.PanelNew = a.PanelNew AND r.PayerName_Raw = a.PayerName_Raw
    ) x
    ORDER BY PanelName, BilledYearMonth, PayerRank;
END
GO

-- ============================================================
-- Weekly Billed Production Summary (last 4 complete Mon-Sun weeks)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_WeeklyBilledProductionSummary
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
        SELECT  PanelType AS PanelName, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges
        FROM    dbo.Aug_WeeklyBilledProductionSummary
        ORDER BY WeekStart ASC, PanelName, PayerRank;
        RETURN;
    END

    -- Mon-Sun anchor: 1900-01-01 is a known Monday.
    DECLARE @Today            DATE = CAST(GETDATE() AS DATE);
    DECLARE @ThisWeekMonStart DATE = DATEADD(day, -(DATEDIFF(day, '1900-01-01', @Today) % 7), @Today);

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
        DECLARE @ws DATE = DATEADD(week, -@i, @ThisWeekMonStart);
        DECLARE @we DATE = DATEADD(day, 6, @ws);
        INSERT INTO @Weeks (WeekIndex, WeekStart, WeekEnd, WeekLabel)
        VALUES (@i, @ws, @we, FORMAT(@ws, 'yyyy-MM-dd') + ' - ' + FORMAT(@we, 'yyyy-MM-dd'));
        SET @i += 1;
    END

    ;WITH Agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(cl.PanelNew,      'Unknown')))         AS PanelNew,
            LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown')))         AS PayerName_Raw,
            w.WeekStart, w.WeekEnd, w.WeekLabel,
            COUNT(*)                                                   AS ClaimCount,
            ISNULL(SUM(TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2))),0)  AS TotalCharges
        FROM   dbo.ClaimLevelData cl
        JOIN   @Weeks w ON TRY_CAST(cl.ChargeEnteredDate AS DATE) BETWEEN w.WeekStart AND w.WeekEnd
        WHERE  TRY_CAST(cl.FirstBilledDate AS DATE) IS NOT NULL
          AND  LTRIM(RTRIM(cl.FirstBilledDate)) <> ''
          AND  (@HasPayerFilter   = 0 OR LTRIM(RTRIM(ISNULL(cl.PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND  (@HasPanelFilter   = 0 OR LTRIM(RTRIM(ISNULL(cl.PanelNew,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND  (@DosFrom          IS NULL OR TRY_CAST(cl.DateOfService      AS DATE) >= @DosFrom)
          AND  (@DosTo            IS NULL OR TRY_CAST(cl.DateOfService      AS DATE) <= @DosTo)
          AND  (@FirstBillFrom    IS NULL OR TRY_CAST(cl.ChargeEnteredDate  AS DATE) >= @FirstBillFrom)
          AND  (@FirstBillTo      IS NULL OR TRY_CAST(cl.ChargeEnteredDate  AS DATE) <= @FirstBillTo)
          AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(cl.FirstBilledDate    AS DATE) >= @FirstBilledFrom)
          AND  (@FirstBilledTo    IS NULL OR TRY_CAST(cl.FirstBilledDate    AS DATE) <= @FirstBilledTo)
        GROUP BY LTRIM(RTRIM(ISNULL(cl.PanelNew,'Unknown'))), LTRIM(RTRIM(ISNULL(cl.PayerName_Raw,'Unknown'))), w.WeekStart, w.WeekEnd, w.WeekLabel
    ),
    Ranks AS (
        SELECT  PanelNew, PayerName_Raw,
                DENSE_RANK() OVER (PARTITION BY PanelNew ORDER BY SUM(ClaimCount) DESC) AS PayerRank
        FROM    Agg GROUP BY PanelNew, PayerName_Raw
    ),
    PanelTotal AS (
        SELECT  PanelNew, WeekStart, WeekEnd, WeekLabel, SUM(ClaimCount) AS ClaimCount, SUM(TotalCharges) AS TotalCharges
        FROM    Agg GROUP BY PanelNew, WeekStart, WeekEnd, WeekLabel
    )
    SELECT  PanelName, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges
    FROM (
        SELECT  pt.PanelNew AS PanelName, N'' AS PayerName, CAST(0 AS TINYINT) AS PayerRank,
                pt.WeekStart, pt.WeekEnd, pt.WeekLabel, pt.ClaimCount, pt.TotalCharges
        FROM    PanelTotal pt
        UNION ALL
        SELECT  a.PanelNew AS PanelName, a.PayerName_Raw AS PayerName, CAST(r.PayerRank AS TINYINT) AS PayerRank,
                a.WeekStart, a.WeekEnd, a.WeekLabel, a.ClaimCount, a.TotalCharges
        FROM    Agg a JOIN Ranks r ON r.PanelNew = a.PanelNew AND r.PayerName_Raw = a.PayerName_Raw
    ) x
    ORDER BY WeekStart ASC, PanelName, PayerRank;
END
GO

-- ============================================================
-- Payer Breakdown (PayerName x Month)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_PayerBreakdown
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
        SELECT  PayerName, BilledYearMonth, ClaimCount, TotalCharges
        FROM    dbo.Aug_PayerBreakdown
        ORDER BY PayerName, BilledYearMonth;
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

    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))         AS PayerName,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM') AS BilledYearMonth,
        COUNT(*)                                               AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0) AS TotalCharges
    FROM   dbo.ClaimLevelData
    WHERE  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND  LTRIM(RTRIM(FirstBilledDate)) <> ''
      AND  (@HasPayerFilter   = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND  (@HasPanelFilter   = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService      AS DATE) >= @DosFrom)
      AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService      AS DATE) <= @DosTo)
      AND  (@FirstBillFrom    IS NULL OR TRY_CAST(ChargeEnteredDate  AS DATE) >= @FirstBillFrom)
      AND  (@FirstBillTo      IS NULL OR TRY_CAST(ChargeEnteredDate  AS DATE) <= @FirstBillTo)
      AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate    AS DATE) >= @FirstBilledFrom)
      AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate    AS DATE) <= @FirstBilledTo)
    GROUP BY LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))),
             FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
    ORDER BY PayerName, BilledYearMonth;
END
GO

-- ============================================================
-- Payer x Panel  (PayerName x PanelNew)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_PayerByPanel
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
        SELECT  PayerName, PanelType AS PanelName, ClaimCount, TotalCharges
        FROM    dbo.Aug_PayerByPanel
        ORDER BY PayerName, PanelName;
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

    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                              AS PayerName,
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)), ''), '(No PanelNew)')))   AS PanelName,
        COUNT(ClaimID)                                                              AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)                      AS TotalCharges
    FROM   dbo.ClaimLevelData
    WHERE  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND  LTRIM(RTRIM(FirstBilledDate)) <> ''
      AND  (@HasPayerFilter   = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND  (@HasPanelFilter   = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)), ''), '(No PanelNew)'))) IN (SELECT Value FROM @PanelList))
      AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService      AS DATE) >= @DosFrom)
      AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService      AS DATE) <= @DosTo)
      AND  (@FirstBillFrom    IS NULL OR TRY_CAST(ChargeEnteredDate  AS DATE) >= @FirstBillFrom)
      AND  (@FirstBillTo      IS NULL OR TRY_CAST(ChargeEnteredDate  AS DATE) <= @FirstBillTo)
      AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate    AS DATE) >= @FirstBilledFrom)
      AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate    AS DATE) <= @FirstBilledTo)
    GROUP BY LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))),
             LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)), ''), '(No PanelNew)')))
    ORDER BY PayerName, PanelName;
END
GO

-- ============================================================
-- Coding Breakdown (UNBILLED claims, PanelNew + CPT detail)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CodingBreakdown
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
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom         IS NOT NULL OR @DosTo         IS NOT NULL THEN 1
            WHEN @FirstBillFrom   IS NOT NULL OR @FirstBillTo   IS NOT NULL THEN 1
            WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  PanelName, ClaimCount, TotalCharges
        FROM    dbo.Aug_CodingPanelSummary ORDER BY TotalCharges DESC;

        SELECT  PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges
        FROM    dbo.Aug_CodingCPTDetail ORDER BY PanelName, TotalCharges DESC;
        RETURN;
    END

    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)), ''), '(No PanelNew)'))) AS PanelNew,
        LTRIM(RTRIM(ISNULL(CPTCodeXUnitsXModifier, '')))                          AS CPTDetail,
        COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''), NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS VisitKey,
        TRY_CAST(ChargeAmount AS DECIMAL(18,2))                                   AS Charge
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
      AND (@HasPanelFilter    = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)), ''), '(No PanelNew)'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom           IS NULL OR TRY_CAST(DateOfService      AS DATE) >= @DosFrom)
      AND (@DosTo             IS NULL OR TRY_CAST(DateOfService      AS DATE) <= @DosTo)
      AND (@FirstBillFrom     IS NULL OR TRY_CAST(ChargeEnteredDate  AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo       IS NULL OR TRY_CAST(ChargeEnteredDate  AS DATE) <= @FirstBillTo)
      AND (@FirstBilledFrom   IS NULL OR TRY_CAST(FirstBilledDate    AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo     IS NULL OR TRY_CAST(FirstBilledDate    AS DATE) <= @FirstBilledTo);

    SELECT  PanelNew AS PanelName, COUNT(VisitKey) AS ClaimCount, ISNULL(SUM(Charge), 0) AS TotalCharges
    FROM    #Raw GROUP BY PanelNew ORDER BY TotalCharges DESC;

    SELECT  PanelNew AS PanelName, CPTDetail AS CPTCodeXUnitsXModifier, COUNT(VisitKey) AS ClaimCount, ISNULL(SUM(Charge), 0) AS TotalCharges
    FROM    #Raw WHERE CPTDetail <> '' GROUP BY PanelNew, CPTDetail ORDER BY PanelName, TotalCharges DESC;

    DROP TABLE IF EXISTS #Raw;
END
GO

-- ============================================================
-- Unbilled Aging (PanelNew x Aging bucket)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_UnbilledAging
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
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom         IS NOT NULL OR @DosTo         IS NOT NULL THEN 1
            WHEN @FirstBillFrom   IS NOT NULL OR @FirstBillTo   IS NOT NULL THEN 1
            WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  PanelName, Aging AS AgingBucket, ClaimCount, TotalCharges
        FROM    dbo.Aug_UnbilledAging
        ORDER BY PanelName, AgingBucket;
        RETURN;
    END

    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)), ''), '(No PanelNew)'))) AS PanelName,
        ISNULL(LTRIM(RTRIM(Aging)), 'Unknown')                                    AS AgingBucket,
        COUNT(DISTINCT COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''), NULLIF(LTRIM(RTRIM(ClaimID)), ''))) AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)                    AS TotalCharges
    FROM   dbo.ClaimLevelData
    WHERE  (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
      AND  (@HasPanelFilter   = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)), ''), '(No PanelNew)'))) IN (SELECT Value FROM @PanelList))
      AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService      AS DATE) >= @DosFrom)
      AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService      AS DATE) <= @DosTo)
      AND  (@FirstBillFrom    IS NULL OR TRY_CAST(ChargeEnteredDate  AS DATE) >= @FirstBillFrom)
      AND  (@FirstBillTo      IS NULL OR TRY_CAST(ChargeEnteredDate  AS DATE) <= @FirstBillTo)
      AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate    AS DATE) >= @FirstBilledFrom)
      AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate    AS DATE) <= @FirstBilledTo)
    GROUP BY LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)), ''), '(No PanelNew)'))),
             ISNULL(LTRIM(RTRIM(Aging)), 'Unknown')
    ORDER BY PanelName, AgingBucket;
END
GO

-- ============================================================
-- CPT Breakdown (line-level)
--   Returns ClaimCount column (count of line rows) so the UI can
--   render a "No. of Claims" column alongside Billed Units / Charges.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CPTBreakdown
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
            WHEN @DosFrom         IS NOT NULL OR @DosTo         IS NOT NULL THEN 1
            WHEN @FirstBillFrom   IS NOT NULL OR @FirstBillTo   IS NOT NULL THEN 1
            WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges
        FROM    dbo.Aug_CPTBreakdown ORDER BY CPTCode, BilledYearMonth;
        RETURN;
    END

    SELECT
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown')))                AS CPTCode,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')  AS BilledYearMonth,
        COUNT(*)                                                AS CPTCount,
        ISNULL(SUM(TRY_CAST(Units        AS DECIMAL(18,2))), 0) AS BilledUnits,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    FROM   dbo.LineLevelData
    WHERE  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND  LTRIM(RTRIM(FirstBilledDate)) <> ''
      AND  NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
      AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService      AS DATE) >= @DosFrom)
      AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService      AS DATE) <= @DosTo)
      AND  (@FirstBillFrom    IS NULL OR TRY_CAST(ChargeEnteredDate  AS DATE) >= @FirstBillFrom)
      AND  (@FirstBillTo      IS NULL OR TRY_CAST(ChargeEnteredDate  AS DATE) <= @FirstBillTo)
      AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate    AS DATE) >= @FirstBilledFrom)
      AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate    AS DATE) <= @FirstBilledTo)
    GROUP BY LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown'))),
             FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
    ORDER BY CPTCode, BilledYearMonth;
END
GO

PRINT '14_Augustus_ReadSPs.sql completed.';
