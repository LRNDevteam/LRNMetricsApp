namespace PredictionAnalysis.Models;

/// <summary>
/// Represents one lab's I/O paths loaded from {LabConfigFolder}\{LabName}.json.
/// Runtime fields are written back after every successful run.
/// </summary>
public class LabConfig
{
    public string  LabName               { get; set; } = string.Empty;

    /// <summary>Root input folder. Source files live under Year\Month\WeekFolder subfolders.</summary>
    public string  InputFolderPath       { get; set; } = string.Empty;

    /// <summary>Flat staging folder. Source file is COPIED here before processing.</summary>
    public string  ProcessingFolderPath  { get; set; } = string.Empty;

    /// <summary>Root output folder. Report is written to Year\Month\WeekFolder mirror.</summary>
    public string  OutputFolderPath      { get; set; } = string.Empty;

    // ?? Database settings (per-lab) ???????????????????????????????????????????

    /// <summary>
    /// Set to true to persist PayerValidation source rows to SQL Server before
    /// the prediction analysis runs.  Requires <see cref="DbConnectionString"/>
    /// to be populated.  Defaults to false — DB insert is opt-in per lab.
    /// </summary>
    public bool    EnableDatabaseInsert  { get; set; } = false;

    /// <summary>
    /// SQL Server connection string for this lab's database.
    /// Each lab can target a different database / server.
    /// Ignored when <see cref="EnableDatabaseInsert"/> is false.
    /// </summary>
    public string? DbConnectionString    { get; set; }

    // ?? Runtime fields (written back after every successful run) ?????????????

    /// <summary>Full path of the last successfully processed INPUT source file.
    /// Compared on next run — matching path causes the lab to be skipped.</summary>
    public string? LastProcessedFile          { get; set; }

    /// <summary>Relative sub-folder of the last run (e.g. "2026\02. February\02.25.2026 - 03.03.2026").
    /// Mirrors the Input structure under OutputFolderPath.</summary>
    public string? LastProcessedRelativePath  { get; set; }

    /// <summary>Full path of the generated report from the last successful run.
    /// Used by the SharePoint importer to open the file directly.</summary>
    public string? LastOutputFilePath         { get; set; }
}