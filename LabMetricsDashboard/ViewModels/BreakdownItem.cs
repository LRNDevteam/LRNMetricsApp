namespace LabMetricsDashboard.ViewModels;

public class BreakdownItem
{
    public string Label { get; set; } = string.Empty;
    public int Count { get; set; }
    public decimal Percentage { get; set; }
    public int OpenCount { get; set; }
    public int CompletedCount { get; set; }
    public int OverdueCount { get; set; }
    public int HighPriorityCount { get; set; }
    public decimal InsuranceBalanceSum { get; set; }
    public double AverageSla { get; set; }
}
