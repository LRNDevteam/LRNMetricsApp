namespace LabMetricsDashboard.Models;

public sealed class ReviewerOption
{
    public int LabUserId { get; set; }
    public string UserName { get; set; } = string.Empty;
    public string FullName { get; set; } = string.Empty;
    public string Email { get; set; } = string.Empty;

    public string DisplayName => string.IsNullOrWhiteSpace(FullName) ? UserName : $"{FullName} ({UserName})";
}
