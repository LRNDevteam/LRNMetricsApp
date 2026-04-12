namespace LabMetricsDashboard.Models;

public sealed class UsageHeartbeatRequest
{
    public string? TabId { get; set; }
    public string? PageName { get; set; }
    public string? Path { get; set; }
    public string? QueryString { get; set; }
    public int IdleSeconds { get; set; }
    public string? LocationText { get; set; }
    public decimal? Latitude { get; set; }
    public decimal? Longitude { get; set; }
}
