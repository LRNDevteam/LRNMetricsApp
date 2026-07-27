-- ============================================================
-- 15_PayerValidation_AggregateControlSPs.sql
-- Control stored procedures for the FileStatus aggregate handshake.
--
-- Split of responsibilities:
--   Python app  : captures the CSV, inserts into PayerValidationFileLog +
--                 PayerValidationReport, and sets FileStatus = 3 (Ready).
--   PredictionAnalysisApp (aggregate-only) : calls the 3 SPs below to run the
--                 aggregate SPs and move FileStatus 3 -> 4 -> 5.
--
-- FileStatus:  3 = Ready for aggregate (Python)
--              4 = Aggregate InProgress (app, step 3)
--              5 = Aggregate Completed  (app, step 5)
--
-- Run once per lab database (PCRLOA_LRN, CoveLRN, ...).
-- Safe to re-run (CREATE OR ALTER + guarded column add).
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- Safety net: ensure the FileStatus column exists (you already added it;
-- this is a no-op if present).
IF COL_LENGTH('dbo.PayerValidationFileLog', 'FileStatus') IS NULL
BEGIN
    ALTER TABLE dbo.PayerValidationFileLog ADD FileStatus INT NULL;
END
GO

-- ── STEP 1: latest RunId pending aggregate ───────────────────────────────────
-- @IncludeAnyStatus = 0 -> newest run whose FileStatus = 3 (Ready).
-- @IncludeAnyStatus = 1 -> newest run regardless of status (DBRefresh = true).
CREATE OR ALTER PROCEDURE dbo.usp_PV_GetLatestAggregateRun
    @IncludeAnyStatus BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (1) RunId
    FROM   dbo.PayerValidationFileLog
    WHERE  RunId IS NOT NULL AND RunId <> N''
      AND (@IncludeAnyStatus = 1 OR FileStatus = 3)
    ORDER BY FileLogId DESC;
END
GO

-- ── STEP 2: does the report data match the FileLog RunId? ────────────────────
-- Returns BIT 1 when the RunId tied to the newest rows in PayerValidationReport
-- equals @RunId (confirms Python finished loading rows for that run).
CREATE OR ALTER PROCEDURE dbo.usp_PV_ReportRunIdMatches
    @RunId NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @NewestReportRunId NVARCHAR(100);

    SELECT TOP (1) @NewestReportRunId = CONVERT(NVARCHAR(100), RunId)
    FROM   dbo.PayerValidationReport
    WHERE  RunId IS NOT NULL
    GROUP BY CONVERT(NVARCHAR(100), RunId)
    ORDER BY MAX(ReportId) DESC;   -- ReportId identity => newest load wins

    SELECT CASE
             WHEN @NewestReportRunId IS NOT NULL
              AND @NewestReportRunId = @RunId THEN CAST(1 AS BIT)
             ELSE CAST(0 AS BIT)
           END AS IsMatch;
END
GO

-- ── STEP 3 / STEP 5: set FileStatus for a run ────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PV_UpdateFileStatus
    @RunId      NVARCHAR(100),
    @FileStatus INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.PayerValidationFileLog
    SET    FileStatus = @FileStatus
    WHERE  RunId = @RunId;
END
GO
