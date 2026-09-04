-- ============================================================
-- Production Insights — TotalCharge + export/template FieldKey
-- Run on the lab database (CoveLRN) AFTER 07_ProductionInsights_Cove.sql.
-- Recreates write/read/template SPs so TotalCharge, DataLink and
-- FieldKey flow through stored procedures only.
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
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

        DECLARE @NextEntryNo INT = ISNULL((SELECT MAX(EntryNo) FROM dbo.NotesInsight), 0) + 1;

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

IF OBJECT_ID('dbo.usp_NotesInsight_Update', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_NotesInsight_Update;
GO
CREATE PROCEDURE dbo.usp_NotesInsight_Update
    @NoteId           INT,
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
    @SourceAction     NVARCHAR(50)  = 'Save Changes',
    @LastEditedBy     NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

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
            TotalCharge        = @TotalCharge,
            DataLink           = @DataLink,
            ActionSolution     = @ActionSolution,
            FeedbackResponse   = @FeedbackResponse,
            Responsibility     = @Responsibility,
            DiscussionDate     = @DiscussionDate,
            ETA                = @ETA,
            ClosedDate         = CASE WHEN @StatusId = @ClosedStatusId AND @ClosedDate IS NULL
                                      THEN CAST(GETDATE() AS DATE) ELSE @ClosedDate END,
            StatusId           = @StatusId,
            VersionNumber      = @NewVersion,
            LastEditedBy       = @LastEditedBy,
            LastEditedDateTime = GETDATE()
        WHERE NoteId = @NoteId;

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
             @OldSnapshot, @LastEditedBy, GETDATE());

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

