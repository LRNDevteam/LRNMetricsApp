-- PhiLife — Read Stored Procedures for the Production Summary Report tabs.
-- Called by LabMetricsDashboard.SqlLabProductionSummaryRepository.
--
-- Each SP supports two execution paths:
--   1) NO filter parameters supplied  -> return rows from the pre-aggregated snapshot
--      table (fast path).
--   2) ANY filter parameter supplied  -> aggregate live from dbo.ClaimLevelData /
--      dbo.LineLevelData using the same filter semantics as the Refresh SPs.
--
-- List parameters use '|' as the delimiter so payer/panel names that contain
-- commas are passed safely.
--
-- Source routing notes (PhiLife inverted structure):
--   ClaimLevelData : has individual CPTCode/Units, CheckDate, FirstBilledDate,
--                    ChargeEnteredDate, InsurancePayment, ChargeAmount, ClaimID
--   LineLevelData  : has CPTCodeXUnitsXModifier, AgingBucket, BilledUnbilled,
--                    FirstBilledDate, ChargeEnteredDate, ChargeAmount
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Monthly Billed Production Summary
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPhi_MonthlyBilledProductionSummary
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
        SELECT  PanelType AS PanelName,
                PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
        FROM    dbo.Phi_MonthlyBilledProductionSummary
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
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))         AS Panelname,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))         AS PayerName_Raw,
            FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM') AS BilledYearMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))      AS ClaimCount,
            ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0) AS TotalCharges
        FROM   dbo.ClaimLevelData
        WHERE  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
          AND  LTRIM(RTRIM(FirstBilledDate)) <> ''
          AND  PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''
          AND  TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
          AND  (@HasPayerFilter   = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND  (@HasPanelFilter   = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND  (@FirstBillFrom    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND  (@FirstBillTo      IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
          AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))),
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
    ),
    Ranks AS (
        SELECT  Panelname, PayerName_Raw,
                DENSE_RANK() OVER (PARTITION BY Panelname ORDER BY SUM(ClaimCount) DESC) AS PayerRank
        FROM    Agg GROUP BY Panelname, PayerName_Raw
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
        SELECT  a.Panelname AS PanelName, a.PayerName_Raw AS PayerName, CAST(r.PayerRank AS TINYINT) AS PayerRank,
                a.BilledYearMonth, a.ClaimCount, a.TotalCharges
        FROM    Agg a JOIN Ranks r ON r.Panelname = a.Panelname AND r.PayerName_Raw = a.PayerName_Raw
    ) x
    ORDER BY PanelName, BilledYearMonth, PayerRank;
END
GO

