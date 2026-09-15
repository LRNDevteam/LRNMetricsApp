-- Run against LRNMaster.
--
-- One row per (LabId, DenialCode) currently unresolved: a denial code this lab's own denial
-- database produced that LRNMaster's dbo.DenialMapperSuperMaster does not have an active mapping
-- for. Surfaced to AR Managers on login in the React Denial Workflow app (Denial Action Master >
-- Missing Denial Codes) and drives dbo.DenialCodeMailQueue.
--
-- The worker (LRN.DenialDatabaseWorker\Notifications\MissingDenialCodeDetector.cs) and the API
-- (LRN.ReportsApi\Services\DenialMapperService.cs) both create this table idempotently on first use,
-- so running this script by hand is optional - it exists for a reviewable, versioned record of the
-- schema, same as LRN.MasterFileProcessorWorker\sql\Create_RerunRequests.sql.

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

    -- One active (unacknowledged) row per Lab+Code. Once acknowledged, a later re-occurrence of the
    -- same code opens a fresh row rather than reusing the acknowledged one.
    CREATE UNIQUE INDEX UX_MDCN_Lab_Code_Active ON dbo.MissingDenialCodeNotification (LabId, DenialCode)
        WHERE IsAcknowledged = 0;

    CREATE INDEX IX_MDCN_Lab_CreatedOn ON dbo.MissingDenialCodeNotification (LabId, LastSeenOn DESC);
END
