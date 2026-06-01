-- PhiLife — CPT Breakdown (claim-level individual CPT)
-- Rule:
--   Source  : ClaimLevelData
--   Filter  : TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--   Rows    : CPTCode
--   Columns : ChargeEnteredDate month (yyyy-MM)
--             | CPTCount (COUNT of lines) | SUM(Units) | SUM(ChargeAmount)
--
-- Note: PhiLife's ClaimLevelData carries individual CPTCode and Units columns
--       (the inverted structure — claim-level has per-CPT rows).
--       LineLevelData carries aggregate CPT (CPTCodeXUnitsXModifier).
-- ============================================================

SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_CPTBreakdown')
CREATE TABLE dbo.Phi_CPTBreakdown
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    CPTCode         NVARCHAR(200)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,
    CPTCount        INT             NOT NULL DEFAULT 0,
    BilledUnits     DECIMAL(18,2)   NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_CPTBreakdown
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown')))                        AS CPTCode,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')          AS BilledYearMonth,
        COUNT(*)                                                         AS CPTCount,
        ISNULL(SUM(TRY_CAST(Units        AS DECIMAL(18,2))), 0)         AS BilledUnits,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)         AS TotalCharges
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL AND LTRIM(RTRIM(FirstBilledDate)) <> ''
      AND NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

    TRUNCATE TABLE dbo.Phi_CPTBreakdown;

    INSERT INTO dbo.Phi_CPTBreakdown
        (CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, RefreshedAt)
    SELECT CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, GETDATE()
    FROM #Raw
    ORDER BY CPTCode, BilledYearMonth;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshPhi_CPTBreakdown completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT '11_PhiLife_CPTBreakdown.sql completed.';
