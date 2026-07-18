/* =============================================================================
   Async Report Generation — Stored Procedures (run on EACH lab database)
   Idempotent — safe to re-run.
   ============================================================================= */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ── usp_ClaimNextUserReqReport ────────────────────────────────────────────────
   Atomically claims the oldest Queued request (FIFO).
   UPDLOCK + READPAST + ROWLOCK: multiple worker instances/threads can poll the
   same table concurrently — each claims a different row, none block each other.
   Returns 0 rows when the queue is empty.                                      */
CREATE OR ALTER PROCEDURE dbo.usp_ClaimNextUserReqReport
    @WorkerName NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sp_set_session_context @key = N'AppUser', @value = @WorkerName;

    -- NOTE: OUTPUT ... INTO is required — the audit trigger on UserReqReports
    -- forbids a bare OUTPUT clause (SQL error 334).
    DECLARE @claimed TABLE
    (
        ReportId      BIGINT,
        ReportType    VARCHAR(50),
        LabName       VARCHAR(50),
        RequestedBy   NVARCHAR(100),
        FilterDetails NVARCHAR(MAX),
        RetryCount    TINYINT
    );

    ;WITH nextJob AS
    (
        SELECT TOP (1) *
        FROM dbo.UserReqReports WITH (UPDLOCK, READPAST, ROWLOCK)
        WHERE GenerationStatus = 1              -- Queued
        ORDER BY ReportId                       -- FIFO
    )
    UPDATE nextJob
       SET GenerationStatus = 2,               -- Processing
           StartedDate      = SYSDATETIME(),
           WorkerName       = @WorkerName,
           ErrorMessage     = NULL,
           ProgressPercent  = 0,
           UpdatedDate      = SYSDATETIME()
    OUTPUT inserted.ReportId,
           inserted.ReportType,
           inserted.LabName,
           inserted.RequestedBy,
           inserted.FilterDetails,
           inserted.RetryCount
      INTO @claimed;

    SELECT ReportId, ReportType, LabName, RequestedBy, FilterDetails, RetryCount
    FROM @claimed;
END
GO

/* ── usp_CompleteUserReqReport ──────────────────────────────────────────────── */
CREATE OR ALTER PROCEDURE dbo.usp_CompleteUserReqReport
    @ReportId       BIGINT,
    @FileName       NVARCHAR(260),
    @FilePath       NVARCHAR(1024),
    @FileSizeBytes  BIGINT,
    @ReportRowCount INT,
    @RetentionDays  INT = 7,
    @WorkerName     NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @WorkerName IS NOT NULL
        EXEC sp_set_session_context @key = N'AppUser', @value = @WorkerName;

    UPDATE dbo.UserReqReports
       SET GenerationStatus = 3,               -- Completed
           [FileName]       = @FileName,
           FilePath         = @FilePath,
           FileSizeBytes    = @FileSizeBytes,
           ReportRowCount   = @ReportRowCount,
           CompletedDate    = SYSDATETIME(),
           ExpiryDate       = DATEADD(DAY, @RetentionDays, SYSDATETIME()),
           ProgressPercent  = 100,
           ErrorMessage     = NULL,
           UpdatedDate      = SYSDATETIME()
     WHERE ReportId = @ReportId
       AND GenerationStatus = 2;               -- only from Processing
END
GO

/* ── usp_FailUserReqReport ─────────────────────────────────────────────────────
   Transient failures are re-queued (up to @MaxRetries); permanent ones fail.  */
CREATE OR ALTER PROCEDURE dbo.usp_FailUserReqReport
    @ReportId     BIGINT,
    @ErrorMessage NVARCHAR(2000),
    @IsTransient  BIT = 0,
    @MaxRetries   TINYINT = 2,
    @WorkerName   NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @WorkerName IS NOT NULL
        EXEC sp_set_session_context @key = N'AppUser', @value = @WorkerName;

    UPDATE dbo.UserReqReports
       SET GenerationStatus = CASE WHEN @IsTransient = 1 AND RetryCount < @MaxRetries
                                   THEN 1      -- back to Queued for auto-retry
                                   ELSE 4 END, -- Failed
           RetryCount   = RetryCount + 1,
           ErrorMessage = LEFT(@ErrorMessage, 2000),
           UpdatedDate  = SYSDATETIME()
     WHERE ReportId = @ReportId
       AND GenerationStatus = 2;
