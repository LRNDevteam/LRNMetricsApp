namespace LabMetricsDashboard.ViewModels;

public class RecordsPagerViewModel
{
    public string TabName { get; set; } = string.Empty;
    public int Page { get; set; }
    public int TotalPages { get; set; }
    public int TotalItems { get; set; }
    public int PageSize { get; set; }
    public string ItemLabel { get; set; } = "rows";
    public Func<int, string?, string> BuildUrl { get; set; } = (_, _) => "#";
}
