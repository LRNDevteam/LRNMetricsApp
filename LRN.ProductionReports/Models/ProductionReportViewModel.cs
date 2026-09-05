namespace LRN.ProductionReports.Models;

/// <summary>
/// View model for the Production Report page.
/// Contains the lab selector, filter state, and the "Monthly Claim Volume"
/// pivot table grouped by PanelName (rows)  Year/Month of FirstBilledDate (columns).
/// Each panel row includes drill-down sub-rows for its top 3 payers by unique claim count.
/// </summary>
public sealed class ProductionReportViewModel
{
    public List<string> AvailableLabs { get; init; } = [];
    public string SelectedLab { get; init; } = string.Empty;

    /// <summary>
    /// Active per-lab Production Summary rule applied to the Monthly Claim Volume tab
    /// (e.g. <c>"Rule1"</c>). Null/empty when the lab uses the legacy default behavior.
    /// </summary>
    public string? ProductionSummaryRule { get; init; }

    /// <summary>
    /// Active per-lab rule applied to the Weekly Claim Volume tab
    /// (e.g. <c>"Rule5"</c>). Independent from <see cref="ProductionSummaryRule"/>;
    /// when the lab does not configure a separate <c>weekrule</c>, falls back to it.
    /// </summary>
    public string? ProductionSummaryWeekRule { get; init; }

    /// <summary>
    /// Active per-lab week boundary applied to the Weekly Claim Volume tab
    /// (e.g. <c>"Mon to Sun"</c>, <c>"Thu to Wed"</c>). Null/empty when the lab uses
    /// the default Monday-to-Sunday week.
    /// </summary>
    public string? ProductionSummaryWeekRange { get; init; }

    // Filters
    public List<string> FilterPayerNames { get; init; } = [];
    public List<string> FilterPanelNames { get; init; } = [];

    /// <summary>
    /// When <c>true</c>, the selected <see cref="FilterPayerNames"/> are <em>excluded</em>
    /// from results rather than included. Only used by the Production Summary Report.
    /// </summary>
    public bool FilterPayerNamesExclude { get; init; }

    /// <summary>
    /// When <c>true</c>, the selected <see cref="FilterPanelNames"/> are <em>excluded</em>
    /// from results rather than included. Only used by the Production Summary Report.
    /// </summary>
    public bool FilterPanelNamesExclude { get; init; }
    public string? FilterFirstBillFrom { get; init; }
    public string? FilterFirstBillTo { get; init; }
    public string? FilterDosFrom { get; init; }
    public string? FilterDosTo { get; init; }
    public string? FilterFirstBilledFrom { get; init; }
    public string? FilterFirstBilledTo { get; init; }

    // Filter option lists
    public List<string> PayerNames { get; init; } = [];
    public List<string> PanelNames { get; init; } = [];

    /// <summary>Ordered list of year/month column keys (e.g. "2025-01").</summary>
    public List<string> Months { get; set; } = [];

    /// <summary>Ordered list of distinct years found in the data.</summary>
    public List<int> Years { get; set; } = [];

    /// <summary>Panel rows sorted by grand-total claim count descending.</summary>
    public List<ProductionPanelRow> PanelRows { get; set; } = [];

    /// <summary>Grand total across all panels for each month.</summary>
    public Dictionary<string, ProductionMonthCell> GrandTotalByMonth { get; set; } = [];

    /// <summary>Grand total claim count across all panels and months.</summary>
    public int GrandTotalClaims { get; set; }

    /// <summary>Grand total billed charges across all panels and months.</summary>
    public decimal GrandTotalCharges { get; set; }

    // ?? Weekly Claim Volume ??????????????????????????????????????

    public List<WeekColumn> WeekColumns { get; set; } = [];
    public List<WeeklyPanelRow> WeeklyPanelRows { get; set; } = [];
    public Dictionary<string, ProductionMonthCell> WeeklyGrandTotalByWeek { get; set; } = [];
    public int WeeklyGrandTotalClaims { get; set; }
    public decimal WeeklyGrandTotalCharges { get; set; }

