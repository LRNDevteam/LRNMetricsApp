SET NOCOUNT ON;
GO

/*
    dbo.ReportSnapshotRun / dbo.ReportSnapshotFile  (LRNMaster)

    The index of weekly Parquet snapshots (docs/master-file-processor/
    LRN_Report_Snapshots_Parquet_Storage_Implementation.pdf). The files themselves live in Blob
    Storage (container report-snapshots) or a configured folder; these tables only say which
    snapshots exist and where.

    One ReportSnapshotRun row per lab + RunId. Written by LRN.MasterFileProcessorWorker step 88
    after the weekly load: InProgress -> Success | Failed. A re-run of the same RunId resets the
    row and overwrites its files. One ReportSnapshotFile row per file.

    Master data uses ReportCode LINELEVEL / CLAIMLEVEL / LIMS with ResultSetName 'Data'. The
    standard report snapshots will add their own ReportCodes to the same tables.

    Retention is applied by the worker (MasterDataSnapshot:KeepWeeks / KeepMonthEnd): it deletes a
    run's files under BlobPrefix first, then the run row - file rows cascade.

    Idempotent: safe to run again.
*/

IF OBJECT_ID('dbo.ReportSnapshotRun', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ReportSnapshotRun
    (
        SnapshotRunId   BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ReportSnapshotRun PRIMARY KEY,
        LabId           INT            NOT NULL,
        LabName         NVARCHAR(100)  NOT NULL,
        RunId           NVARCHAR(64)   NOT NULL,       -- LRN_Run_Log.RunID, e.g. R20261012NWL0001
        WeekFolder      NVARCHAR(100)  NOT NULL,       -- e.g. 10.06.2026 - 10.12.2026
        SnapshotDate    DATE           NOT NULL,       -- the week folder's end date ("data as of")

        -- The start of every file this run wrote: {LabName}/{RunId}_{WeekRange}_ (files are
        -- ..._LINELEVEL.parquet, ..._CLAIMLEVEL.parquet, ..._LIMS.parquet). Retention deletes by it,
        -- so a file uploaded but never indexed (a crash in between) is still removed.
        BlobPrefix      NVARCHAR(500)  NULL,

        Status          VARCHAR(20)    NOT NULL,       -- InProgress | Success | Failed
        ErrorMessage    NVARCHAR(4000) NULL,
        CreatedOn       DATETIME2(0)   NOT NULL
            CONSTRAINT DF_ReportSnapshotRun_CreatedOn DEFAULT (SYSUTCDATETIME()),
        CompletedOn     DATETIME2(0)   NULL,

        CONSTRAINT UQ_ReportSnapshotRun UNIQUE (LabId, RunId)
    );
END
GO

-- The week selector and retention: one lab's snapshots, newest first.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_ReportSnapshotRun_Lab_SnapshotDate'
                 AND object_id = OBJECT_ID('dbo.ReportSnapshotRun'))
BEGIN
    CREATE INDEX IX_ReportSnapshotRun_Lab_SnapshotDate
        ON dbo.ReportSnapshotRun (LabId, SnapshotDate DESC)
        INCLUDE (RunId, WeekFolder, Status, CreatedOn);
END
GO

IF OBJECT_ID('dbo.ReportSnapshotFile', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ReportSnapshotFile
    (
        SnapshotFileId  BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ReportSnapshotFile PRIMARY KEY,
        SnapshotRunId   BIGINT         NOT NULL
            CONSTRAINT FK_ReportSnapshotFile_Run
            REFERENCES dbo.ReportSnapshotRun (SnapshotRunId) ON DELETE CASCADE,
        ReportCode      VARCHAR(50)    NOT NULL,       -- LINELEVEL | CLAIMLEVEL | LIMS | <report>
        ResultSetName   NVARCHAR(100)  NOT NULL,
        BlobPath        NVARCHAR(500)  NOT NULL,
        [RowCount]      BIGINT         NOT NULL,
        SizeBytes       BIGINT         NOT NULL,
        ContentSha256   CHAR(64)       NOT NULL,       -- also the reader's local cache key
        SchemaJson      NVARCHAR(MAX)  NOT NULL,       -- [{name, sourceName, type, sqlType, precision, scale}]
        SchemaVersion   INT            NOT NULL,
        CreatedOn       DATETIME2(0)   NOT NULL
            CONSTRAINT DF_ReportSnapshotFile_CreatedOn DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT UQ_ReportSnapshotFile UNIQUE (SnapshotRunId, ReportCode, ResultSetName)
    );
END
GO

/*
    Successful snapshots of one report for one lab, newest first - fills the "Data as of" week
    selector in LabMetricsDashboard. @ReportCode NULL lists every report.
*/
CREATE OR ALTER PROCEDURE dbo.usp_ReportSnapshot_List
    @LabId      INT,
    @ReportCode VARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT  r.SnapshotRunId,
            r.RunId,
            r.WeekFolder,
            r.SnapshotDate,
            r.CompletedOn,
            f.SnapshotFileId,
            f.ReportCode,
            f.ResultSetName,
            f.BlobPath,
            f.[RowCount],
            f.SizeBytes,
            f.ContentSha256,
            f.SchemaVersion
    FROM    dbo.ReportSnapshotRun  r
    JOIN    dbo.ReportSnapshotFile f ON f.SnapshotRunId = r.SnapshotRunId
    WHERE   r.LabId = @LabId
      AND   r.Status = 'Success'
      AND   (@ReportCode IS NULL OR f.ReportCode = @ReportCode)
    ORDER BY r.SnapshotDate DESC, r.CreatedOn DESC, f.ReportCode, f.ResultSetName;
END
GO
