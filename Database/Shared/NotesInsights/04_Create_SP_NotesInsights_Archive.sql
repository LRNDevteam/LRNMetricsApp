-- ============================================================
-- Script  : 04_Create_SP_NotesInsights_Archive.sql
-- Feature : Executive Summary Notes & Insights
-- Purpose : Archive lifecycle procedures (scheduled Archive Job).
--             - usp_NotesInsight_RunArchiveLifecycle
--             - usp_NotesInsight_GetArchiveSummary  (archive cards)
-- Rule    : Only CLOSED notes older than the 4-week retention
--           threshold move to Archived. Open/WIP/Deferred notes
--           older than 4 weeks stay in Active Notes as
--           "Carry Forward" items (never buried in archive).
--           Archived rows are retained, not deleted.
-- Run     : After 01-03 scripts. usp_..RunArchiveLifecycle is
--           intended to be invoked by a SQL Agent job / scheduler.
-- ============================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ------------------------------------------------------------
-- usp_NotesInsight_RunArchiveLifecycle
--   1. Flags older unresolved (non-closed) notes as Carry Forward.
--   2. Moves Closed notes older than @RetentionWeeks into Archived,
--      stamping ArchivedDate and recording a "Moved to Archive"
--      revision event per note.
--   @AsOfDate lets the job be tested deterministically.
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesInsight_RunArchiveLifecycle', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesInsight_RunArchiveLifecycle;
GO
CREATE PROCEDURE dbo.usp_NotesInsight_RunArchiveLifecycle
    @RetentionWeeks INT           = 4,
    @AsOfDate       DATE          = NULL,
    @RunBy          NVARCHAR(200) = 'Archive Job'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Today   DATE = ISNULL(@AsOfDate, CAST(GETDATE() AS DATE));
    DECLARE @Cutoff  DATE = DATEADD(DAY, -7 * @RetentionWeeks, @Today);
    DECLARE @ClosedStatusId INT = (SELECT StatusId FROM dbo.NotesStatus WHERE StatusCode = 'Closed');

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Step 1: mark older, still-open items as Carry Forward
        UPDATE n
        SET n.ArchiveStatus = 'Carry Forward'
        FROM dbo.NotesInsight n
        INNER JOIN dbo.NotesStatus s ON s.StatusId = n.StatusId
        WHERE n.IsDeleted = 0
          AND n.ArchiveStatus = 'Active'
          AND n.WeekRangeEnd < @Cutoff
          AND s.IsClosedState = 0;

        -- Step 2: collect Closed notes past retention to archive
        DECLARE @ToArchive TABLE (NoteId INT PRIMARY KEY, Version INT);
        INSERT INTO @ToArchive (NoteId, Version)
        SELECT n.NoteId, n.VersionNumber
        FROM dbo.NotesInsight n
        WHERE n.IsDeleted = 0
          AND n.ArchiveStatus <> 'Archived'
          AND n.StatusId = @ClosedStatusId
          AND n.WeekRangeEnd < @Cutoff;

        UPDATE n
        SET n.ArchiveStatus = 'Archived',
            n.ArchivedDate  = GETDATE()
        FROM dbo.NotesInsight n
        INNER JOIN @ToArchive a ON a.NoteId = n.NoteId;

        -- revision event per archived note
        INSERT INTO dbo.NotesInsightRevision
            (NoteId, VersionNumber, EventType, SourceAction, RevisionSummary, EventUser, EventDateTime)
        SELECT a.NoteId, a.Version, 'Moved to Archive', 'Archive Job',
               'Closed note older than ' + CAST(@RetentionWeeks AS NVARCHAR(5)) + ' weeks moved to Archived.',
               @RunBy, GETDATE()
        FROM @ToArchive a;

        DECLARE @ArchivedCount INT = (SELECT COUNT(*) FROM @ToArchive);

        COMMIT TRANSACTION;

        SELECT @ArchivedCount AS NotesArchived, @Cutoff AS RetentionCutoff;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ------------------------------------------------------------
-- usp_NotesInsight_GetArchiveSummary
--   Feeds the archive summary cards: Total Archived, Red Risk
--   Archived, Closed This Month, Last Archived Date.
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesInsight_GetArchiveSummary', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesInsight_GetArchiveSummary;
GO
CREATE PROCEDURE dbo.usp_NotesInsight_GetArchiveSummary
    @ReportKeyId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        (SELECT COUNT(*) FROM dbo.NotesInsight
          WHERE ReportKeyId = @ReportKeyId AND ArchiveStatus = 'Archived' AND IsDeleted = 0)         AS TotalArchived,
        (SELECT COUNT(*) FROM dbo.NotesInsight n
           INNER JOIN dbo.NotesRiskLevel r ON r.RiskLevelId = n.RiskLevelId
          WHERE n.ReportKeyId = @ReportKeyId AND n.ArchiveStatus = 'Archived'
            AND n.IsDeleted = 0 AND r.RiskCode = 'Red')                                              AS RedRiskArchived,
        (SELECT COUNT(*) FROM dbo.NotesInsight
          WHERE ReportKeyId = @ReportKeyId AND ArchiveStatus = 'Archived' AND IsDeleted = 0
            AND ClosedDate >= DATEADD(DAY, 1, EOMONTH(GETDATE(), -1)))                               AS ClosedThisMonth,
        (SELECT MAX(ArchivedDate) FROM dbo.NotesInsight
          WHERE ReportKeyId = @ReportKeyId AND ArchiveStatus = 'Archived' AND IsDeleted = 0)         AS LastArchivedDate;
END
GO

PRINT '== 04_Create_SP_NotesInsights_Archive.sql complete ==';
GO
