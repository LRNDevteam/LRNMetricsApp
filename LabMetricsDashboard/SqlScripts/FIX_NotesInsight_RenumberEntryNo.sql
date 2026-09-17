-- ============================================================
-- Script  : 09_NotesInsight_RenumberEntryNo.sql
-- Purpose : Insight # is 1..n for remaining active notes in the
--           same report + week. Delete compactes the list so the
--           next add is previous count + 1 (not MAX+1 forever).
-- Run     : Lab database (CoveLRN) after 08_NotesInsight_TotalCharge_SPs.sql
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

;WITH grp AS
(
    SELECT NoteId,
           ROW_NUMBER() OVER (
               PARTITION BY ReportKeyId, WeekRangeStart
               ORDER BY ISNULL(EntryNo, 2147483647), NoteId
           ) AS NewNo
    FROM dbo.NotesInsight
    WHERE IsDeleted = 0
      AND ArchiveStatus <> 'Archived'
)
UPDATE n
SET n.EntryNo = g.NewNo
FROM dbo.NotesInsight n
INNER JOIN grp g ON g.NoteId = n.NoteId;
GO

IF OBJECT_ID('dbo.usp_NotesInsight_Insert', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_NotesInsight_Insert;
GO
CREATE PROCEDURE dbo.usp_NotesInsight_Insert
    @ReportKeyId      INT,
    @ReportRunId      NVARCHAR(50)  = NULL,
    @WeekRangeStart   DATE,
    @WeekRangeEnd     DATE,
    @WeekRangeText    NVARCHAR(50)  = NULL,
    @RiskCode         NVARCHAR(20),
    @ResponsibleParty NVARCHAR(200) = NULL,
    @Insights         NVARCHAR(MAX) = NULL,
    @NoOfSamples      INT           = NULL,
    @TotalCharge      DECIMAL(18,2) = NULL,
    @DataLink         NVARCHAR(500) = NULL,
    @ActionSolution   NVARCHAR(MAX) = NULL,
    @FeedbackResponse NVARCHAR(MAX) = NULL,
    @Responsibility   NVARCHAR(200) = NULL,
    @DiscussionDate   DATE          = NULL,
    @ETA              DATE          = NULL,
    @ClosedDate       DATE          = NULL,
    @StatusCode       NVARCHAR(20),
    @SourceAction     NVARCHAR(50)  = 'Add Row',
    @CreatedBy        NVARCHAR(200),
    @NewNoteId        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @RiskLevelId INT = (SELECT RiskLevelId FROM dbo.NotesRiskLevel WHERE RiskCode = @RiskCode);
    DECLARE @StatusId    INT = (SELECT StatusId    FROM dbo.NotesStatus    WHERE StatusCode = @StatusCode);
    DECLARE @ReportName  NVARCHAR(200) = (SELECT ReportName FROM dbo.NotesReport WHERE ReportKeyId = @ReportKeyId);

    IF @RiskLevelId IS NULL BEGIN RAISERROR('Invalid RiskCode "%s".', 16, 1, @RiskCode); RETURN; END
    IF @StatusId    IS NULL BEGIN RAISERROR('Invalid StatusCode "%s".', 16, 1, @StatusCode); RETURN; END
    IF @ReportName  IS NULL BEGIN RAISERROR('Invalid ReportKeyId %d.', 16, 1, @ReportKeyId); RETURN; END

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @NextEntryNo INT =
        (
            SELECT COUNT(*) + 1
            FROM dbo.NotesInsight
            WHERE ReportKeyId = @ReportKeyId
              AND WeekRangeStart = @WeekRangeStart
              AND IsDeleted = 0
              AND ArchiveStatus <> 'Archived'
        );

        INSERT INTO dbo.NotesInsight
        (
            EntryNo, ReportKeyId, ReportName, ReportRunId,
            WeekRangeStart, WeekRangeEnd, WeekRangeText,
            RiskLevelId, ResponsibleParty, Insights, NoOfSamples, TotalCharge, DataLink,
            ActionSolution, FeedbackResponse, Responsibility,
            DiscussionDate, ETA, ClosedDate, StatusId,
            ArchiveStatus, VersionNumber, CreatedBy, CreatedDateTime
        )
        VALUES
        (
            @NextEntryNo, @ReportKeyId, @ReportName, @ReportRunId,
            @WeekRangeStart, @WeekRangeEnd, @WeekRangeText,
            @RiskLevelId, @ResponsibleParty, @Insights, @NoOfSamples, @TotalCharge, @DataLink,
            @ActionSolution, @FeedbackResponse, @Responsibility,
            @DiscussionDate, @ETA, @ClosedDate, @StatusId,
            'Active', 1, @CreatedBy, GETDATE()
        );

        SET @NewNoteId = SCOPE_IDENTITY();

        INSERT INTO dbo.NotesInsightRevision
            (NoteId, VersionNumber, EventType, SourceAction, RevisionSummary, RevisionSnapshot, EventUser, EventDateTime)
        VALUES
            (@NewNoteId, 1, 'Created', @SourceAction,
             'Note created for ' + @ReportName + ' (' + ISNULL(@WeekRangeText, '') + ').',
             (SELECT * FROM dbo.NotesInsight WHERE NoteId = @NewNoteId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
             @CreatedBy, GETDATE());

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

IF OBJECT_ID('dbo.usp_NotesInsight_Delete', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_NotesInsight_Delete;
GO
CREATE PROCEDURE dbo.usp_NotesInsight_Delete
    @NoteId     INT,
    @DeletedBy  NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ArchiveStatus NVARCHAR(20), @Version INT, @ReportKeyId INT, @WeekStart DATE;
    SELECT @ArchiveStatus = ArchiveStatus,
           @Version = VersionNumber,
           @ReportKeyId = ReportKeyId,
           @WeekStart = WeekRangeStart
    FROM dbo.NotesInsight WHERE NoteId = @NoteId AND IsDeleted = 0;

    IF @ArchiveStatus IS NULL BEGIN RAISERROR('NoteId %d not found or already deleted.', 16, 1, @NoteId); RETURN; END
    IF @ArchiveStatus = 'Archived'
        BEGIN RAISERROR('NoteId %d is archived and cannot be deleted.', 16, 1, @NoteId); RETURN; END

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.NotesInsight
        SET IsDeleted          = 1,
            LastEditedBy       = @DeletedBy,
            LastEditedDateTime = GETDATE()
        WHERE NoteId = @NoteId;

        INSERT INTO dbo.NotesInsightRevision
            (NoteId, VersionNumber, EventType, SourceAction, RevisionSummary, EventUser, EventDateTime)
        VALUES
            (@NoteId, @Version, 'Field Updated', 'Delete',
             'Active note soft-deleted.', @DeletedBy, GETDATE());

        ;WITH numbered AS
        (
            SELECT NoteId,
                   ROW_NUMBER() OVER (ORDER BY ISNULL(EntryNo, 2147483647), NoteId) AS NewNo
            FROM dbo.NotesInsight
            WHERE ReportKeyId = @ReportKeyId
              AND WeekRangeStart = @WeekStart
              AND IsDeleted = 0
              AND ArchiveStatus <> 'Archived'
        )
        UPDATE n
        SET n.EntryNo = numbered.NewNo
        FROM dbo.NotesInsight n
        INNER JOIN numbered ON numbered.NoteId = n.NoteId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

PRINT '== 09_NotesInsight_RenumberEntryNo.sql complete ==';
GO
