-- ============================================================
-- Script  : 01_Create_NotesInsights_Tables.sql
-- Feature : Executive Summary Notes & Insights
--           (generic, report-agnostic Notes component)
-- Purpose : Creates all tables required to support the
--           Notes & Insights feature described in
--           Notes_Feature_Requirements_v8_3:
--             - dbo.NotesRiskLevel        (lookup)
--             - dbo.NotesStatus           (lookup)
--             - dbo.NotesReport           (report registry)
--             - dbo.NotesInsight          (main log: active + archived)
--             - dbo.NotesInsightRevision  (auto-versioned audit trail)
--             - dbo.NotesTemplate         (Insight Template Library)
--             - dbo.NotesTemplateColumn   (template column definitions)
--             - dbo.NotesTemplateColumnValue (dropdown values)
--             - dbo.NotesImportStaging    (Excel import / validation preview)
-- Run On  : LRN Lab Revenue Navigator application database
-- Run     : Once, before the stored-procedure scripts.
--           Idempotent — creates only what does not already exist.
-- Design  : ALL data access for this feature is performed through
--           stored procedures only. These tables must not be read
--           from or written to by inline application SQL.
-- ============================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ------------------------------------------------------------
-- 1. dbo.NotesRiskLevel  (Red / Yellow / Green severity lookup)
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.NotesRiskLevel', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.NotesRiskLevel
    (
        RiskLevelId   INT           IDENTITY(1,1) NOT NULL,
        RiskCode      NVARCHAR(20)                NOT NULL,   -- Red / Yellow / Green
        RiskLabel     NVARCHAR(50)                NOT NULL,   -- High Risk / Medium-Watch / Low-Resolved
        ColorHex      NVARCHAR(10)                NULL,       -- pill/inline highlight color
        SortOrder     INT                         NOT NULL DEFAULT 0,
        IsActive      BIT                         NOT NULL DEFAULT 1,

        CONSTRAINT PK_NotesRiskLevel PRIMARY KEY CLUSTERED (RiskLevelId),
        CONSTRAINT UQ_NotesRiskLevel_Code UNIQUE (RiskCode)
    );
    PRINT 'dbo.NotesRiskLevel created.';
END
ELSE
    PRINT 'dbo.NotesRiskLevel already exists - skipped.';
GO

-- ------------------------------------------------------------
-- 2. dbo.NotesStatus  (Open / In Progress / Closed / Deferred)
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.NotesStatus', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.NotesStatus
    (
        StatusId      INT           IDENTITY(1,1) NOT NULL,
        StatusCode    NVARCHAR(20)                NOT NULL,   -- Open / WIP / Closed / Deferred
        StatusLabel   NVARCHAR(50)                NOT NULL,
        IsClosedState BIT                         NOT NULL DEFAULT 0, -- drives archive lifecycle
        SortOrder     INT                         NOT NULL DEFAULT 0,
        IsActive      BIT                         NOT NULL DEFAULT 1,

        CONSTRAINT PK_NotesStatus PRIMARY KEY CLUSTERED (StatusId),
        CONSTRAINT UQ_NotesStatus_Code UNIQUE (StatusCode)
    );
    PRINT 'dbo.NotesStatus created.';
END
ELSE
    PRINT 'dbo.NotesStatus already exists - skipped.';
GO

-- ------------------------------------------------------------
-- 3. dbo.NotesReport  (report registry - makes feature report-agnostic)
--    Scopes notes to a report type (Executive Summary, Denial
--    Dashboard, etc.). Report Name/Type is auto-populated on the note.
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.NotesReport', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.NotesReport
    (
        ReportKeyId   INT           IDENTITY(1,1) NOT NULL,
        ReportName    NVARCHAR(200)               NOT NULL,   -- "Executive Summary"
        ReportCode    NVARCHAR(50)                NULL,       -- stable machine key
        IsActive      BIT                         NOT NULL DEFAULT 1,
        CreatedDateTime DATETIME                  NOT NULL DEFAULT GETDATE(),

        CONSTRAINT PK_NotesReport PRIMARY KEY CLUSTERED (ReportKeyId),
        CONSTRAINT UQ_NotesReport_Name UNIQUE (ReportName)
    );
    PRINT 'dbo.NotesReport created.';
END
ELSE
    PRINT 'dbo.NotesReport already exists - skipped.';
GO

