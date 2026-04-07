namespace LabMetricsDashboard.Models;

public class TaskBoardCsvUpdate
{
    public string UniqueTrackId { get; set; } = string.Empty;
    public string TaskId { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public string AssignedTo { get; set; } = string.Empty;
    public string RunId { get; set; } = string.Empty;
    public DateTime? DateCompleted { get; set; }
}
