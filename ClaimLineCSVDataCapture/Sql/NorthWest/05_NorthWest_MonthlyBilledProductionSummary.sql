-- ============================================================
-- NorthWest Lab — Monthly Claim Production Billed Summary
-- Rule:
--   Filter  : BilledStatus = 'Billed'
--   Rows    : PanelType  x  Top 3 Payer (by claim count, per PanelType)
--   Columns : ChargeEnteredDate Year-Month | Claim Count | Sum Charge Amount
--
-- Step 1 — Create the aggregate table (safe to re-run).
-- Step 2 — Create / Alter the stored procedure that populates it.
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1: Aggregate table
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'NW_MonthlyBilledProductionSummary')
CREATE TABLE dbo.NW_MonthlyBilledProductionSummary
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelType       NVARCHAR(MAX)   NOT NULL,
    PayerName       NVARCHAR(500)   NOT NULL,
    PayerRank       TINYINT         NOT NULL,   -- 1 / 2 / 3  within the PanelType
    BilledYearMonth NVARCHAR(7)     NOT NULL,   -- 'yyyy-MM'
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO
USE [NWL]
GO
/****** Object:  StoredProcedure [dbo].[usp_RefreshNW_MonthlyBilledProductionSummary]    Script Date: 5/1/2026 8:41:06 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

Create or ALTER   PROCEDURE [dbo].[usp_RefreshNW_MonthlyBilledProductionSummary]
AS
BEGIN
    SET NOCOUNT ON;

    -- Collect production claims by excluding unbilled statuses and zero-dollar rows
    SELECT
        LTRIM(RTRIM(ISNULL(PanelType, 'Unknown')))              AS PanelType,
        LTRIM(RTRIM(ISNULL(Payername_Raw, 'Unknown')))              AS Payername_Raw,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')  AS BilledYearMonth,
        COUNT(*)                                                AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)  AS TotalCharges
    INTO #BilledRaw
    FROM dbo.ClaimLevelData
    WHERE LTRIM(RTRIM(ClaimStatus)) NOT IN (
              'Unbilled in Daq',
              'Unbilled in Daq - PR',
              'Unbilled in Webpm',
              'Unbilled in Webpm - PR',
              'Billed amount 0'
          )
      AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(PanelType)), '') IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(Payername_Raw)), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(PanelType, 'Unknown'))),
        LTRIM(RTRIM(ISNULL(Payername_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

    -- Rank payers within each PanelType (Top 3 by total claim count)
    SELECT
        PanelType,
        Payername_Raw,
        DENSE_RANK() OVER (
            PARTITION BY PanelType
            ORDER BY SUM(ClaimCount) DESC
        ) AS PayerRank
    INTO #PayerRanks
    FROM #BilledRaw
    GROUP BY PanelType, Payername_Raw;

    -- Keep only Top 3 payers per PanelType
    SELECT
        b.PanelType,
        b.Payername_Raw,
        CAST(r.PayerRank AS TINYINT) AS PayerRank,
        b.BilledYearMonth,
        b.ClaimCount,
        b.TotalCharges
    INTO #Top3
    FROM #BilledRaw b
    JOIN #PayerRanks r
      ON r.PanelType = b.PanelType
     AND r.Payername_Raw = b.Payername_Raw
    WHERE r.PayerRank <= 3;

    TRUNCATE TABLE dbo.NW_MonthlyBilledProductionSummary;

    INSERT INTO dbo.NW_MonthlyBilledProductionSummary
    (PanelType, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelType, Payername_Raw, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #Top3
    ORDER BY PanelType, PayerRank, BilledYearMonth;

    DROP TABLE IF EXISTS #BilledRaw;
    DROP TABLE IF EXISTS #PayerRanks;
    DROP TABLE IF EXISTS #Top3;

    PRINT 'usp_RefreshNW_MonthlyBilledProductionSummary completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows loaded.';
END

PRINT '05_NorthWest_MonthlyBilledProductionSummary.sql completed.';

