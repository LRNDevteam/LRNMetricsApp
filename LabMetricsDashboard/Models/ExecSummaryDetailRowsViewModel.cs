namespace LabMetricsDashboard.Models;

// =====================================================================
// Executive Summary – Detail Page (row-level drill-down) view model
//
// Unlike the older <see cref="ExecSummaryDetailViewModel"/> /
// <see cref="ExecSummaryDetailRow"/> pair (a fixed 13–17 column shared
// shape), this view model is column-agnostic: the column list and the
// row values are read directly off the SqlDataReader for whichever
// "row-level detail" SP was called (LIMSMaster, ClaimLevelData, or —
// for RisingTides "2. PMS Breakdown → Paid - Client" — ClientPaidListData).
// This lets the Detail page show the full set of columns the business
// asked for, regardless of which source table they come from, and lets
// a single Excel export builder work for all three.
// =====================================================================

/// <summary>View model for the Executive Summary Detail page (row-level drill-down).</summary>
public sealed class ExecSummaryDetailRowsViewModel
{
    public string Category    { get; set; } = string.Empty;
    public string RowCode     { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public int    Year        { get; set; }
    public int    Month       { get; set; }

    /// <summary>e.g. "Jan 2025" or "All".</summary>
    public string MonthLabel  { get; set; } = string.Empty;

    /// <summary>The value of the cell that was clicked on the Executive Summary grid.</summary>
    public decimal? SelectedValue { get; set; }

    /// <summary>Selected value formatted as currency (Cash/Avg categories) or a whole-number count.</summary>
    public string SelectedValueFormatted =>
        SelectedValue is not { } v ? string.Empty :
        (Category is "Cash" or "Avg") ? LabMetricsDashboard.Helpers.AccountingHtml.Text(v) : ((long)v).ToString("N0");

    /// <summary>URL to return to the Executive Summary index (with original filters).</summary>
    public string BackUrl { get; set; } = string.Empty;

    /// <summary>Friendly name of the source table (e.g. "LIMSMaster", "ClaimLevelData", "ClientPaidListData").</summary>
    public string SourceLabel { get; set; } = string.Empty;

    /// <summary>Column names, in the order returned by the SP.</summary>
    public List<string> Columns { get; set; } = [];

    /// <summary>Row values, each array aligned with <see cref="Columns"/>. Cell values may be null.</summary>
    public List<object?[]> Rows { get; set; } = [];

    public string? ErrorMessage { get; set; }

    public bool HasData => Rows.Count > 0;
}
