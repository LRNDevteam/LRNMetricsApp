-- NorthWest Labs - UI Display (READ) Stored Procedures
-- Called by LabMetricsDashboard.SqlNorthWestProductionSummaryRepository /
-- used by the Production Summary Report page.
--
-- Each SP supports two execution paths (mirrors 14_Augustus_ReadSPs.sql):
--   1) NO filter parameters supplied  -> return rows from the pre-aggregated
--      snapshot table (NW_*) populated by the 05-09 refresh SPs.
--   2) ANY filter parameter supplied  -> aggregate live from
--      dbo.ClaimLevelData / dbo.LineLevelData using the same NorthWest
--      filter semantics (PanelType, ClaimStatus exclusion,
--      ChargeEnteredDate-based monthly/weekly groupings, Thu-Wed week boundary).
--
-- List parameters use '|' as the delimiter so payer/panel names that contain
-- commas are passed safely.
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Monthly Billed Production Summary (PanelType x Top-N Payer x Month)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_MonthlyBilledProductionSummary
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

    -- ?? No-filter fast path: serve the pre-aggregated snapshot ??????????????
    IF @HasFilter = 0
    BEGIN
        SELECT  PanelType        AS PanelName,
                PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
        FROM    dbo.NW_MonthlyBilledProductionSummary
        ORDER BY PanelName, BilledYearMonth, PayerRank;
        RETURN;
    END

    -- ?? Filter path: aggregate live from ClaimLevelData ?????????????????????
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

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH Agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PanelType,      'Unknown')))         AS PanelType,
            LTRIM(RTRIM(ISNULL(PayerName_Raw,  'Unknown')))         AS PayerName_Raw,
            FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')  AS BilledYearMonth,
            COUNT(*)                                                AS ClaimCount,
            ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)  AS TotalCharges
        FROM   dbo.ClaimLevelData
        WHERE  LTRIM(RTRIM(ClaimStatus)) NOT IN (
                   'Unbilled in Daq','Unbilled in Daq - PR',
                   'Unbilled in Webpm','Unbilled in Webpm - PR',
                   'Billed amount 0')
          AND  TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
          AND  NULLIF(LTRIM(RTRIM(PanelType)), '') IS NOT NULL
          AND  (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND  (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelType,   'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
          AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
          AND  (@FirstBillFrom    IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
          AND  (@FirstBillTo      IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
          AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
          AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(PanelType,     'Unknown'))),
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
    ),
    Ranks AS (
        SELECT  PanelType, PayerName_Raw,
                DENSE_RANK() OVER (PARTITION BY PanelType ORDER BY SUM(ClaimCount) DESC) AS PayerRank
        FROM    Agg
        GROUP BY PanelType, PayerName_Raw
    ),
    PanelTotal AS (
        SELECT  PanelType, BilledYearMonth,
                SUM(ClaimCount)   AS ClaimCount,
                SUM(TotalCharges) AS TotalCharges
        FROM    Agg
        GROUP BY PanelType, BilledYearMonth
    )
    SELECT  PanelName, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
    FROM (
        -- PayerRank = 0 : panel-level total across ALL payers
        SELECT  pt.PanelType        AS PanelName,
                N''                 AS PayerName,
                CAST(0 AS TINYINT)  AS PayerRank,
                pt.BilledYearMonth,
                pt.ClaimCount,
                pt.TotalCharges
        FROM    PanelTotal pt
        UNION ALL
        -- PayerRank >= 1 : ranked payer drill-down rows
        SELECT  a.PanelType         AS PanelName,
                a.PayerName_Raw     AS PayerName,
                CAST(r.PayerRank AS TINYINT) AS PayerRank,
                a.BilledYearMonth,
                a.ClaimCount,
                a.TotalCharges
        FROM    Agg a
        JOIN    Ranks r ON r.PanelType = a.PanelType AND r.PayerName_Raw = a.PayerName_Raw
    ) x
    ORDER BY PanelName, BilledYearMonth, PayerRank;
END
GO

-- ============================================================
-- Weekly Billed Production Summary (last 4 complete Thu-Wed weeks)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_WeeklyBilledProductionSummary
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

    -- ?? No-filter fast path ??????????????????????????????????????????????????
    IF @HasFilter = 0
    BEGIN
        SELECT  PanelType AS PanelName, PayerName, PayerRank,
                WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges
        FROM    dbo.NW_WeeklyBilledProductionSummary
        ORDER BY WeekStart ASC, PanelName, PayerRank;
        RETURN;
    END

    -- ?? Filter path ?????????????????????????????????????????????????????????
    -- NorthWest uses Thu-Wed week boundary. 1900-01-04 is a known Thursday.
    DECLARE @Today            DATE = CAST(GETDATE() AS DATE);
    DECLARE @ThisWeekThuStart DATE = DATEADD(day,
        -(DATEDIFF(day, '1900-01-04', @Today) % 7), @Today);

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

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    DECLARE @Weeks TABLE (
        WeekIndex INT NOT NULL PRIMARY KEY,
        WeekStart DATE NOT NULL,
        WeekEnd   DATE NOT NULL,
        WeekLabel NVARCHAR(32) NOT NULL
    );
    DECLARE @i INT = 1;
    WHILE @i <= 4
    BEGIN
        DECLARE @ws DATE = DATEADD(week, -@i, @ThisWeekThuStart);
        DECLARE @we DATE = DATEADD(day,   6,  @ws);   -- Thu + 6 = Wed
        INSERT INTO @Weeks (WeekIndex, WeekStart, WeekEnd, WeekLabel)
        VALUES (@i, @ws, @we, FORMAT(@ws, 'yyyy-MM-dd') + ' - ' + FORMAT(@we, 'yyyy-MM-dd'));
        SET @i += 1;
    END

    ;WITH Agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(cl.PanelType,     'Unknown')))         AS PanelType,
            LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown')))         AS PayerName_Raw,
            w.WeekStart, w.WeekEnd, w.WeekLabel,
            COUNT(*)                                                   AS ClaimCount,
            ISNULL(SUM(TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2))),0) AS TotalCharges
        FROM   dbo.ClaimLevelData cl
        JOIN   @Weeks w ON TRY_CAST(cl.ChargeEnteredDate AS DATE) BETWEEN w.WeekStart AND w.WeekEnd
        WHERE  LTRIM(RTRIM(cl.ClaimStatus)) NOT IN (
                   'Unbilled in Daq','Unbilled in Daq - PR',
                   'Unbilled in Webpm','Unbilled in Webpm - PR',
                   'Billed amount 0')
          AND  NULLIF(LTRIM(RTRIM(cl.PanelType)), '') IS NOT NULL
          AND  (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(cl.PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND  (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(cl.PanelType,   'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND  (@DosFrom          IS NULL OR TRY_CAST(cl.DateOfService     AS DATE) >= @DosFrom)
          AND  (@DosTo            IS NULL OR TRY_CAST(cl.DateOfService     AS DATE) <= @DosTo)
          AND  (@FirstBillFrom    IS NULL OR TRY_CAST(cl.ChargeEnteredDate AS DATE) >= @FirstBillFrom)
          AND  (@FirstBillTo      IS NULL OR TRY_CAST(cl.ChargeEnteredDate AS DATE) <= @FirstBillTo)
          AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(cl.FirstBilledDate   AS DATE) >= @FirstBilledFrom)
          AND  (@FirstBilledTo    IS NULL OR TRY_CAST(cl.FirstBilledDate   AS DATE) <= @FirstBilledTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(cl.PanelType,     'Unknown'))),
            LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown'))),
            w.WeekStart, w.WeekEnd, w.WeekLabel
    ),
    Ranks AS (
        SELECT  PanelType, PayerName_Raw,
                DENSE_RANK() OVER (PARTITION BY PanelType ORDER BY SUM(ClaimCount) DESC) AS PayerRank
        FROM    Agg
        GROUP BY PanelType, PayerName_Raw
    ),
    PanelTotal AS (
        SELECT  PanelType, WeekStart, WeekEnd, WeekLabel,
                SUM(ClaimCount)   AS ClaimCount,
                SUM(TotalCharges) AS TotalCharges
        FROM    Agg
        GROUP BY PanelType, WeekStart, WeekEnd, WeekLabel
    )
    SELECT  PanelName, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges
    FROM (
        SELECT  pt.PanelType        AS PanelName,
                N''                 AS PayerName,
                CAST(0 AS TINYINT)  AS PayerRank,
                pt.WeekStart, pt.WeekEnd, pt.WeekLabel,
                pt.ClaimCount, pt.TotalCharges
        FROM    PanelTotal pt
        UNION ALL
        SELECT  a.PanelType         AS PanelName,
                a.PayerName_Raw     AS PayerName,
                CAST(r.PayerRank AS TINYINT) AS PayerRank,
                a.WeekStart, a.WeekEnd, a.WeekLabel,
                a.ClaimCount, a.TotalCharges
        FROM    Agg a
        JOIN    Ranks r ON r.PanelType = a.PanelType AND r.PayerName_Raw = a.PayerName_Raw
    ) x
    ORDER BY WeekStart ASC, PanelName, PayerRank;
END
GO

-- ============================================================
-- Payer Breakdown (PayerName x Month)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_PayerBreakdown
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
        FROM    dbo.NW_PayerBreakdown
        ORDER BY PayerName, BilledYearMonth;
        RETURN;
    END

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

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))              AS PayerName,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')      AS BilledYearMonth,
        COUNT(*)                                                    AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)      AS TotalCharges
    FROM   dbo.ClaimLevelData
    WHERE  LTRIM(RTRIM(ClaimStatus)) NOT IN (
               'Unbilled in Daq','Unbilled in Daq - PR',
               'Unbilled in Webpm','Unbilled in Webpm - PR',
               'Billed amount 0')
      AND  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND  LTRIM(RTRIM(FirstBilledDate)) <> ''
      AND  (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND  (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)),''), ISNULL(PanelName,'Unknown')))) IN (SELECT Value FROM @PanelList))
      AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND  (@FirstBillFrom    IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
      AND  (@FirstBillTo      IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
      AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
    ORDER BY PayerName, BilledYearMonth;
END
GO

-- ============================================================
-- Payer x Panel  (PayerName x PanelType)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_PayerByPanel
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
        FROM    dbo.NW_PayerByPanel
        ORDER BY PayerName, PanelName;
        RETURN;
    END

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

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                      AS PayerName,
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)),''), ISNULL(PanelName,'Unknown')))) AS PanelName,
        COUNT(DISTINCT COALESCE(
            NULLIF(LTRIM(RTRIM(AccessionNumber)),''),
            NULLIF(LTRIM(RTRIM(ClaimID)),'')
        ))                                                                  AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)              AS TotalCharges
    FROM   dbo.ClaimLevelData
    WHERE  LTRIM(RTRIM(ClaimStatus)) NOT IN (
               'Unbilled in Daq','Unbilled in Daq - PR',
               'Unbilled in Webpm','Unbilled in Webpm - PR',
               'Billed amount 0')
      AND  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND  LTRIM(RTRIM(FirstBilledDate)) <> ''
      AND  (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND  (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)),''), ISNULL(PanelName,'Unknown')))) IN (SELECT Value FROM @PanelList))
      AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND  (@FirstBillFrom    IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
      AND  (@FirstBillTo      IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
      AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)),''), ISNULL(PanelName,'Unknown'))))
    ORDER BY PayerName, PanelName;
