-- Run against LRNMaster.
--
-- A queue, not a send: LRN.DenialDatabaseWorker inserts a row here for every newly detected missing
-- denial code (see Create_MissingDenialCodeNotifications.sql), addressed to that lab's AR Manager(s).
-- Status stays 'Queued' - nothing in this codebase sends these yet. Once Microsoft Graph is
-- configured, a separate dispatcher can poll Status='Queued' rows, call Graph's sendMail, and update
-- Status/SentOn/ErrorMessage accordingly.
--
-- Created idempotently in code too (MissingDenialCodeDetector.cs), so running this script by hand is
-- optional - it exists for a reviewable, versioned record of the schema.

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

    CREATE INDEX IX_DCMQ_Status_CreatedOn ON dbo.DenialCodeMailQueue (Status, CreatedOn);
END
