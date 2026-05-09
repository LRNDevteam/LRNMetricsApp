-- PCRLabsofAmerica — Monthly Claim Production Billed Summary
-- Rule:
--   Filter  : TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--   Rows    : Panelname  x  Top 3 Payer (by COUNT(DISTINCT ClaimID), per Panelname)
--   Columns : ChargeEnteredDate Year-Month (yyyy-MM) | COUNT(DISTINCT ClaimID) | SUM(ChargeAmount)
--   Note    : Column pivot uses ChargeEnteredDate, not FirstBilledDate.
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1: Aggregate table
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PCR_MonthlyBilledProductionSummary')
CREATE TABLE dbo.PCR_MonthlyBilledProductionSummary
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelType       NVARCHAR(MAX)   NOT NULL,   -- stores Panelname value
    PayerName       NVARCHAR(500)   NOT NULL,
    PayerRank       TINYINT         NOT NULL,   -- 1 / 2 / 3 within the Panelname
    BilledYearMonth NVARCHAR(7)     NOT NULL,   -- 'yyyy-MM' from ChargeEnteredDate
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2: Stored procedure
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_MonthlyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    -- Aggregate by Panelname x PayerName_Raw x ChargeEnteredDate month.
    -- Filter: FirstBilledDate must be a valid date.
    SELECT
        LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))                   AS Panelname,
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                   AS PayerName_Raw,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')           AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)          AS TotalCharges
    INTO #BilledRaw
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL and FirstBilledDate != ''
    GROUP BY
        LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))),
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

    -- Rank payers within each Panelname by total claim count (Top 3).
    SELECT
        Panelname,
        PayerName_Raw,
        DENSE_RANK() OVER (
            PARTITION BY Panelname
            ORDER BY SUM(ClaimCount) DESC
        ) AS PayerRank
    INTO #PayerRanks
    FROM #BilledRaw
    GROUP BY Panelname, PayerName_Raw;

    SELECT
        b.Panelname,
        b.PayerName_Raw,
        CAST(r.PayerRank AS TINYINT) AS PayerRank,
        b.BilledYearMonth,
        b.ClaimCount,
        b.TotalCharges
    INTO #Top3
    FROM #BilledRaw b
    JOIN #PayerRanks r ON r.Panelname = b.Panelname AND r.PayerName_Raw = b.PayerName_Raw;
  --  WHERE r.PayerRank <= 3;

    TRUNCATE TABLE dbo.PCR_MonthlyBilledProductionSummary;

    INSERT INTO dbo.PCR_MonthlyBilledProductionSummary
        (PanelType, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, PayerName_Raw, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #Top3
    ORDER BY Panelname, PayerRank, BilledYearMonth;

    DROP TABLE IF EXISTS #BilledRaw;
    DROP TABLE IF EXISTS #PayerRanks;
    DROP TABLE IF EXISTS #Top3;

    PRINT 'usp_RefreshPCR_MonthlyBilledProductionSummary completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

-- ============================================================
-- Step 3: Read stored procedure
-- Called by LabMetricsDashboard.SqlLabProductionSummaryRepository.
--
-- Two execution paths controlled by the input parameters:
--   1) NO filter parameters supplied  -> return rows from the pre-aggregated
--      dbo.PCR_MonthlyBilledProductionSummary table (fast path).
--   2) ANY filter parameter supplied  -> aggregate live from dbo.ClaimLevelData
--      using the same filter semantics that the C# inline live query used to
--      apply (legacy / Rule5 default: FirstBilledDate not blank, PayerName_Raw
--      not blank, ChargeEnteredDate-month columns, Top-3 payer drill-down per
--      Panelname by COUNT(DISTINCT ClaimID)).
--
-- Output schema (identical for both paths):
--   PanelName, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
--   PayerRank = 0  -> panel-level totals across ALL payers (panel row).
--   PayerRank 1..N -> per-payer drill-down rows (caller keeps Top 3).
--
-- List parameters use '|' as the delimiter so payer/panel names that contain
-- commas are passed safely.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_MonthlyBilledProductionSummary
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
        SELECT  PanelType        AS PanelName,
                PayerName,
                PayerRank,
                BilledYearMonth,
                ClaimCount,
                TotalCharges
        FROM    dbo.PCR_MonthlyBilledProductionSummary
        ORDER BY PanelName, BilledYearMonth, PayerRank;
        RETURN;
    END

    -- Filtered path: aggregate live from ClaimLevelData.
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

    ;WITH Agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))         AS Panelname,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))         AS PayerName_Raw,
            FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM') AS BilledYearMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))      AS ClaimCount,
            ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0) AS TotalCharges
        FROM   dbo.ClaimLevelData
        WHERE  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
          AND  FirstBilledDate <> ''
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
                DENSE_RANK() OVER (PARTITION BY Panelname ORDER BY SUM(ClaimCount) DESC) AS PayerRank
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
                pt.BilledYearMonth,
                pt.ClaimCount,
                pt.TotalCharges
        FROM    PanelTotal pt
        UNION ALL
        SELECT  a.Panelname            AS PanelName,
                a.PayerName_Raw        AS PayerName,
                CAST(r.PayerRank AS TINYINT) AS PayerRank,
                a.BilledYearMonth,
                a.ClaimCount,
                a.TotalCharges
        FROM    Agg   a
        JOIN    Ranks r ON r.Panelname = a.Panelname AND r.PayerName_Raw = a.PayerName_Raw
    ) x
    ORDER BY PanelName, BilledYearMonth, PayerRank;
END
GO

/*
SELECT PanelType, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
FROM dbo.PCR_MonthlyBilledProductionSummary
ORDER BY PanelType, PayerRank, BilledYearMonth;
*/

PRINT '06_PCRLabsofAmerica_MonthlyBilledProductionSummary.sql completed.';