END
GO

-- ============================================================
-- Coding Breakdown (UNBILLED claims, PanelType + CPT detail)
-- Returns TWO result sets:
--   RS1: PanelName, ClaimCount, TotalCharges
--   RS2: PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CodingBreakdown
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
        FROM    dbo.NW_CodingPanelSummary
        ORDER BY TotalCharges DESC;

        SELECT  PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges
        FROM    dbo.NW_CodingCPTDetail
        ORDER BY PanelName, TotalCharges DESC;
        RETURN;
    END

    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)),''), ISNULL(PanelName,'Unknown')))) AS PanelNew,
        LTRIM(RTRIM(ISNULL(CPTCodeXUnitsXModifier, '')))                                      AS CPTDetail,
        COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)),''), NULLIF(LTRIM(RTRIM(ClaimID)),''))   AS VisitKey,
        TRY_CAST(ChargeAmount AS DECIMAL(18,2))                                               AS Charge
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE LTRIM(RTRIM(ClaimStatus)) IN ('Unbilled in Daq', 'Unbilled in Webpm')
      AND (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
      AND (@HasPanelFilter    = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)),''), ISNULL(PanelName,'Unknown')))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom           IS NULL OR TRY_CAST(DateOfService    AS DATE) >= @DosFrom)
      AND (@DosTo             IS NULL OR TRY_CAST(DateOfService    AS DATE) <= @DosTo)
      AND (@FirstBilledFrom   IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo     IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBilledTo);

    -- RS1: panel summary
    SELECT  PanelNew AS PanelName,
            COUNT(VisitKey)        AS ClaimCount,
            ISNULL(SUM(Charge), 0) AS TotalCharges
    FROM    #Raw
    GROUP BY PanelNew
    ORDER BY TotalCharges DESC;

    -- RS2: CPT detail
    SELECT  PanelNew AS PanelName,
            CPTDetail AS CPTCodeXUnitsXModifier,
            COUNT(VisitKey)        AS ClaimCount,
            ISNULL(SUM(Charge), 0) AS TotalCharges
    FROM    #Raw
    WHERE   CPTDetail <> ''
    GROUP BY PanelNew, CPTDetail
    ORDER BY PanelName, TotalCharges DESC;

    DROP TABLE IF EXISTS #Raw;
