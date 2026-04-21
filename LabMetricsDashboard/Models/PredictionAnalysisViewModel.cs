namespace LabMetricsDashboard.Models;

public sealed class PredictionAnalysisViewModel
{
    public List<string> AvailableLabs { get; init; } = [];
    public string SelectedLab { get; init; } = string.Empty;
    public string? ResolvedFilePath { get; init; }
    public bool FileFound => ResolvedFilePath is not null;

    /// <summary>False when the selected lab has DBEnabled=false — shows a "not available" banner.</summary>
    public bool PredictionAvailable { get; init; } = true;

    /// <summary>Error message to display when feature is disabled or unavailable.</summary>
    public string? ErrorMessage { get; init; }

    /// <summary>Monday of the current week — the global filter cutoff date.</summary>
    public DateOnly CurrentWeekStartDate { get; init; }

    // Active filters
    public string? FilterPayerName { get; init; }
    public string? FilterPayerType { get; init; }
    public string? FilterPanelName { get; init; }
    public string? FilterFinalCoverageStatus { get; init; }
    public string? FilterPayability { get; init; }
    public string? FilterCPTCode { get; init; }

    // Filter option lists
    public List<string> PayerNames { get; init; } = [];
    public List<string> PayerTypes { get; init; } = [];
    public List<string> PanelNames { get; init; } = [];
    public List<string> FinalCoverageStatuses { get; init; } = [];
    public List<string> PayabilityOptions { get; init; } = [];
    public List<string> CPTCodes { get; init; } = [];

    // ?? Prediction buckets (primary metric table) ?????????????????????????
    public IReadOnlyList<PredictionBucketRow> Buckets { get; init; } = [];

    // ?? Breakdown charts ??????????????????????????????????????????????????
    public IReadOnlyDictionary<string, int> PayabilityBreakdown { get; init; } = new Dictionary<string, int>();
    public IReadOnlyDictionary<string, int> FinalCoverageStatusBreakdown { get; init; } = new Dictionary<string, int>();
    public IReadOnlyDictionary<string, int> ForecastingPayabilityBreakdown { get; init; } = new Dictionary<string, int>();
    public IReadOnlyDictionary<string, int> ICDComplianceBreakdown { get; init; } = new Dictionary<string, int>();
    public IReadOnlyDictionary<string, int> PayerTypeBreakdown { get; init; } = new Dictionary<string, int>();

    // ?? Insight tables ???????????????????????????????????????????????????? 
    public IReadOnlyList<PredictionPayerRow> TopPayerInsights { get; init; } = [];
    public IReadOnlyList<PredictionCptRow> TopCptInsights { get; init; } = [];
    public IReadOnlyList<PredictionPanelRow> TopPanelInsights { get; init; } = [];

    // ?? Expected payment by month ????????????????????????????????????????? 
    public IReadOnlyList<(string Month, decimal ExpectedPayment)> ExpectedPaymentByMonth { get; init; } = [];

    // ?? Paged detail records ?????????????????????????????????????????????? 
    public List<PredictionRecord> Records { get; init; } = [];
    public PageInfo Paging { get; init; } = new(1, 50, 0, 0);

    // ?? Prediction Analysis Summary metrics (3 sections) ?????????????????
    public PredictionSummaryMetrics SummaryMetrics { get; init; } = new();

    // ?? Last 4 Weeks Forecasting – Median & Mode summaries ??????????????? 
    public WeeklyForecastSummary MedianWeeklySummary { get; init; } = new();
    public WeeklyForecastSummary ModeWeeklySummary { get; init; } = new();

    // ?? Predicted to Pay vs Denial Breakdown ??????????????????????
    public DenialBreakdown DenialBreakdown { get; init; } = new();

    // ?? Predicted to Pay vs No Response Breakdown ?????????????????
    public NoResponseBreakdown NoResponseBreakdown { get; init; } = new();

    // ?? AI-generated prediction insight (optional) ????????????????
    public PredictionInsight? Insight { get; init; }
}

/// <summary>One row in the Prediction Analysis bucket summary table.</summary>
public sealed record PredictionBucketRow(
    string BucketName,
    int ClaimCount,
    decimal PredictedAllowed,
    decimal PredictedInsurance,
    decimal? ActualAllowed,
    decimal? ActualInsurance,
    decimal? Variance);

/// <summary>
/// Holds the three metric sections from the Prediction Analysis Summary sheet:
/// Section 1 – Metrics (buckets with formula descriptions),
/// Section 2 – Ratios,
/// Section 3 – Prediction Accuracy.
/// </summary>
public sealed class PredictionSummaryMetrics
{
    // Section 2 – Ratios
    public decimal? PaymentRatioClaim      { get; init; }
    public decimal? PaymentRatioAllowed    { get; init; }
    public decimal? PaymentRatioInsurance  { get; init; }