-- ------------------------------------------------------------
-- 4. dbo.NotesInsight  (main running log — active AND archived)
--    One row per note/insight entry. Archive is a state, not a
--    separate table, so revision history and IDs stay intact
--    across the lifecycle. Rich-text fields stored as HTML.
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.NotesInsight', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.NotesInsight
    (
        NoteId              INT           IDENTITY(1,1) NOT NULL,  -- Note/Entry ID (system-generated)
        EntryNo             INT                         NULL,      -- "#" sequential running-log number (not reset per week)

        -- ---- Report / period context (auto-populated) ----
        ReportKeyId         INT                         NOT NULL,  -- FK -> NotesReport
        ReportName          NVARCHAR(200)               NOT NULL,  -- denormalized for fast log/consolidated views
        ReportRunId         NVARCHAR(50)                NULL,      -- Report ID (RUNID) e.g. 20260702R0245
        WeekRangeStart      DATE                        NOT NULL,  -- Billed Week Range start
        WeekRangeEnd        DATE                        NOT NULL,  -- Billed Week Range end
        WeekRangeText       NVARCHAR(50)                NULL,      -- display form "06.12.2026 - 06.18.2026"

        -- ---- Structured template fields ----
        RiskLevelId         INT                         NOT NULL,  -- FK -> NotesRiskLevel
        ResponsibleParty    NVARCHAR(200)               NULL,      -- person/team accountable
        Insights            NVARCHAR(MAX)               NULL,      -- rich text (HTML); inline color must match Risk
        NoOfSamples         INT                         NULL,      -- optional data point
        DataLink            NVARCHAR(500)               NULL,      -- optional, low priority
        ActionSolution      NVARCHAR(MAX)               NULL,      -- Action / Solution / Suggestions (rich text)
        FeedbackResponse    NVARCHAR(MAX)               NULL,      -- Feedback / Response (rich text)
        Responsibility      NVARCHAR(200)               NULL,      -- follow-up action owner (may differ from ResponsibleParty)
        DiscussionDate      DATE                        NULL,
        ETA                 DATE                        NULL,
        ClosedDate          DATE                        NULL,
        StatusId            INT                         NOT NULL,  -- FK -> NotesStatus

        -- ---- Lifecycle / archive ----
        ArchiveStatus       NVARCHAR(20)                NOT NULL DEFAULT 'Active', -- Active / Carry Forward / Archived
        ArchivedDate        DATETIME                    NULL,      -- set when Closed note crosses 4-week threshold

        -- ---- Audit metadata (system-managed) ----
        VersionNumber       INT                         NOT NULL DEFAULT 1,       -- auto-incremented on every edit
        CreatedBy           NVARCHAR(200)               NOT NULL,
        CreatedDateTime     DATETIME                    NOT NULL DEFAULT GETDATE(),
        LastEditedBy        NVARCHAR(200)               NULL,
        LastEditedDateTime  DATETIME                    NULL,
        IsDeleted           BIT                         NOT NULL DEFAULT 0,        -- soft delete (active grid trash action)

        CONSTRAINT PK_NotesInsight PRIMARY KEY CLUSTERED (NoteId),
        CONSTRAINT FK_NotesInsight_Report FOREIGN KEY (ReportKeyId) REFERENCES dbo.NotesReport (ReportKeyId),
        CONSTRAINT FK_NotesInsight_Risk   FOREIGN KEY (RiskLevelId) REFERENCES dbo.NotesRiskLevel (RiskLevelId),
        CONSTRAINT FK_NotesInsight_Status FOREIGN KEY (StatusId)    REFERENCES dbo.NotesStatus (StatusId),
        CONSTRAINT CK_NotesInsight_Archive CHECK (ArchiveStatus IN ('Active','Carry Forward','Archived'))
    );

    CREATE INDEX IX_NotesInsight_Report_Week
        ON dbo.NotesInsight (ReportKeyId, WeekRangeStart, WeekRangeEnd) INCLUDE (ArchiveStatus, StatusId, IsDeleted);
    CREATE INDEX IX_NotesInsight_ArchiveStatus
        ON dbo.NotesInsight (ArchiveStatus, IsDeleted);

    PRINT 'dbo.NotesInsight created.';
END
ELSE
    PRINT 'dbo.NotesInsight already exists - skipped.';
GO

