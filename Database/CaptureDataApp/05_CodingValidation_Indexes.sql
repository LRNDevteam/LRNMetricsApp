-- =============================================================================
-- 05_CodingValidation_Indexes.sql
-- Supporting indexes for the Coding Summary page + CaptureDataApp.
--
-- Why: usp_GetCodingValidationDetail resolves the latest week via
--      "TOP 1 ... ORDER BY InsertedDateTime DESC" and then filters
--      "WHERE WeekFolder = ...". CaptureDataApp's skip-check
--      (GetLatestSourceFilePath) also sorts by InsertedDateTime.
--      Without these indexes both cause full scans of CodingValidation
--      on every dashboard page load / app run.
--
-- Deployment: run once per lab database (after 04_CodingAggregates.sql).
-- =============================================================================

-- Latest-row lookups (detail proc subquery + GetLatestSourceFilePath)
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_CodingValidation_InsertedDateTime'
                 AND object_id = OBJECT_ID('dbo.CodingValidation'))
CREATE INDEX IX_CodingValidation_InsertedDateTime
    ON dbo.CodingValidation (InsertedDateTime DESC)
    INCLUDE (WeekFolder, LabName, SourceFilePath);
GO

-- Latest-week detail rows (detail proc main query)
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_CodingValidation_WeekFolder'
                 AND object_id = OBJECT_ID('dbo.CodingValidation'))
CREATE INDEX IX_CodingValidation_WeekFolder
    ON dbo.CodingValidation (WeekFolder)
    INCLUDE (PanelName, AccessionNo, DateofService, ValidationStatus, TotalCharge);
GO