END
GO

-- ============================================================
-- Unbilled Aging (PayerName x Aging bucket)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_UnbilledAging
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
            WHEN @DosFrom         IS NOT NULL OR @DosTo         IS NOT NULL THEN 1
            WHEN @FirstBillFrom   IS NOT NULL OR @FirstBillTo   IS NOT NULL THEN 1
            WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  PayerName, Aging AS AgingBucket, ClaimCount, TotalCharges
        FROM    dbo.NW_UnbilledAging
        ORDER BY PayerName, AgingBucket;
        RETURN;
    END

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))            AS PayerName,
        ISNULL(LTRIM(RTRIM(Aging)), 'Unknown')                    AS AgingBucket,
        COUNT(*)                                                  AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)    AS TotalCharges
    FROM   dbo.ClaimLevelData
    WHERE  LTRIM(RTRIM(ClaimStatus)) IN ('Unbilled in Daq', 'Unbilled in Webpm')
      AND  (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
      AND  (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND  (@DosFrom         IS NULL OR TRY_CAST(DateOfService    AS DATE) >= @DosFrom)
      AND  (@DosTo           IS NULL OR TRY_CAST(DateOfService    AS DATE) <= @DosTo)
      AND  (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBilledFrom)
      AND  (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBilledTo)
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        ISNULL(LTRIM(RTRIM(Aging)), 'Unknown')
    ORDER BY PayerName, AgingBucket;
END
GO

-- ============================================================
-- CPT Breakdown (line-level: PayerName x Month)
-- ============================================================
CREATE   PROCEDURE dbo.usp_GetNW_CPTBreakdown  
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
        FROM    dbo.NW_CPTBreakdown ORDER BY CPTCode, BilledYearMonth;    
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
      AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService    AS DATE) >= @DosFrom)    
      AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService    AS DATE) <= @DosTo)    
      AND  (@FirstBillFrom    IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBillFrom)    
      AND  (@FirstBillTo      IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBillTo)    
      AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBilledFrom)    
      AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBilledTo)    
    GROUP BY LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown'))),    
             FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')    
    ORDER BY CPTCode, BilledYearMonth;    
END  
GO

/* =========================================================
   Raw Export SPs  (ClaimLevel + LineLevel)
   Bucketing column : FirstBilledDate
   Split logic      : total <= @Threshold  -> one ALL sheet
                      year > @Threshold    -> split by month
   ========================================================= */