-- ------------------------------------------------------------
-- 5. dbo.NotesInsightRevision  (auto-versioned audit trail)
--    One row per revision EVENT. Prior versions are preserved
--    (never overwritten). A JSON snapshot of the note at each
--    version supports audit/reference without a restore feature.
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.NotesInsightRevision', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.NotesInsightRevision
    (
        RevisionId      INT           IDENTITY(1,1) NOT NULL,
        NoteId          INT                         NOT NULL,  -- FK -> NotesInsight
        VersionNumber   INT                         NOT NULL,  -- version associated with the event
        EventType       NVARCHAR(50)                NOT NULL,  -- Created / Field Updated / Risk Changed / ETA Changed / Feedback Added / Status Changed / Note Closed / Moved to Archive
        SourceAction    NVARCHAR(50)                NULL,      -- Add Row / Save Changes / Status Update / Archive Job / Import
        RevisionSummary NVARCHAR(MAX)               NULL,      -- human-readable "what changed"
        RevisionSnapshot NVARCHAR(MAX)              NULL,      -- JSON snapshot of the note at this version (preserved prior version)
        EventUser       NVARCHAR(200)               NOT NULL,  -- who performed the action
        EventDateTime   DATETIME                    NOT NULL DEFAULT GETDATE(),

        CONSTRAINT PK_NotesInsightRevision PRIMARY KEY CLUSTERED (RevisionId),
        CONSTRAINT FK_NotesInsightRevision_Note FOREIGN KEY (NoteId) REFERENCES dbo.NotesInsight (NoteId)
    );

    CREATE INDEX IX_NotesInsightRevision_Note
        ON dbo.NotesInsightRevision (NoteId, EventDateTime);

    PRINT 'dbo.NotesInsightRevision created.';
END
ELSE
    PRINT 'dbo.NotesInsightRevision already exists - skipped.';
GO

-- ------------------------------------------------------------
-- 6. dbo.NotesTemplate  (Insight Template Library — per report)
--    Governs the report-specific column set used by the Notes
--    grid and by Excel import.
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.NotesTemplate', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.NotesTemplate
    (
        TemplateId      INT           IDENTITY(1,1) NOT NULL,
        ReportKeyId     INT                         NOT NULL,  -- FK -> NotesReport
        TemplateName    NVARCHAR(200)               NOT NULL,
        IsActive        BIT                         NOT NULL DEFAULT 1,
        CreatedBy       NVARCHAR(200)               NOT NULL,
        CreatedDateTime DATETIME                    NOT NULL DEFAULT GETDATE(),
        LastEditedBy    NVARCHAR(200)               NULL,
        LastEditedDateTime DATETIME                 NULL,

        CONSTRAINT PK_NotesTemplate PRIMARY KEY CLUSTERED (TemplateId),
        CONSTRAINT FK_NotesTemplate_Report FOREIGN KEY (ReportKeyId) REFERENCES dbo.NotesReport (ReportKeyId)
    );
    PRINT 'dbo.NotesTemplate created.';
END
ELSE
    PRINT 'dbo.NotesTemplate already exists - skipped.';
GO

-- ------------------------------------------------------------
-- 7. dbo.NotesTemplateColumn  (column definitions per template)
--    ColumnType drives grid rendering: Text / Date (date picker) /
--    Dropdown (configured values).
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.NotesTemplateColumn', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.NotesTemplateColumn
    (
        ColumnId        INT           IDENTITY(1,1) NOT NULL,
        TemplateId      INT                         NOT NULL,  -- FK -> NotesTemplate
        ColumnName      NVARCHAR(200)               NOT NULL,
        ColumnType      NVARCHAR(20)                NOT NULL,  -- Text / Date / Dropdown
        IsRequired      BIT                         NOT NULL DEFAULT 0,
        SortOrder       INT                         NOT NULL DEFAULT 0,
        IsActive        BIT                         NOT NULL DEFAULT 1,

        CONSTRAINT PK_NotesTemplateColumn PRIMARY KEY CLUSTERED (ColumnId),
        CONSTRAINT FK_NotesTemplateColumn_Template FOREIGN KEY (TemplateId) REFERENCES dbo.NotesTemplate (TemplateId),
        CONSTRAINT CK_NotesTemplateColumn_Type CHECK (ColumnType IN ('Text','Date','Dropdown'))
    );
    PRINT 'dbo.NotesTemplateColumn created.';
END
ELSE
    PRINT 'dbo.NotesTemplateColumn already exists - skipped.';
GO

