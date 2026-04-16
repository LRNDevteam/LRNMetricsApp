namespace LabMetricsDashboard.Models;


public sealed class LineLevelViewModel
{
    public List<string> AvailableLabs { get; init; } = [];
    public string SelectedLab { get; init; } = string.Empty;

    // Filter inputs
    public string? FilterPayerName { get; init; }
    public List<string> FilterPayerTypes { get; init; } = [];
    public List<string> FilterClaimStatuses { get; init; } = [];
    public List<string> FilterPayStatuses { get; init; } = [];
    public List<string> FilterCPTCodes { get; init; } = [];
    public List<string> FilterClinicNames { get; init; } = [];
    public string? FilterDenialCode { get; init; }

    // Filter option lists (populated from data)
    public List<string> PayerTypes { get; init; } = [];
    public List<string> ClaimStatuses { get; init; } = [];
    public List<string> PayStatuses { get; init; } = [];
    public List<string> ClinicNames { get; init; } = [];
    public List<string> CPTCodes { get; init; } = [];

    /// <summary>True when any filter is active.</summary>
    public bool HasFilters => !string.IsNullOrWhiteSpace(FilterPayerName)
        || FilterPayerTypes.Count > 0
        || FilterClaimStatuses.Count > 0
        || FilterPayStatuses.Count > 0
        || FilterCPTCodes.Count > 0
        || FilterClinicNames.Count > 0
        || !string.IsNullOrWhiteSpace(FilterDenialCode);

    // Current page of records (already sliced)
    public List<LineRecord> Records { get; init; } = [];

    public PageInfo Paging { get; init; } = new(1, 50, 0, 0);

    /// <summary>Full path of the source CSV file that was loaded.</summary>
    public string? ResolvedFilePath { get; init; }

    /// <summary>Describes the data source (e.g. "SQL Database" or CSV file path).</summary>
    public string? DataSource { get; init; }

    /// <summary>User-facing error message when the query fails (e.g. timeout).</summary>
    public string? ErrorMessage { get; init; }
}
