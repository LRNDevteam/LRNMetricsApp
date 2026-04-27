-- ============================================================
-- NorthWest Lab - Weekly Claim Production Billed Summary
-- Rule:
--   Filter  : Exclude ClaimStatus IN
--               'Unbilled in Daq', 'Unbilled in Daq - PR',
--               'Unbilled in Webpm', 'Unbilled in Webpm - PR',
--               'Billed amount 0'
--   Rows    : PanelType  x  Top 3 Payer (by claim count, per PanelType)
--   Columns : ChargeEnteredDate week range (Thu - Wed), Claim Count, Sum Charge Amount
--   Range   : last 4 weeks (current Thu-Wed and previous 3 Thu-Wed ranges)
--
-- Creates aggregate table + stored procedure to populate it.
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1: Aggregate table
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'NW_WeeklyBilledProductionSummary')
CREATE TABLE dbo.NW_WeeklyBilledProductionSummary
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelType       NVARCHAR(MAX)   NOT NULL,
    PayerName       NVARCHAR(500)   NOT NULL,
    PayerRank       TINYINT         NOT NULL,   -- 1 / 2 / 3 within the PanelType
    WeekStart       DATE            NOT NULL,   -- Thursday
    WeekEnd         DATE            NOT NULL,   -- following Wednesday
    WeekLabel       NVARCHAR(32)    NOT NULL,   -- 'yyyy-MM-dd - yyyy-MM-dd'
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2: Stored procedure
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_WeeklyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    -- Determine the current week start (Thursday) for GETDATE()
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    -- Reference Thursday: 1900-01-04 is a Thursday
    DECLARE @ThisWeekStart DATE = DATEADD(day, - (DATEDIFF(day, '1900-01-04', @Today) % 7), @Today);

    -- Prepare the last 4 Thu-Wed week ranges (0 = current week, 1 = previous week, ...)
    DECLARE @i INT = 0;
    CREATE TABLE #Weeks
    (
        WeekIndex INT PRIMARY KEY,
        WeekStart DATE,
        WeekEnd   DATE,
        WeekLabel NVARCHAR(32)
    );

    WHILE @i < 4
    BEGIN
        DECLARE @ws DATE = DATEADD(week, -@i, @ThisWeekStart);
        DECLARE @we DATE = DATEADD(day, 6, @ws); -- Thu + 6 = Wed
        INSERT INTO #Weeks (WeekIndex, WeekStart, WeekEnd, WeekLabel)
        VALUES (@i, @ws, @we, FORMAT(@ws, 'yyyy-MM-dd') + ' - ' + FORMAT(@we, 'yyyy-MM-dd'));
        SET @i = @i + 1;
    END

    -- --------------------------------------------------------
    -- Collect production claims by excluding unbilled and zero-charge statuses
    -- then group by panel x payer x week range.
    -- Excluded ClaimStatus values are explicit per requirement.
    -- --------------------------------------------------------
    SELECT
        LTRIM(RTRIM(ISNULL(cl.PanelType, 'Unknown')))                 AS PanelType,
        LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown')))                 AS PayerName_Raw,
        w.WeekStart,
        w.WeekEnd,
        w.WeekLabel,
        COUNT(*)                                                       AS ClaimCount,
        ISNULL(SUM(TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2))), 0)     AS TotalCharges
    INTO #BilledRaw
    FROM dbo.ClaimLevelData cl
    JOIN #Weeks w
      ON TRY_CAST(cl.ChargeEnteredDate AS DATE) BETWEEN w.WeekStart AND w.WeekEnd
    WHERE LTRIM(RTRIM(cl.ClaimStatus)) NOT IN (
              'Unbilled in Daq',
              'Unbilled in Daq - PR',
              'Unbilled in Webpm',
              'Unbilled in Webpm - PR',
              'Billed amount 0'
          )
      AND TRY_CAST(cl.ChargeEnteredDate AS DATE) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(cl.PanelType)),  '') IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(cl.PayerName_Raw)),  '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(cl.PanelType, 'Unknown'))),
        LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown'))),
        w.WeekStart, w.WeekEnd, w.WeekLabel;

    -- --------------------------------------------------------
    -- Rank payers within each PanelType by total claim count across the 4-week window
    -- (Top 3 per panel).
    -- --------------------------------------------------------
    SELECT
        PanelType,
        PayerName_Raw,
        DENSE_RANK() OVER (
            PARTITION BY PanelType
            ORDER BY SUM(ClaimCount) DESC
        ) AS PayerRank
    INTO #PayerRanks
    FROM #BilledRaw
    GROUP BY PanelType, PayerName_Raw;

    -- --------------------------------------------------------
    -- Keep only Top 3 payers per PanelType and insert into aggregate table
    -- --------------------------------------------------------
    SELECT
        b.PanelType,
        b.PayerName_Raw,
        CAST(r.PayerRank AS TINYINT) AS PayerRank,
        b.WeekStart,
        b.WeekEnd,
        b.WeekLabel,
        b.ClaimCount,
        b.TotalCharges
    INTO #Top3
    FROM #BilledRaw b
    JOIN #PayerRanks r
      ON r.PanelType = b.PanelType
     AND r.PayerName_Raw = b.PayerName_Raw
    WHERE r.PayerRank <= 3;

    -- Atomic replace
    TRUNCATE TABLE dbo.NW_WeeklyBilledProductionSummary;

    INSERT INTO dbo.NW_WeeklyBilledProductionSummary
    (
        PanelType, PayerName, PayerRank,
        WeekStart, WeekEnd, WeekLabel,
        ClaimCount, TotalCharges, RefreshedAt
    )
    SELECT
        PanelType, PayerName_Raw, PayerRank,
        WeekStart, WeekEnd, WeekLabel,
        ClaimCount, TotalCharges, GETDATE()
    FROM #Top3
    ORDER BY PanelType, PayerRank, WeekStart DESC;

    -- Clean up
    DROP TABLE IF EXISTS #BilledRaw;
    DROP TABLE IF EXISTS #PayerRanks;
    DROP TABLE IF EXISTS #Top3;
    DROP TABLE IF EXISTS #Weeks;

    PRINT 'usp_RefreshNW_WeeklyBilledProductionSummary completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows loaded.';
END
GO

-- ============================================================
-- Quick verification query
-- ============================================================
/*
-- Preview generated week ranges (for debugging)
SELECT * FROM #Weeks ORDER BY WeekIndex;

-- Preview the data
SELECT PanelType, PayerRank, PayerName, WeekLabel, ClaimCount, TotalCharges
FROM dbo.NW_WeeklyBilledProductionSummary
ORDER BY PanelType, PayerRank, WeekStart DESC;
*/

PRINT '06_NorthWest_WeeklyBilledProductionSummary.sql completed.';