-- ------------------------------------------------------------
-- 8. dbo.NotesTemplateColumnValue  (dropdown values for a column)
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.NotesTemplateColumnValue', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.NotesTemplateColumnValue
    (
        ColumnValueId   INT           IDENTITY(1,1) NOT NULL,
        ColumnId        INT                         NOT NULL,  -- FK -> NotesTemplateColumn
        DropdownValue   NVARCHAR(200)               NOT NULL,
        SortOrder       INT                         NOT NULL DEFAULT 0,
        IsActive        BIT                         NOT NULL DEFAULT 1,

        CONSTRAINT PK_NotesTemplateColumnValue PRIMARY KEY CLUSTERED (ColumnValueId),
        CONSTRAINT FK_NotesTemplateColumnValue_Column FOREIGN KEY (ColumnId) REFERENCES dbo.NotesTemplateColumn (ColumnId)
    );
    PRINT 'dbo.NotesTemplateColumnValue created.';
END
ELSE
    PRINT 'dbo.NotesTemplateColumnValue already exists - skipped.';
GO

-- ------------------------------------------------------------
-- 9. dbo.NotesImportStaging  (Excel import + validation preview)
--    Rows are loaded here per import batch, validated, previewed,
--    then committed (truncate/replace by Report + Week Range).
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.NotesImportStaging', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.NotesImportStaging
    (
        StagingId        INT           IDENTITY(1,1) NOT NULL,
        ImportBatchId    UNIQUEIDENTIFIER            NOT NULL,  -- one batch per uploaded file
        RowNumber        INT                         NOT NULL,  -- source Excel row (for validation grid)

        -- ---- Mandatory import context ----
        ReportName       NVARCHAR(200)               NULL,      -- mandatory
        WeekRangeText    NVARCHAR(50)                NULL,      -- mandatory
        ReportRunId      NVARCHAR(50)                NULL,      -- optional if within a report instance

        -- ---- Raw template fields (as text, validated on commit) ----
        RiskText         NVARCHAR(50)                NULL,
        ResponsibleParty NVARCHAR(200)               NULL,
        Insights         NVARCHAR(MAX)               NULL,
        NoOfSamplesText  NVARCHAR(50)                NULL,
        ActionSolution   NVARCHAR(MAX)               NULL,
        FeedbackResponse NVARCHAR(MAX)               NULL,
        Responsibility   NVARCHAR(200)               NULL,
        DiscussionDateText NVARCHAR(50)              NULL,
        ETAText          NVARCHAR(50)                NULL,
        ClosedDateText   NVARCHAR(50)                NULL,
        StatusText       NVARCHAR(50)                NULL,

        -- ---- Validation results ----
        IsValid          BIT                         NOT NULL DEFAULT 0,
        ValidationError  NVARCHAR(MAX)               NULL,      -- field | error | recommended correction
        CreatedBy        NVARCHAR(200)               NOT NULL,
        CreatedDateTime  DATETIME                    NOT NULL DEFAULT GETDATE(),

        CONSTRAINT PK_NotesImportStaging PRIMARY KEY CLUSTERED (StagingId)
    );

    CREATE INDEX IX_NotesImportStaging_Batch
        ON dbo.NotesImportStaging (ImportBatchId);

    PRINT 'dbo.NotesImportStaging created.';
END
ELSE
    PRINT 'dbo.NotesImportStaging already exists - skipped.';
GO

-- ============================================================
-- Seed lookup values (idempotent)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.NotesRiskLevel)
BEGIN
    INSERT INTO dbo.NotesRiskLevel (RiskCode, RiskLabel, ColorHex, SortOrder)
    VALUES ('Red',    'High Risk',        '#D64545', 1),
           ('Yellow', 'Medium / Watch',   '#E0A800', 2),
           ('Green',  'Low / Resolved',   '#2E9E5B', 3);
    PRINT 'dbo.NotesRiskLevel seeded.';
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.NotesStatus)
BEGIN
    INSERT INTO dbo.NotesStatus (StatusCode, StatusLabel, IsClosedState, SortOrder)
    VALUES ('Open',     'Open',         0, 1),
           ('WIP',      'In Progress',  0, 2),
           ('Deferred', 'Deferred',     0, 3),
           ('Closed',   'Closed',       1, 4);
    PRINT 'dbo.NotesStatus seeded.';
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.NotesReport WHERE ReportName = 'Executive Summary')
BEGIN
    INSERT INTO dbo.NotesReport (ReportName, ReportCode)
    VALUES ('Executive Summary', 'EXEC_SUMMARY');
    PRINT 'dbo.NotesReport seeded with Executive Summary.';
END
GO

PRINT '== 01_Create_NotesInsights_Tables.sql complete ==';
GO
