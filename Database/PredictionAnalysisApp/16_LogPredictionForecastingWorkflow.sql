-- ============================================================
-- 16_LogPredictionForecastingWorkflow.sql
-- DEPLOY ON: LRNMaster ONLY (Azure MI)
--
-- IMPORTANT: Drop first — CREATE OR ALTER does not rename/remove
-- old parameters. If the prior version had @RequestedRunId only,
-- callers passing @RunId get Msg 8145 until this drop+create runs.
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.usp_LogPredictionForecastingWorkflow', N'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_LogPredictionForecastingWorkflow;
GO

CREATE PROCEDURE dbo.usp_LogPredictionForecastingWorkflow
    @Status           VARCHAR(50),                              -- InProgress | Success | Failed | Skipped
    @RunId            VARCHAR(30)  = NULL,                      -- preferred (app + backfill)
    @RequestedRunId   VARCHAR(30)  = NULL,                      -- alias accepted for older callers
    @SourceSystem     VARCHAR(100) = N'PayerValidationReport',
    @CreatedBy        VARCHAR(100) = N'PredictionAnalysis',
    @SourceFileName   NVARCHAR(400) = NULL,
    @LogMessage       NVARCHAR(4000) = NULL,
    @RowCount         BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -------------------------------------------------------------------------
    -- Resolve RunId (@RunId preferred, else @RequestedRunId)
    -------------------------------------------------------------------------
    DECLARE @ResolvedRunId VARCHAR(30) =
        COALESCE(
            NULLIF(LTRIM(RTRIM(@RunId)), N''),
            NULLIF(LTRIM(RTRIM(@RequestedRunId)), N'')
        );

    IF @ResolvedRunId IS NULL
    BEGIN
        RAISERROR('usp_LogPredictionForecastingWorkflow: @RunId (or @RequestedRunId) is required.', 16, 1);
        RETURN;
    END;

    -------------------------------------------------------------------------
    -- FUTURE: validate @ResolvedRunId against LIS / Claim / LRN_Run_Log
    -------------------------------------------------------------------------

    DECLARE @LogType VARCHAR(50) =
        CASE @Status
            WHEN N'InProgress' THEN N'Start'
            WHEN N'Success'    THEN N'Info'
            WHEN N'Failed'     THEN N'Error'
            WHEN N'Skipped'    THEN N'Warning'
            ELSE N'Info'
        END;

    DECLARE @Msg NVARCHAR(4000) = @LogMessage;
    IF @Msg IS NULL OR LTRIM(RTRIM(@Msg)) = N''
        SET @Msg = CASE @Status
            WHEN N'InProgress' THEN N'Prediction Analysis / Forecasting started (PayerValidation aggregates).'
            WHEN N'Success'    THEN N'Prediction Analysis / Forecasting completed (PayerValidation aggregates refreshed).'
            WHEN N'Failed'     THEN N'Prediction Analysis / Forecasting failed.'
            WHEN N'Skipped'    THEN N'Prediction Analysis / Forecasting skipped.'
            ELSE N'Prediction Analysis / Forecasting workflow update.'
        END;

    -------------------------------------------------------------------------
    -- ReportTypeMaster: 11 = Prediction Analysis, 7 = Forecasting
    -------------------------------------------------------------------------
    DECLARE @ReportName VARCHAR(100);

    DECLARE report_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT v.ReportName
        FROM (VALUES
            (N'Prediction Analysis'),   -- ReportTypeId 11
            (N'Forecasting')            -- ReportTypeId 7
        ) AS v(ReportName);

    OPEN report_cursor;
    FETCH NEXT FROM report_cursor INTO @ReportName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.usp_ReportRunIdInfoLog_Insert
            @RunId          = @ResolvedRunId,
            @ReportType     = @ReportName,
            @SourceSystem   = @SourceSystem,
            @SourceFileName = @SourceFileName,
            @LogType        = @LogType,
            @LogMessage     = @Msg,
            @CreatedBy      = @CreatedBy;

        EXEC dbo.usp_ReportsWorkflowTracker_Upsert
            @RunId      = @ResolvedRunId,
            @ReportName = @ReportName,
            @Status     = @Status,
            @RowCount   = @RowCount,
            @CreatedBy  = @CreatedBy;

        FETCH NEXT FROM report_cursor INTO @ReportName;
    END;

    CLOSE report_cursor;
    DEALLOCATE report_cursor;
END
GO

-- Verify parameters after deploy:
-- SELECT p.name, t.name AS type_name, p.max_length
-- FROM sys.procedures sp
-- JOIN sys.parameters p ON p.object_id = sp.object_id
-- JOIN sys.types t ON t.user_type_id = p.user_type_id
-- WHERE sp.name = 'usp_LogPredictionForecastingWorkflow'
-- ORDER BY p.parameter_id;
GO
