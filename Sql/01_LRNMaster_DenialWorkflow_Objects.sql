/* ============================================================================
   RUN AGAINST: LRNMaster (once, central database)

   Consolidates every LRNMaster-level object added for the Denial Workflow
   changes (denial code master fallback, missing-code notifications, mail
   queue, and Denial Database Service re-run queue). RE-RUNNABLE and
   non-destructive - every statement is IF-NOT-EXISTS guarded.

   Canonical per-feature source files (kept in step with the app's own
   idempotent schema-creation code - re-run this script any time you are
   unsure the database matches the deployed code):
     - LRN.DenialDatabaseWorker\Sql\Create_MissingDenialCodeNotifications.sql
     - LRN.DenialDatabaseWorker\Sql\Create_DenialCodeMailQueue.sql
     - LRN.DenialDatabaseWorker\Sql\Create_DenialDatabaseRerunRequests.sql

   dbo.DenialMapperSuperMaster / dbo.DenialMapperPushAudit / etc. (the Denial
   Mapper admin feature) already existed before this change and are NOT
   included here - see LRN.ReportsApi\Sql\DenialMapper_Setup.sql.
   ============================================================================ */

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

/* ----------------------------------------------------------------------------
   1) dbo.MissingDenialCodeNotification
   A denial code LRN.DenialDatabaseWorker found in a lab's own denial database
   that is not present (active) in dbo.DenialMapperSuperMaster. Surfaced to AR
   Managers on login in the React Denial Workflow app. One active
   (unacknowledged) row per (LabId, DenialCode); re-acknowledged codes reopen
   a fresh row if seen again.
   Written by: LRN.DenialDatabaseWorker\Notifications\MissingDenialCodeDetector.cs
   Read/acknowledged via: LRN.ReportsApi\Controllers\DenialMapperController.cs
     (GET/POST api/denialworkflow/denial-mapper/missing-code-notifications)
---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.MissingDenialCodeNotification', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.MissingDenialCodeNotification
    (
        NotificationId          BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_MissingDenialCodeNotification PRIMARY KEY,
        LabId                   INT NOT NULL,
        LabName                 NVARCHAR(120) NULL,
        DenialCode              NVARCHAR(50) NOT NULL,
        RunId                   VARCHAR(30) NULL,
        FirstSeenOn             DATETIME2(3) NOT NULL CONSTRAINT DF_MDCN_FirstSeenOn DEFAULT SYSUTCDATETIME(),
        LastSeenOn              DATETIME2(3) NOT NULL CONSTRAINT DF_MDCN_LastSeenOn DEFAULT SYSUTCDATETIME(),
        OccurrenceCount         INT NOT NULL CONSTRAINT DF_MDCN_OccurrenceCount DEFAULT 1,
        IsAcknowledged          BIT NOT NULL CONSTRAINT DF_MDCN_IsAcknowledged DEFAULT 0,
        AcknowledgedOn          DATETIME2(3) NULL,
        AcknowledgedByUserName  NVARCHAR(200) NULL
    );
    PRINT 'Created dbo.MissingDenialCodeNotification';
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_MDCN_Lab_Code_Active' AND object_id = OBJECT_ID('dbo.MissingDenialCodeNotification'))
    CREATE UNIQUE INDEX UX_MDCN_Lab_Code_Active ON dbo.MissingDenialCodeNotification (LabId, DenialCode)
        WHERE IsAcknowledged = 0;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_MDCN_Lab_CreatedOn' AND object_id = OBJECT_ID('dbo.MissingDenialCodeNotification'))
    CREATE INDEX IX_MDCN_Lab_CreatedOn ON dbo.MissingDenialCodeNotification (LabId, LastSeenOn DESC);
GO

/* ----------------------------------------------------------------------------
   2) dbo.DenialCodeMailQueue
   A queue, not a send: one row per newly-detected missing denial code,
   addressed to that lab's AR Manager(s). Status stays 'Queued' until Graph
   API is configured and a dispatcher is built to send these - nothing sends
   them today by design.
   Written by: LRN.DenialDatabaseWorker\Notifications\MissingDenialCodeDetector.cs
---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.DenialCodeMailQueue', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialCodeMailQueue
    (
        MailQueueId     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialCodeMailQueue PRIMARY KEY,
        LabId           INT NOT NULL,
        NotificationId  BIGINT NULL,
        ToAddresses     NVARCHAR(1000) NOT NULL,
        Subject         NVARCHAR(300) NOT NULL,
        Body            NVARCHAR(MAX) NOT NULL,
        IsHtml          BIT NOT NULL CONSTRAINT DF_DCMQ_IsHtml DEFAULT 1,
        Status          VARCHAR(20) NOT NULL CONSTRAINT DF_DCMQ_Status DEFAULT 'Queued', -- Queued | Sent | Failed
        CreatedOn       DATETIME2(3) NOT NULL CONSTRAINT DF_DCMQ_CreatedOn DEFAULT SYSUTCDATETIME(),
        SentOn          DATETIME2(3) NULL,
        ErrorMessage    NVARCHAR(MAX) NULL
    );
    PRINT 'Created dbo.DenialCodeMailQueue';
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DCMQ_Status_CreatedOn' AND object_id = OBJECT_ID('dbo.DenialCodeMailQueue'))
    CREATE INDEX IX_DCMQ_Status_CreatedOn ON dbo.DenialCodeMailQueue (Status, CreatedOn);
GO

/* ----------------------------------------------------------------------------
   3) dbo.DenialDatabaseRerunRequest
   The hand-off between the Report Audit Log screen ("Re-run Denial Database
   Service") and LRN.DenialDatabaseWorker. Same shape/purpose as
   dbo.MasterFileProcessorRerunRequest, a separate table on purpose (every
   worker in this estate is self-contained). Queue AND audit log - completed
   rows are never deleted.
   Written by: LabMetricsDashboard\Services\SqlDenialDatabaseRerunRepository.cs
   Claimed by: LRN.DenialDatabaseWorker\Services\ReportLogging\DenialDatabaseRerunRequestStore.cs
---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.DenialDatabaseRerunRequest', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialDatabaseRerunRequest
    (
        RerunRequestId          BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialDatabaseRerunRequest PRIMARY KEY,
        BatchId                 UNIQUEIDENTIFIER NOT NULL,
        LabId                   INT NOT NULL,
        LabName                 VARCHAR(120) NULL,
        Status                  VARCHAR(20) NOT NULL CONSTRAINT DF_DDRerun_Status DEFAULT ('Pending'), -- Pending -> Claimed -> Completed | Failed
        RequestedBy             NVARCHAR(200) NOT NULL,
        RequestedByRole         NVARCHAR(100) NULL,
        RequestedOn             DATETIME2(3) NOT NULL CONSTRAINT DF_DDRerun_RequestedOn DEFAULT (SYSUTCDATETIME()),
        RequestedFromApp        VARCHAR(100) NULL,
        RequestedFromHost       NVARCHAR(200) NULL,
        RequestedFromIp         VARCHAR(64) NULL,
        RequestedFromUserAgent  NVARCHAR(400) NULL,
        Notes                   NVARCHAR(1000) NULL,
        ClaimedOn               DATETIME2(3) NULL,
        ClaimedByHost           NVARCHAR(200) NULL,
        CompletedOn             DATETIME2(3) NULL,
        RunId                   VARCHAR(30) NULL,
        ResultStatus            VARCHAR(30) NULL, -- SUCCESS | FAILED | SKIPPED
        ResultMessage           NVARCHAR(MAX) NULL
    );
    PRINT 'Created dbo.DenialDatabaseRerunRequest';
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_DDRerun_Lab_Outstanding' AND object_id = OBJECT_ID('dbo.DenialDatabaseRerunRequest'))
    CREATE UNIQUE INDEX UX_DDRerun_Lab_Outstanding ON dbo.DenialDatabaseRerunRequest (LabId) WHERE Status IN ('Pending', 'Claimed');
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DDRerun_Status_RequestedOn' AND object_id = OBJECT_ID('dbo.DenialDatabaseRerunRequest'))
    CREATE INDEX IX_DDRerun_Status_RequestedOn ON dbo.DenialDatabaseRerunRequest (Status, RequestedOn) INCLUDE (LabId, LabName, RequestedBy, Notes);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DDRerun_RequestedOn' AND object_id = OBJECT_ID('dbo.DenialDatabaseRerunRequest'))
    CREATE INDEX IX_DDRerun_RequestedOn ON dbo.DenialDatabaseRerunRequest (RequestedOn DESC);
GO

PRINT 'LRNMaster Denial Workflow objects are up to date.';
GO
