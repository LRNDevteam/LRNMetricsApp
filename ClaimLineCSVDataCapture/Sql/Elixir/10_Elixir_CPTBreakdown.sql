-- Elixir Labs — CPT Breakdown (line-level)
-- Rule:
--   Source  : LineLevelData
--   Filter  : TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--   Rows    : CPTCode
--   Columns : ChargeEnteredDate month (yyyy-MM)
--             | CPTCount (COUNT of lines — not SUM of Units)
--             | SUM(Units)
--             | SUM(ChargeAmount)
-- ============================================================

SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Elix_CPTBreakdown')
CREATE TABLE dbo.Elix_CPTBreakdown
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    CPTCode         NVARCHAR(200)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,   -- 'yyyy-MM' from FirstBilledDate
    CPTCount        INT             NOT NULL DEFAULT 0,   -- COUNT of line rows per CPT per month
    BilledUnits     DECIMAL(18,2)   NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshElix_CPTBreakdown
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown')))                        AS CPTCode,
        FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM')          AS BilledYearMonth,
        COUNT(*)                                                         AS CPTCount,
        ISNULL(SUM(TRY_CAST(Units        AS DECIMAL(18,2))), 0)         AS BilledUnits,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)         AS TotalCharges
    INTO #Raw
    FROM dbo.LineLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown'))),
        FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM');

    TRUNCATE TABLE dbo.Elix_CPTBreakdown;

    INSERT INTO dbo.Elix_CPTBreakdown
        (CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, RefreshedAt)
    SELECT CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, GETDATE()
    FROM #Raw
    ORDER BY CPTCode, BilledYearMonth;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshElix_CPTBreakdown completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

/*
SELECT CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges
FROM dbo.Elix_CPTBreakdown ORDER BY CPTCode, BilledYearMonth;
*/

PRINT '10_Elixir_CPTBreakdown.sql completed.';
