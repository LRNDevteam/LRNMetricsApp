namespace LabMetricsDashboard.Models;

// =====================================================================
// PhiLife Executive Summary – View Model
// =====================================================================

/// <summary>
/// One row in the Executive Summary grid.
/// Counts (LIS / PMS sections) and dollar amounts (Cash / Avg sections)
/// are both stored as <c>decimal</c>; the view decides how to format.
/// </summary>
public sealed class ExecSummaryRow
{
    /// <summary>Short code used for ordering and indentation logic (e.g. "A", "B1", "D-Recv").</summary>
    public string RowCode { get; set; } = string.Empty;

    /// <summary>Section label: "LIS", "PMS", "Cash", "Avg".</summary>
    public string Category { get; set; } = string.Empty;

    /// <summary>Human-readable metric name shown in the Description column.</summary>
    public string Description { get; set; } = string.Empty;

    /// <summary>
    /// True when the description starts with whitespace (sub-row / indented bullet).
    /// Derived from the SP returning descriptions with leading spaces.
    /// </summary>
    public bool IsSubRow => Description.StartsWith("  ", StringComparison.Ordinal);

    /// <summary>
    /// True when the description starts with four or more leading spaces,
    /// indicating a second-level sub-row (e.g. D.5.1 PanelType under D.5 Coding Exception).
    /// </summary>
    public bool IsSubSubRow => Description.StartsWith("    ", StringComparison.Ordinal);

    /// <summary>Values keyed by (Year, Month). Year=0, Month=0 is the grand total.</summary>
    public Dictionary<(int Year, int Month), decimal> ValuesByYearMonth { get; set; } = [];

    /// <summary>Grand-total value (Year=0, Month=0).</summary>
    public decimal Total => ValuesByYearMonth.TryGetValue((0, 0), out var v) ? v : 0m;
}

/// <summary>
/// Top-level view model for the PhiLife Executive Summary page.
/// </summary>
public sealed class PhiExecutiveSummaryViewModel
{
    /// <summary>All available labs for the lab selector drop-down.</summary>
    public List<string> AvailableLabs { get; set; } = [];

    /// <summary>Currently selected lab name (e.g. "Phi_Life").</summary>
    public string SelectedLab { get; set; } = string.Empty;

    // ── Filter state – legacy year/month ───────────────────────────
    public int? SelectedYearFrom  { get; set; }
    public int? SelectedYearTo    { get; set; }
    public int? SelectedMonthFrom { get; set; }
    public int? SelectedMonthTo   { get; set; }

    // ── Filter state – exact date ranges (Cove and future labs) ────
    public DateTime? DosFrom      { get; set; }
    public DateTime? DosTo        { get; set; }
    public DateTime? ReceivedFrom { get; set; }
    public DateTime? ReceivedTo   { get; set; }
    public DateTime? BilledFrom   { get; set; }
    public DateTime? BilledTo     { get; set; }
    public DateTime? PostedFrom   { get; set; }
    public DateTime? PostedTo     { get; set; }

    // ── Filter state – dimension multi-select (Cove and future labs)
    public List<string> SelectedPanels    { get; set; } = [];
    public List<string> SelectedClinics   { get; set; } = [];
    public List<string> SelectedProviders { get; set; } = [];
    public List<string> SelectedReps      { get; set; } = [];

    // ── Filter option lists ─────────────────────────────────────────
    public List<int>    AvailableYears     { get; set; } = [];

    // Available dimension options (populated for Cove only on initial load;
    // also refreshable via /ExecutiveSummary/FilterOptions AJAX for all labs)
    public List<string> AvailablePanels    { get; set; } = [];
    public List<string> AvailableClinics   { get; set; } = [];
    public List<string> AvailableProviders { get; set; } = [];
    public List<string> AvailableReps      { get; set; } = [];

    // ── Data ────────────────────────────────────────────────────────
    /// <summary>
    /// Ordered list of (Year, Month) columns discovered in the data.
    /// Year=0, Month=0 is always appended last as the "Total" column.
    /// </summary>
    public List<(int Year, int Month)> YearMonthColumns { get; set; } = [];

    /// <summary>Grand totals for each year, keyed by year.</summary>
    public Dictionary<int, decimal> YearlyTotals { get; set; } = [];

    /// <summary>All metric rows, in display order (A, B, B1…B31, C … AL).</summary>
    public List<ExecSummaryRow> Rows { get; set; } = [];


    /// <summary>Error message when the query fails or is unavailable.</summary>
    public string? ErrorMessage { get; set; }

    public bool HasData => Rows.Count > 0;

    // ── Convenience section accessors for the view ──────────────────
    public IEnumerable<ExecSummaryRow> LisRows  => Rows.Where(r => r.Category == "LIS");
    public IEnumerable<ExecSummaryRow> PmsRows  => Rows.Where(r => r.Category == "PMS");
    public IEnumerable<ExecSummaryRow> CashRows => Rows.Where(r => r.Category == "Cash");
    public IEnumerable<ExecSummaryRow> AvgRows  => Rows.Where(r => r.Category == "Avg");
}