    public List<CodingPanelRow> CodingPanelRows { get; set; } = [];
    public int CodingGrandTotalClaims { get; set; }
    public decimal CodingGrandTotalCharges { get; set; }

    public List<string> PayerBreakdownMonths { get; set; } = [];
    public List<int> PayerBreakdownYears { get; set; } = [];
    public List<PayerBreakdownRow> PayerBreakdownRows { get; set; } = [];
    public Dictionary<string, int> PayerBreakdownGrandByMonth { get; set; } = [];
    public int PayerBreakdownGrandTotal { get; set; }
    public Dictionary<string, decimal> PayerBreakdownGrandChargesByMonth { get; set; } = [];
    public decimal PayerBreakdownGrandTotalCharges { get; set; }

    public List<string> PanelBreakdownMonths { get; set; } = [];
    public List<int> PanelBreakdownYears { get; set; } = [];
    public List<PayerBreakdownRow> PanelBreakdownRows { get; set; } = [];
    public Dictionary<string, int> PanelBreakdownGrandByMonth { get; set; } = [];
    public int PanelBreakdownGrandTotal { get; set; }
    public Dictionary<string, decimal> PanelBreakdownGrandChargesByMonth { get; set; } = [];
    public decimal PanelBreakdownGrandTotalCharges { get; set; }

    public List<string> InsightDaqMonths { get; set; } = [];
    public List<int> InsightDaqYears { get; set; } = [];
    public List<PayerBreakdownRow> InsightDaqRows { get; set; } = [];
    public Dictionary<string, int> InsightDaqGrandByMonth { get; set; } = [];
    public int InsightDaqGrandTotal { get; set; }
    public Dictionary<string, decimal> InsightDaqGrandChargesByMonth { get; set; } = [];
    public decimal InsightDaqGrandTotalCharges { get; set; }

    public List<string> InsightWebPmMonths { get; set; } = [];
    public List<int> InsightWebPmYears { get; set; } = [];
    public List<PayerBreakdownRow> InsightWebPmRows { get; set; } = [];
    public Dictionary<string, int> InsightWebPmGrandByMonth { get; set; } = [];
    public int InsightWebPmGrandTotal { get; set; }
    public Dictionary<string, decimal> InsightWebPmGrandChargesByMonth { get; set; } = [];
    public decimal InsightWebPmGrandTotalCharges { get; set; }

    public List<string> HighestPayerMonths { get; set; } = [];
    public List<int> HighestPayerYears { get; set; } = [];
    public List<ProductionPanelRow> HighestPayerRows { get; set; } = [];
    public Dictionary<string, ProductionMonthCell> HighestPayerGrandByMonth { get; set; } = [];
    public int HighestPayerGrandTotalClaims { get; set; }
    public decimal HighestPayerGrandTotalCharges { get; set; }

    /// <summary>True when this page is the NorthWest Production Summary.</summary>
    public bool IsNorthWestLab =>
        SelectedLab.Equals("NorthWest", StringComparison.OrdinalIgnoreCase)
        || SelectedLab.Equals("NorthWest_Labs", StringComparison.OrdinalIgnoreCase);

    /// <summary>True when this page is the Augustus Production Summary.</summary>
    public bool IsAugustusLab =>
        SelectedLab.Equals("Augustus_Labs", StringComparison.OrdinalIgnoreCase)
        || SelectedLab.Equals("Augustus", StringComparison.OrdinalIgnoreCase);

    // ?? Payer X Panel ?????????????????????????????????????????????

    /// <summary>Ordered list of distinct panel names used as column headers.</summary>
    public List<string> PayerPanelColumns { get; set; } = [];

    /// <summary>Payer rows for the Payer X Panel table, sorted by grand total descending.</summary>
    public List<PayerPanelRow> PayerPanelRows { get; set; } = [];

    /// <summary>Grand total per panel across all payers (claims).</summary>
    public Dictionary<string, ProductionMonthCell> PayerPanelGrandByPanel { get; set; } = [];

    /// <summary>Grand total claim count across all payers and panels.</summary>
    public int PayerPanelGrandTotalClaims { get; set; }

    /// <summary>Grand total billed charges across all payers and panels.</summary>
    public decimal PayerPanelGrandTotalCharges { get; set; }

