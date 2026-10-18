-- ============================================================
-- Script  : 11_NotesInsight_WeekRangeLifecycle.sql
-- Feature : Notes & Insights - week-range lifecycle
-- Purpose :
--   - usp_NotesInsight_ArchivePreviousWeeks : when a new week range is
--     loaded, every non-archived insight of the report whose
--     WeekRangeEnd is before the current week start moves to Archived
--     (one "Moved to Archive" revision per insight).
--   - usp_NotesInsight_SetWeekRange : edit WeekRangeStart / End / Text
--     of an active insight.
--   - usp_NotesInsight_GetArchived  : adds TotalCharge / DataLink and
--     lists the newest week range first.
-- Enable  : run on a lab database after scripts 01-10. The web app turns
--           on the editable week range + auto-archive for a lab only when
--           dbo.usp_NotesInsight_ArchivePreviousWeeks exists there.
-- Re-run  : safe (CREATE OR ALTER).
-- ============================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_NotesInsight_ArchivePreviousWeeks
    @ReportKeyId      INT,
    @CurrentWeekStart DATE,
    @CurrentWeekText  NVARCHAR(50)  = NULL,
    @RunBy            NVARCHAR(200) = 'Week Range Rollover'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Archived TABLE (NoteId INT PRIMARY KEY, VersionNumber INT, WeekRangeText NVARCHAR(50));
    DECLARE @WeekLabel NVARCHAR(50) =
        ISNULL(NULLIF(LTRIM(RTRIM(@CurrentWeekText)), ''), CONVERT(NVARCHAR(10), @CurrentWeekStart, 101));

    BEGIN TRANSACTION;

    UPDATE n
    SET    n.ArchiveStatus = 'Archived',
           n.ArchivedDate  = GETDATE()
    OUTPUT inserted.NoteId, inserted.VersionNumber, inserted.WeekRangeText
    INTO   @Archived (NoteId, VersionNumber, WeekRangeText)
    FROM   dbo.NotesInsight n
    WHERE  n.ReportKeyId   = @ReportKeyId
      AND  n.IsDeleted     = 0
      AND  n.ArchiveStatus <> 'Archived'
      AND  n.WeekRangeEnd  < @CurrentWeekStart;

    INSERT INTO dbo.NotesInsightRevision
        (NoteId, VersionNumber, EventType, SourceAction, RevisionSummary, EventUser, EventDateTime)
    SELECT a.NoteId, a.VersionNumber, 'Moved to Archive', 'Week Range Rollover',
           'New week range ' + @WeekLabel + ' loaded. Insight for '
             + ISNULL(a.WeekRangeText, 'previous week') + ' moved to Archived.',
           @RunBy, GETDATE()
    FROM @Archived a;

    COMMIT TRANSACTION;

    SELECT COUNT(*) AS NotesArchived FROM @Archived;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_NotesInsight_SetWeekRange
    @NoteId         INT,
    @WeekRangeStart DATE,
    @WeekRangeEnd   DATE,
    @WeekRangeText  NVARCHAR(50)  = NULL,
    @EditedBy       NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @WeekRangeEnd < @WeekRangeStart
    BEGIN
        RAISERROR('Week Range End cannot be before Week Range Start.', 16, 1);
        RETURN;
    END;

    DECLARE @Text NVARCHAR(50) = NULLIF(LTRIM(RTRIM(@WeekRangeText)), '');
    IF @Text IS NULL
        SET @Text = CASE WHEN @WeekRangeStart = @WeekRangeEnd
                         THEN FORMAT(@WeekRangeStart, 'MM.dd.yyyy')
                         ELSE FORMAT(@WeekRangeStart, 'MM.dd.yyyy') + ' - ' + FORMAT(@WeekRangeEnd, 'MM.dd.yyyy') END;

    DECLARE @OldText NVARCHAR(50), @OldStart DATE, @OldEnd DATE, @Archive NVARCHAR(20), @Version INT;
    SELECT @OldText = WeekRangeText, @OldStart = WeekRangeStart, @OldEnd = WeekRangeEnd,
           @Archive = ArchiveStatus, @Version = VersionNumber
    FROM dbo.NotesInsight
    WHERE NoteId = @NoteId AND IsDeleted = 0;

    IF @Archive IS NULL BEGIN RAISERROR('NoteId %d not found or already deleted.', 16, 1, @NoteId); RETURN; END;
    IF @Archive = 'Archived' BEGIN RAISERROR('Archived insights are read-only.', 16, 1); RETURN; END;

    IF @OldStart = @WeekRangeStart AND @OldEnd = @WeekRangeEnd AND ISNULL(@OldText, '') = @Text
    BEGIN
        SELECT CAST(0 AS BIT) AS Changed;
        RETURN;
    END;

    BEGIN TRANSACTION;

    UPDATE dbo.NotesInsight
    SET    WeekRangeStart     = @WeekRangeStart,
           WeekRangeEnd       = @WeekRangeEnd,
           WeekRangeText      = @Text,
           LastEditedBy       = @EditedBy,
           LastEditedDateTime = GETDATE()
    WHERE  NoteId = @NoteId;

    INSERT INTO dbo.NotesInsightRevision
        (NoteId, VersionNumber, EventType, SourceAction, RevisionSummary, EventUser, EventDateTime)
    VALUES
        (@NoteId, @Version, 'Week Range Changed', 'Save Changes',
         'Week range changed from ' + ISNULL(@OldText, '(blank)') + ' to ' + @Text + '.',
         @EditedBy, GETDATE());

    COMMIT TRANSACTION;

    SELECT CAST(1 AS BIT) AS Changed;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_NotesInsight_GetArchived
    @ReportKeyId        INT,
    @WeekRangeStart     DATE          = NULL,
    @DiscussionDateFrom DATE          = NULL,
    @DiscussionDateTo   DATE          = NULL,
    @ETAFrom            DATE          = NULL,
    @ETATo              DATE          = NULL,
    @ClosedDateFrom     DATE          = NULL,
    @ClosedDateTo       DATE          = NULL,
    @Responsibility     NVARCHAR(200) = NULL,
    @ResponsibleParty   NVARCHAR(200) = NULL,
    @StatusCode         NVARCHAR(20)  = NULL,
    @RiskCode           NVARCHAR(20)  = NULL,
    @SearchText         NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT  n.NoteId, n.EntryNo, n.ReportName, n.ReportRunId,
            n.WeekRangeText, n.WeekRangeStart, n.WeekRangeEnd,
            r.RiskCode, r.RiskLabel, r.ColorHex,
            n.ResponsibleParty, n.Insights, n.NoOfSamples, n.TotalCharge, n.DataLink,
            n.ActionSolution, n.FeedbackResponse, n.Responsibility,
            n.DiscussionDate, n.ETA, n.ClosedDate,
            s.StatusCode, s.StatusLabel,
            n.ArchiveStatus, n.ArchivedDate, n.VersionNumber,
            n.CreatedBy, n.CreatedDateTime, n.LastEditedBy, n.LastEditedDateTime
    FROM        dbo.NotesInsight   n
    INNER JOIN  dbo.NotesRiskLevel r ON r.RiskLevelId = n.RiskLevelId
    INNER JOIN  dbo.NotesStatus    s ON s.StatusId    = n.StatusId
    WHERE   n.ReportKeyId   = @ReportKeyId
        AND n.IsDeleted     = 0
        AND n.ArchiveStatus = 'Archived'
        AND (@WeekRangeStart     IS NULL OR n.WeekRangeStart = @WeekRangeStart)
        AND (@DiscussionDateFrom IS NULL OR n.DiscussionDate >= @DiscussionDateFrom)
        AND (@DiscussionDateTo   IS NULL OR n.DiscussionDate <= @DiscussionDateTo)
        AND (@ETAFrom            IS NULL OR n.ETA >= @ETAFrom)
        AND (@ETATo              IS NULL OR n.ETA <= @ETATo)
        AND (@ClosedDateFrom     IS NULL OR n.ClosedDate >= @ClosedDateFrom)
        AND (@ClosedDateTo       IS NULL OR n.ClosedDate <= @ClosedDateTo)
        AND (@Responsibility     IS NULL OR n.Responsibility = @Responsibility)
        AND (@ResponsibleParty   IS NULL OR n.ResponsibleParty = @ResponsibleParty)
        AND (@StatusCode         IS NULL OR s.StatusCode = @StatusCode)
        AND (@RiskCode           IS NULL OR r.RiskCode = @RiskCode)
        AND (@SearchText         IS NULL
             OR n.Insights         LIKE '%' + @SearchText + '%'
             OR n.ActionSolution   LIKE '%' + @SearchText + '%'
             OR n.FeedbackResponse LIKE '%' + @SearchText + '%'
             OR n.ResponsibleParty LIKE '%' + @SearchText + '%'
             OR n.Responsibility   LIKE '%' + @SearchText + '%'
             OR n.WeekRangeText    LIKE '%' + @SearchText + '%'
             OR n.CreatedBy        LIKE '%' + @SearchText + '%'
             OR n.LastEditedBy     LIKE '%' + @SearchText + '%')
    ORDER BY n.WeekRangeStart DESC, n.EntryNo ASC, n.NoteId ASC;
END
GO

PRINT '11_NotesInsight_WeekRangeLifecycle: week-range lifecycle procedures ready.';
GO
