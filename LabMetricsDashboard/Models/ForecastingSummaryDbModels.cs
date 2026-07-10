namespace LabMetricsDashboard.Models;

/// <summary>Bucket definition row from usp_GetForecastingSummaryByWeekRange (RS1).</summary>
public sealed record ForecastingBucketSpRow(
    int SortOrder,
    string BucketKey,
    DateOnly? WeekStart,
    DateOnly? WeekEnd,
    string BucketLabel);

/// <summary>Payer x bucket summary row from usp_GetForecastingSummaryByWeekRange (RS2/RS3).</summary>
public sealed record ForecastingPayerBucketSpRow(
    string PayerName,
    int SortOrder,
    string BucketKey,
    string BucketLabel,
    DateOnly? WeekStart,
    DateOnly? WeekEnd,
    long ClaimLineCount,
    decimal MedianAllowedTotal,
    decimal MedianPaidTotal,
    decimal ModeAllowedTotal,
    decimal ModePaidTotal);

/// <summary>Median and Mode weekly summaries produced by the forecasting summary SP.</summary>
public sealed record ForecastingSummaryFromDb(
    WeeklyForecastSummary MedianSummary,
    WeeklyForecastSummary ModeSummary);
