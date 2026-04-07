namespace LabMetricsDashboard.Models;

/// <summary>
/// Configuration for a single lab, bound from its dedicated JSON config file.
/// </summary>
public sealed class LabCsvConfig
{
    /// <summary>
    /// Root folder containing the year/month/week sub-folder hierarchy for this lab's CSV files.
    /// </summary>  
    public string ProductionMasterCsvPath { get; init; } = string.Empty;

    /// <summary>
    /// Root folder containing the year/month/week sub-folder hierarchy for this lab's
    /// Payer Policy Validation Report Excel files.
    /// </summary>
    public string PayerPolicyValidationReportPath { get; init; } = string.Empty;

    /// <summary>
    /// When true the Prediction Analysis dashboard reads from the SQL
    /// PayerValidationReport table using <see cref="DbConnectionString"/>.
    /// When false (default) it falls back to parsing the Excel file.
    /// </summary>
    public bool DBEnabled { get; init; } = false;

    /// <summary>
    /// Per-lab SQL Server connection string.
    /// Required when <see cref="DBEnabled"/> is true.
    /// </summary>
    public string? DbConnectionString { get; init; }

    /// <summary>
    /// The lab name as stored in the database's <c>PayerValidationReport.LabName</c> column.
    /// Use this when the PredictionAnalysisApp inserts data with a different lab name
    /// than the dashboard config key (e.g. DB has "PCRCO" but dashboard key is "PCR_Dx_CO").
    /// When null or empty, the dashboard config key is used.
    /// </summary>
    public string? DbLabName { get; init; }

    /// <summary>
    /// Folder that contains AI-generated prediction insight JSON files.
    /// The dashboard will pick the most-recent file whose name contains
    /// "prediction_insights" (case-insensitive).
    /// When null or empty the insight panel is not shown.
    /// </summary>
    public string? InsightPath { get; init; }

    /// <summary>
    /// Output folder for the background-generated RCM summary JSON file.
    /// The file is named using the same base name as the Claim Level CSV
    /// but with "Claim Level" replaced by "RCM".
    /// When null or empty RCM JSON generation is skipped for this lab.
    /// </summary>
    public string? RCMJsonPath { get; init; }

    /// <summary>
    /// Output folder that contains the latest CodingValidated Excel reports
    /// (used to resolve the most-recent file for display on the home tile).
    /// Mirrors the <c>Output.Reports</c> path in the CaptureDataApp lab config.
    /// When null or empty the Coding Summary tile is not shown.
    /// </summary>
    public string? Reports { get; init; }
}