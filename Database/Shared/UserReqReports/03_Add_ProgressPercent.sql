/* =============================================================================
   UserReqReports - add ProgressPercent (idempotent)

   Fixes: Invalid column name 'ProgressPercent' on My Reports / badge Summary.

   Run this on EVERY lab database that already has dbo.UserReqReports from an
   older deploy (before ProgressPercent existed). Safe to re-run.

   Also re-applies claim/complete procs from 02 if those still reference the
   column - run 02_UserReqReports_Procs.sql after this if claim/complete fail.
   ============================================================================= */

SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.UserReqReports', N'U') IS NULL
BEGIN
    RAISERROR(N'dbo.UserReqReports does not exist - run 01_UserReqReports_Schema.sql first.', 16, 1);
    RETURN;
END
GO

IF COL_LENGTH('dbo.UserReqReports', 'ProgressPercent') IS NULL
BEGIN
    ALTER TABLE dbo.UserReqReports ADD ProgressPercent TINYINT NULL;
    PRINT N'Added dbo.UserReqReports.ProgressPercent.';
END
ELSE
    PRINT N'ProgressPercent already present - skipped ALTER.';
GO

-- Rebuild user-panel index so ProgressPercent is covered (no key lookups).
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_UserReqReports_User' AND object_id = OBJECT_ID(N'dbo.UserReqReports'))
    DROP INDEX IX_UserReqReports_User ON dbo.UserReqReports;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_UserReqReports_User' AND object_id = OBJECT_ID(N'dbo.UserReqReports'))
    CREATE NONCLUSTERED INDEX IX_UserReqReports_User
        ON dbo.UserReqReports (RequestedBy, GenerationStatus)
        INCLUDE (ReportType, LabName, RequestedDate, [FileName], FileSizeBytes,
                 CompletedDate, ExpiryDate, ErrorMessage, DownloadToken, ReportRowCount,
                 ProgressPercent);
GO

PRINT N'Done. Recycle the web app / Report Worker so any in-memory schema cache refreshes.';
GO