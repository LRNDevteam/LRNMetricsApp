-- ============================================================
-- Script  : 05_Create_SP_NotesInsights_Import.sql
-- Feature : Executive Summary Notes & Insights
-- Purpose : Excel import via staging + validation preview, then
--           truncate/replace commit.
--             - usp_NotesImport_LoadStagingRow  (append one raw row)
--             - usp_NotesImport_Validate         (build validation preview)
--             - usp_NotesImport_Commit           (replace notes for Report+Week)
-- Rule    : Report Name, Week Range and file are mandatory.
--           On commit, existing ACTIVE notes for the same
--           Report + Week Range are truncated/replaced by the
--           imported rows. No Entry ID merge/update logic.
-- Run     : After 01-04 scripts.
-- ============================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ------------------------------------------------------------
-- usp_NotesImport_LoadStagingRow
--   App layer parses the uploaded Excel and calls this once per
--   row to load raw text into staging under one ImportBatchId.
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesImport_LoadStagingRow', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesImport_LoadStagingRow;
GO
CREATE PROCEDURE dbo.usp_NotesImport_LoadStagingRow
    @ImportBatchId      UNIQUEIDENTIFIER,
    @RowNumber          INT,
    @ReportName         NVARCHAR(200),
    @WeekRangeText      NVARCHAR(50),
    @ReportRunId        NVARCHAR(50)  = NULL,
    @RiskText           NVARCHAR(50)  = NULL,
    @ResponsibleParty   NVARCHAR(200) = NULL,
    @Insights           NVARCHAR(MAX) = NULL,
    @NoOfSamplesText    NVARCHAR(50)  = NULL,
    @ActionSolution     NVARCHAR(MAX) = NULL,
    @FeedbackResponse   NVARCHAR(MAX) = NULL,
    @Responsibility     NVARCHAR(200) = NULL,
    @DiscussionDateText NVARCHAR(50)  = NULL,
    @ETAText            NVARCHAR(50)  = NULL,
    @ClosedDateText     NVARCHAR(50)  = NULL,
    @StatusText         NVARCHAR(50)  = NULL,
    @CreatedBy          NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.NotesImportStaging
        (ImportBatchId, RowNumber, ReportName, WeekRangeText, ReportRunId,
         RiskText, ResponsibleParty, Insights, NoOfSamplesText, ActionSolution,
         FeedbackResponse, Responsibility, DiscussionDateText, ETAText,
         ClosedDateText, StatusText, CreatedBy)
    VALUES
        (@ImportBatchId, @RowNumber, @ReportName, @WeekRangeText, @ReportRunId,
         @RiskText, @ResponsibleParty, @Insights, @NoOfSamplesText, @ActionSolution,
         @FeedbackResponse, @Responsibility, @DiscussionDateText, @ETAText,
         @ClosedDateText, @StatusText, @CreatedBy);
END
GO

