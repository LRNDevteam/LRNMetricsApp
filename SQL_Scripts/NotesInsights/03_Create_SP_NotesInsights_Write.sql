-- ============================================================
-- Script  : 03_Create_SP_NotesInsights_Write.sql
-- Feature : Executive Summary Notes & Insights
-- Purpose : Transactional write procedures. ALL inserts/updates/
--           deletes for the Notes feature go through these
--           procedures only; each write records a revision event.
--             - usp_NotesInsight_Insert   (Add Insight / Create)
--             - usp_NotesInsight_Update   (Save Changes -> new version)
--             - usp_NotesInsight_Delete   (soft delete active note)
-- Run     : After 01 and 02 scripts.
-- Notes   : Versioning + audit are enforced here so the app layer
--           cannot bypass revision history with inline SQL.
-- ============================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ------------------------------------------------------------
-- usp_NotesInsight_Insert
--   Creates a new note (version 1) scoped to a report + week,
--   assigns the next running-log EntryNo, resolves Risk/Status
--   codes to IDs, and writes a "Created" revision event.
--   Returns the new NoteId.
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesInsight_Insert', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesInsight_Insert;
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

        -- next sequential running-log number (global, not per week)
        DECLARE @NextEntryNo INT = ISNULL((SELECT MAX(EntryNo) FROM dbo.NotesInsight), 0) + 1;

        INSERT INTO dbo.NotesInsight
        (
            EntryNo, ReportKeyId, ReportName, ReportRunId,
            WeekRangeStart, WeekRangeEnd, WeekRangeText,
            RiskLevelId, ResponsibleParty, Insights, NoOfSamples, DataLink,
            ActionSolution, FeedbackResponse, Responsibility,
            DiscussionDate, ETA, ClosedDate, StatusId,
            ArchiveStatus, VersionNumber, CreatedBy, CreatedDateTime
        )
        VALUES
        (
            @NextEntryNo, @ReportKeyId, @ReportName, @ReportRunId,
            @WeekRangeStart, @WeekRangeEnd, @WeekRangeText,
            @RiskLevelId, @ResponsibleParty, @Insights, @NoOfSamples, @DataLink,
            @ActionSolution, @FeedbackResponse, @Responsibility,
            @DiscussionDate, @ETA, @ClosedDate, @StatusId,
            'Active', 1, @CreatedBy, GETDATE()
        );

        SET @NewNoteId = SCOPE_IDENTITY();

        -- revision event: Created
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

