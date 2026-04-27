namespace LabMetricsDashboard.Models;

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
    public List<string> Months { get; init; } = [];

    /// <summary>Ordered list of distinct years found in the data.</summary>
    public List<int> Years { get; init; } = [];

    /// <summary>Panel rows sorted by grand-total claim count descending.</summary>
    public List<ProductionPanelRow> PanelRows { get; init; } = [];

    /// <summary>Grand total across all panels for each month.</summary>
    public Dictionary<string, ProductionMonthCell> GrandTotalByMonth { get; init; } = [];

    /// <summary>Grand total claim count across all panels and months.</summary>
    public int GrandTotalClaims { get; init; }

    /// <summary>Grand total billed charges across all panels and months.</summary>
    public decimal GrandTotalCharges { get; init; }

    // ?? Weekly Claim Volume ??????????????????????????????????????

    /// <summary>Ordered list of week column descriptors for the last 4 weeks.</summary>
    public List<WeekColumn> WeekColumns { get; init; } = [];

    /// <summary>Panel rows for the Weekly Claim Volume table, sorted by grand total descending.</summary>
    public List<WeeklyPanelRow> WeeklyPanelRows { get; init; } = [];

    /// <summary>Grand total across all panels for each week key.</summary>
    public Dictionary<string, ProductionMonthCell> WeeklyGrandTotalByWeek { get; init; } = [];

    /// <summary>Grand total claim count across all panels and weeks.</summary>
    public int WeeklyGrandTotalClaims { get; init; }

    /// <summary>Grand total billed charges across all panels and weeks.</summary>
    public decimal WeeklyGrandTotalCharges { get; init; }

    // ?? Coding ???????????????????????????????????????????????????

    /// <summary>Panel rows for the Coding table (where FirstBilledDate is blank), sorted by grand total descending.</summary>
    public List<CodingPanelRow> CodingPanelRows { get; init; } = [];

    /// <summary>Grand total claim count across all panels in the Coding table.</summary>
    public int CodingGrandTotalClaims { get; init; }

    /// <summary>Grand total billed charges across all panels in the Coding table.</summary>
    public decimal CodingGrandTotalCharges { get; init; }

    // ?? Payer Breakdown ???????????????????????????????????????????

    /// <summary>Ordered list of year/month column keys for Payer Breakdown (ChargeEnteredDate).</summary>
    public List<string> PayerBreakdownMonths { get; init; } = [];

    /// <summary>Ordered list of distinct years in the Payer Breakdown data.</summary>
    public List<int> PayerBreakdownYears { get; init; } = [];

    /// <summary>Payer rows for the Payer Breakdown table, sorted by grand total descending.</summary>
    public List<PayerBreakdownRow> PayerBreakdownRows { get; init; } = [];

    /// <summary>Grand total per month across all payers.</summary>
    public Dictionary<string, int> PayerBreakdownGrandByMonth { get; init; } = [];

    /// <summary>Grand total claim count across all payers.</summary>
    public int PayerBreakdownGrandTotal { get; init; }

    // ?? Payer X Panel ?????????????????????????????????????????????

    /// <summary>Ordered list of distinct panel names used as column headers.</summary>
    public List<string> PayerPanelColumns { get; init; } = [];

    /// <summary>Payer rows for the Payer X Panel table, sorted by grand total descending.</summary>
    public List<PayerPanelRow> PayerPanelRows { get; init; } = [];

    /// <summary>Grand total per panel across all payers (claims).</summary>
    public Dictionary<string, ProductionMonthCell> PayerPanelGrandByPanel { get; init; } = [];

    /// <summary>Grand total claim count across all payers and panels.</summary>
    public int PayerPanelGrandTotalClaims { get; init; }

    /// <summary>Grand total billed charges across all payers and panels.</summary>
    public decimal PayerPanelGrandTotalCharges { get; init; }

    // ?? Unbilled X Aging ?????????????????????????????????????????

    /// <summary>Panel rows for the Unbilled X Aging table, sorted by grand total descending.</summary>
    public List<UnbilledAgingRow> UnbilledAgingRows { get; init; } = [];

    /// <summary>Grand total per aging bucket across all panels.</summary>
    public Dictionary<string, ProductionMonthCell> UnbilledAgingGrandByBucket { get; init; } = [];

    /// <summary>Grand total claim count across all panels and buckets.</summary>
    public int UnbilledAgingGrandTotalClaims { get; init; }

    /// <summary>Grand total billed charges across all panels and buckets.</summary>
    public decimal UnbilledAgingGrandTotalCharges { get; init; }

    // ?? CPT Breakdown ????????????????????????????????????????????

    /// <summary>Ordered list of year/month column keys for CPT Breakdown (FirstBilledDate).</summary>
    public List<string> CptBreakdownMonths { get; init; } = [];

    /// <summary>Ordered list of distinct years in the CPT Breakdown data.</summary>
    public List<int> CptBreakdownYears { get; init; } = [];

    /// <summary>CPT rows for the CPT Breakdown table, sorted by grand total descending.</summary>
    public List<CptBreakdownRow> CptBreakdownRows { get; init; } = [];

    /// <summary>Grand total per month across all CPT codes.</summary>
    public Dictionary<string, CptBreakdownCell> CptBreakdownGrandByMonth { get; init; } = [];

    /// <summary>Grand total units across all CPT codes.</summary>
    public decimal CptBreakdownGrandTotalUnits { get; init; }

    /// <summary>Grand total billed charges across all CPT codes.</summary>
    public decimal CptBreakdownGrandTotalCharges { get; init; }

    /// <summary>Error message when the DB query fails or is unavailable.</summary>
    public string? ErrorMessage { get; init; }

    public bool HasFilters => FilterPayerNames.Count > 0
        || FilterPanelNames.Count > 0
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

public sealed record CptBreakdownCell(decimal Units, decimal BilledCharges);

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
}
