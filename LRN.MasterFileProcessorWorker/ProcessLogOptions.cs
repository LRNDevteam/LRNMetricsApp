using static SharePointDownloader;

public sealed class ProcessLogOptions
{
    public bool Enabled { get; set; } = true;

    /// <summary>
    /// Also write Run_Log / Step_Log / Error_Log as CSV files (matching LRN_Process_Log_Template.xlsx headers).
    /// </summary>
    public bool CsvEnabled { get; set; } = false;

    /// <summary>
    /// Write a SINGLE Excel workbook per day with 3 sheets:
    ///   Run_Log, Step_Log, Error_Log
    /// This matches the template sheets in LRN_Process_Log_Template.xlsx.
    /// </summary>
    public bool WorkbookEnabled { get; set; } = true;

    /// <summary>
    /// Local folder root for the daily workbook.
    /// If empty, defaults to: {MasterFileProcessor.ReportOutputsRoot}\ProcessLogs
    /// </summary>
    public string WorkbookLocalFolder { get; set; } = "";

    /// <summary>
    /// Daily workbook file prefix. File name will be:
    ///   {WorkbookFilePrefix}.{ddMMyyyy}.xlsx
    /// </summary>
    public string WorkbookFilePrefix { get; set; } = "LRN_Process_Logs";

    /// <summary>
    /// Upload the workbook to SharePoint after writing.
    /// </summary>
    public bool WorkbookUploadToSharePoint { get; set; } = true;

    /// <summary>
    /// SharePoint folder path where the workbook should be uploaded.
    /// If empty, falls back to MasterFileProcessor:SharePoint:FileStatusLogUploadFolderPath.
    /// If this ends with "ImportLogs", it will be expanded to: ImportLogs/{yyyy}/{Month}.
    /// If this ends with "ImportLogs/{yyyy}", it will be expanded to: ImportLogs/{yyyy}/{Month}.
    /// </summary>
    public string WorkbookSharePointFolderPath { get; set; } = "";

    /// <summary>
    /// Upload strategy:
    /// - "EachWrite" : upload workbook after every Run/Step/Error write
    /// - "EndOfRun"  : upload workbook only on CompleteRunAsync
    /// </summary>
    public string WorkbookUploadMode { get; set; } = "EachWrite";

    /// <summary>
    /// Local folder root for CSV logs.
    /// If empty, defaults to: {MasterFileProcessor.ReportOutputsRoot}\ProcessLogs
    /// </summary>
    public string CsvLocalFolder { get; set; } = "";

    // Table names should match the SQL script (Create_ProcessLogs.sql)
    public string RunLogTable { get; set; } = "dbo.LRN_Run_Log";
    public string StepLogTable { get; set; } = "dbo.LRN_Step_Log";
    public string ErrorLogTable { get; set; } = "dbo.LRN_Error_Log";

    // Stored proc that generates RUN-YYYY-MM-DD-0001
    public string NextRunIdStoredProc { get; set; } = "dbo.sp_LRN_NextRunId";

    // Defaults used when worker doesn't supply values
    public string DefaultPipelineName { get; set; } = "LRN.MasterFileProcessorWorker";
    public string DefaultTriggerType { get; set; } = "Schedule";
    public string DefaultTriggeredBy { get; set; } = "Worker";
}