-- ============================================================
-- Weekly Billed Production Summary (last 4 complete Thu-Wed weeks)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPhi_WeeklyBilledProductionSummary
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
        FROM    dbo.Phi_WeeklyBilledProductionSummary
        ORDER BY WeekStart ASC, PanelName, PayerRank;
        RETURN;
    END

    DECLARE @Today            DATE = CAST(GETDATE() AS DATE);
    -- Thu-Wed anchor: 1900-01-04 is Thursday
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
            LTRIM(RTRIM(ISNULL(cl.Panelname,     'Unknown')))         AS Panelname,
            LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown')))         AS PayerName_Raw,
            w.WeekStart, w.WeekEnd, w.WeekLabel,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(cl.ClaimID)), ''))      AS ClaimCount,
            ISNULL(SUM(TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2))),0) AS TotalCharges
        FROM   dbo.ClaimLevelData cl
        JOIN   @Weeks w ON TRY_CAST(cl.ChargeEnteredDate AS DATE) BETWEEN w.WeekStart AND w.WeekEnd
        WHERE  TRY_CAST(cl.FirstBilledDate AS DATE) IS NOT NULL
          AND  LTRIM(RTRIM(cl.FirstBilledDate)) <> ''
          AND  cl.PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(cl.PayerName_Raw)) <> ''
          AND  (@HasPayerFilter   = 0 OR LTRIM(RTRIM(cl.PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND  (@HasPanelFilter   = 0 OR LTRIM(RTRIM(ISNULL(cl.Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND  (@DosFrom          IS NULL OR TRY_CAST(cl.DateOfService   AS DATE) >= @DosFrom)
          AND  (@DosTo            IS NULL OR TRY_CAST(cl.DateOfService   AS DATE) <= @DosTo)
          AND  (@FirstBillFrom    IS NULL OR TRY_CAST(cl.FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND  (@FirstBillTo      IS NULL OR TRY_CAST(cl.FirstBilledDate AS DATE) <= @FirstBillTo)
          AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(cl.FirstBilledDate AS DATE) >= @FirstBilledFrom)
          AND  (@FirstBilledTo    IS NULL OR TRY_CAST(cl.FirstBilledDate AS DATE) <= @FirstBilledTo)
        GROUP BY LTRIM(RTRIM(ISNULL(cl.Panelname,'Unknown'))), LTRIM(RTRIM(ISNULL(cl.PayerName_Raw,'Unknown'))),
                 w.WeekStart, w.WeekEnd, w.WeekLabel
    ),
    Ranks AS (
        SELECT  Panelname, PayerName_Raw,
                DENSE_RANK() OVER (PARTITION BY Panelname ORDER BY SUM(ClaimCount) DESC) AS PayerRank
        FROM    Agg GROUP BY Panelname, PayerName_Raw
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
        SELECT  a.Panelname AS PanelName, a.PayerName_Raw AS PayerName, CAST(r.PayerRank AS TINYINT) AS PayerRank,
                a.WeekStart, a.WeekEnd, a.WeekLabel, a.ClaimCount, a.TotalCharges
        FROM    Agg a JOIN Ranks r ON r.Panelname = a.Panelname AND r.PayerName_Raw = a.PayerName_Raw
    ) x
    ORDER BY WeekStart ASC, PanelName, PayerRank;
END
GO

-- ============================================================
-- Payer Breakdown
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPhi_PayerBreakdown
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
        FROM    dbo.Phi_PayerBreakdown
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
        LTRIM(RTRIM(PayerName_Raw))                             AS PayerName,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')  AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))       AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)  AS TotalCharges
    FROM   dbo.ClaimLevelData
    WHERE  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND  LTRIM(RTRIM(FirstBilledDate)) <> ''
      AND  PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''
      AND  TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
      AND  (@HasPayerFilter   = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
      AND  (@HasPanelFilter   = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND  (@FirstBillFrom    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND  (@FirstBillTo      IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
      AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
    GROUP BY LTRIM(RTRIM(PayerName_Raw)), FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
    ORDER BY PayerName, BilledYearMonth;
END
GO

-- ============================================================
-- Payer × Panel
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPhi_PayerByPanel
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
        FROM    dbo.Phi_PayerByPanel
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
        LTRIM(RTRIM(PayerName_Raw))                                                  AS PayerName,
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) AS PanelName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                            AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)                       AS TotalCharges
    FROM   dbo.ClaimLevelData
    WHERE  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND  LTRIM(RTRIM(FirstBilledDate)) <> ''
      AND  PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''
      AND  (@HasPayerFilter   = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
      AND  (@HasPanelFilter   = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) IN (SELECT Value FROM @PanelList))
      AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND  (@FirstBillFrom    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND  (@FirstBillTo      IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
      AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
    GROUP BY LTRIM(RTRIM(PayerName_Raw)),
             LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')))
    ORDER BY PayerName, PanelName;
END
GO

-- ============================================================
-- Coding Breakdown (BILLED claims) — LineLevelData
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPhi_CodingBreakdown
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
        FROM    dbo.Phi_CodingPanelSummary ORDER BY TotalCharges DESC;

        SELECT  PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges
        FROM    dbo.Phi_CodingCPTDetail ORDER BY PanelName, TotalCharges DESC;
        RETURN;
    END

    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) AS Panelname,
        LTRIM(RTRIM(ISNULL(CPTCodeXUnitsXModifier, '')))                            AS CPTDetail,
        COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''), NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS VisitKey,
        TRY_CAST(ChargeAmount AS DECIMAL(18,2))                                      AS Charge
    INTO #Raw
    FROM dbo.LineLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND LTRIM(RTRIM(FirstBilledDate)) <> ''
      AND (@HasPanelFilter    = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom           IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo             IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom     IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo       IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@FirstBilledFrom   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo     IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo);

    SELECT  Panelname AS PanelName, COUNT(DISTINCT VisitKey) AS ClaimCount, ISNULL(SUM(Charge), 0) AS TotalCharges
    FROM    #Raw GROUP BY Panelname ORDER BY TotalCharges DESC;

    SELECT  Panelname AS PanelName, CPTDetail AS CPTCodeXUnitsXModifier,
            COUNT(DISTINCT VisitKey) AS ClaimCount, ISNULL(SUM(Charge), 0) AS TotalCharges
    FROM    #Raw WHERE CPTDetail <> '' GROUP BY Panelname, CPTDetail ORDER BY PanelName, TotalCharges DESC;

    DROP TABLE IF EXISTS #Raw;
END
GO

-- ============================================================
-- Unbilled Aging (Panelname × AgingBucket) — LineLevelData
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPhi_UnbilledAging
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
        SELECT  PanelName, AgingBucket, ClaimCount, TotalCharges
        FROM    dbo.Phi_UnbilledAging
        ORDER BY PanelName, AgingBucket;
        RETURN;
    END

    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) AS PanelName,
        ISNULL(LTRIM(RTRIM(AgingBucket)), 'Unknown')                                 AS AgingBucket,
        COUNT(DISTINCT COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''), NULLIF(LTRIM(RTRIM(ClaimID)), ''))) AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)                       AS TotalCharges
    FROM   dbo.LineLevelData
    WHERE  (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
      AND  (@HasPanelFilter   = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) IN (SELECT Value FROM @PanelList))
      AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND  (@FirstBillFrom    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND  (@FirstBillTo      IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
      AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
    GROUP BY LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))),
             ISNULL(LTRIM(RTRIM(AgingBucket)), 'Unknown')
    ORDER BY PanelName, AgingBucket;
END
GO

-- ============================================================
-- CPT Breakdown (claim-level individual CPT) — ClaimLevelData
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPhi_CPTBreakdown
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
        FROM    dbo.Phi_CPTBreakdown ORDER BY CPTCode, BilledYearMonth;
        RETURN;
    END

    SELECT
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown')))                AS CPTCode,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')  AS BilledYearMonth,
        COUNT(*)                                                 AS CPTCount,
        ISNULL(SUM(TRY_CAST(Units        AS DECIMAL(18,2))), 0) AS BilledUnits,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    FROM   dbo.ClaimLevelData
    WHERE  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND  LTRIM(RTRIM(FirstBilledDate)) <> ''
      AND  NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
      AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND  (@FirstBillFrom    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND  (@FirstBillTo      IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
      AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
    GROUP BY LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown'))),
             FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
    ORDER BY CPTCode, BilledYearMonth;
END
GO

PRINT '13_PhiLife_ReadSPs.sql completed.';
