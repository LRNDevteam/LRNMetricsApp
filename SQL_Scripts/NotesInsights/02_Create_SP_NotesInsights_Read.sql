-- ============================================================
-- Script  : 02_Create_SP_NotesInsights_Read.sql
-- Feature : Executive Summary Notes & Insights
-- Purpose : Read/query stored procedures. ALL reads for the
--           Notes feature go through these procedures only.
--             - usp_NotesInsight_GetActive        (Active log: last 4 weeks + carry-forward)
--             - usp_NotesInsight_GetArchived       (report-scoped archive)
--             - usp_NotesInsight_GetById           (detail modal)
--             - usp_NotesInsight_GetRevisionHistory
--             - usp_NotesInsight_GetConsolidated   (cross-report Insights Log)
--             - usp_NotesInsight_GetExportData     (Export Excel Notes sheet)
--             - usp_NotesInsight_GetArchiveSummary (archive summary cards)
--             - usp_NotesReport_Ensure             (report registry resolution)
--             - usp_NotesLookup_GetAll             (Risk/Status/Report lists)
-- Run     : After 01_Create_NotesInsights_Tables.sql.
-- ============================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ------------------------------------------------------------
-- usp_NotesInsight_GetActive
--   Active Notes log for a report: the most recent 4 billed
--   weeks PLUS older unresolved (Open/WIP/Deferred) carry-forward
--   items. Archived rows and soft-deleted rows are excluded.
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesInsight_GetActive', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesInsight_GetActive;
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

    SELECT  n.NoteId,
            n.EntryNo,
            n.ReportName,
            n.ReportRunId,
            n.WeekRangeText,
            n.WeekRangeStart,
            n.WeekRangeEnd,
            r.RiskCode,
            r.RiskLabel,
            r.ColorHex,
            n.ResponsibleParty,
            n.Insights,
            n.NoOfSamples,
            n.ActionSolution,
            n.FeedbackResponse,
            n.Responsibility,
            n.DiscussionDate,
            n.ETA,
            n.ClosedDate,
            s.StatusCode,
            s.StatusLabel,
            n.ArchiveStatus,
            n.VersionNumber,
            n.CreatedBy,
            n.CreatedDateTime,
            n.LastEditedBy,
            n.LastEditedDateTime,
            CASE WHEN n.ETA IS NOT NULL AND n.ETA < CAST(GETDATE() AS DATE)
                      AND s.IsClosedState = 0 THEN 1 ELSE 0 END AS IsOverdueETA
    FROM        dbo.NotesInsight   n
    INNER JOIN  dbo.NotesRiskLevel r ON r.RiskLevelId = n.RiskLevelId
    INNER JOIN  dbo.NotesStatus    s ON s.StatusId    = n.StatusId
    WHERE   n.ReportKeyId = @ReportKeyId
        AND n.IsDeleted   = 0
        AND n.ArchiveStatus <> 'Archived'
        AND ( n.WeekRangeStart >= @WindowStart
              OR s.IsClosedState = 0 )
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

-- ------------------------------------------------------------
-- usp_NotesInsight_GetArchived
--   Report-scoped, read-only archive: Closed entries older than
--   the 4-week retention window. Full filter + search surface.
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesInsight_GetArchived', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesInsight_GetArchived;
GO
CREATE PROCEDURE dbo.usp_NotesInsight_GetArchived
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

    SELECT  n.NoteId,
            n.EntryNo,
            n.ReportName,
            n.ReportRunId,
            n.WeekRangeText,
            n.WeekRangeStart,
            n.WeekRangeEnd,
            r.RiskCode,
            r.RiskLabel,
            r.ColorHex,
            n.ResponsibleParty,
            n.Insights,
            n.NoOfSamples,
            n.ActionSolution,
            n.FeedbackResponse,
            n.Responsibility,
            n.DiscussionDate,
            n.ETA,
            n.ClosedDate,
            s.StatusCode,
            s.StatusLabel,
            n.ArchiveStatus,
            n.ArchivedDate,
            n.VersionNumber,
            n.CreatedBy,
            n.CreatedDateTime,
            n.LastEditedBy,
            n.LastEditedDateTime
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
    ORDER BY n.ArchivedDate DESC, n.WeekRangeStart DESC, n.EntryNo DESC;
END
GO

-- ------------------------------------------------------------
-- usp_NotesInsight_GetById   (Active/Archived detail modal)
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesInsight_GetById', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesInsight_GetById;
GO
CREATE PROCEDURE dbo.usp_NotesInsight_GetById
    @NoteId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT  n.NoteId,
            n.EntryNo,
            n.ReportKeyId,
            n.ReportName,
            n.ReportRunId,
            n.WeekRangeText,
            n.WeekRangeStart,
            n.WeekRangeEnd,
            n.RiskLevelId,
            r.RiskCode,
            r.RiskLabel,
            r.ColorHex,
            n.ResponsibleParty,
            n.Insights,
            n.NoOfSamples,
            n.DataLink,
            n.ActionSolution,
            n.FeedbackResponse,
            n.Responsibility,
            n.DiscussionDate,
            n.ETA,
            n.ClosedDate,
            n.StatusId,
            s.StatusCode,
            s.StatusLabel,
            n.ArchiveStatus,
            n.ArchivedDate,
            n.VersionNumber,
            n.CreatedBy,
            n.CreatedDateTime,
            n.LastEditedBy,
            n.LastEditedDateTime,
            CASE WHEN n.ArchiveStatus = 'Archived' OR n.IsDeleted = 1
                 THEN 0 ELSE 1 END AS IsEditable
    FROM        dbo.NotesInsight   n
    INNER JOIN  dbo.NotesRiskLevel r ON r.RiskLevelId = n.RiskLevelId
    INNER JOIN  dbo.NotesStatus    s ON s.StatusId    = n.StatusId
    WHERE n.NoteId = @NoteId;
