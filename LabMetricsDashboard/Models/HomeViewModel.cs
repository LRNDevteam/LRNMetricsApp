namespace LabMetricsDashboard.Models;

public sealed class HomeViewModel
{
    public List<LabTileViewModel> LabTiles { get; init; } = [];

    /// <summary>Current sort mode: "latest" or "az".</summary>
    public string Sort { get; init; } = "latest";
}
