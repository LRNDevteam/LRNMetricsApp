/*
Creates Run_Log / Step_Log / Error_Log tables matching the columns in LRN_Process_Log_Template.xlsx.
RunID generation is NOT here - see sql/LRNMaster/11_RunId_PerLab.sql.
*/

SET NOCOUNT ON;
GO

/*
    RunID generation lives in sql/LRNMaster/11_RunId_PerLab.sql, which is authoritative.

    It used to be here: dbo.LRN_RunIdSequence keyed on RunDate alone, plus a dbo.sp_LRN_NextRunId
    that produced the old global format (20260801R0007). RunIds are now per lab and continuous
    (R20260803CRT0001), and both objects changed shape.

    The definitions are deliberately NOT duplicated here. Re-running this file after a deployment
    would otherwise quietly put the old daily global counter back and start issuing the old format
    again, which is the kind of regression nobody notices until the ids are already in the data.
*/

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
