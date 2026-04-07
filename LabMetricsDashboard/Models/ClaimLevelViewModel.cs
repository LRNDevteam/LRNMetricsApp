namespace LabMetricsDashboard.Models;

public sealed class ClaimLevelViewModel
{
    public List<string> AvailableLabs { get; init; } = [];
    public string SelectedLab { get; init; } = string.Empty;

    // Filter inputs
    public string? FilterPayerName { get; init; }
    public string? FilterPayerType { get; init; }
    public string? FilterClaimStatus { get; init; }
    public string? FilterClinicName { get; init; }
    public string? FilterDenialCode { get; init; }

    // Filter options (populated from data)
    public List<string> PayerTypes { get; init; } = [];
    public List<string> ClaimStatuses { get; init; } = [];
    public List<string> ClinicNames { get; init; } = [];

    // Current page of records (already sliced)
    public List<ClaimRecord> Records { get; init; } = [];

    public PageInfo Paging { get; init; } = new(1, 50, 0, 0);

    /// <summary>Full path of the source CSV file that was loaded.</summary>
    public string? ResolvedFilePath { get; init; }
}
