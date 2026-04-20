namespace LabMetricsDashboard.Models;

/// <summary>
/// A single entry in the help-bot knowledge base.
/// </summary>
public sealed record HelpBotEntry
{
    public int Id { get; init; }
    public List<string> Keywords { get; init; } = [];
    public string Question { get; init; } = string.Empty;
    public string Answer { get; init; } = string.Empty;
}
