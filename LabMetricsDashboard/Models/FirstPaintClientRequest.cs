namespace LabMetricsDashboard.Models;

public sealed class FirstPaintClientRequest
{
    public string? Report { get; set; }
    public string? Lab { get; set; }
    public string? Stage { get; set; }
    public long Ms { get; set; }
    public long? TtfbMs { get; set; }
    public long? ResponseEndMs { get; set; }
    public string? Extra { get; set; }
}
