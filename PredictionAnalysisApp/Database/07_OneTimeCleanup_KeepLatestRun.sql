-- ============================================================================
-- 07_OneTimeCleanup_KeepLatestRun.sql
-- ONE-TIME cleanup to apply the "keep only latest run" retention policy to
-- data that accumulated BEFORE the policy was added.
--
-- Going forward this is automatic:
--   * usp_BulkInsertPayerValidationReport deletes all previous rows for the
--     lab before inserting the new run          (02_CreateStoredProcedures.sql)
--   * usp_RefreshAllPredictionAggregates purges PV_* rows of older RunIds
--                                               (05_PredictionAggregateRefreshSPs.sql)
--
-- Run this once per lab database (Rising_Tides, NWL, CoveLRN, ...) AFTER
-- re-running the updated 02 and 05 scripts.
-- PayerValidationFileLog is intentionally NOT touched - it is the permanent
-- dedupe/history log the ingestion app checks before inserting.
-- ============================================================================

SET NOCOUNT ON;

-- ── 1. PayerValidationReport: keep each lab's newest RunId only ─────────────
;WITH LatestRun AS
(
    SELECT LabName, RunId,
           ROW_NUMBER() OVER (PARTITION BY LabName ORDER BY MAX(InsertedDateTime) DESC) AS rn
    FROM   dbo.PayerValidationReport
    WHERE  RunId IS NOT NULL
    GROUP  BY LabName, RunId
)
DELETE r
FROM   dbo.PayerValidationReport r
WHERE  NOT EXISTS
(
    SELECT 1
    FROM   LatestRun k
    WHERE  k.rn = 1
      AND  k.LabName = r.LabName
      AND  k.RunId   = r.RunId
);

PRINT CONCAT('PayerValidationReport: ', @@ROWCOUNT, ' old-run rows deleted.');

-- ── 2. PV_* snapshots: keep the newest RunId only ───────────────────────────
DECLARE @KeepRunId NVARCHAR(100);

SELECT TOP 1 @KeepRunId = RunId
FROM   dbo.PayerValidationReport
WHERE  RunId IS NOT NULL
ORDER  BY InsertedDateTime DESC;

IF @KeepRunId IS NOT NULL
BEGIN
    DELETE FROM dbo.PV_SummaryBuckets       WHERE RunId <> @KeepRunId;
    DELETE FROM dbo.PV_ValidationByPayer    WHERE RunId <> @KeepRunId;
    DELETE FROM dbo.PV_ValidationByPanel    WHERE RunId <> @KeepRunId;
    DELETE FROM dbo.PV_ValidationByCPT      WHERE RunId <> @KeepRunId;
    DELETE FROM dbo.PV_DenialBreakdown      WHERE RunId <> @KeepRunId;
    DELETE FROM dbo.PV_NoResponseBreakdown  WHERE RunId <> @KeepRunId;
    DELETE FROM dbo.PV_SummaryMetrics       WHERE RunId <> @KeepRunId;

    PRINT CONCAT('PV_* snapshots: purged all runs except ', @KeepRunId, '.');

    -- Ensure snapshots exist for the kept run (in case they were never built)
    EXEC dbo.usp_RefreshAllPredictionAggregates @RunId = @KeepRunId;
    PRINT 'PV_* snapshots refreshed for the kept run.';
END
ELSE
    PRINT 'No RunId found in PayerValidationReport - nothing to purge.';

-- ── 3. Verify ────────────────────────────────────────────────────────────────
SELECT LabName, RunId, COUNT(*) AS Rows, MAX(InsertedDateTime) AS InsertedAt
FROM   dbo.PayerValidationReport
GROUP  BY LabName, RunId
ORDER  BY MAX(InsertedDateTime) DESC;
