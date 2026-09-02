using System.Text.Json.Serialization;

namespace LabMetricsDashboard.Models;

/// <summary>
/// Beech Tree Revenue Pipeline LIS executive screen (v1.6 VOL-01 / VOL-02 / RES-01).
/// Separate from the existing Three-Pillar Diagnostic page.
/// </summary>
public sealed class RevenuePipelineLisViewModel
{
    public string LabName { get; set; } = "";
    public string BackUrl { get; set; } = "/ExecutiveSummary";
    public DateTime AsOfDate { get; set; }
    public string? WeekFolder { get; set; }
    public string? ErrorMessage { get; set; }
    public string? WarningMessage { get; set; }

    public Vol01Response? Vol01 { get; set; }
    public Vol01DistributionResponse? Vol01Clinic { get; set; }
    public Vol01DistributionResponse? Vol01Panel { get; set; }
    public Vol02Response? Vol02 { get; set; }
    public Vol02aResponse? Vol02a { get; set; }
    public Vol02bResponse? Vol02b { get; set; }
    public Res01Response? Res01 { get; set; }
    public IReadOnlyList<Res01AgingBucket> Res01Aging { get; set; } = [];
}

public sealed record DailySampleCount(DateTime Date, int Samples);

public sealed record Vol01DailyPoint(
    [property: JsonPropertyName("date")] string Date,
    [property: JsonPropertyName("samples")] int Samples,
    [property: JsonPropertyName("moving_average_7d")] decimal MovingAverage7d,
    [property: JsonPropertyName("window")] string Window);

public sealed record Vol01Window(
    [property: JsonPropertyName("start")] string Start,
    [property: JsonPropertyName("end")] string End,
    [property: JsonPropertyName("days")] int Days);

public sealed record Vol01Calculation(
    [property: JsonPropertyName("current_total_samples")] int CurrentTotalSamples,
    [property: JsonPropertyName("previous_total_samples")] int PreviousTotalSamples,
    [property: JsonPropertyName("absolute_change_samples")] int AbsoluteChangeSamples,
    [property: JsonPropertyName("percent_change")] decimal? PercentChange,
    [property: JsonPropertyName("current_average_per_calendar_day")] decimal CurrentAveragePerCalendarDay,
    [property: JsonPropertyName("previous_average_per_calendar_day")] decimal PreviousAveragePerCalendarDay,
    [property: JsonPropertyName("sample_calculation")] string SampleCalculation);

public sealed record Vol01Response(
    [property: JsonPropertyName("metric_id")] string MetricId,
    [property: JsonPropertyName("metric_name")] string MetricName,
    [property: JsonPropertyName("as_of_date")] string AsOfDate,
    [property: JsonPropertyName("current_window")] Vol01Window CurrentWindow,
    [property: JsonPropertyName("previous_window")] Vol01Window PreviousWindow,
    [property: JsonPropertyName("calculation")] Vol01Calculation Calculation,
    [property: JsonPropertyName("daily_data")] IReadOnlyList<Vol01DailyPoint> DailyData);

public sealed record DimensionWindowCount(string Name, bool IsCurrent, int Samples);

public sealed record Vol01DistributionRow(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("current_samples")] int CurrentSamples,
    [property: JsonPropertyName("previous_samples")] int PreviousSamples,
    [property: JsonPropertyName("absolute_change")] int AbsoluteChange,
    [property: JsonPropertyName("percent_change")] decimal? PercentChange,
    [property: JsonPropertyName("current_share")] decimal CurrentShare,
    [property: JsonPropertyName("previous_share")] decimal PreviousShare,
    [property: JsonPropertyName("share_change_percentage_points")] decimal ShareChangePercentagePoints);

public sealed record Vol01DistributionResponse(
    [property: JsonPropertyName("metric_id")] string MetricId,
    [property: JsonPropertyName("parent_metric_id")] string ParentMetricId,
    [property: JsonPropertyName("dimension")] string Dimension,
    [property: JsonPropertyName("as_of_date")] string AsOfDate,
    [property: JsonPropertyName("current_window_start")] string CurrentWindowStart,
    [property: JsonPropertyName("current_window_end")] string CurrentWindowEnd,
    [property: JsonPropertyName("previous_window_start")] string PreviousWindowStart,
    [property: JsonPropertyName("previous_window_end")] string PreviousWindowEnd,
    [property: JsonPropertyName("current_total_samples")] int CurrentTotalSamples,
    [property: JsonPropertyName("previous_total_samples")] int PreviousTotalSamples,
    [property: JsonPropertyName("rows")] IReadOnlyList<Vol01DistributionRow> Rows);

