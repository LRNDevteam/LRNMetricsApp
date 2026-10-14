-- Local-dev stubs for Coding Validation Report Control Board logging.
-- Deploy to LRNMaster when usp_ReportRunIdInfoLog_Insert / usp_ReportsWorkflowTracker_Upsert
-- and sp_GetRecentSuccessRunByLab are not present (local ASKS\MYDEV).
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE LRNMaster;
GO

IF OBJECT_ID(N'dbo.ReportTypeMaster', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ReportTypeMaster
    (
        ReportTypeId INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        ReportName   VARCHAR(200) NOT NULL UNIQUE,
        DisplayOrder INT NOT NULL DEFAULT 0,
        IsActive     BIT NOT NULL DEFAULT 1
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.ReportTypeMaster WHERE ReportName = 'Coding Validation')
    INSERT INTO dbo.ReportTypeMaster (ReportName, DisplayOrder) VALUES ('Coding Validation', 10);
GO

IF OBJECT_ID(N'dbo.ReportRunIdInfoLog', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ReportRunIdInfoLog
    (
        ReportRunIdInfoLogId BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        RunId            VARCHAR(30)  NOT NULL,
        ReportType       VARCHAR(100) NOT NULL,
        SourceSystem     VARCHAR(100) NULL,
        SourceFileName   NVARCHAR(400) NULL,
        LogType          VARCHAR(50)  NOT NULL,
        LogMessage       NVARCHAR(MAX) NULL,
        CreatedBy        VARCHAR(100) NULL,
        CreatedOn        DATETIME2(3) NOT NULL CONSTRAINT DF_ReportRunIdInfoLog_CreatedOn DEFAULT SYSUTCDATETIME()
    );
END
GO

IF OBJECT_ID(N'dbo.ReportsWorkflowTracker', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ReportsWorkflowTracker
    (
        ReportsWorkflowTrackerId BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        RunId       VARCHAR(30)  NOT NULL,
        ReportName  VARCHAR(200) NOT NULL,
        Status      VARCHAR(50)  NOT NULL,
        [RowCount]  BIGINT NULL,
        StartedOn   DATETIME2(3) NULL,
        CompletedOn DATETIME2(3) NULL,
        Remarks     NVARCHAR(MAX) NULL,
        CreatedBy   VARCHAR(100) NULL,
        UpdatedOn   DATETIME2(3) NOT NULL CONSTRAINT DF_ReportsWorkflowTracker_UpdatedOn DEFAULT SYSUTCDATETIME(),
        CONSTRAINT UQ_ReportsWorkflowTracker_Run_Report UNIQUE (RunId, ReportName)
    );
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_ReportRunIdInfoLog_Insert
    @RunId          VARCHAR(30),
    @ReportType     VARCHAR(100),
    @SourceSystem   VARCHAR(100) = NULL,
    @SourceFileName NVARCHAR(400) = NULL,
    @LogType        VARCHAR(50),
    @LogMessage     NVARCHAR(MAX) = NULL,
    @CreatedBy      VARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.ReportTypeMaster WHERE ReportName = @ReportType)
    BEGIN
        RAISERROR('usp_ReportRunIdInfoLog_Insert: unknown ReportType ''%s''.', 16, 1, @ReportType);
        RETURN;
    END;

    INSERT INTO dbo.ReportRunIdInfoLog
        (RunId, ReportType, SourceSystem, SourceFileName, LogType, LogMessage, CreatedBy)
    VALUES
        (@RunId, @ReportType, @SourceSystem, @SourceFileName, @LogType, @LogMessage, @CreatedBy);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_ReportsWorkflowTracker_Upsert
    @RunId       VARCHAR(30),
    @ReportName  VARCHAR(200),
    @Status      VARCHAR(50),
    @RowCount    BIGINT = NULL,
    @StartedOn   DATETIME2(3) = NULL,
    @CompletedOn DATETIME2(3) = NULL,
    @Remarks     NVARCHAR(MAX) = NULL,
    @CreatedBy   VARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.ReportTypeMaster WHERE ReportName = @ReportName)
    BEGIN
        RAISERROR('usp_ReportsWorkflowTracker_Upsert: unknown ReportName ''%s''.', 16, 1, @ReportName);
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.ReportsWorkflowTracker WHERE RunId = @RunId AND ReportName = @ReportName)
    BEGIN
        UPDATE dbo.ReportsWorkflowTracker
        SET Status      = @Status,
            [RowCount]  = COALESCE(@RowCount, [RowCount]),
            StartedOn   = COALESCE(@StartedOn, StartedOn),
            CompletedOn = COALESCE(@CompletedOn, CompletedOn),
            Remarks     = COALESCE(@Remarks, Remarks),
            CreatedBy   = COALESCE(@CreatedBy, CreatedBy),
            UpdatedOn   = SYSUTCDATETIME()
        WHERE RunId = @RunId AND ReportName = @ReportName;
    END
    ELSE
    BEGIN
        INSERT INTO dbo.ReportsWorkflowTracker
            (RunId, ReportName, Status, [RowCount], StartedOn, CompletedOn, Remarks, CreatedBy)
        VALUES
            (@RunId, @ReportName, @Status, @RowCount, @StartedOn, @CompletedOn, @Remarks, @CreatedBy);
    END
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_GetRecentSuccessRunByLab
    @LabName NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        RunID,
        LabName,
        OverallStatus,
        StartTimeIST,
        EndTimeIST
    FROM dbo.LRN_Run_Log
    WHERE OverallStatus = 'SUCCESS'
      AND (
            @LabName IS NULL
            OR LTRIM(RTRIM(@LabName)) = ''
            OR LabName LIKE '%' + LTRIM(RTRIM(@LabName)) + '%'
          )
    ORDER BY EndTimeIST DESC, RunID DESC;
END
GO

-- Seed Cove successful run that matches local COVELRN Claim/Line data.
IF NOT EXISTS (SELECT 1 FROM dbo.LRN_Run_Log WHERE RunID = '20260710R0111')
BEGIN
    INSERT INTO dbo.LRN_Run_Log
    (
        RunID, LabName, PipelineName, TriggerType, TriggeredBy,
        StartTimeIST, EndTimeIST, DurationSeconds, OverallStatus,
        LatestMasterFileFound, Notes, UpdatedOn, UpdatedBy
    )
    VALUES
    (
        '20260710R0111', 'Cove', 'LocalDevSeed', 'Manual', 'LocalDev',
        DATEADD(HOUR, -2, SYSDATETIME()), SYSDATETIME(), 7200, 'SUCCESS',
        1, 'Seeded for CodingMaster.Runner DB-input local test', SYSDATETIME(), 'LocalDev'
    );
END
ELSE
BEGIN
    UPDATE dbo.LRN_Run_Log
    SET LabName = 'Cove',
        OverallStatus = 'SUCCESS',
        EndTimeIST = COALESCE(EndTimeIST, SYSDATETIME()),
        UpdatedOn = SYSDATETIME(),
        UpdatedBy = 'LocalDev'
    WHERE RunID = '20260710R0111';
END
GO