-- ------------------------------------------------------------
-- usp_NotesImport_Validate
--   Validates all rows in a batch and returns the validation
--   preview grid (row number, field, error, recommended fix).
--   Checks: mandatory Report/Week, known Report, valid Risk,
--   valid Status, parseable dates and sample count.
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesImport_Validate', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesImport_Validate;
GO
CREATE PROCEDURE dbo.usp_NotesImport_Validate
    @ImportBatchId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE st
    SET IsValid = 0,
        ValidationError =
            STUFF(
                CASE WHEN st.ReportName IS NULL OR LTRIM(RTRIM(st.ReportName)) = ''
                     THEN ' | Report Name: required. Provide a report name.' ELSE '' END +
                CASE WHEN NOT EXISTS (SELECT 1 FROM dbo.NotesReport rp WHERE rp.ReportName = st.ReportName)
                      AND st.ReportName IS NOT NULL
                     THEN ' | Report Name: unknown report. Use a registered report.' ELSE '' END +
                CASE WHEN st.WeekRangeText IS NULL OR LTRIM(RTRIM(st.WeekRangeText)) = ''
                     THEN ' | Week Range: required. Provide the billed week range.' ELSE '' END +
                CASE WHEN st.RiskText IS NOT NULL
                      AND NOT EXISTS (SELECT 1 FROM dbo.NotesRiskLevel r WHERE r.RiskCode = st.RiskText)
                     THEN ' | Risk: invalid value. Use Red, Yellow or Green.' ELSE '' END +
                CASE WHEN st.StatusText IS NOT NULL
                      AND NOT EXISTS (SELECT 1 FROM dbo.NotesStatus s WHERE s.StatusCode = st.StatusText)
                     THEN ' | Status: invalid value. Use Open, WIP, Deferred or Closed.' ELSE '' END +
                CASE WHEN st.NoOfSamplesText IS NOT NULL AND st.NoOfSamplesText <> ''
                      AND TRY_CONVERT(INT, st.NoOfSamplesText) IS NULL
                     THEN ' | # of Samples: not a number.' ELSE '' END +
                CASE WHEN st.DiscussionDateText IS NOT NULL AND st.DiscussionDateText <> ''
                      AND TRY_CONVERT(DATE, st.DiscussionDateText) IS NULL
                     THEN ' | Discussion Date: invalid date.' ELSE '' END +
                CASE WHEN st.ETAText IS NOT NULL AND st.ETAText <> ''
                      AND TRY_CONVERT(DATE, st.ETAText) IS NULL
                     THEN ' | ETA: invalid date.' ELSE '' END +
                CASE WHEN st.ClosedDateText IS NOT NULL AND st.ClosedDateText <> ''
                      AND TRY_CONVERT(DATE, st.ClosedDateText) IS NULL
                     THEN ' | Closed Date: invalid date.' ELSE '' END,
            1, 3, '')   -- trim leading ' | '
    FROM dbo.NotesImportStaging st
    WHERE st.ImportBatchId = @ImportBatchId;

    -- rows with no accumulated error are valid
    UPDATE dbo.NotesImportStaging
    SET IsValid = 1
    WHERE ImportBatchId = @ImportBatchId
      AND (ValidationError IS NULL OR ValidationError = '');

    -- preview result set
    SELECT RowNumber, ReportName, WeekRangeText, RiskText, StatusText,
           IsValid, ValidationError
    FROM   dbo.NotesImportStaging
    WHERE  ImportBatchId = @ImportBatchId
    ORDER BY RowNumber;

    -- summary counts
    SELECT
        SUM(CASE WHEN IsValid = 1 THEN 1 ELSE 0 END) AS AcceptedRows,
        SUM(CASE WHEN IsValid = 0 THEN 1 ELSE 0 END) AS RejectedRows,
        COUNT(*)                                     AS TotalRows
    FROM dbo.NotesImportStaging
    WHERE ImportBatchId = @ImportBatchId;
END
GO