IF OBJECT_ID('dbo.usp_NotesInsight_GetActive', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_NotesInsight_GetActive;
GO
CREATE PROCEDURE dbo.usp_NotesInsight_GetActive
    @ReportKeyId     INT,
    @WeekRangeStart  DATE          = NULL,
    @DiscussionDate  DATE          = NULL,
    @ETADate         DATE          = NULL,
    @StatusCode      NVARCHAR(20)  = NULL,
    @RiskCode        NVARCHAR(20)  = NULL,
    @Responsibility  NVARCHAR(200) = NULL,
    @SearchText      NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @LatestWeekEnd DATE =
    (
        SELECT MAX(WeekRangeEnd)
        FROM dbo.NotesInsight
        WHERE ReportKeyId = @ReportKeyId AND IsDeleted = 0
    );
    DECLARE @WindowStart DATE = DATEADD(DAY, -27, ISNULL(@LatestWeekEnd, CAST(GETDATE() AS DATE)));

    SELECT  n.NoteId, n.EntryNo, n.ReportName, n.ReportRunId,
            n.WeekRangeText, n.WeekRangeStart, n.WeekRangeEnd,
            r.RiskCode, r.RiskLabel, r.ColorHex,
            n.ResponsibleParty, n.Insights, n.NoOfSamples, n.TotalCharge, n.DataLink,
            n.ActionSolution, n.FeedbackResponse, n.Responsibility,
            n.DiscussionDate, n.ETA, n.ClosedDate,
            s.StatusCode, s.StatusLabel, n.ArchiveStatus, n.VersionNumber,
            n.CreatedBy, n.CreatedDateTime, n.LastEditedBy, n.LastEditedDateTime,
            CASE WHEN n.ETA IS NOT NULL AND n.ETA < CAST(GETDATE() AS DATE)
                      AND s.IsClosedState = 0 THEN 1 ELSE 0 END AS IsOverdueETA
    FROM        dbo.NotesInsight   n
    INNER JOIN  dbo.NotesRiskLevel r ON r.RiskLevelId = n.RiskLevelId
    INNER JOIN  dbo.NotesStatus    s ON s.StatusId    = n.StatusId
    WHERE   n.ReportKeyId = @ReportKeyId
        AND n.IsDeleted   = 0
        AND n.ArchiveStatus <> 'Archived'
        AND ( n.WeekRangeStart >= @WindowStart OR s.IsClosedState = 0 )
        AND (@WeekRangeStart IS NULL OR n.WeekRangeStart = @WeekRangeStart)
        AND (@DiscussionDate IS NULL OR n.DiscussionDate = @DiscussionDate)
        AND (@ETADate        IS NULL OR n.ETA            = @ETADate)
        AND (@StatusCode     IS NULL OR s.StatusCode     = @StatusCode)
        AND (@RiskCode       IS NULL OR r.RiskCode       = @RiskCode)
        AND (@Responsibility IS NULL OR n.Responsibility = @Responsibility)
        AND (@SearchText     IS NULL
             OR n.Insights         LIKE '%' + @SearchText + '%'
             OR n.ActionSolution   LIKE '%' + @SearchText + '%'
             OR n.FeedbackResponse LIKE '%' + @SearchText + '%'
             OR n.ResponsibleParty LIKE '%' + @SearchText + '%')
    ORDER BY n.WeekRangeStart DESC, n.EntryNo DESC;
END
GO

IF OBJECT_ID('dbo.usp_NotesInsight_GetById', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_NotesInsight_GetById;
GO
CREATE PROCEDURE dbo.usp_NotesInsight_GetById
    @NoteId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT  n.NoteId, n.EntryNo, n.ReportKeyId, n.ReportName, n.ReportRunId,
            n.WeekRangeText, n.WeekRangeStart, n.WeekRangeEnd,
            n.RiskLevelId, r.RiskCode, r.RiskLabel, r.ColorHex,
            n.ResponsibleParty, n.Insights, n.NoOfSamples, n.TotalCharge, n.DataLink,
            n.ActionSolution, n.FeedbackResponse, n.Responsibility,
            n.DiscussionDate, n.ETA, n.ClosedDate,
            n.StatusId, s.StatusCode, s.StatusLabel,
            n.ArchiveStatus, n.ArchivedDate, n.VersionNumber,
            n.CreatedBy, n.CreatedDateTime, n.LastEditedBy, n.LastEditedDateTime,
            CASE WHEN n.ArchiveStatus = 'Archived' OR n.IsDeleted = 1 THEN 0 ELSE 1 END AS IsEditable
    FROM        dbo.NotesInsight   n
    INNER JOIN  dbo.NotesRiskLevel r ON r.RiskLevelId = n.RiskLevelId
    INNER JOIN  dbo.NotesStatus    s ON s.StatusId    = n.StatusId
    WHERE n.NoteId = @NoteId;
END
GO

IF OBJECT_ID('dbo.usp_NotesInsight_GetExportData', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_NotesInsight_GetExportData;
GO
CREATE PROCEDURE dbo.usp_NotesInsight_GetExportData
    @ReportKeyId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @LatestWeekEnd DATE =
    (
        SELECT MAX(WeekRangeEnd)
        FROM dbo.NotesInsight
        WHERE ReportKeyId = @ReportKeyId AND IsDeleted = 0
    );
    DECLARE @WindowStart DATE = DATEADD(DAY, -27, ISNULL(@LatestWeekEnd, CAST(GETDATE() AS DATE)));

    SELECT  n.EntryNo               AS [#],
            CASE r.RiskCode WHEN 'Red' THEN N'High' WHEN 'Green' THEN N'Low' ELSE N'Medium' END AS [Risk],
            n.ResponsibleParty      AS [Responsible Party],
            n.Insights              AS [Insights],
            n.NoOfSamples           AS [# of Claims],
            n.TotalCharge           AS [Total Charge],
            n.DataLink              AS [Data],
            n.ActionSolution        AS [Action / Solution / Suggestions],
            n.FeedbackResponse      AS [Feedback / Response],
            n.Responsibility        AS [Responsibility],
            n.DiscussionDate        AS [Discussion Date],
            n.ETA                   AS [ETA],
            n.ClosedDate            AS [Closed Date],
            s.StatusLabel           AS [Status]
    FROM        dbo.NotesInsight   n
    INNER JOIN  dbo.NotesRiskLevel r ON r.RiskLevelId = n.RiskLevelId
    INNER JOIN  dbo.NotesStatus    s ON s.StatusId    = n.StatusId
    WHERE   n.ReportKeyId = @ReportKeyId
        AND n.IsDeleted   = 0
        AND n.ArchiveStatus <> 'Archived'
        AND (n.WeekRangeStart >= @WindowStart OR s.IsClosedState = 0)
    ORDER BY n.WeekRangeStart DESC, n.EntryNo DESC;
END
GO

IF OBJECT_ID('dbo.usp_NotesTemplate_GetByReport', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_NotesTemplate_GetByReport;
GO
CREATE PROCEDURE dbo.usp_NotesTemplate_GetByReport
    @ReportKeyId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TemplateId, ReportKeyId, TemplateName, IsActive,
           CreatedBy, CreatedDateTime, LastEditedBy, LastEditedDateTime
    FROM   dbo.NotesTemplate
    WHERE  ReportKeyId = @ReportKeyId AND IsActive = 1;

    SELECT c.ColumnId, c.TemplateId, c.ColumnName, c.ColumnType,
           c.IsRequired, c.SortOrder, c.IsActive, c.FieldKey
    FROM   dbo.NotesTemplateColumn c
    INNER JOIN dbo.NotesTemplate t ON t.TemplateId = c.TemplateId
    WHERE  t.ReportKeyId = @ReportKeyId AND t.IsActive = 1 AND c.IsActive = 1
    ORDER BY c.TemplateId, c.SortOrder;

    SELECT v.ColumnValueId, v.ColumnId, v.DropdownValue, v.SortOrder, v.IsActive
    FROM   dbo.NotesTemplateColumnValue v
    INNER JOIN dbo.NotesTemplateColumn c ON c.ColumnId = v.ColumnId
    INNER JOIN dbo.NotesTemplate t ON t.TemplateId = c.TemplateId
    WHERE  t.ReportKeyId = @ReportKeyId AND t.IsActive = 1
       AND c.IsActive = 1 AND v.IsActive = 1
    ORDER BY v.ColumnId, v.SortOrder;
END
GO

IF OBJECT_ID('dbo.usp_NotesTemplateColumn_Upsert', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_NotesTemplateColumn_Upsert;
GO
CREATE PROCEDURE dbo.usp_NotesTemplateColumn_Upsert
    @ColumnId       INT           = NULL,
    @TemplateId     INT,
    @ColumnName     NVARCHAR(200),
    @ColumnType     NVARCHAR(20),
    @IsRequired     BIT           = 0,
    @SortOrder      INT           = 0,
    @FieldKey       NVARCHAR(50)  = NULL,
    @DropdownValues NVARCHAR(MAX) = NULL,
    @OutColumnId    INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ColumnType NOT IN ('Text', 'Date', 'Dropdown')
    BEGIN
        RAISERROR('ColumnType must be Text, Date or Dropdown.', 16, 1);
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @ColumnId IS NULL
        BEGIN
            INSERT INTO dbo.NotesTemplateColumn (TemplateId, ColumnName, ColumnType, IsRequired, SortOrder, IsActive, FieldKey)
            VALUES (@TemplateId, @ColumnName, @ColumnType, @IsRequired, @SortOrder, 1, @FieldKey);
            SET @OutColumnId = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            UPDATE dbo.NotesTemplateColumn
            SET ColumnName = @ColumnName,
                ColumnType = @ColumnType,
                IsRequired = @IsRequired,
                SortOrder  = @SortOrder,
                FieldKey   = @FieldKey
            WHERE ColumnId = @ColumnId;
            SET @OutColumnId = @ColumnId;
        END

        IF @ColumnType = 'Dropdown'
        BEGIN
            UPDATE dbo.NotesTemplateColumnValue SET IsActive = 0 WHERE ColumnId = @OutColumnId;

            IF @DropdownValues IS NOT NULL AND LTRIM(RTRIM(@DropdownValues)) <> ''
            BEGIN
                ;WITH parsed AS
                (
                    SELECT LTRIM(RTRIM(value)) AS DropdownValue,
                           ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS Ord
                    FROM STRING_SPLIT(@DropdownValues, '|')
                    WHERE LTRIM(RTRIM(value)) <> ''
                )
                INSERT INTO dbo.NotesTemplateColumnValue (ColumnId, DropdownValue, SortOrder, IsActive)
                SELECT @OutColumnId, DropdownValue, Ord, 1 FROM parsed;
            END
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

PRINT '== 08_NotesInsight_TotalCharge_SPs.sql complete ==';
GO
