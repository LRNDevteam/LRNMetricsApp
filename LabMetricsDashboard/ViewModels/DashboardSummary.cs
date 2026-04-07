namespace LabMetricsDashboard.ViewModels;

public class DashboardSummary
{
    public int TotalTasks { get; set; }
    public int OpenTasks { get; set; }
    public int InProgressTasks { get; set; }
    public int CompletedTasks { get; set; }
    public int OverdueTasks { get; set; }
    public int DueInThreeDays { get; set; }
    public int HighPriorityTasks { get; set; }
    public int EscalatedTasks { get; set; }
    public decimal TotalInsuranceBalance { get; set; }
}
