/*==============================================================================
  usp_RefreshBT_ExecutiveSummary_OnNewFile

  PURPOSE
    Gate the heavy refresh so it runs ONLY when a NEW "TransactionDetail
    Adjustment" file has been loaded - not on every run.

  HOW IT DECIDES "NEW"
    A file is new if its name is present in dbo.BTTransactionDetailFileLogs
    (i.e. ClaimLineCSVDataCapture has already loaded it) BUT not yet present in
    the tracking table dbo.BTExecSummaryRefreshLog (i.e. we have not refreshed
    for it yet). Once refreshed, the name is recorded so the next run skips it.

  WHEN IT RUNS
    Only when at least one such new file exists. It then executes, in order:
        usp_RefreshBT_WOSummary      (rebuild BTWOSummary - Complete W/O split)
        usp_RefreshBT_ExecutiveSummary
    and records the file name(s) as refreshed.

  HOW TO CALL (from ClaimLineCSVDataCapture, AFTER it has loaded the file and
  written the row into BTTransactionDetailFileLogs):
        EXEC dbo.usp_RefreshBT_ExecutiveSummary_OnNewFile
             @FileName = N'TransactionDetail Adjustment_05.22.2026-05.28.2026.xlsx';
    Or, to auto-detect any unprocessed adjustment file, call with no argument:
        EXEC dbo.usp_RefreshBT_ExecutiveSummary_OnNewFile;

  NOTE: only file names starting with 'TransactionDetail Adjustment' trigger a
        refresh (change @Prefix below if your naming differs).
==============================================================================*/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE OR ALTER PROCEDURE [dbo].[usp_RefreshBT_ExecutiveSummary_OnNewFile]
    @FileName NVARCHAR(260) = NULL   -- pass the just-loaded file; NULL = auto-detect
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Prefix NVARCHAR(100) = N'TransactionDetail Adjustment';

    /* Tracking table - which files have already triggered a refresh */
    IF OBJECT_ID('dbo.BTExecSummaryRefreshLog', 'U') IS NULL
        CREATE TABLE dbo.BTExecSummaryRefreshLog
        (
            FileName    NVARCHAR(260) NOT NULL PRIMARY KEY,
            RefreshedAt DATETIME      NOT NULL CONSTRAINT DF_BTESRefresh_At DEFAULT (GETDATE())
        );

    /* -----------------------------------------------------------------
       Determine whether there is anything NEW to process.
       #New = adjustment files logged by the app but not yet refreshed.
    ------------------------------------------------------------------ */
    DROP TABLE IF EXISTS #New;
    SELECT DISTINCT LTRIM(RTRIM(l.FileName)) AS FileName
    INTO   #New
    FROM   dbo.BTTransactionDetailFileLogs l
    WHERE  l.FileName LIKE @Prefix + N'%'
      AND (@FileName IS NULL OR LTRIM(RTRIM(l.FileName)) = LTRIM(RTRIM(@FileName)))
      AND  NOT EXISTS (
            SELECT 1 FROM dbo.BTExecSummaryRefreshLog r
            WHERE  r.FileName = LTRIM(RTRIM(l.FileName)));

    IF NOT EXISTS (SELECT 1 FROM #New)
    BEGIN
        PRINT 'No new TransactionDetail Adjustment file - refresh skipped.';
        RETURN;
    END

    /* -----------------------------------------------------------------
       New file found -> refresh, then record it. Wrapped in TRY/CATCH so
       a failed refresh does NOT get marked as processed.
    ------------------------------------------------------------------ */
    BEGIN TRY
        BEGIN TRAN;

        EXEC dbo.usp_RefreshBT_WOSummary;          -- rebuild BTWOSummary (Complete W/O split)
        EXEC dbo.usp_RefreshBT_ExecutiveSummary;   -- rebuild the executive summary tables

        INSERT INTO dbo.BTExecSummaryRefreshLog (FileName, RefreshedAt)
        SELECT n.FileName, GETDATE()
        FROM   #New n
        WHERE  NOT EXISTS (SELECT 1 FROM dbo.BTExecSummaryRefreshLog r WHERE r.FileName = n.FileName);

        COMMIT;
        PRINT 'Executive summary refreshed for new TransactionDetail Adjustment file(s).';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        DECLARE @msg NVARCHAR(2048) = ERROR_MESSAGE();
        RAISERROR('Refresh failed, nothing marked as processed: %s', 16, 1, @msg);
    END CATCH
END
GO