END
GO

/* ── usp_ResetStuckUserReqReports ──────────────────────────────────────────────
   Worker restart / crash recovery: rows stuck in Processing longer than
   @StuckAfterMinutes are re-queued (or failed once retries are exhausted).    */
CREATE OR ALTER PROCEDURE dbo.usp_ResetStuckUserReqReports
    @StuckAfterMinutes INT = 60,
    @MaxRetries        TINYINT = 2,
    @WorkerName        NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @WorkerName IS NOT NULL
        EXEC sp_set_session_context @key = N'AppUser', @value = @WorkerName;

    UPDATE dbo.UserReqReports
       SET GenerationStatus = CASE WHEN RetryCount < @MaxRetries THEN 1 ELSE 4 END,
           RetryCount   = RetryCount + 1,
           ErrorMessage = CONCAT(N'Recovered: worker did not finish within ',
                                 @StuckAfterMinutes, N' minutes (restart/crash).'),
           UpdatedDate  = SYSDATETIME()
     WHERE GenerationStatus = 2
       AND StartedDate < DATEADD(MINUTE, -@StuckAfterMinutes, SYSDATETIME());

    SELECT @@ROWCOUNT AS RecoveredCount;
END
GO

/* ── usp_ExpireUserReqReports ──────────────────────────────────────────────────
   Step 1 of cleanup. Marks Completed/Downloaded rows past ExpiryDate as
   Expired and RETURNS their file paths — the worker then deletes the physical
   files (missing files are logged and skipped, never an error).               */
CREATE OR ALTER PROCEDURE dbo.usp_ExpireUserReqReports
    @WorkerName NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @WorkerName IS NOT NULL
        EXEC sp_set_session_context @key = N'AppUser', @value = @WorkerName;

    DECLARE @expired TABLE (ReportId BIGINT, FilePath NVARCHAR(1024) NULL);

    UPDATE dbo.UserReqReports
       SET GenerationStatus = 6,               -- Expired
           UpdatedDate      = SYSDATETIME()
    OUTPUT inserted.ReportId, inserted.FilePath INTO @expired
     WHERE GenerationStatus IN (3, 5)          -- Completed / Downloaded
       AND ExpiryDate IS NOT NULL
       AND ExpiryDate < SYSDATETIME();

    SELECT ReportId, FilePath FROM @expired;
END
GO

/* ── usp_PurgeUserReqReports ───────────────────────────────────────────────────
   Step 2 of cleanup. Hard-deletes Expired/Deleted/Failed/Cancelled queue rows
   older than @PurgeAfterDays. Audit rows are KEPT for @AuditRetentionDays.    */
CREATE OR ALTER PROCEDURE dbo.usp_PurgeUserReqReports
    @PurgeAfterDays     INT = 90,
    @AuditRetentionDays INT = 365
AS
BEGIN
    SET NOCOUNT ON;

    DELETE dbo.UserReqReports
     WHERE GenerationStatus IN (4, 6, 7, 8)    -- Failed / Expired / Deleted / Cancelled
       AND UpdatedDate < DATEADD(DAY, -@PurgeAfterDays, SYSDATETIME());

    DECLARE @purged INT = @@ROWCOUNT;

    DELETE dbo.UserReqReportsAudit
     WHERE ChangedDate < DATEADD(DAY, -@AuditRetentionDays, SYSDATETIME());

    SELECT @purged AS PurgedRequests, @@ROWCOUNT AS PurgedAuditRows;
END
GO

PRINT 'UserReqReports procedures deployed.';
GO
