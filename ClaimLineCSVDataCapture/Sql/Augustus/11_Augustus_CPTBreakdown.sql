-- ============================================================
-- Augustus Labs — CPT Breakdown (line-level)
-- Rule:
--   Source  : LineLevelData
--   Filter  : TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--             AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
--   Rows    : CPTCode
--   Columns : ChargeEnteredDate month (yyyy-MM) | COUNT(DISTINCT CPTCode) | Sum ChargeAmount
--
-- NOTE: The CPT tab in Production Summary Report always uses the live query
-- (GetCptBreakdownAsync with Rule3 ? COUNT DISTINCT CPTCode).
-- This SP pre-computes the table for potential future use / performance.
-- ============================================================

SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Aug_CPTBreakdown')
CREATE TABLE dbo.Aug_CPTBreakdown
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    CPTCode         NVARCHAR(200)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,   -- 'yyyy-MM' from ChargeEnteredDate
    CPTCount        INT             NOT NULL DEFAULT 0,   -- COUNT(DISTINCT CPTCode) per group
    BilledUnits     DECIMAL(18,2)   NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CPTBreakdown
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown')))                AS CPTCode,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')  AS BilledYearMonth,
        -- Augustus metric: distinct CPT codes (not SUM of Units)
        COUNT(DISTINCT LTRIM(RTRIM(ISNULL(CPTCode, ''))))       AS CPTCount,
        ISNULL(SUM(TRY_CAST(Units          AS DECIMAL(18,2))),0) AS BilledUnits,
        ISNULL(SUM(TRY_CAST(ChargeAmount   AS DECIMAL(18,2))),0) AS TotalCharges
    INTO #Raw
    FROM dbo.LineLevelData
    WHERE TRY_CAST(FirstBilledDate   AS DATE) IS NOT NULL
     -- AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

    TRUNCATE TABLE dbo.Aug_CPTBreakdown;

    INSERT INTO dbo.Aug_CPTBreakdown
        (CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, RefreshedAt)
    SELECT CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, GETDATE()
    FROM #Raw
    ORDER BY CPTCode, BilledYearMonth;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshAug_CPTBreakdown completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

/*
SELECT CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges
FROM dbo.Aug_CPTBreakdown ORDER BY CPTCode, BilledYearMonth;
*/

PRINT '11_Augustus_CPTBreakdown.sql completed.';
