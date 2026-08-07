namespace LabMetricsDashboard.Models;

// =====================================================================
// Executive Summary – LIS Breakdown analytical drill-through view model
//
// Backs the "Total No. of Samples" (RowCode L_0) and
// "Billable Samples - Resulted" (RowCode L_A) drill pages, reachable from
// the Grand Total / Year Total cells of the LIS Breakdown section.
//
// The layout mirrors the attached logic workbook
// (ExecutiveSummary_DrillThrough_Logics&Formulas):
//   • Summary band  – latest-month count, MoM change, last-6-month average
//                     (WeekRange end month + 5 prior, full-month),
//                     current-vs-average, and the first-N-days volume
//                     comparison (latest vs previous month).
//   • Nine-day band – first-9-days volume for each of the trailing months.
//   • Top panels    – top panels by sample volume with share % and a
//                     first-9-days MoM comparison.
//   • Result rate   – (Billable metric only) resulted / received rate per month.
//
// Source: LIMSMaster (the "LIS Breakdown" source), grouped on DateOfCollection.
// =====================================================================

/// <summary>Summary band (single row) for the LIS drill page.</summary>
public sealed class LisDrillSummary
{
    /// <summary>Latest collection date present in the data — the report cutoff.</summary>
    public DateTime? CutoffDate { get; set; }

    /// <summary>Label of the latest month present (e.g. "Jul 2026").</summary>
    public string LatestMonthLabel { get; set; } = string.Empty;

    /// <summary>Sample / billable count for the latest month.</summary>
    public long LatestCount { get; set; }

    /// <summary>Label of the previous month (e.g. "Jun 2026").</summary>
    public string PrevMonthLabel { get; set; } = string.Empty;

    /// <summary>Sample / billable count for the previous month.</summary>
    public long PrevCount { get; set; }

    /// <summary>(Latest − Prev) / Prev × 100.</summary>
    public decimal? MoMChangePct { get; set; }

    /// <summary>Average of the trailing 6 months (WeekRange end month + 5 prior, full-month).</summary>
    public decimal? Avg6 { get; set; }

    /// <summary>(Latest − Avg6) / Avg6 × 100.</summary>
    public decimal? CurrVsAvgPct { get; set; }

    /// <summary>Label for the latest-month 9-day window (e.g. "Jul 2026 (1–9)").</summary>
    public string Latest9DayLabel { get; set; } = string.Empty;

    /// <summary>First-9-days volume for the latest month.</summary>
    public long Latest9DayCount { get; set; }

    /// <summary>Label for the previous-month 9-day window.</summary>
    public string Prev9DayLabel { get; set; } = string.Empty;

    /// <summary>First-9-days volume for the previous month.</summary>
    public long Prev9DayCount { get; set; }

    /// <summary>(Latest9Day − Prev9Day) / Prev9Day × 100.</summary>
    public decimal? NineDayMoMPct { get; set; }
}

/// <summary>One month's full total for the trend chart.</summary>
public sealed class LisDrillMonthly
{
    public string MonthLabel { get; set; } = string.Empty;
    public string ShortLabel { get; set; } = string.Empty;
    public long   Total      { get; set; }
    public bool   IsPartial  { get; set; }
}

/// <summary>One clinic nested under a top panel (Avg 6 Months / MoM).</summary>
public sealed class LisDrillPanelClinic
{
    public string   Clinic      { get; set; } = string.Empty;
    public long     PeriodTotal { get; set; }
    public decimal  Avg6Months  { get; set; }
    public decimal  SharePct    { get; set; }
    public long     Prev9Day    { get; set; }
    public long     Latest9Day  { get; set; }
    public decimal? MoMDeltaPct { get; set; }
}

/// <summary>One panel row in the "Top Panels" band.</summary>
public sealed class LisDrillPanel
{
    public string   Panel       { get; set; } = string.Empty;
    public long     PeriodTotal { get; set; }
    /// <summary>Average of full-month monthly counts over WeekRange end month + 5 prior.</summary>
    public decimal  Avg6Months  { get; set; }
    public decimal  SharePct    { get; set; }
    public long     Prev9Day    { get; set; }
    public long     Latest9Day  { get; set; }
    public decimal? MoMDeltaPct { get; set; }

    /// <summary>Top clinics nested under this panel (empty when SP has no clinic set).</summary>
    public List<LisDrillPanelClinic> Clinics { get; set; } = [];
}