public sealed record Vol02MonthlyPoint(
    [property: JsonPropertyName("month")] string Month,
    [property: JsonPropertyName("window_start")] string WindowStart,
    [property: JsonPropertyName("window_end")] string WindowEnd,
    [property: JsonPropertyName("matched_mtd_samples")] int MatchedMtdSamples,
    [property: JsonPropertyName("elapsed_calendar_dates")] int ElapsedCalendarDates,
    [property: JsonPropertyName("lis_observed_collection_dates")] int LisObservedCollectionDates,
    [property: JsonPropertyName("period")] string Period);

public sealed record Vol02Calculation(
    [property: JsonPropertyName("current_matched_mtd_samples")] int CurrentMatchedMtdSamples,
    [property: JsonPropertyName("previous_month_matched_mtd_samples")] int PreviousMonthMatchedMtdSamples,
    [property: JsonPropertyName("previous_month_absolute_change")] int PreviousMonthAbsoluteChange,
    [property: JsonPropertyName("previous_month_percent_variance")] decimal? PreviousMonthPercentVariance,
    [property: JsonPropertyName("same_month_prior_year_samples")] int SameMonthPriorYearSamples,
    [property: JsonPropertyName("same_month_prior_year_absolute_change")] int SameMonthPriorYearAbsoluteChange,
    [property: JsonPropertyName("same_month_prior_year_percent_variance")] decimal? SameMonthPriorYearPercentVariance,
    [property: JsonPropertyName("prior_12_month_average")] decimal Prior12MonthAverage,
    [property: JsonPropertyName("prior_12_month_median")] decimal Prior12MonthMedian,
    [property: JsonPropertyName("percent_variance_to_prior_12_average")] decimal? PercentVarianceToPrior12Average,
    [property: JsonPropertyName("interpretation_label")] string InterpretationLabel,
    [property: JsonPropertyName("projected_month_volume")] int? ProjectedMonthVolume,
    [property: JsonPropertyName("projection_status")] string ProjectionStatus);

public sealed record Vol02Response(
    [property: JsonPropertyName("metric_id")] string MetricId,
    [property: JsonPropertyName("metric_name")] string MetricName,
    [property: JsonPropertyName("as_of_date")] string AsOfDate,
    [property: JsonPropertyName("matched_cutoff_day")] int MatchedCutoffDay,
    [property: JsonPropertyName("history_months")] int HistoryMonths,
    [property: JsonPropertyName("calculation")] Vol02Calculation Calculation,
    [property: JsonPropertyName("monthly_data")] IReadOnlyList<Vol02MonthlyPoint> MonthlyData);

public sealed record MonthlyCategoryCount(string Month, string Dimension, string Category, int Samples);

public sealed record Vol02aTrendPoint(
    [property: JsonPropertyName("month")] string Month,
    [property: JsonPropertyName("samples")] decimal Samples);

public sealed record Vol02aCategory(
    [property: JsonPropertyName("category")] string Category,
    [property: JsonPropertyName("current_samples")] decimal CurrentSamples,
    [property: JsonPropertyName("comparison_samples")] decimal ComparisonSamples,
    [property: JsonPropertyName("absolute_change")] decimal AbsoluteChange,
    [property: JsonPropertyName("percent_change")] decimal? PercentChange,
    [property: JsonPropertyName("current_share")] decimal CurrentShare,
    [property: JsonPropertyName("comparison_share")] decimal ComparisonShare,
    [property: JsonPropertyName("share_change_percentage_points")] decimal ShareChangePercentagePoints,
    [property: JsonPropertyName("trend")] IReadOnlyList<Vol02aTrendPoint> Trend);

public sealed record Vol02aDimension(
    [property: JsonPropertyName("category_count")] int CategoryCount,
    [property: JsonPropertyName("current_total")] decimal CurrentTotal,
    [property: JsonPropertyName("comparison_total")] decimal ComparisonTotal,
    [property: JsonPropertyName("categories")] IReadOnlyList<Vol02aCategory> Categories);

public sealed record Vol02aResponse(
    [property: JsonPropertyName("metric_id")] string MetricId,
    [property: JsonPropertyName("parent_metric_id")] string ParentMetricId,
    [property: JsonPropertyName("selected_month")] string SelectedMonth,
    [property: JsonPropertyName("default_comparison")] string DefaultComparison,
    [property: JsonPropertyName("matched_cutoff_day")] int MatchedCutoffDay,
    [property: JsonPropertyName("monthly_totals")] IReadOnlyDictionary<string, int> MonthlyTotals,
    [property: JsonPropertyName("dimensions")] IReadOnlyDictionary<string, Vol02aDimension> Dimensions);