    public decimal? NonPaymentRateClaim     { get; init; }
    public decimal? NonPaymentRateAllowed   { get; init; }
    public decimal? NonPaymentRateInsurance { get; init; }

    public decimal? DeniedPctClaim      { get; init; }
    public decimal? DeniedPctAllowed    { get; init; }
    public decimal? DeniedPctInsurance  { get; init; }

    public decimal? NoResponsePctClaim      { get; init; }
    public decimal? NoResponsePctAllowed    { get; init; }
    public decimal? NoResponsePctInsurance  { get; init; }

    public decimal? AdjustedPctClaim      { get; init; }
    public decimal? AdjustedPctAllowed    { get; init; }
    public decimal? AdjustedPctInsurance  { get; init; }

    // Section 3 – Prediction Accuracy
    public decimal? PredVsActualRatioClaim     { get; init; }
    public decimal? PredVsActualAllowedAmount  { get; init; }
    public decimal? PredVsActualInsPayment     { get; init; }
}

/// <summary>Payer-level prediction validation row (Claim Level).</summary>
public sealed record PredictionPayerRow(
    string  PayerName,
    string  PayerType,
    int     TotalClaims,
    int     Paid,
    int     Denied,
    int     NoResponse,
    int     Adjusted,
    int     Unpaid,
    decimal? PaymentRatePct,
    decimal PredictedAllowed,
    decimal PredictedInsurance,
    decimal ActualAllowed,
    decimal ActualInsurance,
    decimal Variance);

/// <summary>CPT-level prediction insight row.</summary>
public sealed record PredictionCptRow(
    string CPTCode,
    int LineItems,
    decimal BilledAmount,
    decimal PredictedAllowed,
    decimal PredictedInsurance);

/// <summary>Panel-level prediction validation row (Claim Level).</summary>
public sealed record PredictionPanelRow(
    string  PanelName,
    int     TotalClaims,
    int     Paid,
    int     Denied,
    int     NoResponse,
    int     Adjusted,
    int     Unpaid,
    decimal? PaymentRatePct,
    decimal PredictedAllowed,
    decimal PredictedInsurance,
    decimal ActualAllowed,
    decimal ActualInsurance,
    decimal Variance);

// ?? Predicted to Pay vs Denial Breakdown model ??????????????????????

/// <summary>
/// Month-level amounts (claim count + predicted allowed + predicted insurance)
/// used in the denial breakdown pivot columns.
/// </summary>
public sealed record DenialMonthAmount(
    int    ClaimCount,
    decimal PredictedAllowed,
    decimal PredictedInsurance);

/// <summary>
/// One denial-code sub-row for a payer inside the denial breakdown table.
/// </summary>
public sealed record DenialCodeRow(
    string DenialCode,
    string DenialDescription,
    int    TotalClaims,
    decimal TotalPredictedAllowed,
    decimal TotalPredictedInsurance,
    IReadOnlyDictionary<string, DenialMonthAmount> ByMonth);

/// <summary>
/// One payer header-row (top-1 by total claim count) with its top-5 denial sub-rows.
/// </summary>
public sealed record DenialPayerRow(
    string PayerName,
    int    TotalClaims,
    decimal TotalPredictedAllowed,
    decimal TotalPredictedInsurance,
    IReadOnlyDictionary<string, DenialMonthAmount> ByMonth,
    IReadOnlyList<DenialCodeRow> TopDenialCodes);

/// <summary>
/// Full denial breakdown table: ordered months + payer rows + grand-total footer.
/// </summary>
public sealed class DenialBreakdown
{
    public IReadOnlyList<string>          Months     { get; init; } = [];
    public IReadOnlyList<DenialPayerRow>  PayerRows  { get; init; } = [];

    // Grand-total footer row
    public int     TotalClaims              { get; init; }
    public decimal TotalPredictedAllowed    { get; init; }
    public decimal TotalPredictedInsurance  { get; init; }
    public IReadOnlyDictionary<string, DenialMonthAmount> TotalByMonth { get; init; }
        = new Dictionary<string, DenialMonthAmount>();
}

// ?? Predicted to Pay vs No Response Breakdown model ??????????????????

/// <summary>Age-bucket columns used in the No Response breakdown.</summary>
public static class AgeBuckets
{
    public const string B0_30   = "0-30";
    public const string B31_60  = "31-60";
    public const string B61_90  = "61-90";
    public const string B91_120 = "91-120";
    public const string B120P   = ">120";

