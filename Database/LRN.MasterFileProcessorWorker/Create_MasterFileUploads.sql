SET NOCOUNT ON;
GO

/*
    dbo.MasterFileUpload  (LRNMaster)

    AR Workbench > Data Processing > Upload Master File. For a lab whose master file does not reach
    the SharePoint master folder (a client that takes only the AR Workbench), or any lab that wants
    to load a file by hand, the user fills the standard template (one workbook, sheets "Claim Level"
    and "Line Level") and uploads it. LRN.ReportsApi validates it, stores the workbook here and
    queues a dbo.MasterFileProcessorRerunRequest row carrying the UploadId. The Master File
    Processor claims the request on its next poll, reads the workbook from this row instead of
    SharePoint, and runs the same pipeline: standardize, denial enrichment, bulk load into
    dbo.LineLevelData / dbo.ClaimLevelData, AR Workbench sync.

    FileContent is PHI. The worker sets it to NULL (ContentPurgedOn) as soon as it has its local
    working copy - success or failure - so the workbook does not rest here; the processed copy is
    archived with every other master file (LRN-RAWFILE\Archive). The row itself is kept as the audit
    of who uploaded what, when, and what the worker made of it.

    Requires Create_RerunRequests.sql first (the UploadId column is added to its table below).
*/

IF OBJECT_ID('dbo.MasterFileUpload', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.MasterFileUpload
    (
        UploadId            BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_MasterFileUpload PRIMARY KEY,

        LabId               INT NOT NULL,
        LabName             VARCHAR(120) NULL,

        -- The workbook as uploaded. NULL once the worker has taken it (ContentPurgedOn).
        FileName            NVARCHAR(260) NOT NULL,
        FileSizeBytes       BIGINT NOT NULL,
        FileSha256          CHAR(64) NOT NULL,
        FileContent         VARBINARY(MAX) NULL,
        ContentPurgedOn     DATETIME2(3) NULL,

        -- The week the data belongs to: names the output files and the week folder, exactly as the
        -- SharePoint week folder ("MM.dd.yyyy - MM.dd.yyyy") does for a SharePoint file.
        PeriodStart         DATE NOT NULL,
        PeriodEnd           DATE NOT NULL,

        -- What the API's validation counted, so the screen can show it before the worker runs.
        ClaimRows           INT NULL,
        LineRows            INT NULL,
        TemplateVersion     VARCHAR(20) NULL,

        UploadedBy          NVARCHAR(200) NOT NULL,
        UploadedOn          DATETIME2(3) NOT NULL
            CONSTRAINT DF_MasterFileUpload_UploadedOn DEFAULT (SYSUTCDATETIME()),
        UploadedFromApp     VARCHAR(100) NULL,
        Notes               NVARCHAR(1000) NULL
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_MasterFileUpload_Lab_UploadedOn'
                 AND object_id = OBJECT_ID('dbo.MasterFileUpload'))
BEGIN
    CREATE INDEX IX_MasterFileUpload_Lab_UploadedOn
        ON dbo.MasterFileUpload (LabId, UploadedOn DESC);
END
GO

-- The request that carries an upload. NULL = the normal SharePoint (or lab database) load.
IF COL_LENGTH('dbo.MasterFileProcessorRerunRequest', 'UploadId') IS NULL
BEGIN
    ALTER TABLE dbo.MasterFileProcessorRerunRequest ADD UploadId BIGINT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_MFPRerun_MasterFileUpload')
BEGIN
    ALTER TABLE dbo.MasterFileProcessorRerunRequest
        ADD CONSTRAINT FK_MFPRerun_MasterFileUpload
        FOREIGN KEY (UploadId) REFERENCES dbo.MasterFileUpload (UploadId);
END
GO