    // ?? Unbilled X Aging ?????????????????????????????????????????

    /// <summary>Panel rows for the Unbilled X Aging table, sorted by grand total descending.</summary>
    public List<UnbilledAgingRow> UnbilledAgingRows { get; set; } = [];

    /// <summary>Grand total per aging bucket across all panels.</summary>
    public Dictionary<string, ProductionMonthCell> UnbilledAgingGrandByBucket { get; set; } = [];

    /// <summary>Grand total claim count across all panels and buckets.</summary>
    public int UnbilledAgingGrandTotalClaims { get; set; }

    /// <summary>Grand total billed charges across all panels and buckets.</summary>
    public decimal UnbilledAgingGrandTotalCharges { get; set; }

    // ?? CPT Breakdown ????????????????????????????????????????????

    /// <summary>Ordered list of year/month column keys for CPT Breakdown (FirstBilledDate).</summary>
    public List<string> CptBreakdownMonths { get; set; } = [];

    /// <summary>Ordered list of distinct years in the CPT Breakdown data.</summary>
    public List<int> CptBreakdownYears { get; set; } = [];

    /// <summary>CPT rows for the CPT Breakdown table, sorted by grand total descending.</summary>
    public List<CptBreakdownRow> CptBreakdownRows { get; set; } = [];

    /// <summary>Grand total per month across all CPT codes.</summary>
    public Dictionary<string, CptBreakdownCell> CptBreakdownGrandByMonth { get; set; } = [];

    /// <summary>Grand total units across all CPT codes.</summary>
    public decimal CptBreakdownGrandTotalUnits { get; set; }

    /// <summary>Grand total billed charges across all CPT codes.</summary>
    public decimal CptBreakdownGrandTotalCharges { get; set; }

    /// <summary>
    /// Column header for the CPT Breakdown units column.
    /// Defaults to <c>"No. of Claims"</c>. Set to <c>"Billed Units"</c> for Certus,
    /// where the column represents <c>BilledUnits</c> from <c>Cert_CPTBreakdown</c>.
    /// </summary>
    public string CptUnitsLabel { get; init; } = "No. of Claims";

    /// <summary>Error message when the DB query fails or is unavailable.</summary>
    public string? ErrorMessage { get; init; }

    /// <summary>The most recent WeekFolder from LineClaimFileLogs (e.g. "04.20.2026 - 04.26.2026").</summary>
    public string? ReportWeekFolder { get; init; }

    /// <summary>The most recent RunId from LineClaimFileLogs.</summary>
    public string? ReportRunId { get; init; }

    /// <summary>The most recent RunId from LIMSMaster, shown alongside the LineClaimFileLogs RunId.</summary>
    public string? LimsRunId { get; init; }

    /// <summary>When the latest claim/line file was inserted (LineClaimFileLogs.InsertedDateTime), if available.</summary>
    public DateTime? ReportInsertedDateTime { get; init; }

    public bool HasFilters => FilterPayerNames.Count > 0
        || FilterPanelNames.Count > 0
        || FilterPayerNamesExclude
        || FilterPanelNamesExclude
        || !string.IsNullOrWhiteSpace(FilterFirstBillFrom)
        || !string.IsNullOrWhiteSpace(FilterFirstBillTo)
        || !string.IsNullOrWhiteSpace(FilterDosFrom)
        || !string.IsNullOrWhiteSpace(FilterDosTo)
        || !string.IsNullOrWhiteSpace(FilterFirstBilledFrom)
        || !string.IsNullOrWhiteSpace(FilterFirstBilledTo);
}

/// <summary>One panel's row in the Monthly Claim Volume table.</summary>
public sealed class ProductionPanelRow
{
    public string PanelName { get; init; } = string.Empty;

    /// <summary>Per-month data keyed by "yyyy-MM".</summary>
    public Dictionary<string, ProductionMonthCell> ByMonth { get; init; } = [];

    /// <summary>Per-year totals keyed by year.</summary>
    public Dictionary<int, ProductionYearTotal> ByYear { get; init; } = [];

    /// <summary>Grand total claim count for this panel.</summary>
    public int TotalClaims { get; init; }

