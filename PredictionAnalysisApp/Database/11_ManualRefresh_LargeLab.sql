-- ============================================================
-- 11_ManualRefresh_LargeLab.sql
-- One-shot: rebuild PV_* for latest (or specified) run after deploying
-- 10_ChunkedAggregateRefresh_LargeLabs.sql.
--
-- Use for NorthWest OR any lab with PayerValidationReport >= ~7 lakh rows.
-- Chunking does NOT change COUNT(DISTINCT VisitNumber) / SUM results.
-- ============================================================
SET NOCOUNT ON;

DECLARE @RunId NVARCHAR(100) = NULL;   -- NULL = latest run
DECLARE @LabName NVARCHAR(255) = NULL; -- e.g. N'NorthWest'; leave NULL for latest any lab
DECLARE @ChunkSize INT = 100000;

-- SET @LabName = N'NorthWest';
-- SET @RunId = N'your-run-id-here';

IF @RunId IS NULL
BEGIN
    SELECT TOP 1 @RunId = CONVERT(NVARCHAR(100), RunId)
    FROM dbo.PayerValidationReport
    WHERE RunId IS NOT NULL
      AND (@LabName IS NULL OR LabName = @LabName)
    ORDER BY InsertedDateTime DESC;
END

DECLARE @RowCount BIGINT =
(
    SELECT COUNT_BIG(1) FROM dbo.PayerValidationReport
    WHERE CONVERT(NVARCHAR(100), RunId) = @RunId
      AND (@LabName IS NULL OR LabName = @LabName)
);

PRINT 'RunId=' + ISNULL(@RunId, N'(null)') + N' rows=' + CAST(@RowCount AS NVARCHAR(20));

EXEC dbo.usp_RefreshAllPredictionAggregates
    @RunId         = @RunId,
    @WeekStartDate = NULL,
    @LabName       = @LabName,
    @ChunkSize     = @ChunkSize;

SELECT 'PV_SummaryBuckets' AS T, COUNT(*) AS Rows FROM dbo.PV_SummaryBuckets WHERE RunId = @RunId
UNION ALL SELECT 'PV_SummaryMetrics', COUNT(*) FROM dbo.PV_SummaryMetrics WHERE RunId = @RunId
UNION ALL SELECT 'PV_ValidationByPayer', COUNT(*) FROM dbo.PV_ValidationByPayer WHERE RunId = @RunId
UNION ALL SELECT 'PV_DenialBreakdown', COUNT(*) FROM dbo.PV_DenialBreakdown WHERE RunId = @RunId
UNION ALL SELECT 'PV_FilterOptions', COUNT(*) FROM dbo.PV_FilterOptions WHERE RunId = @RunId
UNION ALL SELECT 'PV_WorkingBase', COUNT(*) FROM dbo.PV_WorkingBase WHERE RunId = @RunId;

SELECT TOP 20 * FROM dbo.PV_SummaryMetrics WHERE RunId = @RunId;
GO
