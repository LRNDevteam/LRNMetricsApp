-- BeechTree — Monthly Claim Production Billed Summary
-- Rule:
--   Filter  : TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--   Rows    : Panelname  x  Top 3 Payer (by COUNT(DISTINCT ClaimID), per Panelname)
--   Columns : ChargeEnteredDate Year-Month (yyyy-MM) | COUNT(DISTINCT ClaimID) | SUM(ChargeAmount)
--   Note    : Column pivot uses ChargeEnteredDate, not FirstBilledDate.
-- ============================================================

SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'BT_MonthlyBilledProductionSummary')
CREATE TABLE dbo.BT_MonthlyBilledProductionSummary
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelType       NVARCHAR(MAX)   NOT NULL,
    PayerName       NVARCHAR(500)   NOT NULL,
    PayerRank       TINYINT         NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

--CREATE OR ALTER PROCEDURE dbo.usp_RefreshBT_MonthlyBilledProductionSummary
--AS
--BEGIN
--    SET NOCOUNT ON;

--    SELECT
--        LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))                   AS Panelname,
--        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                   AS PayerName_Raw,
--        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')           AS BilledYearMonth,
--        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                AS ClaimCount,
--        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)          AS TotalCharges
--    INTO #BilledRaw
--    FROM dbo.ClaimLevelData
--    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--    GROUP BY
--        LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))),
--        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
--        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

--    SELECT
--        Panelname,
--        PayerName_Raw,
--        DENSE_RANK() OVER (
--            PARTITION BY Panelname
--            ORDER BY SUM(ClaimCount) DESC
--        ) AS PayerRank
--    INTO #PayerRanks
--    FROM #BilledRaw
--    GROUP BY Panelname, PayerName_Raw;

--    SELECT
--        b.Panelname,
--        b.PayerName_Raw,
--        CAST(r.PayerRank AS TINYINT) AS PayerRank,
--        b.BilledYearMonth,
--        b.ClaimCount,
--        b.TotalCharges
--    INTO #Top3
--    FROM #BilledRaw b
--    JOIN #PayerRanks r ON r.Panelname = b.Panelname AND r.PayerName_Raw = b.PayerName_Raw
--    WHERE r.PayerRank <= 3;

--    TRUNCATE TABLE dbo.BT_MonthlyBilledProductionSummary;

--    INSERT INTO dbo.BT_MonthlyBilledProductionSummary
--        (PanelType, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
--    SELECT Panelname, PayerName_Raw, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
--    FROM #Top3
--    ORDER BY Panelname, PayerRank, BilledYearMonth;

--    DROP TABLE IF EXISTS #BilledRaw;
--    DROP TABLE IF EXISTS #PayerRanks;
--    DROP TABLE IF EXISTS #Top3;

--    PRINT 'usp_RefreshBT_MonthlyBilledProductionSummary completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
--END



CREATE OR ALTER PROCEDURE dbo.usp_RefreshBT_MonthlyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    -- ✅ All column names confirmed from INFORMATION_SCHEMA
    SELECT
        LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))                AS Panelname,
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                AS PayerName_Raw,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')        AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))             AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)       AS TotalCharges
    INTO #BilledRaw
    FROM dbo.ClaimLevelData   -- ⚠️ Change schema if not dbo
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))),
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

    -- Top 3 Payers per Panel
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

    -- Filter Top 3 only
    SELECT
        b.Panelname,
        b.PayerName_Raw,
        CAST(r.PayerRank AS TINYINT)  AS PayerRank,
        b.BilledYearMonth,
        b.ClaimCount,
        b.TotalCharges
    INTO #Top3
    FROM #BilledRaw  b
    JOIN #PayerRanks r 
        ON  r.Panelname    = b.Panelname
        AND r.PayerName_Raw = b.PayerName_Raw
    WHERE r.PayerRank <= 3;

    -- Refresh Summary Table
    TRUNCATE TABLE dbo.BT_MonthlyBilledProductionSummary;

    INSERT INTO dbo.BT_MonthlyBilledProductionSummary
        (PanelType, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT
        Panelname,
        PayerName_Raw,
        PayerRank,
        BilledYearMonth,
        ClaimCount,
        TotalCharges,
        GETDATE()
    FROM #Top3
    ORDER BY Panelname, PayerRank, BilledYearMonth;

    -- Cleanup
    DROP TABLE IF EXISTS #BilledRaw;
    DROP TABLE IF EXISTS #PayerRanks;
    DROP TABLE IF EXISTS #Top3;

    PRINT 'usp_RefreshBT_MonthlyBilledProductionSummary completed — '
          + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO
GO

PRINT '06_BeechTree_MonthlyBilledProductionSummary.sql completed.';