    /// <summary>Grand total billed charges for this panel.</summary>
    public decimal TotalCharges { get; init; }

    /// <summary>Top 3 payers for this panel by unique claim count.</summary>
    public List<ProductionPayerDrillDown> TopPayers { get; init; } = [];
}

/// <summary>A single month cell in the pivot (claim count + billed charges).</summary>
public sealed record ProductionMonthCell(int ClaimCount, decimal BilledCharges);

/// <summary>Year-level totals (sum across months in that year).</summary>
public sealed record ProductionYearTotal(int ClaimCount, decimal BilledCharges);

/// <summary>Top-payer drill-down sub-row under a panel row.</summary>
public sealed class ProductionPayerDrillDown
{
    public string PayerName { get; init; } = string.Empty;

    /// <summary>Per-month data keyed by "yyyy-MM".</summary>
    public Dictionary<string, ProductionMonthCell> ByMonth { get; init; } = [];

    /// <summary>Per-year totals keyed by year.</summary>
    public Dictionary<int, ProductionYearTotal> ByYear { get; init; } = [];

    /// <summary>Grand total claim count for this payer under the panel.</summary>
    public int TotalClaims { get; init; }

    /// <summary>Grand total billed charges for this payer under the panel.</summary>
    public decimal TotalCharges { get; init; }
}

// ?? Weekly Claim Volume models ???????????????????????????????????????????

/// <summary>Describes one week column in the Weekly Claim Volume table.</summary>
public sealed record WeekColumn(string Key, DateOnly WeekStart, DateOnly WeekEnd);

/// <summary>One panel's row in the Weekly Claim Volume table.</summary>
public sealed class WeeklyPanelRow
{
    public string PanelName { get; init; } = string.Empty;

    /// <summary>Per-week data keyed by week key (e.g. "2025-W26").</summary>
    public Dictionary<string, ProductionMonthCell> ByWeek { get; init; } = [];

    /// <summary>Grand total claim count for this panel across all weeks.</summary>
    public int TotalClaims { get; init; }

    /// <summary>Grand total billed charges for this panel across all weeks.</summary>
    public decimal TotalCharges { get; init; }

    /// <summary>Top 3 payers for this panel by unique claim count.</summary>
    public List<WeeklyPayerDrillDown> TopPayers { get; init; } = [];
}

/// <summary>Top-payer drill-down sub-row under a weekly panel row.</summary>
public sealed class WeeklyPayerDrillDown
{
    public string PayerName { get; init; } = string.Empty;

    /// <summary>Per-week data keyed by week key.</summary>
    public Dictionary<string, ProductionMonthCell> ByWeek { get; init; } = [];

    /// <summary>Grand total claim count for this payer under the panel.</summary>
    public int TotalClaims { get; init; }

    /// <summary>Grand total billed charges for this payer under the panel.</summary>
    public decimal TotalCharges { get; init; }
}

// ?? Coding ????????????????????????????????????????????????????????????

public sealed class CodingPanelRow
{
    public string PanelName { get; init; } = string.Empty;

    /// <summary>Claim count for this panel (unique ClaimID).</summary>
    public int ClaimCount { get; init; }

    /// <summary>Total billed charges for this panel.</summary>
    public decimal TotalCharges { get; init; }

    /// <summary>CPT Code drill-down rows for this panel.</summary>
    public List<CodingCptDrillDown> CptRows { get; init; } = [];
}

public sealed class CodingCptDrillDown
{
    public string CptCodeUnitsModifier { get; init; } = string.Empty;

    /// <summary>Claim count for this CPT code under the panel.</summary>
    public int ClaimCount { get; init; }

    /// <summary>Total billed charges for this CPT code under the panel.</summary>
    public decimal TotalCharges { get; init; }
}

// ?? Payer Breakdown models ?????????????????????????????????????????????????

public sealed class PayerBreakdownRow
{
    public string PayerName { get; init; } = string.Empty;

    /// <summary>Per-month claim count keyed by "yyyy-MM" (ChargeEnteredDate).</summary>
    public Dictionary<string, int> ByMonth { get; init; } = [];