/* ---- 1) ClaimLevel Buckets -------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetClaimLevelExportBuckets
    @Threshold        INT           = 50000,
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PanelNames       NVARCHAR(MAX) = NULL,
    @DosFrom          DATE          = NULL,
    @DosTo            DATE          = NULL,
    @CEDFrom          DATE          = NULL,
    @CEDTo            DATE          = NULL,
    @FirstBilledFrom  DATE          = NULL,
    @FirstBilledTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PayerList TABLE (Value NVARCHAR(200) NOT NULL);
    DECLARE @PanelList TABLE (Value NVARCHAR(200) NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    -- >>> CVEXP-ALL (2026-07-27): claim/line export must write EVERY row; the buckets are only
    --     for splitting into sheets. #Base now INCLUDES rows with a NULL/blank/unparseable
    --     FirstBilledDate (previously excluded, which silently dropped those claims).
    --     REVERT: restore FirstBilledDate DATE NOT NULL + the "WHERE ... IS NOT NULL" line.
    CREATE TABLE #Base
    (
        FirstBilledDate DATE          NULL,   -- CVEXP-ALL: was NOT NULL
        ClaimId         NVARCHAR(100) NULL
    );

    INSERT INTO #Base (FirstBilledDate, ClaimId)
    SELECT
        TRY_CAST(FirstBilledDate AS DATE),
        CAST(ClaimId AS NVARCHAR(100))
    FROM dbo.ClaimLevelData
    WHERE (@HasPayerFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))),200) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PanelType,'Unknown'))),200) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
      AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo);
    -- <<< END CVEXP-ALL

    DECLARE @cntClaim   INT = 0;
    DECLARE @cntUndated INT = 0;   -- CVEXP-ALL: rows with no usable FirstBilledDate
    SELECT @cntClaim   = COUNT(*) FROM #Base;
    SELECT @cntUndated = COUNT(*) FROM #Base WHERE FirstBilledDate IS NULL;

    CREATE TABLE #Buckets
    (
        BucketType   VARCHAR(20),
        YearNo       INT           NULL,
        MonthNo      INT           NULL,
        FromDate     DATE          NULL,
        ToDate       DATE          NULL,
        RecordCount  INT,
        SheetName    NVARCHAR(50)
    );

    IF (@cntClaim <= @Threshold)
    BEGIN
        -- CVEXP-ALL: single sheet holds EVERYTHING (dated + undated); data SP returns all rows for 'ALL'.
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        VALUES ('ALL', NULL, NULL, NULL, NULL, @cntClaim, 'All_Claim');
    END
    ELSE
    BEGIN
        ;WITH YearCounts AS
        (
            SELECT YEAR(FirstBilledDate) AS YearNo, COUNT(*) AS RecordCount
            FROM #Base
            WHERE FirstBilledDate IS NOT NULL   -- CVEXP-ALL: undated rows handled by the UNDATED bucket below
            GROUP BY YEAR(FirstBilledDate)
        )
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        SELECT 'YEAR', yc.YearNo, NULL,
               DATEFROMPARTS(yc.YearNo, 1, 1),
               DATEFROMPARTS(yc.YearNo, 12, 31),
               yc.RecordCount,
               -- CVEXP-ALL: placeholder/garbage dates that parse to year 1900 are labelled 'Other_' instead of '1900_'.
               CASE WHEN yc.YearNo <= 1900 THEN 'Other' ELSE CAST(yc.YearNo AS VARCHAR(4)) END + '_Claim'
        FROM YearCounts yc
        WHERE yc.RecordCount <= @Threshold;

        ;WITH LargeYears AS
        (
            SELECT YEAR(FirstBilledDate) AS YearNo
            FROM #Base
            WHERE FirstBilledDate IS NOT NULL   -- CVEXP-ALL
            GROUP BY YEAR(FirstBilledDate)
            HAVING COUNT(*) > @Threshold
        ),
        MonthCounts AS
        (
            SELECT YEAR(b.FirstBilledDate) AS YearNo,
                   MONTH(b.FirstBilledDate) AS MonthNo,
                   COUNT(*) AS RecordCount
            FROM #Base b
            INNER JOIN LargeYears y ON YEAR(b.FirstBilledDate) = y.YearNo
            GROUP BY YEAR(b.FirstBilledDate), MONTH(b.FirstBilledDate)
        )
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        SELECT 'MONTH', mc.YearNo, mc.MonthNo,
               DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1),
               EOMONTH(DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1)),
               mc.RecordCount,
               LEFT(DATENAME(MONTH, DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1)), 3)
                   + CAST(mc.YearNo AS VARCHAR(4)) + '_Claim'
        FROM MonthCounts mc;

        -- >>> CVEXP-ALL (2026-07-27): dedicated sheet for rows with no usable FirstBilledDate,
        --     so the split path never drops them. REVERT: delete this IF block.
        IF (@cntUndated > 0)
            INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
            VALUES ('UNDATED', NULL, NULL, NULL, NULL, @cntUndated, 'Undated_Claim');
        -- <<< END CVEXP-ALL
    END

    SELECT BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName
    FROM #Buckets
    ORDER BY CASE WHEN YearNo IS NULL THEN 1 ELSE 0 END, YearNo DESC, MonthNo ASC;
END
GO

/* ---- 2) ClaimLevel Data By Date Range -------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetClaimLevelExportDataByDateRange
    @FromDate         DATE          = NULL,   -- CVEXP-ALL: nullable now (ALL/UNDATED buckets pass no dates)
    @ToDate           DATE          = NULL,
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PanelNames       NVARCHAR(MAX) = NULL,
    @DosFrom          DATE          = NULL,
    @DosTo            DATE          = NULL,
    @CEDFrom          DATE          = NULL,
    @CEDTo            DATE          = NULL,
    @FirstBilledFrom  DATE          = NULL,
    @FirstBilledTo    DATE          = NULL,
    @BucketType       VARCHAR(20)   = 'RANGE'  -- CVEXP-ALL: 'ALL' = every row, 'UNDATED' = null-date rows, else date range
AS
BEGIN
    SET NOCOUNT ON;

    -- >>> CVEXP-ALL (2026-07-27): only the date-RANGE buckets need From/To. ALL and UNDATED
    --     buckets deliberately pass no dates. REVERT: restore the unconditional NULL check.
    IF @BucketType NOT IN ('ALL','UNDATED') AND (@FromDate IS NULL OR @ToDate IS NULL)
    BEGIN
        -- CVEXP-ALL: backward-compat — a pre-fix caller (e.g. an un-rebuilt ClaimLineCSVDataCapture)
        -- that receives the new UNDATED bucket passes null dates without @BucketType. Return an
        -- empty set instead of raising, so deploying these SPs never disturbs that app.
        RETURN;
    END;

    IF @BucketType NOT IN ('ALL','UNDATED') AND @FromDate > @ToDate
    BEGIN
        RAISERROR('FromDate cannot be greater than ToDate.', 16, 1);
        RETURN;
    END;
    -- <<< END CVEXP-ALL

    DECLARE @PayerList TABLE (Value NVARCHAR(200) NOT NULL);
    DECLARE @PanelList TABLE (Value NVARCHAR(200) NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT *
    FROM dbo.ClaimLevelData
    -- >>> CVEXP-ALL (2026-07-27): row inclusion by bucket type.
    --     ALL     -> every row (no FirstBilledDate filter)
    --     UNDATED -> only rows with no usable FirstBilledDate
    --     RANGE   -> original date-range slice
    --     REVERT: restore the two-line FirstBilledDate BETWEEN predicate.
    WHERE (
              @BucketType = 'ALL'
           OR (@BucketType = 'UNDATED' AND TRY_CAST(FirstBilledDate AS DATE) IS NULL)
           OR (@BucketType NOT IN ('ALL','UNDATED')
               AND TRY_CAST(FirstBilledDate AS DATE) >= @FromDate
               AND TRY_CAST(FirstBilledDate AS DATE) < DATEADD(DAY, 1, @ToDate))
          )
    -- <<< END CVEXP-ALL
      AND (@HasPayerFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))),200) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PanelType,'Unknown'))),200) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
      AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
    ORDER BY TRY_CAST(FirstBilledDate AS DATE), ClaimId;
END
GO

/* ---- 3) LineLevel Buckets --------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetLineLevelExportBuckets
    @Threshold        INT           = 50000,
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PanelNames       NVARCHAR(MAX) = NULL,
    @DosFrom          DATE          = NULL,
    @DosTo            DATE          = NULL,
    @CEDFrom          DATE          = NULL,
    @CEDTo            DATE          = NULL,
    @FirstBilledFrom  DATE          = NULL,
    @FirstBilledTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PayerList TABLE (Value NVARCHAR(200) NOT NULL);
    DECLARE @PanelList TABLE (Value NVARCHAR(200) NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    -- >>> CVEXP-ALL (2026-07-27): include rows with NULL/blank/unparseable FirstBilledDate so no line is dropped.
    --     REVERT: restore FirstBilledDate DATE NOT NULL + the "WHERE ... IS NOT NULL" line.
    CREATE TABLE #Base
    (
        FirstBilledDate DATE          NULL,   -- CVEXP-ALL: was NOT NULL
        ClaimId         NVARCHAR(100) NULL
    );

    INSERT INTO #Base (FirstBilledDate, ClaimId)
    SELECT
        TRY_CAST(FirstBilledDate AS DATE),
        CAST(ClaimId AS NVARCHAR(100))
    FROM dbo.LineLevelData
    WHERE (@HasPayerFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))),200) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))),200) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
      AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo);
    -- <<< END CVEXP-ALL

    DECLARE @cntLine    INT = 0;
    DECLARE @cntUndated INT = 0;   -- CVEXP-ALL
    SELECT @cntLine    = COUNT(*) FROM #Base;
    SELECT @cntUndated = COUNT(*) FROM #Base WHERE FirstBilledDate IS NULL;

    CREATE TABLE #Buckets
    (
        BucketType   VARCHAR(20),
        YearNo       INT           NULL,
        MonthNo      INT           NULL,
        FromDate     DATE          NULL,
        ToDate       DATE          NULL,
        RecordCount  INT,
        SheetName    NVARCHAR(50)
    );

    IF (@cntLine <= @Threshold)
    BEGIN
        -- CVEXP-ALL: single sheet holds EVERYTHING (dated + undated); data SP returns all rows for 'ALL'.
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        VALUES ('ALL', NULL, NULL, NULL, NULL, @cntLine, 'All_Line');
    END
    ELSE
    BEGIN
        ;WITH YearCounts AS
        (
            SELECT YEAR(FirstBilledDate) AS YearNo, COUNT(*) AS RecordCount
            FROM #Base
            WHERE FirstBilledDate IS NOT NULL   -- CVEXP-ALL: undated rows handled by the UNDATED bucket below
            GROUP BY YEAR(FirstBilledDate)
        )
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        SELECT 'YEAR', yc.YearNo, NULL,
               DATEFROMPARTS(yc.YearNo, 1, 1),
               DATEFROMPARTS(yc.YearNo, 12, 31),
               yc.RecordCount,
               -- CVEXP-ALL: placeholder/garbage dates that parse to year 1900 are labelled 'Other_' instead of '1900_'.
               CASE WHEN yc.YearNo <= 1900 THEN 'Other' ELSE CAST(yc.YearNo AS VARCHAR(4)) END + '_Line'
        FROM YearCounts yc
        WHERE yc.RecordCount <= @Threshold;

        ;WITH LargeYears AS
        (
            SELECT YEAR(FirstBilledDate) AS YearNo
            FROM #Base
            WHERE FirstBilledDate IS NOT NULL   -- CVEXP-ALL
            GROUP BY YEAR(FirstBilledDate)
            HAVING COUNT(*) > @Threshold
        ),
        MonthCounts AS
        (
            SELECT YEAR(b.FirstBilledDate) AS YearNo,
                   MONTH(b.FirstBilledDate) AS MonthNo,
                   COUNT(*) AS RecordCount
            FROM #Base b
            INNER JOIN LargeYears y ON YEAR(b.FirstBilledDate) = y.YearNo
            GROUP BY YEAR(b.FirstBilledDate), MONTH(b.FirstBilledDate)
        )
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        SELECT 'MONTH', mc.YearNo, mc.MonthNo,
               DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1),
               EOMONTH(DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1)),
               mc.RecordCount,
               LEFT(DATENAME(MONTH, DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1)), 3)
                   + CAST(mc.YearNo AS VARCHAR(4)) + '_Line'
        FROM MonthCounts mc;

        -- >>> CVEXP-ALL (2026-07-27): dedicated sheet for rows with no usable FirstBilledDate.
        --     REVERT: delete this IF block.
        IF (@cntUndated > 0)
            INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
            VALUES ('UNDATED', NULL, NULL, NULL, NULL, @cntUndated, 'Undated_Line');
        -- <<< END CVEXP-ALL
    END

    SELECT BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName
    FROM #Buckets
    ORDER BY CASE WHEN YearNo IS NULL THEN 1 ELSE 0 END, YearNo DESC, MonthNo ASC;
END
GO

/* ---- 4) LineLevel Data By Date Range --------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetLineLevelExportDataByDateRange
    @FromDate         DATE          = NULL,   -- CVEXP-ALL: nullable now (ALL/UNDATED buckets pass no dates)
    @ToDate           DATE          = NULL,
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PanelNames       NVARCHAR(MAX) = NULL,
    @DosFrom          DATE          = NULL,
    @DosTo            DATE          = NULL,
    @CEDFrom          DATE          = NULL,
    @CEDTo            DATE          = NULL,
    @FirstBilledFrom  DATE          = NULL,
    @FirstBilledTo    DATE          = NULL,
    @BucketType       VARCHAR(20)   = 'RANGE'  -- CVEXP-ALL: 'ALL' = every row, 'UNDATED' = null-date rows, else date range
AS
BEGIN
    SET NOCOUNT ON;

    -- >>> CVEXP-ALL (2026-07-27): only date-RANGE buckets need From/To. REVERT: restore unconditional NULL check.
    IF @BucketType NOT IN ('ALL','UNDATED') AND (@FromDate IS NULL OR @ToDate IS NULL)
    BEGIN
        -- CVEXP-ALL: backward-compat — a pre-fix caller (e.g. an un-rebuilt ClaimLineCSVDataCapture)
        -- that receives the new UNDATED bucket passes null dates without @BucketType. Return an
        -- empty set instead of raising, so deploying these SPs never disturbs that app.
        RETURN;
    END;

    IF @BucketType NOT IN ('ALL','UNDATED') AND @FromDate > @ToDate
    BEGIN
        RAISERROR('FromDate cannot be greater than ToDate.', 16, 1);
        RETURN;
    END;
    -- <<< END CVEXP-ALL

    DECLARE @PayerList TABLE (Value NVARCHAR(200) NOT NULL);
    DECLARE @PanelList TABLE (Value NVARCHAR(200) NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT *
    FROM dbo.LineLevelData
    -- >>> CVEXP-ALL (2026-07-27): ALL = every row, UNDATED = null-date rows, RANGE = date slice.
    --     REVERT: restore the two-line FirstBilledDate BETWEEN predicate.
    WHERE (
              @BucketType = 'ALL'
           OR (@BucketType = 'UNDATED' AND TRY_CAST(FirstBilledDate AS DATE) IS NULL)
           OR (@BucketType NOT IN ('ALL','UNDATED')
               AND TRY_CAST(FirstBilledDate AS DATE) >= @FromDate
               AND TRY_CAST(FirstBilledDate AS DATE) < DATEADD(DAY, 1, @ToDate))
          )
    -- <<< END CVEXP-ALL
      AND (@HasPayerFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))),200) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))),200) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
      AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
    ORDER BY TRY_CAST(FirstBilledDate AS DATE), ClaimId;
END
GO

PRINT '14_NorthWest_ReadSPs.sql completed.';
-- usp_GetNW_ClaimLevelExportBuckets  : returns date-range slices for ClaimLevelData
-- usp_GetNW_LineLevelExportBuckets   : returns date-range slices for LineLevelData
-- usp_GetNW_ClaimLevelExportByRange  : returns ClaimLevelData rows for one slice
-- usp_GetNW_LineLevelExportByRange   : returns LineLevelData rows for one slice
--
-- Bucketing column : ChargeEnteredDate (NW Rule4 convention)
-- Split logic      : total <= @Threshold  -> one "ALL" sheet
--                    else group by year;  year > @Threshold -> split by month
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_ClaimLevelExportBuckets
    @Threshold       INT           = 300000,
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @CEDFrom         DATE          = NULL,
    @CEDTo           DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)),'') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames,'|') WHERE NULLIF(LTRIM(RTRIM(value)),'') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)),'') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames,'|') WHERE NULLIF(LTRIM(RTRIM(value)),'') IS NOT NULL;

    DECLARE @HasPayer BIT = CASE WHEN EXISTS(SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanel BIT = CASE WHEN EXISTS(SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    -- Resolve effective panel expression (PanelType with PanelName fallback)
    SELECT
        TRY_CAST(ChargeEnteredDate AS DATE)                                        AS CED,
        YEAR(TRY_CAST(ChargeEnteredDate AS DATE))                                  AS YearNo,
        MONTH(TRY_CAST(ChargeEnteredDate AS DATE))                                 AS MonthNo
    INTO #Base
    FROM dbo.ClaimLevelData
    WHERE LTRIM(RTRIM(ClaimStatus)) NOT IN (
              'Unbilled in Daq','Unbilled in Daq - PR',
              'Unbilled in Webpm','Unbilled in Webpm - PR','Billed amount 0')
      AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)),''), ISNULL(PanelName,'')))), '') IS NOT NULL
      AND (@HasPayer = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanel = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)),''), ISNULL(PanelName,'Unknown')))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom        IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo          IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@CEDFrom        IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
      AND (@CEDTo          IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBilledTo);

    DECLARE @Total BIGINT = (SELECT COUNT(*) FROM #Base);

    IF @Total = 0 OR @Total <= @Threshold
    BEGIN
        SELECT 'ALL'               AS BucketType,
               NULL                AS YearNo,
               NULL                AS MonthNo,
               CAST(MIN(CED) AS DATETIME) AS FromDate,
               CAST(MAX(CED) AS DATETIME) AS ToDate,
               CAST(@Total AS INT) AS RecordCount,
               'ClaimLevel'        AS SheetName
        FROM #Base;
        DROP TABLE #Base;
        RETURN;
    END

    SELECT YearNo, COUNT(*) AS Cnt, MIN(CED) AS YMin, MAX(CED) AS YMax
    INTO #Yr FROM #Base GROUP BY YearNo;

    SELECT b.YearNo, b.MonthNo, COUNT(*) AS Cnt, MIN(b.CED) AS MMin, MAX(b.CED) AS MMax
    INTO #Mo FROM #Base b
    JOIN #Yr y ON y.YearNo = b.YearNo AND y.Cnt > @Threshold
    GROUP BY b.YearNo, b.MonthNo;

    SELECT
        CASE WHEN y.Cnt > @Threshold THEN 'MONTH' ELSE 'YEAR' END AS BucketType,
        y.YearNo,
        NULL AS MonthNo,
        CAST(y.YMin AS DATETIME) AS FromDate,
        CAST(y.YMax AS DATETIME) AS ToDate,
        CAST(y.Cnt AS INT)       AS RecordCount,
        CAST(y.YearNo AS NVARCHAR(4)) + '_ClaimLevel' AS SheetName
    FROM #Yr y WHERE y.Cnt <= @Threshold
    UNION ALL
    SELECT
        'MONTH' AS BucketType,
        m.YearNo,
        m.MonthNo,
        CAST(m.MMin AS DATETIME) AS FromDate,
        CAST(m.MMax AS DATETIME) AS ToDate,
        CAST(m.Cnt AS INT)       AS RecordCount,
        CAST(m.YearNo AS NVARCHAR(4)) + '_' + RIGHT('0' + CAST(m.MonthNo AS NVARCHAR(2)), 2) + '_ClaimLevel' AS SheetName
    FROM #Mo m
    ORDER BY YearNo, MonthNo;

    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Yr;
    DROP TABLE IF EXISTS #Mo;
END
GO

-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_LineLevelExportBuckets
    @Threshold       INT           = 300000,
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @CEDFrom         DATE          = NULL,
    @CEDTo           DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)),'') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames,'|') WHERE NULLIF(LTRIM(RTRIM(value)),'') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)),'') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames,'|') WHERE NULLIF(LTRIM(RTRIM(value)),'') IS NOT NULL;

    DECLARE @HasPayer BIT = CASE WHEN EXISTS(SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanel BIT = CASE WHEN EXISTS(SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        TRY_CAST(ChargeEnteredDate AS DATE)       AS CED,
        YEAR(TRY_CAST(ChargeEnteredDate AS DATE))  AS YearNo,
        MONTH(TRY_CAST(ChargeEnteredDate AS DATE)) AS MonthNo
    INTO #Base
    FROM dbo.LineLevelData
    WHERE TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
      AND (@HasPayer = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanel = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom        IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo          IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@CEDFrom        IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
      AND (@CEDTo          IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBilledTo);

    DECLARE @Total BIGINT = (SELECT COUNT(*) FROM #Base);

    IF @Total = 0 OR @Total <= @Threshold
    BEGIN
        SELECT 'ALL'               AS BucketType,
               NULL                AS YearNo,
               NULL                AS MonthNo,
               CAST(MIN(CED) AS DATETIME) AS FromDate,
               CAST(MAX(CED) AS DATETIME) AS ToDate,
               CAST(@Total AS INT) AS RecordCount,
               'LineLevel'         AS SheetName
        FROM #Base;
        DROP TABLE #Base;
        RETURN;
    END

    SELECT YearNo, COUNT(*) AS Cnt, MIN(CED) AS YMin, MAX(CED) AS YMax
    INTO #Yr FROM #Base GROUP BY YearNo;

    SELECT b.YearNo, b.MonthNo, COUNT(*) AS Cnt, MIN(b.CED) AS MMin, MAX(b.CED) AS MMax
    INTO #Mo FROM #Base b
    JOIN #Yr y ON y.YearNo = b.YearNo AND y.Cnt > @Threshold
    GROUP BY b.YearNo, b.MonthNo;

    SELECT
        CASE WHEN y.Cnt > @Threshold THEN 'MONTH' ELSE 'YEAR' END AS BucketType,
        y.YearNo,
        NULL AS MonthNo,
        CAST(y.YMin AS DATETIME) AS FromDate,
        CAST(y.YMax AS DATETIME) AS ToDate,
        CAST(y.Cnt AS INT)       AS RecordCount,
        CAST(y.YearNo AS NVARCHAR(4)) + '_LineLevel' AS SheetName
    FROM #Yr y WHERE y.Cnt <= @Threshold
    UNION ALL
    SELECT
        'MONTH' AS BucketType,
        m.YearNo,
        m.MonthNo,
        CAST(m.MMin AS DATETIME) AS FromDate,
        CAST(m.MMax AS DATETIME) AS ToDate,
        CAST(m.Cnt AS INT)       AS RecordCount,
        CAST(m.YearNo AS NVARCHAR(4)) + '_' + RIGHT('0' + CAST(m.MonthNo AS NVARCHAR(2)), 2) + '_LineLevel' AS SheetName
    FROM #Mo m
    ORDER BY YearNo, MonthNo;

    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Yr;
    DROP TABLE IF EXISTS #Mo;
END
GO

-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_ClaimLevelExportByRange
    @FromDate        DATE          = NULL,
    @ToDate          DATE          = NULL,
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @CEDFrom         DATE          = NULL,
    @CEDTo           DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)),'') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames,'|') WHERE NULLIF(LTRIM(RTRIM(value)),'') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)),'') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames,'|') WHERE NULLIF(LTRIM(RTRIM(value)),'') IS NOT NULL;

    DECLARE @HasPayer BIT = CASE WHEN EXISTS(SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanel BIT = CASE WHEN EXISTS(SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        [ClaimID],[AccessionNumber],[PayerName],[PayerType],[BillingProvider],[ReferringProvider],
        [ClinicName],[SalesRepname],[PatientID],[PatientDOB],[DateofService],[ChargeEnteredDate],
        [FirstBilledDate],[Panelname],[CPTCodeXUnitsXModifier],[POS],[TOS],[ChargeAmount],[AllowedAmount],
        [InsurancePayment],[PatientPayment],[TotalPayments],[InsuranceAdjustments],[PatientAdjustments],
        [TotalAdjustments],[InsuranceBalance],[PatientBalance],[TotalBalance],[CheckDate],[ClaimStatus],
        [DenialCode],[ICDCode],[DaystoDOS],[RollingDays],[DaystoBill],[DaystoPost],[ICDPointer],[InsertedDateTime]
    FROM dbo.ClaimLevelData
    WHERE LTRIM(RTRIM(ClaimStatus)) NOT IN (
              'Unbilled in Daq','Unbilled in Daq - PR',
              'Unbilled in Webpm','Unbilled in Webpm - PR','Billed amount 0')
      AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)),''), ISNULL(PanelName,'')))), '') IS NOT NULL
      AND (@FromDate IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FromDate)
      AND (@ToDate   IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @ToDate)
      AND (@HasPayer = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanel = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)),''), ISNULL(PanelName,'Unknown')))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom        IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo          IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@CEDFrom        IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
      AND (@CEDTo          IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBilledTo)
    ORDER BY TRY_CAST(ChargeEnteredDate AS DATE), ClaimID, AccessionNumber;
END
GO

-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_LineLevelExportByRange
    @FromDate        DATE          = NULL,
    @ToDate          DATE          = NULL,
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @CEDFrom         DATE          = NULL,
    @CEDTo           DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)),'') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames,'|') WHERE NULLIF(LTRIM(RTRIM(value)),'') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)),'') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames,'|') WHERE NULLIF(LTRIM(RTRIM(value)),'') IS NOT NULL;

    DECLARE @HasPayer BIT = CASE WHEN EXISTS(SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanel BIT = CASE WHEN EXISTS(SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        [ClaimID],[AccessionNumber],[PayerName],[PayerType],[BillingProvider],[ReferringProvider],
        [ClinicName],[SalesRepname],[PatientID],[PatientDOB],[DateofService],[ChargeEnteredDate],
        [FirstBilledDate],[Panelname],[CPTCode],[Units],[Modifier],[POS],[TOS],
        [ChargeAmount],[ChargeAmountPerUnit],[AllowedAmount],[AllowedAmountPerUnit],
        [InsurancePayment],[InsurancePaymentPerUnit],[PatientPayment],[PatientPaymentPerUnit],
        [TotalPayments],[InsuranceAdjustments],[PatientAdjustments],[TotalAdjustments],
        [InsuranceBalance],[PatientBalance],[PatientBalancePerUnit],[TotalBalance],
        [CheckDate],[PostingDate],[ClaimStatus],[PayStatus],[DenialCode],[DenialDate],
        [ICDCode],[DaystoDOS],[RollingDays],[DaystoBill],[DaystoPost],[ICDPointer]
    FROM dbo.LineLevelData
    WHERE TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
      AND (@FromDate IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FromDate)
      AND (@ToDate   IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @ToDate)
      AND (@HasPayer = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanel = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom        IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo          IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@CEDFrom        IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
      AND (@CEDTo          IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBilledTo)
    ORDER BY TRY_CAST(ChargeEnteredDate AS DATE), ClaimID, AccessionNumber;
END
GO

PRINT '14_NorthWest_ReadSPs.sql completed.';
