-- InHealthDTR — Monthly Claim Production Billed Summary
-- Rule:
--   Source  : ClaimLevelData
--   Filter  : TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--   Rows    : Panelname  x  All Payers (ranked by COUNT(DISTINCT ClaimID) per Panelname)
--   Columns : ChargeEnteredDate Year-Month (yyyy-MM) | COUNT(DISTINCT ClaimID) | SUM(ChargeAmount)
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1: Aggregate table
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'InH_MonthlyBilledProductionSummary')
CREATE TABLE dbo.InH_MonthlyBilledProductionSummary
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

-- ============================================================
-- Step 2: Stored procedure
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshInH_MonthlyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))                AS Panelname,
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                AS PayerName_Raw,
        FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM')        AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))             AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)       AS TotalCharges
    INTO #BilledRaw
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL AND LTRIM(RTRIM(FirstBilledDate)) <> ''
    GROUP BY
        LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))),
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM');

    -- Rank all Payers per Panel by total ClaimCount
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
    INTO #Final
    FROM #BilledRaw b
    JOIN #PayerRanks r ON r.Panelname = b.Panelname AND r.PayerName_Raw = b.PayerName_Raw;

    TRUNCATE TABLE dbo.InH_MonthlyBilledProductionSummary;

    INSERT INTO dbo.InH_MonthlyBilledProductionSummary
        (PanelType, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT
        Panelname,
        PayerName_Raw,
        PayerRank,
        BilledYearMonth,
        ClaimCount,
        TotalCharges,
        GETDATE()
    FROM #Final
    ORDER BY Panelname, PayerRank, BilledYearMonth;

    DROP TABLE IF EXISTS #BilledRaw;
    DROP TABLE IF EXISTS #PayerRanks;
    DROP TABLE IF EXISTS #Final;

    PRINT 'usp_RefreshInH_MonthlyBilledProductionSummary completed — '
          + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT '06_InHealthDTR_MonthlyBilledProductionSummary.sql completed.';
