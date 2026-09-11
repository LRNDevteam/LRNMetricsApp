SET NOCOUNT ON;
GO

/*
    dbo.MasterFileProcessorRerunRequest  (LRNMaster)

    The hand-off between the Report Audit Log screen and LRN.MasterFileProcessorWorker.

    The worker is a Windows Service that polls on a timer; the dashboard is a separate web
    application that cannot reach into its process. So a re-run is a ROW, not a call: the screen
    inserts one Pending row per selected lab, the worker claims it on its next poll, runs that lab
    with its "already processed" gates bypassed, and writes the outcome back onto the same row.

    That shape is also what makes the audit trail possible. The request survives a worker restart,
    a failed run and a redeploy, and it carries who asked, from where, when, and why - which a
    fire-and-forget HTTP call would not.

    This table is a QUEUE AND AN AUDIT LOG. Completed rows are never deleted: "who re-ran Cove last
    Tuesday and why" is exactly the question this exists to answer.
*/

IF OBJECT_ID('dbo.MasterFileProcessorRerunRequest', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.MasterFileProcessorRerunRequest
    (
        RerunRequestId          BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_MasterFileProcessorRerunRequest PRIMARY KEY,

        -- One click on the screen produces one BatchId across every lab that was ticked, so the
        -- labs chosen together can still be seen as one decision after the fact.
        BatchId                 UNIQUEIDENTIFIER NOT NULL,

        LabId                   INT NOT NULL,
        LabName                 VARCHAR(120) NULL,

        -- Pending -> Claimed -> Completed | Failed. Cancelled is set from the screen only while
        -- the row is still Pending.
        Status                  VARCHAR(20) NOT NULL
            CONSTRAINT DF_MFPRerun_Status DEFAULT ('Pending'),

        -- ── who asked ──────────────────────────────────────────────────────────────────────────
        RequestedBy             NVARCHAR(200) NOT NULL,
        RequestedByRole         NVARCHAR(100) NULL,
        RequestedOn             DATETIME2(3) NOT NULL
            CONSTRAINT DF_MFPRerun_RequestedOn DEFAULT (SYSUTCDATETIME()),

        -- ── where it was asked from ────────────────────────────────────────────────────────────
        -- Four columns rather than one string: an operations question is usually "which environment
        -- did this come from", and a single free-text field cannot be filtered on.
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

-- A lab can have at most ONE outstanding request. Without this, an impatient double-click queues
-- the same full reload twice and the second one runs against the output of the first.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UX_MFPRerun_Lab_Outstanding'
                 AND object_id = OBJECT_ID('dbo.MasterFileProcessorRerunRequest'))
BEGIN
    CREATE UNIQUE INDEX UX_MFPRerun_Lab_Outstanding
        ON dbo.MasterFileProcessorRerunRequest (LabId)
        WHERE Status IN ('Pending', 'Claimed');
END
GO

-- The worker's claim query: oldest outstanding request first.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_MFPRerun_Status_RequestedOn'
                 AND object_id = OBJECT_ID('dbo.MasterFileProcessorRerunRequest'))
BEGIN
    CREATE INDEX IX_MFPRerun_Status_RequestedOn
        ON dbo.MasterFileProcessorRerunRequest (Status, RequestedOn)
        INCLUDE (LabId, LabName, RequestedBy, Notes);
END
GO

-- The screen's history panel: newest first, by lab.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_MFPRerun_RequestedOn'
                 AND object_id = OBJECT_ID('dbo.MasterFileProcessorRerunRequest'))
BEGIN
    CREATE INDEX IX_MFPRerun_RequestedOn
        ON dbo.MasterFileProcessorRerunRequest (RequestedOn DESC);
END
GO
