namespace LabMetricsDashboard.Models;

public class TaskBoardUploadResult
{
    public int TotalRows { get; set; }
    public int UpdatedRows { get; set; }
    public int SkippedRows { get; set; }
    public List<string> Errors { get; set; } = new();
}
