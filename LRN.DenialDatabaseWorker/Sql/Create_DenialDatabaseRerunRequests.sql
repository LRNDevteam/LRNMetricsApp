SET NOCOUNT ON;
GO

/*
    dbo.DenialDatabaseRerunRequest  (LRNMaster)

    The Denial Database Service equivalent of dbo.MasterFileProcessorRerunRequest
    (see LRN.MasterFileProcessorWorker\sql\Create_RerunRequests.sql for the pattern this mirrors).

    The hand-off between the Report Audit Log screen and LRN.DenialDatabaseWorker. The worker is a
    Windows Service that polls on a timer; the dashboard is a separate web application that cannot
    reach into its process. So a re-run is a ROW, not a call: the screen inserts one Pending row per
    selected lab, the worker claims it on its next poll, reprocesses that lab with its "already
    processed" gates bypassed, and writes the outcome back onto the same row.

    A separate table from the Master File Processor's, not a shared one with a discriminator column:
    every service in this estate is deliberately self-contained (no ProjectReference between workers,
    and even ReportsWorkflowTrackerRepository exists as three independent copies), so this follows the
    same convention rather than adding a cross-service dependency on a table another service owns.

    This table is a QUEUE AND AN AUDIT LOG. Completed rows are never deleted.
*/

IF OBJECT_ID('dbo.DenialDatabaseRerunRequest', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialDatabaseRerunRequest
    (
        RerunRequestId          BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_DenialDatabaseRerunRequest PRIMARY KEY,

        -- One click on the screen produces one BatchId across every lab that was ticked.
        BatchId                 UNIQUEIDENTIFIER NOT NULL,

        LabId                   INT NOT NULL,
        LabName                 VARCHAR(120) NULL,

        -- Pending -> Claimed -> Completed | Failed. Cancelled is set from the screen only while
        -- the row is still Pending.
        Status                  VARCHAR(20) NOT NULL
            CONSTRAINT DF_DDRerun_Status DEFAULT ('Pending'),

        -- ── who asked ──────────────────────────────────────────────────────────────────────────
        RequestedBy             NVARCHAR(200) NOT NULL,
        RequestedByRole         NVARCHAR(100) NULL,
        RequestedOn             DATETIME2(3) NOT NULL
            CONSTRAINT DF_DDRerun_RequestedOn DEFAULT (SYSUTCDATETIME()),

        -- ── where it was asked from ────────────────────────────────────────────────────────────
        RequestedFromApp        VARCHAR(100) NULL,      -- e.g. LabMetricsDashboard
        RequestedFromHost       NVARCHAR(200) NULL,     -- the web server that served the request
        RequestedFromIp         VARCHAR(64) NULL,       -- the requester's client address
        RequestedFromUserAgent  NVARCHAR(400) NULL,

        -- Free text the requester types in the confirmation dialog: why this re-run is happening.
        Notes                   NVARCHAR(1000) NULL,

        -- ── what the worker did with it ────────────────────────────────────────────────────────
        ClaimedOn               DATETIME2(3) NULL,
        ClaimedByHost           NVARCHAR(200) NULL,     -- which worker instance took it
        CompletedOn             DATETIME2(3) NULL,
        RunId                   VARCHAR(30) NULL,       -- the RunID this re-run produced
        ResultStatus            VARCHAR(30) NULL,       -- SUCCESS | FAILED | SKIPPED
        ResultMessage           NVARCHAR(MAX) NULL
    );
END
GO

-- A lab can have at most ONE outstanding request.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UX_DDRerun_Lab_Outstanding'
                 AND object_id = OBJECT_ID('dbo.DenialDatabaseRerunRequest'))
BEGIN
    CREATE UNIQUE INDEX UX_DDRerun_Lab_Outstanding
        ON dbo.DenialDatabaseRerunRequest (LabId)
        WHERE Status IN ('Pending', 'Claimed');
END
GO

-- The worker's claim query: oldest outstanding request first.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_DDRerun_Status_RequestedOn'
                 AND object_id = OBJECT_ID('dbo.DenialDatabaseRerunRequest'))
BEGIN
    CREATE INDEX IX_DDRerun_Status_RequestedOn
        ON dbo.DenialDatabaseRerunRequest (Status, RequestedOn)
        INCLUDE (LabId, LabName, RequestedBy, Notes);
END
GO

-- The screen's history panel: newest first.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_DDRerun_RequestedOn'
                 AND object_id = OBJECT_ID('dbo.DenialDatabaseRerunRequest'))
BEGIN
    CREATE INDEX IX_DDRerun_RequestedOn
        ON dbo.DenialDatabaseRerunRequest (RequestedOn DESC);
END
GO