/// <summary>One month's resulted/received rate (Billable metric only).</summary>
public sealed class LisDrillResultRate
{
    public string   MonthLabel { get; set; } = string.Empty;
    public long     Resulted   { get; set; }
    public long     Received   { get; set; }
    public decimal? RatePct    { get; set; }
}

/// <summary>One ClientStatus/month cell for the Not-Resulted status breakdown.</summary>
public sealed class LisDrillStatusRow
{
    public string Status { get; set; } = string.Empty;
    public int    Year   { get; set; }
    public int    Month  { get; set; }
    public long   Count  { get; set; }
}

/// <summary>One month's first-9-days received volume ("Data for 9 days range").</summary>
public sealed class LisDrillNineDayRange
{
    public string MonthLabel { get; set; } = string.Empty;
    public string ShortLabel { get; set; } = string.Empty;
    public long   Received9  { get; set; }
}

/// <summary>One panel/month cell for the 9-day result-rate matrix.</summary>
public sealed class LisDrillRatePanel
{
    public string Panel     { get; set; } = string.Empty;
    public int    Year      { get; set; }
    public int    Month     { get; set; }
    public long   Resulted9 { get; set; }
    public long   Received9 { get; set; }
}

/// <summary>One panel-group child under a PMS Top-10 Insurance parent.</summary>
public sealed class LisDrillInsurerPanel
{
    public string   Panel  { get; set; } = string.Empty;
    public long     Claims { get; set; }
    public decimal? MoMPct { get; set; }
}

/// <summary>One payer row for the PMS Top-10 Insurance band (real ClaimLevelData).</summary>
public sealed class LisDrillInsurer
{
    public string   Payer  { get; set; } = string.Empty;
    public long     Claims { get; set; }
    public decimal? MoMPct { get; set; }

    /// <summary>Panel groups nested under this payer (empty when SP has no Set 9).</summary>
    public List<LisDrillInsurerPanel> Panels { get; set; } = [];
}

/// <summary>
/// One month of Fully Paid / Billed rate from the Executive Summary PMS grid.
/// </summary>
public sealed class LisDrillFullyPaidRateMonth
{
    public int Year { get; set; }
    public int Month { get; set; }
    public string MonthLabel { get; set; } = string.Empty;
    public string ShortLabel { get; set; } = string.Empty;
    public long FullyPaidCount { get; set; }
    public long BilledCount { get; set; }
    /// <summary>Null when billed is 0 or the month is incomplete/partial with no usable rate.</summary>
    public decimal? RatePct { get; set; }
    public bool IsPartial { get; set; }
}

/// <summary>Top-level view model for the LIS Breakdown analytical drill page.</summary>
public sealed class ExecSummaryLisDrillViewModel
{
    /// <summary>"Samples" (Total No. of Samples) or "Billable" (Billable Samples - Resulted).</summary>
    public string Metric { get; set; } = "Samples";

    public bool IsBillable =>
        Metric.Equals("Billable", StringComparison.OrdinalIgnoreCase);