public sealed record Vol02bPeriodPoint(
    [property: JsonPropertyName("start")] string Start,
    [property: JsonPropertyName("end")] string End,
    [property: JsonPropertyName("samples")] int Samples,
    [property: JsonPropertyName("elapsed_calendar_dates")] int ElapsedCalendarDates,
    [property: JsonPropertyName("lis_observed_collection_dates")] int LisObservedCollectionDates,
    [property: JsonPropertyName("samples_per_lis_observed_date")] decimal? SamplesPerLisObservedDate);

public sealed record Vol02bMonthlyPoint(
    [property: JsonPropertyName("month")] string Month,
    [property: JsonPropertyName("matched_mtd_samples")] int MatchedMtdSamples,
    [property: JsonPropertyName("elapsed_calendar_dates")] int ElapsedCalendarDates,
    [property: JsonPropertyName("lis_observed_collection_dates")] int LisObservedCollectionDates,
    [property: JsonPropertyName("samples_per_lis_observed_date")] decimal? SamplesPerLisObservedDate,
    [property: JsonPropertyName("period")] string Period);

public sealed record Vol02bResponse(
    [property: JsonPropertyName("metric_id")] string MetricId,
    [property: JsonPropertyName("parent_metric_id")] string ParentMetricId,
    [property: JsonPropertyName("metric_name")] string MetricName,
    [property: JsonPropertyName("display_role")] string DisplayRole,
    [property: JsonPropertyName("as_of_date")] string AsOfDate,
    [property: JsonPropertyName("current_rolling_28_day")] Vol02bPeriodPoint CurrentRolling28Day,
    [property: JsonPropertyName("previous_rolling_28_day")] Vol02bPeriodPoint PreviousRolling28Day,
    [property: JsonPropertyName("rolling_28_day_percent_change")] decimal? Rolling28DayPercentChange,
    [property: JsonPropertyName("monthly_data")] IReadOnlyList<Vol02bMonthlyPoint> MonthlyData,
    [property: JsonPropertyName("data_note")] string DataNote);

public sealed record Res01SampleRecord(DateTime Collected, DateTime? Reported);

public sealed record Res01WeeklyCohort(
    [property: JsonPropertyName("week_start")] string WeekStart,
    [property: JsonPropertyName("week_end")] string WeekEnd,
    [property: JsonPropertyName("eligible")] int Eligible,
    [property: JsonPropertyName("within_d10")] int WithinD10,
    [property: JsonPropertyName("d10_rate")] decimal D10Rate,
    [property: JsonPropertyName("median_days")] decimal? MedianDays,
    [property: JsonPropertyName("p75_days")] decimal? P75Days,
    [property: JsonPropertyName("p90_days")] decimal? P90Days,
    [property: JsonPropertyName("p95_days")] decimal? P95Days,
    [property: JsonPropertyName("unresolved")] int Unresolved,
    [property: JsonPropertyName("comparison_window")] string ComparisonWindow);

public sealed record Res01Headline(
    [property: JsonPropertyName("cohort_start")] string CohortStart,
    [property: JsonPropertyName("cohort_end")] string CohortEnd,
    [property: JsonPropertyName("eligible_samples")] int EligibleSamples,
    [property: JsonPropertyName("reported_within_10_days")] int ReportedWithin10Days,
    [property: JsonPropertyName("d10_resulted_rate")] decimal D10ResultedRate,
    [property: JsonPropertyName("prior_d10_resulted_rate")] decimal PriorD10ResultedRate,
    [property: JsonPropertyName("change_percentage_points")] decimal ChangePercentagePoints,
    [property: JsonPropertyName("median_days")] decimal? MedianDays,
    [property: JsonPropertyName("p75_days")] decimal? P75Days,
    [property: JsonPropertyName("p90_days")] decimal? P90Days,
    [property: JsonPropertyName("p95_days")] decimal? P95Days,
    [property: JsonPropertyName("open_samples_older_than_10_days")] int OpenSamplesOlderThan10Days);

public sealed record Res01Response(
    [property: JsonPropertyName("metric_id")] string MetricId,
    [property: JsonPropertyName("metric_name")] string MetricName,
    [property: JsonPropertyName("as_of_date")] string AsOfDate,
    [property: JsonPropertyName("headline")] Res01Headline Headline,
    [property: JsonPropertyName("weekly_cohorts")] IReadOnlyList<Res01WeeklyCohort> WeeklyCohorts);

public sealed record Res01AgingBucket(
    [property: JsonPropertyName("label")] string Label,
    [property: JsonPropertyName("samples")] int Samples);
