-- LRN Averages Import Worker — register its reports in dbo.ReportTypeMaster.
--
-- dbo.usp_ReportsWorkflowTracker_Upsert resolves ReportTypeId from @ReportName and rejects
-- any name not active in this master, so these rows must exist before the worker runs or
-- every tracker write fails with:
--   "X" is not an active report in dbo.ReportTypeMaster.
--
-- TWO reports, not one. The worker produces the CPT and panel aggregates independently and
-- they succeed or fail separately — Augustus imported its CPT averages while the panel
-- aggregate rolled back on a truncation. The tracker holds one row per RunId + Lab + Report,
-- so a single shared name could not represent that split outcome and the dashboard would
-- show one aggregate's failure as if it were both.
--
-- ReportTypeId is IDENTITY and is never supplied — the name is the contract, the id is
-- for reference only. DisplayOrder continues the existing sequence (14 rows, 1-14).
--
-- Idempotent — safe to re-run. Re-running also reactivates a row that was set IsActive = 0.
USE LRNMaster;
GO

DECLARE @Reports TABLE (ReportTypeName VARCHAR(200) PRIMARY KEY, DisplayOrder INT);
INSERT INTO @Reports (ReportTypeName, DisplayOrder)
VALUES ('CPT Averages', 15),
       ('Panel Averages', 16);

INSERT INTO dbo.ReportTypeMaster (ReportTypeName, IsActive, CreatedOn, DisplayOrder)
SELECT r.ReportTypeName, 1, SYSDATETIME(), r.DisplayOrder
FROM   @Reports r
WHERE  NOT EXISTS (SELECT 1 FROM dbo.ReportTypeMaster m WHERE m.ReportTypeName = r.ReportTypeName);

PRINT CONCAT(@@ROWCOUNT, ' report type(s) inserted');

-- A name that exists but was deactivated would still be rejected by the upsert.
UPDATE m
SET    m.IsActive = 1
FROM   dbo.ReportTypeMaster m
JOIN   @Reports r ON r.ReportTypeName = m.ReportTypeName
WHERE  m.IsActive = 0;

PRINT CONCAT(@@ROWCOUNT, ' report type(s) reactivated');
GO

/* --------------------------------------------------------------------- Verify */
-- Both rows must come back IsActive = 1, and the names must match
-- WorkflowReportNames.CptAverages / .PanelAverages character for character.
SELECT ReportTypeId, ReportTypeName, IsActive, DisplayOrder
FROM   dbo.ReportTypeMaster
WHERE  IsActive = 1
ORDER  BY DisplayOrder;
GO
