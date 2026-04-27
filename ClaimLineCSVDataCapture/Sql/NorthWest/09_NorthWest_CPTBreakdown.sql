-- ============================================================
-- NorthWest Lab - CPT Breakdown (line-level)
-- Rule:
--   Filter  : LineLevel rows where FirstBilledDate IS NOT NULL and ChargeEnteredDate IS NOT NULL
--   Rows    : PayerName
--   Columns : ChargeEnteredDate month-year (yyyy-MM) | Count of CPT (lines) | Sum of charge amount
--
-- Creates aggregate table + stored procedure to populate it.
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1: Aggregate table
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'NW_CPTBreakdown')
CREATE TABLE dbo.NW_CPTBreakdown
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName       NVARCHAR(500)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,   -- 'yyyy-MM'
    CPTCount        INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2: Stored procedure
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CPTBreakdown
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown')))                        AS PayerName_Raw,
        FORMAT(TRY_CAST(cl.ChargeEnteredDate AS DATE), 'yyyy-MM')            AS BilledYearMonth,
        COUNT(*)                                                               AS CPTCount,
        ISNULL(SUM(TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2))), 0)           AS TotalCharges
    INTO #Raw
    FROM dbo.LineLevelData cl
    WHERE TRY_CAST(cl.FirstBilledDate AS DATE) IS NOT NULL
      AND TRY_CAST(cl.ChargeEnteredDate AS DATE) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(cl.PayerName_Raw)), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(cl.ChargeEnteredDate AS DATE), 'yyyy-MM');

    TRUNCATE TABLE dbo.NW_CPTBreakdown;

    INSERT INTO dbo.NW_CPTBreakdown (PayerName, BilledYearMonth, CPTCount, TotalCharges, RefreshedAt)
    SELECT PayerName_Raw, BilledYearMonth, CPTCount, TotalCharges, GETDATE()
    FROM #Raw
    ORDER BY PayerName_Raw, BilledYearMonth;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshNW_CPTBreakdown completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows loaded.';
END
GO

-- ============================================================
-- Quick verification queries
-- ============================================================
/*
SELECT PayerName, BilledYearMonth, CPTCount, TotalCharges
FROM dbo.NW_CPTBreakdown
ORDER BY PayerName, BilledYearMonth;
*/

PRINT '09_NorthWest_CPTBreakdown.sql completed.';
