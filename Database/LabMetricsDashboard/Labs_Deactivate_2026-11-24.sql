-- =================================================================
-- Deactivate labs  (2026-11-24)
-- Run against the LRNMaster database (DefaultConnection).
--
-- Sets dbo.Labs.IsActive = 0 for:
--   Certus, Augustus, In Health, PCR Labs of America, PCR AL, PCR CO,
--   Phi Life, Rising Tides
--
-- Effect (no restart needed):
--   * LRN Metrics: hidden from the Report Control Board, the navbar lab
--     dropdown, every lab picker, and the user-creation / assign-lab
--     screens (within 1 minute on every web server).
--   * AR Workbench: hidden from the lab list and closed to everyone
--     (within 1 minute).
--   * Master File Processor: skipped from its next pass.
--   * Existing user-lab assignments are KEPT, so users get the lab back
--     as soon as it is re-enabled.
--
-- To re-enable a lab: LRN Metrics > Admin > Manage Labs > Enable,
-- or  UPDATE dbo.Labs SET IsActive = 1, ModifiedBy = '...', ModifiedDate = SYSUTCDATETIME() WHERE LabId = <id>;
--
-- LabIds match LabConfig:LabsID (LabMetricsDashboard) and
-- MasterFileProcessor:Labs (LRN.MasterFileProcessorWorker):
--   18 Certus | 24 Augustus Labs | 2 Inhealth DTR | 13 PCR Labs of America
--    6 PCR Dx AL | 7 PCR Dx CO | 12 Phi Life | 9 Rising Tides
-- =================================================================

SET NOCOUNT ON;

DECLARE @Deactivate TABLE (LabId INT PRIMARY KEY, Expected NVARCHAR(100));
INSERT INTO @Deactivate (LabId, Expected) VALUES
    (18, N'Certus'),
    (24, N'Augustus'),
    (2,  N'In Health'),
    (13, N'PCR Labs of America'),
    (6,  N'PCR AL'),
    (7,  N'PCR CO'),
    (12, N'Phi Life'),
    (9,  N'Rising Tides');

-- 1. Preview: check each LabName is the lab you expect before committing.
SELECT d.LabId, d.Expected, l.LabName AS LabNameInDbo, l.IsActive AS IsActiveNow,
       CASE WHEN l.LabId IS NULL THEN '*** NOT FOUND in dbo.Labs ***' ELSE '' END AS Warning
FROM   @Deactivate d
LEFT JOIN dbo.Labs l ON l.LabId = d.LabId
ORDER BY d.LabId;

-- 2. Deactivate.
BEGIN TRANSACTION;

UPDATE l
SET    l.IsActive     = 0,
       l.ModifiedBy   = N'Labs_Deactivate_2026-11-24',
       l.ModifiedDate = SYSUTCDATETIME()
FROM   dbo.Labs l
JOIN   @Deactivate d ON d.LabId = l.LabId
WHERE  l.IsActive = 1;

PRINT CAST(@@ROWCOUNT AS NVARCHAR(10)) + ' lab(s) deactivated.';

-- Review the preview above, then COMMIT (or ROLLBACK if any LabName is wrong).
-- COMMIT TRANSACTION;
-- ROLLBACK TRANSACTION;

-- 3. Verify (after COMMIT).
-- SELECT LabId, LabName, IsActive, ModifiedBy, ModifiedDate FROM dbo.Labs ORDER BY IsActive, LabName;
