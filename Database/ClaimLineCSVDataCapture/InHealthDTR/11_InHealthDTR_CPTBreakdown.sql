-- InHealthDTR — CPT Breakdown (individual CPT)
-- Rule:
--   Source  : LineLevelData
--   Filter  : TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--   Rows    : CPTCode
--   Columns : ChargeEnteredDate month (yyyy-MM)
--             | LineCount (COUNT of lines) | SUM(Units) | SUM(ChargeAmount)
--
-- Note: InHealthDTR's LineLevelData carries individual CPTCode, Units, Modifier columns
--       (line-level detail).
-- ============================================================

SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'InH_CPTBreakdown')
CREATE TABLE dbo.InH_CPTBreakdown
(
	SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
	CPTCode         NVARCHAR(200)   NOT NULL,
	BilledYearMonth NVARCHAR(7)     NOT NULL,
	LineCount       INT             NOT NULL DEFAULT 0,
	BilledUnits     DECIMAL(18,2)   NOT NULL DEFAULT 0,
	TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
	RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshInH_CPTBreakdown
AS
BEGIN
	SET NOCOUNT ON;

	SELECT
		LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown')))                        AS CPTCode,
		FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')          AS BilledYearMonth,
		COUNT(*)                                                         AS LineCount,
		ISNULL(SUM(TRY_CAST(Units        AS DECIMAL(18,2))), 0)         AS BilledUnits,
		ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)         AS TotalCharges
	INTO #Raw
	FROM dbo.LineLevelData
	WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL AND LTRIM(RTRIM(FirstBilledDate)) <> ''
	  AND NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
	GROUP BY
		LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown'))),
		FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

	TRUNCATE TABLE dbo.InH_CPTBreakdown;

	INSERT INTO dbo.InH_CPTBreakdown
		(CPTCode, BilledYearMonth, LineCount, BilledUnits, TotalCharges, RefreshedAt)
	SELECT CPTCode, BilledYearMonth, LineCount, BilledUnits, TotalCharges, GETDATE()
	FROM #Raw
	ORDER BY CPTCode, BilledYearMonth;

	DROP TABLE IF EXISTS #Raw;

	PRINT 'usp_RefreshInH_CPTBreakdown completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT '11_InHealthDTR_CPTBreakdown.sql completed.';