    /// <summary>Per-year totals keyed by year.</summary>
    public Dictionary<int, int> ByYear { get; init; } = [];

    /// <summary>Grand total claim count for this payer.</summary>
    public int GrandTotal { get; init; }

    /// <summary>Per-month SUM(ChargeAmount) keyed by "yyyy-MM" (ChargeEnteredDate).</summary>
    public Dictionary<string, decimal> ByMonthCharges { get; init; } = [];

    /// <summary>Per-year SUM(ChargeAmount) keyed by year.</summary>
    public Dictionary<int, decimal> ByYearCharges { get; init; } = [];

    /// <summary>Grand total ChargeAmount for this payer.</summary>
    public decimal GrandTotalCharges { get; init; }

    /// <summary>
    /// Optional child rows for grouped displays, e.g. NorthWest Panel Breakdown
    /// where the parent row is a panel and the children are payer rows.
    /// </summary>
    public List<PayerBreakdownRow> ChildRows { get; init; } = [];
}

// ?? Payer X Panel models ???????????????????????????????????????????????????

public sealed class PayerPanelRow
{
    public string PayerName { get; init; } = string.Empty;

    /// <summary>Per-panel cell keyed by PanelName (claims + charges).</summary>
    public Dictionary<string, ProductionMonthCell> ByPanel { get; init; } = [];

    /// <summary>Grand total claim count for this payer across all panels.</summary>
    public int GrandTotalClaims { get; init; }

    /// <summary>Grand total billed charges for this payer across all panels.</summary>
    public decimal GrandTotalCharges { get; init; }
}

// ?? Unbilled X Aging ?????????????????????????????????????????????

public static class AgingBuckets
{
    public const string Current = "Current";
    public const string Over30  = "30+";
    public const string Over60  = "60+";
    public const string Over90  = "90+";
    public const string Over120 = "120+";

    /// <summary>Ordered list of all bucket keys.</summary>
    public static readonly IReadOnlyList<string> All = [Current, Over30, Over60, Over90, Over120];
}

public sealed class UnbilledAgingRow
{
    public string PanelName { get; init; } = string.Empty;

    /// <summary>Per-bucket cell keyed by bucket key (claims + charges).</summary>
    public Dictionary<string, ProductionMonthCell> ByBucket { get; init; } = [];

    /// <summary>Grand total claim count for this panel across all buckets.</summary>
    public int GrandTotalClaims { get; init; }

    /// <summary>Grand total billed charges for this panel across all buckets.</summary>
    public decimal GrandTotalCharges { get; init; }
}

// ?? CPT Breakdown ???????????????????????????????????????????????

/// <summary>Per-cell metrics for the CPT Breakdown table (line-level).</summary>
/// <param name="Units">Sum of <c>Units</c> in this group (or distinct CPTCode count under Rule3).</param>
/// <param name="BilledCharges">Sum of <c>ChargeAmount</c> in this group.</param>
/// <param name="ClaimCount">Number of line rows in this group (used for the "No. of Claims" column).</param>
 public sealed record CptBreakdownCell(decimal Units, decimal BilledCharges, int ClaimCount = 0);

public sealed class CptBreakdownRow
{
    public string CptCode { get; init; } = string.Empty;

    /// <summary>Per-month data keyed by "yyyy-MM".</summary>
    public Dictionary<string, CptBreakdownCell> ByMonth { get; init; } = [];

    /// <summary>Per-year totals keyed by year.</summary>
    public Dictionary<int, CptBreakdownCell> ByYear { get; init; } = [];

    /// <summary>Grand total units for this CPT code.</summary>
    public decimal GrandTotalUnits { get; init; }

    /// <summary>Grand total billed charges for this CPT code.</summary>
    public decimal GrandTotalCharges { get; init; }

    /// <summary>Grand total claim (line) count for this CPT code.</summary>
    public int GrandTotalClaims { get; init; }

    /// <summary>
    /// Optional child rows for grouped displays, e.g. NorthWest CPT Breakdown
    /// where the parent row is a source and the children are CPT rows.
    /// </summary>
    public List<CptBreakdownRow> ChildRows { get; init; } = [];
}