END
GO

-- ------------------------------------------------------------
-- usp_NotesInsight_GetRevisionHistory  (read-only audit timeline)
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesInsight_GetRevisionHistory', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesInsight_GetRevisionHistory;
GO
CREATE PROCEDURE dbo.usp_NotesInsight_GetRevisionHistory
    @NoteId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT  rev.RevisionId,
            rev.NoteId,
            rev.VersionNumber,
            rev.EventType,
            rev.SourceAction,
            rev.RevisionSummary,
            rev.EventUser,
            rev.EventDateTime
    FROM   dbo.NotesInsightRevision rev
    WHERE  rev.NoteId = @NoteId
    ORDER BY rev.EventDateTime DESC, rev.RevisionId DESC;
END
GO

-- ------------------------------------------------------------
-- usp_NotesInsight_GetConsolidated  (cross-report Insights Log)
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesInsight_GetConsolidated', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesInsight_GetConsolidated;
GO
CREATE PROCEDURE dbo.usp_NotesInsight_GetConsolidated
    @IncludeArchived BIT           = 0,
    @ReportKeyId     INT           = NULL,
    @RiskCode        NVARCHAR(20)  = NULL,
    @StatusCode      NVARCHAR(20)  = NULL,
    @WeekRangeStart  DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @WindowStart DATE = DATEADD(DAY, -27, CAST(GETDATE() AS DATE));

    SELECT  n.NoteId,
            n.ReportKeyId,
            n.ReportName,
            n.ReportRunId,
            n.WeekRangeText,
            n.WeekRangeStart,
            r.RiskCode,
            r.RiskLabel,
            r.ColorHex,
            n.ResponsibleParty,
            n.Insights,
            s.StatusCode,
            s.StatusLabel,
            n.ArchiveStatus,
            n.CreatedBy AS Author,
            n.CreatedDateTime
    FROM        dbo.NotesInsight   n
    INNER JOIN  dbo.NotesRiskLevel r ON r.RiskLevelId = n.RiskLevelId
    INNER JOIN  dbo.NotesStatus    s ON s.StatusId    = n.StatusId
    WHERE   n.IsDeleted = 0
        AND (@IncludeArchived = 1
             OR (n.ArchiveStatus <> 'Archived'
                 AND (n.WeekRangeStart >= @WindowStart OR s.IsClosedState = 0)))
        AND (@ReportKeyId    IS NULL OR n.ReportKeyId    = @ReportKeyId)
        AND (@RiskCode       IS NULL OR r.RiskCode       = @RiskCode)
        AND (@StatusCode     IS NULL OR s.StatusCode     = @StatusCode)
        AND (@WeekRangeStart IS NULL OR n.WeekRangeStart = @WeekRangeStart)
    ORDER BY n.ReportName, n.WeekRangeStart DESC, n.EntryNo DESC;
END
GO

-- ------------------------------------------------------------
-- usp_NotesInsight_GetExportData  (Notes sheet for Export Excel)
--   Last 4 weeks of notes for a report in template field order.
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesInsight_GetExportData', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesInsight_GetExportData;
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
            r.RiskCode              AS [Risk],
            n.WeekRangeText         AS [Week Range],
            n.ResponsibleParty      AS [Responsible Party],
            n.Insights              AS [Insights],
            n.NoOfSamples           AS [# of Samples],
            n.ActionSolution        AS [Action / Solution / Suggestions],
            n.FeedbackResponse      AS [Feedback / Response],
            n.Responsibility        AS [Responsibility],
            n.DiscussionDate        AS [Discussion Date],
            n.ETA                   AS [ETA],
            n.ClosedDate            AS [Closed Date],
            s.StatusCode            AS [Status]
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

-- ------------------------------------------------------------
-- usp_NotesInsight_GetArchiveSummary  (archive summary cards)
--   Total Archived, Red Risk Archived, Closed This Month,
--   Last Archived Date.
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

-- ------------------------------------------------------------
-- usp_NotesReport_Ensure
--   Returns the ReportKeyId for a report name, creating the
--   registry row on first use. Keeps report resolution inside a
--   stored procedure (no inline SQL from the app layer).
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesReport_Ensure', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesReport_Ensure;
GO
CREATE PROCEDURE dbo.usp_NotesReport_Ensure
    @ReportName  NVARCHAR(200),
    @ReportKeyId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.NotesReport WHERE ReportName = @ReportName)
        INSERT INTO dbo.NotesReport (ReportName) VALUES (@ReportName);

    SET @ReportKeyId = (SELECT ReportKeyId FROM dbo.NotesReport WHERE ReportName = @ReportName);
END
GO

-- ------------------------------------------------------------
-- usp_NotesLookup_GetAll
--   Returns Risk, Status and Report lists for dropdowns.
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesLookup_GetAll', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesLookup_GetAll;
GO
CREATE PROCEDURE dbo.usp_NotesLookup_GetAll
AS
BEGIN
    SET NOCOUNT ON;

    SELECT RiskLevelId, RiskCode, RiskLabel, ColorHex, SortOrder
    FROM   dbo.NotesRiskLevel WHERE IsActive = 1 ORDER BY SortOrder;

    SELECT StatusId, StatusCode, StatusLabel, IsClosedState, SortOrder
    FROM   dbo.NotesStatus WHERE IsActive = 1 ORDER BY SortOrder;

    SELECT ReportKeyId, ReportName, ReportCode
    FROM   dbo.NotesReport WHERE IsActive = 1 ORDER BY ReportName;
END
GO

PRINT '== 02_Create_SP_NotesInsights_Read.sql complete ==';
GO
