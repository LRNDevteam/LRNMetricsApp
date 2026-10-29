-- LRN.SnapshotGenerator - register its report in dbo.ReportTypeMaster.
--
-- The service writes one dbo.ReportsWorkflowTracker row per lab + RunId, ReportName 'Report Snapshot'
-- (ReportSnapshot:TrackerReportName): Success / Failed, RowCount = report snapshot files, Remarks =
-- which reports the run's snapshot holds and what happened last. dbo.usp_ReportsWorkflowTracker_Upsert
-- rejects a name that is not active here, so run this before the service, or every tracker write is
-- logged as a warning (the snapshots themselves are not affected).
--
-- ReportTypeId is IDENTITY and never supplied; DisplayOrder goes after the existing rows.
-- Idempotent - safe to re-run. Re-running also reactivates the row if it was set IsActive = 0.
USE LRNMaster;
GO

DECLARE @Name VARCHAR(200) = 'Report Snapshot';

INSERT INTO dbo.ReportTypeMaster (ReportTypeName, IsActive, CreatedOn, DisplayOrder)
SELECT @Name, 1, SYSDATETIME(), ISNULL((SELECT MAX(DisplayOrder) FROM dbo.ReportTypeMaster), 0) + 1
WHERE NOT EXISTS (SELECT 1 FROM dbo.ReportTypeMaster WHERE ReportTypeName = @Name);
PRINT CONCAT(@@ROWCOUNT, ' report type(s) inserted');

UPDATE dbo.ReportTypeMaster SET IsActive = 1 WHERE ReportTypeName = @Name AND IsActive = 0;
PRINT CONCAT(@@ROWCOUNT, ' report type(s) reactivated');
GO

/* --------------------------------------------------------------------- Verify */
SELECT ReportTypeId, ReportTypeName, IsActive, DisplayOrder
FROM   dbo.ReportTypeMaster
WHERE  ReportTypeName = 'Report Snapshot';
GO
