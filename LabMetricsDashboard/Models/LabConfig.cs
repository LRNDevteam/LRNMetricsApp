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
    /// When true the Clinic Summary and Sales Rep Summary pages are available
    /// for this lab (reads from <c>dbo.ClaimLevelData</c>).
    /// Requires <see cref="DBEnabled"/> and <see cref="DbConnectionString"/> to also be set.
    /// </summary>
    public bool LineClaimEnable { get; init; } = false;

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
    /// When true the "Top 5 Insurance Total Payments" tab is disabled
    /// on the Collection Summary page for this lab.
    /// Defaults to false (tab is enabled).
    /// </summary>
    public bool DisableShowTop5TotalPayments { get; init; }

    /// <summary>
    /// Controls which Collection Report output format is used.
    /// When set to <c>"table1"</c>, encounter counts come from <c>LineLevelData</c>.
    /// When absent or empty, encounter counts come from <c>ClaimLevelData</c> (default).
    /// </summary>
    public string? CollectionOutput { get; init; }

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

    /// <summary>
    /// Enables the Coding Summary page under Analytics menu.
    /// Defaults to true for backward compatibility.
    /// </summary>
    public bool EnableCoding { get; init; } = true;

    /// <summary>
    /// Enables the Prediction Analysis page under Analytics menu.
    /// Defaults to true for backward compatibility.
    /// </summary>
    public bool EnablePrediction { get; init; } = true;

    /// <summary>
    /// Enables the Forecasting Summary page under Analytics menu.
    /// Defaults to true for backward compatibility.
    /// </summary>
    public bool EnableForcast { get; init; } = true;

    /// <summary>
    /// Enables the Clinic Summary page under Analytics menu.
    /// Defaults to true for backward compatibility.
    /// </summary>
    public bool EnableClinicsummary { get; init; } = true;

    /// <summary>
    /// Enables the Sales Rep Summary page under Analytics menu.
    /// Defaults to true for backward compatibility.
    /// </summary>
    public bool EnableSalesRepsummary { get; init; } = true;

    /// <summary>
    /// Enables the Production Report page under Standard Reports menu.
    /// Defaults to true for backward compatibility.
    /// </summary>
    public bool EnableProductionReport { get; init; } = true;

    /// <summary>
    /// Enables the Collection Summary page under Standard Reports menu.
    /// Defaults to true for backward compatibility.
    /// </summary>
    public bool EnableCollectionReport { get; init; } = true;

    /// <summary>
    /// Optional per-lab Production Summary settings (rule selection, etc.).
    /// When null or when <see cref="ProductionSummaryConfig.Rule"/> is empty,
    /// the legacy default behavior is used (columns by FirstBilledDate).
    /// </summary>
    public ProductionSummaryConfig? ProductionSummary { get; init; }
}

/// <summary>
/// Per-lab settings that control how the Monthly Claim Volume table
/// in the Production Report is computed. The <see cref="Rule"/> value
/// selects between alternative grouping/filter strategies.
/// </summary>
/// <remarks>
/// Supported rules:
/// <list type="bullet">
///   <item><c>Rule1</c> – Columns grouped by Year/Month of <c>ChargeEnteredDate</c>;
///   filter retains <c>FirstBilledDate IS NOT NULL</c> and <c>PayerName &lt;&gt; ''</c>;
///   rows ranked by <c>COUNT(DISTINCT ClaimID)</c> with Top 3 payer drill-down.
///   Used by PCRLabsofAmerica, Beech Tree, Phi Life, Rising Tides, InHealth, PCR CO, PCR AL.</item>
///   <item><c>Rule2</c> – Same as Rule1 (ChargeEnteredDate columns, Top 3 payer drill-down,
///   sort by Grand Total) but the row filter excludes any row whose <c>PayerName_Raw</c>
///   contains <c>None</c>, <c>Accu Labs</c>, <c>Client Bill</c>, <c>Client</c>, <c>Patient</c>,
///   or <c>Patient Pay</c>. <c>FirstBilledDate IS NOT NULL</c> is still required.
///   Used by Certus Laboratories.</item>
///   <item><c>Rule3</c> – Same as Rule1 (ChargeEnteredDate columns, Top 3 payer drill-down,
///   sort by Grand Total) with explicit filters <c>PayerName &lt;&gt; ''</c>,
///   <c>ChargeEnteredDate IS NOT NULL</c> and <c>FirstBilledDate IS NOT NULL</c>.
///   Row source is <c>PanelName</c> today; will switch to <c>PanelNameNew</c> when that
///   column is added. Used by Augustus Laboratories.</item>
///   <item><c>Rule4</c> – Currently identical to <c>Rule3</c> (same filters, ChargeEnteredDate
///   columns, <c>PanelName</c> fallback). Used by NorthWest. Exists as a distinct rule so it
///   can diverge from Rule3 later.</item>
///   <item><c>Rule5</c> – Identical to the legacy default: columns grouped by
///   <c>YEAR/MONTH(FirstBilledDate)</c>, filter <c>PayerName &lt;&gt; ''</c> and
///   <c>FirstBilledDate IS NOT NULL</c>, with Top 3 payer drill-down by
///   <c>COUNT(DISTINCT ClaimID)</c> sorted by Grand Total. Used by Cove and Elixir.</item>
/// </list>
/// When unset or empty the dashboard falls back to the legacy behavior
/// (columns grouped by <c>FirstBilledDate</c>).
/// </remarks>
public sealed class ProductionSummaryConfig
{
    /// <summary>Rule name (e.g. <c>Rule1</c>). Case-insensitive.</summary>
    public string? Rule { get; init; }

    /// <summary>
    /// Optional rule applied independently to the Weekly Claim Volume tab
    /// (e.g. <c>Rule2</c>, <c>Rule3</c>, <c>Rule4</c>, <c>Rule5</c>).
    /// Same semantics as <see cref="Rule"/>: selects the column date source
    /// (<c>FirstBilledDate</c> vs <c>ChargeEnteredDate</c>) and the row filter
    /// for the last-4-weeks pivot.
    /// When unset or empty the weekly tab falls back to <see cref="Rule"/>.
    /// Configured via the <c>"weekrule"</c> JSON key (case-insensitive binding).
    /// </summary>
    public string? WeekRule { get; init; }

    /// <summary>
    /// Optional week boundary used by the Weekly Claim Volume table.
    /// Accepted values (case-insensitive): <c>Mon to Sun</c> (default), <c>Tue to Mon</c>,
    /// <c>Wed to Tue</c>, <c>Thu to Wed</c>, <c>Fri to Thu</c>.
    /// When unset or unrecognized the dashboard uses Monday-to-Sunday weeks.
    /// </summary>
    public string? WeekRange { get; init; }
}