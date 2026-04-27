-- ============================================================
-- Augustus Labs — Monthly Claim Production Billed Summary
-- Rule:
--   Filter  : TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--             AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
--   Rows    : PanelNew  x  Top 3 Payer (by claim count, per PanelNew)
--   Columns : ChargeEnteredDate Year-Month (yyyy-MM) | Claim Count | Sum Charge Amount
--   Note    : No PayerName_Raw NULL exclusion — rows with blank payer are grouped
--             as 'Unknown'.
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1: Aggregate table  (same structure as NW so reading code is shared)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Aug_MonthlyBilledProductionSummary')
CREATE TABLE dbo.Aug_MonthlyBilledProductionSummary
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelType       NVARCHAR(MAX)   NOT NULL,   -- stores PanelNew value
    PayerName       NVARCHAR(500)   NOT NULL,
    PayerRank       TINYINT         NOT NULL,   -- 1 / 2 / 3 within the PanelNew
    BilledYearMonth NVARCHAR(7)     NOT NULL,   -- 'yyyy-MM' from ChargeEnteredDate
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2: Stored procedure
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_MonthlyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    -- Aggregate by PanelNew × PayerName_Raw × ChargeEnteredDate month.
    -- Filter: both FirstBilledDate and ChargeEnteredDate must be valid dates.
    -- No PayerName_Raw IS NOT NULL guard — blank/null payer → 'Unknown'.
    SELECT
        LTRIM(RTRIM(ISNULL(PanelNew,       'Unknown')))         AS PanelNew,
        LTRIM(RTRIM(ISNULL(PayerName_Raw,  'Unknown')))         AS PayerName_Raw,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')  AS BilledYearMonth,
        COUNT(*)                                                AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)  AS TotalCharges
    INTO #BilledRaw
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate   AS DATE) IS NOT NULL
      --AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
      --AND NULLIF(LTRIM(RTRIM(PanelNew)), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(PanelNew,      'Unknown'))),
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

    -- Rank payers within each PanelNew by total claim count (Top 3).
    SELECT
        PanelNew,
        PayerName_Raw,
        DENSE_RANK() OVER (
            PARTITION BY PanelNew
            ORDER BY SUM(ClaimCount) DESC
        ) AS PayerRank
    INTO #PayerRanks
    FROM #BilledRaw
    GROUP BY PanelNew, PayerName_Raw;

    SELECT
        b.PanelNew,
        b.PayerName_Raw,
        CAST(r.PayerRank AS TINYINT) AS PayerRank,
        b.BilledYearMonth,
        b.ClaimCount,
        b.TotalCharges
    INTO #Top3
    FROM #BilledRaw b
    JOIN #PayerRanks r ON r.PanelNew = b.PanelNew AND r.PayerName_Raw = b.PayerName_Raw
    WHERE r.PayerRank <= 3;

    TRUNCATE TABLE dbo.Aug_MonthlyBilledProductionSummary;

    INSERT INTO dbo.Aug_MonthlyBilledProductionSummary
        (PanelType, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelNew, PayerName_Raw, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #Top3
    ORDER BY PanelNew, PayerRank, BilledYearMonth;

    DROP TABLE IF EXISTS #BilledRaw;
    DROP TABLE IF EXISTS #PayerRanks;
    DROP TABLE IF EXISTS #Top3;

    PRINT 'usp_RefreshAug_MonthlyBilledProductionSummary completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT '07_Augustus_MonthlyBilledProductionSummary.sql completed.';