-- ------------------------------------------------------------
-- usp_NotesImport_Commit
--   Commits a validated batch: for each distinct Report+Week in
--   the batch, soft-deletes existing ACTIVE notes (truncate/
--   replace), then inserts the accepted staged rows as new notes
--   via the standard insert path (versioned, revision-logged).
--   Rejects commit if any row in the batch is still invalid.
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesImport_Commit', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesImport_Commit;
GO
CREATE PROCEDURE dbo.usp_NotesImport_Commit
    @ImportBatchId UNIQUEIDENTIFIER,
    @CommittedBy   NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF EXISTS (SELECT 1 FROM dbo.NotesImportStaging WHERE ImportBatchId = @ImportBatchId AND IsValid = 0)
    BEGIN
        RAISERROR('Import batch has invalid rows. Resolve validation errors before commit.', 16, 1);
        RETURN;
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.NotesImportStaging WHERE ImportBatchId = @ImportBatchId)
    BEGIN
        RAISERROR('Import batch is empty.', 16, 1);
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Step 1: truncate/replace — soft-delete existing ACTIVE notes
        -- for every Report + Week Range represented in the batch.
        UPDATE n
        SET n.IsDeleted = 1,
            n.LastEditedBy = @CommittedBy,
            n.LastEditedDateTime = GETDATE()
        FROM dbo.NotesInsight n
        INNER JOIN dbo.NotesReport rp ON rp.ReportKeyId = n.ReportKeyId
        WHERE n.IsDeleted = 0
          AND n.ArchiveStatus <> 'Archived'
          AND EXISTS (
                SELECT 1 FROM dbo.NotesImportStaging st
                WHERE st.ImportBatchId = @ImportBatchId
                  AND st.ReportName    = rp.ReportName
                  AND st.WeekRangeText = n.WeekRangeText);

        -- Step 2: insert accepted rows as new notes
        DECLARE @RowNumber INT, @NewNoteId INT;
        DECLARE @ReportKeyId INT, @ReportRunId NVARCHAR(50), @WeekRangeText NVARCHAR(50);
        DECLARE @RiskCode NVARCHAR(20), @ResponsibleParty NVARCHAR(200), @Insights NVARCHAR(MAX);
        DECLARE @NoOfSamples INT, @ActionSolution NVARCHAR(MAX), @FeedbackResponse NVARCHAR(MAX);
        DECLARE @Responsibility NVARCHAR(200), @DiscussionDate DATE, @ETA DATE, @ClosedDate DATE;
        DECLARE @StatusCode NVARCHAR(20), @ReportName NVARCHAR(200);
        DECLARE @WeekStart DATE, @WeekEnd DATE;

        DECLARE import_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT RowNumber, ReportName, WeekRangeText, ReportRunId,
                   ISNULL(RiskText, 'Yellow'),
                   ResponsibleParty, Insights,
                   TRY_CONVERT(INT, NoOfSamplesText),
                   ActionSolution, FeedbackResponse, Responsibility,
                   TRY_CONVERT(DATE, DiscussionDateText),
                   TRY_CONVERT(DATE, ETAText),
                   TRY_CONVERT(DATE, ClosedDateText),
                   ISNULL(StatusText, 'Open')
            FROM dbo.NotesImportStaging
            WHERE ImportBatchId = @ImportBatchId AND IsValid = 1
            ORDER BY RowNumber;

        OPEN import_cur;
        FETCH NEXT FROM import_cur INTO
            @RowNumber, @ReportName, @WeekRangeText, @ReportRunId, @RiskCode,
            @ResponsibleParty, @Insights, @NoOfSamples, @ActionSolution,
            @FeedbackResponse, @Responsibility, @DiscussionDate, @ETA,
            @ClosedDate, @StatusCode;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @ReportKeyId = (SELECT ReportKeyId FROM dbo.NotesReport WHERE ReportName = @ReportName);

            -- derive week start/end from "MM.DD.YYYY - MM.DD.YYYY" text (best effort)
            SET @WeekStart = TRY_CONVERT(DATE, REPLACE(LTRIM(RTRIM(LEFT(@WeekRangeText, CHARINDEX('-', @WeekRangeText + '-') - 1))), '.', '/'));
            SET @WeekEnd   = TRY_CONVERT(DATE, REPLACE(LTRIM(RTRIM(SUBSTRING(@WeekRangeText, CHARINDEX('-', @WeekRangeText + '-') + 1, 50))), '.', '/'));
            SET @WeekStart = ISNULL(@WeekStart, CAST(GETDATE() AS DATE));
            SET @WeekEnd   = ISNULL(@WeekEnd, @WeekStart);

            EXEC dbo.usp_NotesInsight_Insert
                 @ReportKeyId      = @ReportKeyId,
                 @ReportRunId      = @ReportRunId,
                 @WeekRangeStart   = @WeekStart,
                 @WeekRangeEnd     = @WeekEnd,
                 @WeekRangeText    = @WeekRangeText,
                 @RiskCode         = @RiskCode,
                 @ResponsibleParty = @ResponsibleParty,
                 @Insights         = @Insights,
                 @NoOfSamples      = @NoOfSamples,
                 @ActionSolution   = @ActionSolution,
                 @FeedbackResponse = @FeedbackResponse,
                 @Responsibility   = @Responsibility,
                 @DiscussionDate   = @DiscussionDate,
                 @ETA              = @ETA,
                 @ClosedDate       = @ClosedDate,
                 @StatusCode       = @StatusCode,
                 @SourceAction     = 'Import',
                 @CreatedBy        = @CommittedBy,
                 @NewNoteId        = @NewNoteId OUTPUT;

            FETCH NEXT FROM import_cur INTO
                @RowNumber, @ReportName, @WeekRangeText, @ReportRunId, @RiskCode,
                @ResponsibleParty, @Insights, @NoOfSamples, @ActionSolution,
                @FeedbackResponse, @Responsibility, @DiscussionDate, @ETA,
                @ClosedDate, @StatusCode;
        END
        CLOSE import_cur;
        DEALLOCATE import_cur;

        -- Step 3: clear staging for this batch
        DELETE FROM dbo.NotesImportStaging WHERE ImportBatchId = @ImportBatchId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        --IF CURSOR_STATUS('local', 'import_cur') >= 0 BEGIN CLOSE import_cur; DEALLOCATE import_cur; END
        --THROW;
		IF CURSOR_STATUS('local', 'import_cur') >= 0
			BEGIN
				CLOSE import_cur;
				DEALLOCATE import_cur;
			END;

		THROW;

    END CATCH
END
GO

PRINT '== 05_Create_SP_NotesInsights_Import.sql complete ==';
GO