    public bool IsNotResulted =>
        Metric.Equals("NotResulted", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// When drilling a specific ES / LIS / PMS row, the grid Description
    /// (or LisDrillRowDef.RowTitle). Drives page + panel section headings.
    /// </summary>
    public string? RowTitleOverride { get; set; }

    /// <summary>Optional description shown under the title (overrides the metric description).</summary>
    public string? DescriptionOverride { get; set; }

    /// <summary>
    /// Display title for the metric / row being drilled.
    /// Prefer <see cref="RowTitleOverride"/> so every Insight Drill row shows
    /// its own heading (not a hardcoded Billable/Samples label).
    /// </summary>
    public string MetricTitle =>
        !string.IsNullOrWhiteSpace(RowTitleOverride) ? RowTitleOverride! :
        IsBillable    ? "Billable Samples - Resulted" :
        IsNotResulted ? "Not Resulted" :
                        "Total No. of Samples";

    /// <summary>Alias for <see cref="MetricTitle"/> — the drilled row’s title.</summary>
    public string RowTitle => MetricTitle;

    /// <summary>Year scope: 0 = Grand Total (all years); otherwise the specific year total.</summary>
    public int Year { get; set; }

    public string ScopeLabel => Year == 0 ? "Grand Total" : Year.ToString();

    /// <summary>The value of the cell that was clicked on the Executive Summary grid.</summary>
    public decimal? SelectedValue { get; set; }

    public string SelectedValueFormatted =>
        SelectedValue is not { } v ? string.Empty :
        IsCashDrill ? v.ToString("C0", System.Globalization.CultureInfo.GetCultureInfo("en-US")) :
        ((long)v).ToString("N0");

    /// <summary>URL back to the Executive Summary index (preserving filters).</summary>
    public string BackUrl { get; set; } = string.Empty;

    /// <summary>Friendly name of the source table.</summary>
    public string SourceLabel { get; set; } = "LIMSMaster";

    /// <summary>
    /// True when this drill is a Cash Breakdown dollar SUM
    /// (usp_GetExecutiveSummaryDetail_CashDrill_Core).
    /// </summary>
    public bool IsCashDrill { get; set; }

    /// <summary>Run/analysis-range banner (Billed Week Range, RunID, Inserted Date).</summary>
    public AnalysisRangeInfo? AnalysisRange { get; set; }

    /// <summary>LIMSMaster RunId, shown alongside the ClaimLevelData RunId.</summary>
    public string? LimsRunId { get; set; }

    public string? ErrorMessage { get; set; }

    public LisDrillSummary            Summary         { get; set; } = new();
    public List<LisDrillMonthly>      Monthly         { get; set; } = [];
    public List<LisDrillPanel>        Panels          { get; set; } = [];
    public List<LisDrillResultRate>   ResultRates     { get; set; } = [];
    public List<LisDrillStatusRow>    StatusBreakdown { get; set; } = [];
    public List<LisDrillNineDayRange> NineDayRange    { get; set; } = [];
    public List<LisDrillRatePanel>    RatePanels      { get; set; } = [];
    public List<LisDrillInsurer>      Insurers        { get; set; } = [];

    /// <summary>
    /// Companion "Billed Mismatches" monthly cells from the Executive Summary
    /// PMS grid (same source as Index), shown under Total Billed (Claims) trend.
    /// </summary>
    public string? SummaryMismatchTitle { get; set; }

    /// <summary>Monthly mismatch counts keyed like <see cref="StatusBreakdown"/>.</summary>
    public List<LisDrillStatusRow> SummaryMismatchMonths { get; set; } = [];

    /// <summary>Year/grand total for the mismatch row from the ES summary.</summary>
    public long SummaryMismatchTotal { get; set; }

    /// <summary>
    /// True when this drill is the PMS Fully Paid row (set from LisDrillRowDef).
    /// Drives companion rate band and trend "Real — from summary" badge.
    /// </summary>
    public bool IsPmsFullyPaidDrill { get; set; }

    /// <summary>
    /// True when this drill is a PMS Billed-Mismatch formula row (PMS − LIS counts),
    /// not a ClaimStatus claim-level filter.
    /// </summary>
    public bool IsPmsMismatchDrill { get; set; }

    /// <summary>
    /// Companion Fully Paid / Billed rate months from the Executive Summary
    /// PMS grid (same source as Index / pmsgrid).
    /// </summary>
    public List<LisDrillFullyPaidRateMonth> FullyPaidRateMonths { get; set; } = [];

    /// <summary>Average of non-partial Fully Paid / Billed rates (same window as trend avg).</summary>
    public decimal? FullyPaidRateAvg { get; set; }

    /// <summary>Label for the rate avg line, e.g. "Jan–Jun".</summary>
    public string? FullyPaidRateAvgRange { get; set; }

    /// <summary>
    /// Comparable partial-month window in days = day-of-month from the
    /// Billed Week Range end date (e.g. 25 when range ends 06/25). Drives the
    /// "N-Day Range &amp; Result Rate" band. Defaults to 9 when unknown.
    /// </summary>
    public int ComparableDayWindow { get; set; } = 9;

    /// <summary>True when this page was built from ClaimLevelData (PMS drill).</summary>
    public bool IsPmsDrill =>
        string.Equals(SourceLabel, "ClaimLevelData", StringComparison.OrdinalIgnoreCase)
        && !IsCashDrill;

    /// <summary>
    /// Chart theme CSS class: LIS → green, PMS → violet, Cash → brown.
    /// </summary>
    public string ChartThemeClass =>
        IsCashDrill ? "idt-cash" :
        IsPmsDrill || IsFullyPaidInsight || IsMismatchFormulaInsight ? "idt-pms" :
        "idt-lis";

    /// <summary>True when the drilled row heading is an Insurance Balance parent.</summary>
    public bool IsInsuranceBalanceInsight
    {
        get
        {
            var t = MetricTitle ?? "";
            return t.Contains("Insurance Balance", StringComparison.OrdinalIgnoreCase)
                   && !t.Contains(" - ", StringComparison.Ordinal);
        }
    }

    /// <summary>
    /// Parent with ≥2 subcategory series (Sec1/2/3 or ES child rows such as
    /// Other Samples → Client Bill / Self Pay) — show a separate stacked bar chart.
    /// Monthly Trend (MoM) stays a normal single-series chart.
    /// </summary>
    public bool UseStackedTrend
    {
        get
        {
            if (IsFullyPaidInsight || IsMismatchFormulaInsight) return false;

            var statuses = StatusBreakdown
                .Select(s => s.Status?.Trim() ?? "")
                .Where(s => s.Length > 0)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
            if (statuses.Count < 2) return false;

            // Child drills use "Parent - Child" titles — don't stack siblings.
            var t = (RowTitleOverride ?? MetricTitle ?? "").Trim();
            var sep = t.LastIndexOf(" - ", StringComparison.Ordinal);
            if (sep >= 0)
            {
                var leaf = t[(sep + 3)..].Trim();
                if (statuses.Any(s => s.Equals(leaf, StringComparison.OrdinalIgnoreCase)))
                    return false;
            }

            return true;
        }
    }

    /// <summary>
    /// Fully Paid Insight path — title-based fallback so Beech Tree
    /// "Fully Paid - Insurance Pay" / em-dash variants still get rate + accordion
    /// even if <see cref="IsPmsFullyPaidDrill"/> was not set on the controller.
    /// </summary>
    public bool IsFullyPaidInsight
    {
        get
        {
            if (IsPmsFullyPaidDrill || HasFullyPaidRate) return true;
            if (!IsPmsDrill && !string.Equals(SourceLabel, "ClaimLevelData", StringComparison.OrdinalIgnoreCase))
                return false;
            if (IsCashDrill) return false;
            var t = MetricTitle?.Trim() ?? "";
            if (t.Contains('$')) return false;
            return t.Contains("Fully Paid", StringComparison.OrdinalIgnoreCase);
        }
    }

    /// <summary>
    /// Mismatch formula Insight — flag or title fallback ("Mismatch" / "Billed vs")
    /// so the claim-filter empty banner never wins when the ES cell is a period delta.
    /// </summary>
    public bool IsMismatchFormulaInsight
    {
        get
        {
            if (IsPmsMismatchDrill) return true;
            return LooksLikeMismatchTitle(RowTitleOverride)
                || LooksLikeMismatchTitle(MetricTitle)
                || LooksLikeMismatchTitle(DescriptionOverride);
        }
    }

    /// <summary>True when <paramref name="title"/> looks like a PMS−LIS mismatch formula row.</summary>
    public static bool LooksLikeMismatchTitle(string? title)
    {
        if (string.IsNullOrWhiteSpace(title)) return false;
        var t = title.Trim();
        if (t.Contains("Mismatch", StringComparison.OrdinalIgnoreCase)) return true;
        if (t.Contains("Billed vs", StringComparison.OrdinalIgnoreCase)) return true;
        if (t.Contains("Billed versus", StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    /// <summary>True when the Billed-vs-Mismatch companion band has summary data.</summary>
    public bool HasSummaryMismatch =>
        SummaryMismatchMonths.Count > 0 || SummaryMismatchTotal != 0;

    /// <summary>True when Fully Paid / Billed rate companion has summary months.</summary>
    public bool HasFullyPaidRate => FullyPaidRateMonths.Count > 0;

    /// <summary>
    /// Show the Monthly Trend "Real — from summary" badge (Total Billed companion,
    /// Fully Paid PMS drill, or mismatch formula backfill from ES).
    /// </summary>
    public bool ShowTrendFromSummaryBadge =>
        HasSummaryMismatch || IsFullyPaidInsight || IsMismatchFormulaInsight;

    /// <summary>
    /// True when KPI / trend / companion bands have content. Mismatch formula rows
    /// also count as having data when the ES cell (<see cref="SelectedValue"/>) is set —
    /// claim-level Top 10 may still be empty.
    /// </summary>
    public bool HasData =>
        Summary.LatestCount != 0 || Panels.Count > 0 || StatusBreakdown.Count > 0
        || Insurers.Count > 0 || HasSummaryMismatch || HasFullyPaidRate
        || Monthly.Count > 0 || NineDayRange.Count > 0
        || (IsMismatchFormulaInsight && SelectedValue is { } sv && sv != 0);
}
