namespace LabMetricsDashboard.Models;

public sealed class LisSummaryViewModel
{
    public List<LabOption> LabOptions { get; init; } = [];
    public int? SelectedLabId { get; init; }
    public string? SelectedLab { get; init; }
    public string? FilterCollectedFrom { get; init; }
    public string? FilterCollectedTo { get; init; }
    public string? LogicSheetName { get; init; }
    public List<string> Months { get; init; } = [];
    public List<int> Years { get; init; } = [];
    public List<LisSummaryRow> Rows { get; init; } = [];
    public Dictionary<string, int> GrandTotalByMonth { get; init; } = [];
    public Dictionary<int, int> GrandTotalByYear { get; init; } = [];
    public int GrandTotal { get; init; }
    public string? ErrorMessage { get; init; }
    public bool HasFilters => !string.IsNullOrWhiteSpace(FilterCollectedFrom) || !string.IsNullOrWhiteSpace(FilterCollectedTo);
}

public sealed class LisSummaryRow
{
    public string Code { get; init; } = string.Empty;
    public string Description { get; init; } = string.Empty;
    public string Logic { get; init; } = string.Empty;
    public int Level { get; init; }
    public Dictionary<string, int> ByMonth { get; init; } = [];
    public Dictionary<int, int> ByYear { get; init; } = [];
    public int Total { get; init; }
    public bool IsSection => Code.Equals("A", StringComparison.OrdinalIgnoreCase) || Code.Equals("B", StringComparison.OrdinalIgnoreCase);
    public bool IsBullet => Code is "•" or "◦";
}

public sealed record LisSummaryResult(
    string LogicSheetName,
    List<string> Months,
    List<int> Years,
    List<LisSummaryRow> Rows,
    Dictionary<string, int> GrandTotalByMonth,
    Dictionary<int, int> GrandTotalByYear,
    int GrandTotal,
    LisSummaryKpiCards KpiCards);

public sealed record LisSummaryKpiCards(
    int TotalSamples,
    int BilledCount,
    int UnbilledCount,
    int SelfPayCount);
    
public sealed class LisSummaryFilters
{
    public int? LabId { get; set; }
    public DateOnly? CollectedFrom { get; set; }
    public DateOnly? CollectedTo { get; set; }
}