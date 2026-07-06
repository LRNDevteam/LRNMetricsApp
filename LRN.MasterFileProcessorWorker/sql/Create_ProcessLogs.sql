/*
Creates Run_Log / Step_Log / Error_Log tables matching the columns in LRN_Process_Log_Template.xlsx
and a RunID generator (RUN-YYYY-MM-DD-0001)
*/

SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.LRN_RunIdSequence', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LRN_RunIdSequence
    (
        RunDate date NOT NULL CONSTRAINT PK_LRN_RunIdSequence PRIMARY KEY,
        LastSeq int NOT NULL
    );
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_LRN_NextRunId
    @RunId varchar(30) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @today date = CONVERT(date, SYSDATETIME());
    DECLARE @seq int;

    BEGIN TRAN;

    UPDATE dbo.LRN_RunIdSequence WITH (UPDLOCK, HOLDLOCK)
       SET LastSeq = LastSeq + 1
     WHERE RunDate = @today;

    IF @@ROWCOUNT = 0
    BEGIN
        INSERT dbo.LRN_RunIdSequence (RunDate, LastSeq)
        VALUES (@today, 1);
    END

    SELECT @seq = LastSeq
      FROM dbo.LRN_RunIdSequence
     WHERE RunDate = @today;

    COMMIT;

    SET @RunId =
        REPLACE(CONVERT(varchar(10), getdate(), 23),'-','') + 'R' + RIGHT('0000' + CONVERT(varchar(10), @seq), 4);
END
GO

IF OBJECT_ID('dbo.LRN_Run_Log', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LRN_Run_Log
    (
        RunID varchar(30) NOT NULL CONSTRAINT PK_LRN_Run_Log PRIMARY KEY,
        LabName varchar(120) NOT NULL,
        PipelineName varchar(200) NULL,
        TriggerType varchar(50) NULL,
        TriggeredBy varchar(200) NULL,
        StartTimeIST datetime2(0) NULL,
        EndTimeIST datetime2(0) NULL,
        DurationSeconds int NULL,
        OverallStatus varchar(30) NULL,
        LatestMasterFileFound varchar(10) NULL,
        InputMasterSharePointPath nvarchar(800) NULL,
        InputMasterFileName nvarchar(300) NULL,
        InputMasterFileModifiedTime datetime2(0) NULL,
        InputMasterFileSizeMB decimal(10,2) NULL,
        MandatoryColumnCheck varchar(10) NULL,
        SplitOutputWrittenToSharePoint varchar(10) NULL,
        PayerPolicyValidationStatus varchar(30) NULL,
        CodingValidationStatus varchar(30) NULL,
        AveragesProcessStatus varchar(30) NULL,
        OutputsCopiedToSharePoint varchar(30) NULL,
        MasterSyncPerformed varchar(30) NULL,
        TotalErrors int NULL,
        TotalWarnings int NULL,
        Notes nvarchar(max) NULL
    );
END
GO

IF OBJECT_ID('dbo.LRN_Step_Log', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LRN_Step_Log
    (
        RunID varchar(30) NOT NULL,
        LabName varchar(120) NULL,
        StepSeq int NOT NULL,
        StepName nvarchar(200) NOT NULL,
        StepCategory varchar(80) NULL,
        SourceSystem varchar(80) NULL,
        StartTimeIST datetime2(0) NULL,
        EndTimeIST datetime2(0) NULL,
        DurationSeconds int NULL,
        Status varchar(30) NULL,
        RecordsIn int NULL,
        RecordsOut int NULL,
        FileNameIn nvarchar(300) NULL,
        FileNameOut nvarchar(300) NULL,
        PathIn nvarchar(800) NULL,
        PathOut nvarchar(800) NULL,
        ErrorCode varchar(80) NULL,
        ErrorMessage nvarchar(800) NULL,
        ErrorDetail nvarchar(max) NULL,
        RetryCount int NULL,
        ExecutedBy varchar(120) NULL,
        Host varchar(120) NULL,
        ModuleVersion varchar(50) NULL,

        CONSTRAINT PK_LRN_Step_Log PRIMARY KEY (RunID, StepSeq),
        CONSTRAINT FK_LRN_Step_Log_Run FOREIGN KEY (RunID) REFERENCES dbo.LRN_Run_Log(RunID)
    );
END
GO

IF OBJECT_ID('dbo.LRN_Error_Log', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LRN_Error_Log
    (
        RunID varchar(30) NOT NULL,
        LabName varchar(120) NULL,
        ErrorTimeIST datetime2(3) NOT NULL,
        Severity varchar(20) NOT NULL,
        StepName nvarchar(200) NULL,
        ErrorCode varchar(80) NULL,
        ErrorSummary nvarchar(800) NOT NULL,
        MissingColumns nvarchar(800) NULL,
        SheetName nvarchar(200) NULL,
        FileName nvarchar(300) NULL,
        FilePath nvarchar(800) NULL,
        RowExample nvarchar(200) NULL,
        RecommendedAction nvarchar(800) NULL,
        OwnerTeam nvarchar(160) NULL,
        TicketID nvarchar(80) NULL,
        Status nvarchar(30) NULL,

        CONSTRAINT PK_LRN_Error_Log PRIMARY KEY (RunID, ErrorTimeIST),
        CONSTRAINT FK_LRN_Error_Log_Run FOREIGN KEY (RunID) REFERENCES dbo.LRN_Run_Log(RunID)
    );
END
GO