-- ------------------------------------------------------------
-- usp_NotesInsight_Update
--   Save Changes on an ACTIVE note. Blocks edits on archived or
--   deleted notes. Increments VersionNumber, captures LastEdited,
--   derives an EventType from what changed, and records a
--   revision event with a before-image snapshot.
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesInsight_Update', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesInsight_Update;
GO
CREATE PROCEDURE dbo.usp_NotesInsight_Update
    @NoteId           INT,
    @RiskCode         NVARCHAR(20),
    @ResponsibleParty NVARCHAR(200) = NULL,
    @Insights         NVARCHAR(MAX) = NULL,
    @NoOfSamples      INT           = NULL,
    @DataLink         NVARCHAR(500) = NULL,
    @ActionSolution   NVARCHAR(MAX) = NULL,
    @FeedbackResponse NVARCHAR(MAX) = NULL,
    @Responsibility   NVARCHAR(200) = NULL,
    @DiscussionDate   DATE          = NULL,
    @ETA              DATE          = NULL,
    @ClosedDate       DATE          = NULL,
    @StatusCode       NVARCHAR(20),
    @SourceAction     NVARCHAR(50)  = 'Save Changes',
    @LastEditedBy     NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- guard: note must exist, be active and not deleted
    DECLARE @ArchiveStatus NVARCHAR(20), @IsDeleted BIT;
    SELECT @ArchiveStatus = ArchiveStatus, @IsDeleted = IsDeleted
    FROM dbo.NotesInsight WHERE NoteId = @NoteId;

    IF @ArchiveStatus IS NULL BEGIN RAISERROR('NoteId %d not found.', 16, 1, @NoteId); RETURN; END
    IF @IsDeleted = 1         BEGIN RAISERROR('NoteId %d is deleted and cannot be edited.', 16, 1, @NoteId); RETURN; END
    IF @ArchiveStatus = 'Archived'
        BEGIN RAISERROR('NoteId %d is archived and is read-only.', 16, 1, @NoteId); RETURN; END

    DECLARE @RiskLevelId INT = (SELECT RiskLevelId FROM dbo.NotesRiskLevel WHERE RiskCode = @RiskCode);
    DECLARE @StatusId    INT = (SELECT StatusId    FROM dbo.NotesStatus    WHERE StatusCode = @StatusCode);
    IF @RiskLevelId IS NULL BEGIN RAISERROR('Invalid RiskCode "%s".', 16, 1, @RiskCode); RETURN; END
    IF @StatusId    IS NULL BEGIN RAISERROR('Invalid StatusCode "%s".', 16, 1, @StatusCode); RETURN; END

    BEGIN TRY
        BEGIN TRANSACTION;

        -- capture before-image for change detection + snapshot
        DECLARE @OldRiskId INT, @OldStatusId INT, @OldETA DATE, @OldFeedback NVARCHAR(MAX), @OldVersion INT;
        DECLARE @OldSnapshot NVARCHAR(MAX);
        SELECT  @OldRiskId   = RiskLevelId,
                @OldStatusId = StatusId,
                @OldETA      = ETA,
                @OldFeedback = FeedbackResponse,
                @OldVersion  = VersionNumber,
                @OldSnapshot = (SELECT * FROM dbo.NotesInsight WHERE NoteId = @NoteId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
        FROM dbo.NotesInsight WHERE NoteId = @NoteId;

        DECLARE @NewVersion INT = @OldVersion + 1;
        DECLARE @ClosedStatusId INT = (SELECT StatusId FROM dbo.NotesStatus WHERE StatusCode = 'Closed');

        UPDATE dbo.NotesInsight
        SET RiskLevelId        = @RiskLevelId,
            ResponsibleParty   = @ResponsibleParty,
            Insights           = @Insights,
            NoOfSamples        = @NoOfSamples,
            DataLink           = @DataLink,
            ActionSolution     = @ActionSolution,
            FeedbackResponse   = @FeedbackResponse,
            Responsibility     = @Responsibility,
            DiscussionDate     = @DiscussionDate,
            ETA                = @ETA,
            -- auto-stamp ClosedDate when transitioning to Closed and none supplied
            ClosedDate         = CASE WHEN @StatusId = @ClosedStatusId AND @ClosedDate IS NULL
                                      THEN CAST(GETDATE() AS DATE) ELSE @ClosedDate END,
            StatusId           = @StatusId,
            VersionNumber      = @NewVersion,
            LastEditedBy       = @LastEditedBy,
            LastEditedDateTime = GETDATE()
        WHERE NoteId = @NoteId;

        -- derive the most meaningful event type
        DECLARE @EventType NVARCHAR(50) =
            CASE
                WHEN @StatusId = @ClosedStatusId AND @OldStatusId <> @ClosedStatusId THEN 'Note Closed'
                WHEN @StatusId <> @OldStatusId                                       THEN 'Status Changed'
                WHEN @RiskLevelId <> @OldRiskId                                      THEN 'Risk Changed'
                WHEN ISNULL(@ETA, '1900-01-01') <> ISNULL(@OldETA, '1900-01-01')     THEN 'ETA Changed'
                WHEN ISNULL(@FeedbackResponse,'') <> ISNULL(@OldFeedback,'')         THEN 'Feedback Added'
                ELSE 'Field Updated'
            END;

        INSERT INTO dbo.NotesInsightRevision
            (NoteId, VersionNumber, EventType, SourceAction, RevisionSummary, RevisionSnapshot, EventUser, EventDateTime)
        VALUES
            (@NoteId, @NewVersion, @EventType, @SourceAction,
             'Saved changes (v' + CAST(@OldVersion AS NVARCHAR(10)) + ' -> v' + CAST(@NewVersion AS NVARCHAR(10)) + ').',
             @OldSnapshot,   -- preserve the prior version image
             @LastEditedBy, GETDATE());

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ------------------------------------------------------------
-- usp_NotesInsight_Delete
--   Soft-deletes an ACTIVE note (Active Notes grid trash action).
--   Archived notes cannot be deleted. Records a revision event.
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesInsight_Delete', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesInsight_Delete;
GO
CREATE PROCEDURE dbo.usp_NotesInsight_Delete
    @NoteId     INT,
    @DeletedBy  NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ArchiveStatus NVARCHAR(20), @Version INT;
    SELECT @ArchiveStatus = ArchiveStatus, @Version = VersionNumber
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

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

PRINT '== 03_Create_SP_NotesInsights_Write.sql complete ==';
GO