    public static readonly IReadOnlyList<string> All =
        [B0_30, B31_60, B61_90, B91_120, B120P];

    /// <summary>Assigns a record to its age bucket using FirstBilledDate days-to-today.</summary>
    public static string Classify(int ageDays) => ageDays switch
    {
        <= 30  => B0_30,
        <= 60  => B31_60,
        <= 90  => B61_90,
        <= 120 => B91_120,
        _      => B120P
    };
}

/// <summary>Counts + amounts for one age bucket cell.</summary>
public sealed record AgeBucketAmount(
    int     ClaimCount,
    decimal PredictedAllowed,
    decimal PredictedInsurance);

/// <summary>One payer row in the No Response breakdown, sorted by total claim count.</summary>
public sealed record NoResponsePayerRow(
    string  PayerName,
    int     TotalClaims,
    decimal TotalPredictedAllowed,
    decimal TotalPredictedInsurance,
    IReadOnlyDictionary<string, AgeBucketAmount> ByBucket,
    /// <summary>Age bucket with the highest claim count — drives Priority Level.</summary>
    string  PriorityBucket);

/// <summary>Full No Response breakdown table.</summary>
public sealed class NoResponseBreakdown
{
    public IReadOnlyList<NoResponsePayerRow> PayerRows { get; init; } = [];

    public int     TotalClaims             { get; init; }
    public decimal TotalPredictedAllowed   { get; init; }
    public decimal TotalPredictedInsurance { get; init; }
    public IReadOnlyDictionary<string, AgeBucketAmount> TotalByBucket { get; init; }
        = new Dictionary<string, AgeBucketAmount>();
}

/// <summary>
/// Weekly forecasting breakdown for Median or Mode summary.
/// Contains 4 week ranges and per-payer rows with weekly + total amounts.
/// </summary>
public sealed class WeeklyForecastSummary
{
    /// <summary>Ordered list of the 4 week ranges (Mon–Sun).</summary>
    public IReadOnlyList<WeekRange> Weeks { get; init; } = [];

    /// <summary>Per-payer rows with weekly breakdown.</summary>
    public IReadOnlyList<WeeklyPayerRow> PayerRows { get; init; } = [];

    /// <summary>Totals row across all payers.</summary>
    public WeeklyPayerRow Totals { get; init; } = new("Total");
}

/// <summary>A Mon–Sun week range.</summary>
public sealed record WeekRange(DateOnly Start, DateOnly End)
{
    public string Label => $"{Start:MM/dd/yyyy} - {End:MM/dd/yyyy}";
}

/// <summary>One payer row in the weekly forecast table.</summary>
public sealed class WeeklyPayerRow
{
    public string PayerName { get; init; }

    /// <summary>Per-week amounts keyed by WeekRange.Start.</summary>
    public Dictionary<DateOnly, WeeklyAmounts> WeekAmounts { get; init; } = [];

    public decimal TotalAllowed { get; init; }
    public decimal TotalPaid { get; init; }

    public WeeklyPayerRow(string payerName) => PayerName = payerName;
}

/// <summary>Expected Allowed Amount and Expected Paid for a single week.</summary>
public sealed record WeeklyAmounts(decimal ExpectedAllowed, decimal ExpectedPaid);

/// <summary>
/// Parsed content from a prediction_insights JSON file produced by the
/// PredictionAnalysisApp AI report. Only the fields the dashboard needs are mapped.
/// </summary>
public sealed class PredictionInsight
{
    public string ReportTitle  { get; init; } = string.Empty;
    public string ReportPeriod { get; init; } = string.Empty;
    public string GeneratedAt  { get; init; } = string.Empty;
    public string ModelUsed    { get; init; } = string.Empty;

    /// <summary>
    /// The cleaned, displayable sections extracted from the raw_response JSON blob.
    /// Each section has a title and ordered subsections with bullet lists.
    /// </summary>
    public IReadOnlyList<InsightSection> Sections { get; init; } = [];

    /// <summary>Source file name shown in the card footer.</summary>
    public string SourceFileName { get; init; } = string.Empty;
}

public sealed class InsightSection
{
    public int    SectionNumber { get; init; }
    public string Title        { get; init; } = string.Empty;
    public IReadOnlyList<InsightSubsection> Subsections { get; init; } = [];
}

public sealed class InsightSubsection
{
    public string Title   { get; init; } = string.Empty;
    public IReadOnlyList<string> Bullets { get; init; } = [];
}
