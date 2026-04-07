namespace LabMetricsDashboard.ViewModels;

public class ClaimPagerViewModel
{
    public int Page { get; set; }
    public int TotalPages { get; set; }
    public int TotalItems { get; set; }
    public int PageSize { get; set; }
    public Func<int, string> BuildUrl { get; set; } = _ => "#";
}
