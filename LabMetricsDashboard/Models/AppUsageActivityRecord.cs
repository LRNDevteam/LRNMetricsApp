namespace LabMetricsDashboard.Models;

public sealed class AppUsageActivityRecord
{
    public long UsageAuditId { get; set; }
    public DateTime OccurredOnUtc { get; set; }
    public string UserName { get; set; } = string.Empty;
    public string BrowserId { get; set; } = string.Empty;
    public string TabId { get; set; } = string.Empty;
    public string PageName { get; set; } = string.Empty;
    public string Path { get; set; } = string.Empty;
    public string QueryString { get; set; } = string.Empty;
    public string IpAddress { get; set; } = string.Empty;
    public string LocationText { get; set; } = string.Empty;
    public decimal? Latitude { get; set; }
    public decimal? Longitude { get; set; }
    public string UserAgent { get; set; } = string.Empty;
    public string ActivityType { get; set; } = string.Empty;
}
