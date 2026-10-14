/* =============================================================================
   Async Report Generation — Queue Schema (run on EACH lab database)
   Labs: InHealthDTRLRN, CoveLRN, PCRAL_LRN, PCRCO_LRN, Rising_Tides, Beech_Tree,
         Phi_Life, PCRLOA, Elixir_LRN, Certus_LRN, Augustus_LRN, NWL, ...
   Idempotent — safe to re-run.
   ============================================================================= */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ── 1. Status lookup ──────────────────────────────────────────────────────── */
IF OBJECT_ID('dbo.UserReqReportStatus', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.UserReqReportStatus
    (
        StatusId   TINYINT      NOT NULL CONSTRAINT PK_UserReqReportStatus PRIMARY KEY,
        StatusName VARCHAR(30)  NOT NULL CONSTRAINT UQ_UserReqReportStatus_Name UNIQUE
    );
END
GO

MERGE dbo.UserReqReportStatus AS t
USING (VALUES
    (1, 'Queued'),
    (2, 'Processing'),
    (3, 'Completed'),
    (4, 'Failed'),
    (5, 'Downloaded'),
    (6, 'Expired'),
    (7, 'Deleted'),
    (8, 'Cancelled')
) AS s (StatusId, StatusName)
ON t.StatusId = s.StatusId
WHEN MATCHED AND t.StatusName <> s.StatusName THEN UPDATE SET StatusName = s.StatusName
WHEN NOT MATCHED THEN INSERT (StatusId, StatusName) VALUES (s.StatusId, s.StatusName);
GO

/* ── 2. Queue table ────────────────────────────────────────────────────────── */
IF OBJECT_ID('dbo.UserReqReports', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.UserReqReports
    (
        ReportId           BIGINT           NOT NULL IDENTITY(1,1)
                           CONSTRAINT PK_UserReqReports PRIMARY KEY CLUSTERED,

        ReportType         VARCHAR(50)      NOT NULL,          -- 'PayerPolicyValidation', 'ForecastingSummary', ...
        LabName            VARCHAR(50)      NOT NULL,          -- dashboard lab key; aids generic worker code + audit
        RequestedBy        NVARCHAR(100)    NOT NULL,          -- ClaimTypes.Name (UserName)
        RequestedByUserId  INT              NULL,              -- ClaimTypes.NameIdentifier (LabUserID), if available
        RequestedDate      DATETIME2(0)     NOT NULL CONSTRAINT DF_UserReqReports_ReqDate DEFAULT SYSDATETIME(),

        GenerationStatus   TINYINT          NOT NULL CONSTRAINT DF_UserReqReports_Status DEFAULT 1
                           CONSTRAINT FK_UserReqReports_Status
                           REFERENCES dbo.UserReqReportStatus (StatusId),

        FilterDetails      NVARCHAR(MAX)    NULL,              -- JSON snapshot of the filters used
        FilterHash         CHAR(64)         NULL,              -- SHA-256 of ReportType+Lab+FilterDetails; duplicate guard

        [FileName]         NVARCHAR(260)    NULL,
        FilePath           NVARCHAR(1024)   NULL,              -- absolute path on the report share (never sent to browser)
        FileSizeBytes      BIGINT           NULL,
        ReportRowCount     INT              NULL,              -- rows written; shown in UI, used for perf tuning

        StartedDate        DATETIME2(0)     NULL,
        CompletedDate      DATETIME2(0)     NULL,
        ErrorMessage       NVARCHAR(2000)   NULL,
        ProgressPercent    TINYINT          NULL,              -- 0–100 while Processing; live badge progress
        RetryCount         TINYINT          NOT NULL CONSTRAINT DF_UserReqReports_Retry DEFAULT 0,
        WorkerName         NVARCHAR(100)    NULL,              -- machine/instance that claimed the job (multi-worker debug)

        DownloadCount      INT              NOT NULL CONSTRAINT DF_UserReqReports_DlCount DEFAULT 0,
        FirstDownloadedDate DATETIME2(0)    NULL,
        LastDownloadedDate DATETIME2(0)     NULL,

        ExpiryDate         DATETIME2(0)     NULL,              -- CompletedDate + retention (7 days)
        DownloadToken      UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_UserReqReports_Token DEFAULT NEWID(),
                                                               -- opaque token in download URL; blocks ID enumeration

        CreatedDate        DATETIME2(0)     NOT NULL CONSTRAINT DF_UserReqReports_Created DEFAULT SYSDATETIME(),
        UpdatedDate        DATETIME2(0)     NOT NULL CONSTRAINT DF_UserReqReports_Updated DEFAULT SYSDATETIME(),

        CONSTRAINT CK_UserReqReports_FilterJson
            CHECK (FilterDetails IS NULL OR ISJSON(FilterDetails) = 1)
    );
END
GO

/* ── 2b. Migration for tables deployed before ProgressPercent existed ──────── */
IF COL_LENGTH('dbo.UserReqReports', 'ProgressPercent') IS NULL
BEGIN
    ALTER TABLE dbo.UserReqReports ADD ProgressPercent TINYINT NULL;

    -- Rebuild the user-panel index so progress reads stay covered (no key lookups).
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_UserReqReports_User')
        DROP INDEX IX_UserReqReports_User ON dbo.UserReqReports;
END
GO

/* ── 3. Indexes ────────────────────────────────────────────────────────────── */

-- Queue pickup: tiny filtered index, only Queued rows. FIFO by ReportId.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_UserReqReports_QueuePickup')
    CREATE NONCLUSTERED INDEX IX_UserReqReports_QueuePickup
        ON dbo.UserReqReports (ReportId)
        INCLUDE (ReportType, RetryCount)
        WHERE GenerationStatus = 1;
GO

-- "My Reports" panel + badge count per user.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_UserReqReports_User')
    CREATE NONCLUSTERED INDEX IX_UserReqReports_User
        ON dbo.UserReqReports (RequestedBy, GenerationStatus)
        INCLUDE (ReportType, LabName, RequestedDate, [FileName], FileSizeBytes,
                 CompletedDate, ExpiryDate, ErrorMessage, DownloadToken, ReportRowCount,
                 ProgressPercent);
GO

-- Cleanup sweep: completed/downloaded rows past expiry.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_UserReqReports_Expiry')
    CREATE NONCLUSTERED INDEX IX_UserReqReports_Expiry
        ON dbo.UserReqReports (ExpiryDate)
        INCLUDE (FilePath, GenerationStatus)
        WHERE GenerationStatus IN (3, 5);
GO

-- Duplicate-request guard: one ACTIVE (Queued/Processing) request per
-- user + report type + identical filter set.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_UserReqReports_ActiveDuplicate')
    CREATE UNIQUE NONCLUSTERED INDEX UX_UserReqReports_ActiveDuplicate
        ON dbo.UserReqReports (RequestedBy, ReportType, FilterHash)
        WHERE GenerationStatus IN (1, 2) AND FilterHash IS NOT NULL;
GO

/* ── 4. Audit history ──────────────────────────────────────────────────────── */
IF OBJECT_ID('dbo.UserReqReportsAudit', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.UserReqReportsAudit
    (
        AuditId     BIGINT        NOT NULL IDENTITY(1,1)
                    CONSTRAINT PK_UserReqReportsAudit PRIMARY KEY CLUSTERED,
        ReportId    BIGINT        NOT NULL,
        OldStatus   TINYINT       NULL,
        NewStatus   TINYINT       NOT NULL,
        ChangedBy   NVARCHAR(128) NOT NULL,
        ChangedDate DATETIME2(0)  NOT NULL CONSTRAINT DF_UserReqReportsAudit_Date DEFAULT SYSDATETIME(),
        Note        NVARCHAR(1000) NULL
    );

    CREATE NONCLUSTERED INDEX IX_UserReqReportsAudit_Report
        ON dbo.UserReqReportsAudit (ReportId, ChangedDate);
END
GO

/* Status-change trigger — audit survives every code path (web, worker, manual). */
CREATE OR ALTER TRIGGER dbo.trg_UserReqReports_Audit
ON dbo.UserReqReports
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @actor NVARCHAR(128) =
        COALESCE(CONVERT(NVARCHAR(128), SESSION_CONTEXT(N'AppUser')), SUSER_SNAME());

    IF NOT EXISTS (SELECT 1 FROM deleted)
    BEGIN
        INSERT dbo.UserReqReportsAudit (ReportId, OldStatus, NewStatus, ChangedBy, Note)
        SELECT i.ReportId, NULL, i.GenerationStatus, @actor, N'Request created'
        FROM inserted i;
        RETURN;
    END

    INSERT dbo.UserReqReportsAudit (ReportId, OldStatus, NewStatus, ChangedBy, Note)
    SELECT i.ReportId, d.GenerationStatus, i.GenerationStatus, @actor,
           LEFT(i.ErrorMessage, 1000)
    FROM inserted i
    JOIN deleted  d ON d.ReportId = i.ReportId
    WHERE i.GenerationStatus <> d.GenerationStatus;
END
GO

PRINT 'UserReqReports schema deployed.';
GO
