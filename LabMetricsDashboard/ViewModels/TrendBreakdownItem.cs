namespace LabMetricsDashboard.ViewModels;

public sealed class TrendBreakdownItem
{
    public string Label { get; set; } = string.Empty;
    public string PeriodType { get; set; } = string.Empty;
    public int Year { get; set; }
    public int PeriodNumber { get; set; }
    public string PeriodName { get; set; } = string.Empty;
    public DateTime PeriodStart { get; set; }
    public DateTime PeriodEnd { get; set; }
    public int DenialCount { get; set; }
    public int ClaimCount { get; set; }
    public decimal InsuranceBalance { get; set; }
    public decimal TotalBalance { get; set; }
    public decimal ImpactPercentage { get; set; }
}
