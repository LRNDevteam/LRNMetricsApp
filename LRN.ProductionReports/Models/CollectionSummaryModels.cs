namespace LRN.ProductionReports.Models;

/// <summary>
/// Filter parameters shared by Collection Summary display and Excel generation.
/// </summary>
public sealed record CollectionSummaryFilters(
    List<string>? PayerNames = null,
    List<string>? PanelNames = null,
    DateOnly? DosFrom = null,
    DateOnly? DosTo = null,
    DateOnly? FirstBillFrom = null,
    DateOnly? FirstBillTo = null,
    DateOnly? CheckDateFrom = null,
    DateOnly? CheckDateTo = null);

/// <summary>
/// A single Collection Summary amount cell: claim count, total paid, and average paid.
/// </summary>
public sealed record CollectionSummaryCell(int ClaimCount, decimal TotalPaid)
{
    public decimal AveragePaidAmount => ClaimCount == 0 ? 0m : TotalPaid / ClaimCount;
}

/// <summary>Year/month period used by Collection Summary Monthly Claim Volume.</summary>
public sealed record CollectionSummaryMonthPeriod(int Year, int Month)
{
    public string Key => $"{Year:D4}-{Month:D2}";
    public string Label => new DateTime(Year, Month, 1).ToString("MMM");
}

/// <summary>Week period used by Collection Summary Weekly Claim Volume.</summary>
public sealed record CollectionSummaryWeekPeriod(byte WeekKey, DateOnly WeekStart, DateOnly WeekEnd)
{
    public string Key => $"W{WeekKey}";
    public string Label => $"Week {WeekKey} ({WeekStart:MM/dd} - {WeekEnd:MM/dd})";
}

/// <summary>Payer drill-down row under a panel for monthly collection claim volume.</summary>
public sealed class CollectionSummaryMonthlyPayerRow
{
    public required string PayerName { get; init; }
    public byte PayerRank { get; init; }
    public Dictionary<string, CollectionSummaryCell> ByMonth { get; init; } = [];
    public Dictionary<int, CollectionSummaryCell> ByYear { get; init; } = [];
    public int TotalClaimCount { get; init; }
    public decimal TotalPaid { get; init; }
    public decimal AveragePaidAmount => TotalClaimCount == 0 ? 0m : TotalPaid / TotalClaimCount;
}

/// <summary>Panel row for monthly collection claim volume.</summary>
public sealed class CollectionSummaryMonthlyPanelRow
{
    public required string PanelName { get; init; }
    public Dictionary<string, CollectionSummaryCell> ByMonth { get; init; } = [];
    public Dictionary<int, CollectionSummaryCell> ByYear { get; init; } = [];
    public int TotalClaimCount { get; init; }
    public decimal TotalPaid { get; init; }
    public decimal AveragePaidAmount => TotalClaimCount == 0 ? 0m : TotalPaid / TotalClaimCount;
    public List<CollectionSummaryMonthlyPayerRow> Payers { get; init; } = [];
}

/// <summary>Monthly Claim Volume result for Collection Summary.</summary>
public sealed class CollectionSummaryMonthlyClaimVolumeResult
{
    public static readonly CollectionSummaryMonthlyClaimVolumeResult Empty = new();

    public List<CollectionSummaryMonthPeriod> Periods { get; init; } = [];
    public List<int> Years { get; init; } = [];
    public List<CollectionSummaryMonthlyPanelRow> PanelRows { get; init; } = [];
    public Dictionary<string, CollectionSummaryCell> GrandTotalByMonth { get; init; } = [];
    public Dictionary<int, CollectionSummaryCell> GrandTotalByYear { get; init; } = [];
    public int GrandTotalClaimCount { get; init; }
    public decimal GrandTotalPaid { get; init; }
    public decimal GrandAveragePaidAmount => GrandTotalClaimCount == 0 ? 0m : GrandTotalPaid / GrandTotalClaimCount;
    public bool HasData => PanelRows.Count > 0;
}

/// <summary>Payer drill-down row under a panel for weekly collection claim volume.</summary>
public sealed class CollectionSummaryWeeklyPayerRow
{
    public required string PayerName { get; init; }
    public byte PayerRank { get; init; }
    public Dictionary<string, CollectionSummaryCell> ByWeek { get; init; } = [];
    public int TotalClaimCount { get; init; }
    public decimal TotalPaid { get; init; }
    public decimal AveragePaidAmount => TotalClaimCount == 0 ? 0m : TotalPaid / TotalClaimCount;
}

/// <summary>Panel row for weekly collection claim volume.</summary>
public sealed class CollectionSummaryWeeklyPanelRow
{
    public required string PanelName { get; init; }
    public Dictionary<string, CollectionSummaryCell> ByWeek { get; init; } = [];
    public int TotalClaimCount { get; init; }
    public decimal TotalPaid { get; init; }
    public decimal AveragePaidAmount => TotalClaimCount == 0 ? 0m : TotalPaid / TotalClaimCount;
    public List<CollectionSummaryWeeklyPayerRow> Payers { get; init; } = [];
}

/// <summary>Weekly Claim Volume result for Collection Summary.</summary>
public sealed class CollectionSummaryWeeklyClaimVolumeResult
{
    public static readonly CollectionSummaryWeeklyClaimVolumeResult Empty = new();

    public List<CollectionSummaryWeekPeriod> Weeks { get; init; } = [];
    public List<CollectionSummaryWeeklyPanelRow> PanelRows { get; init; } = [];
    public Dictionary<string, CollectionSummaryCell> GrandTotalByWeek { get; init; } = [];
    public int GrandTotalClaimCount { get; init; }
    public decimal GrandTotalPaid { get; init; }
    public decimal GrandAveragePaidAmount => GrandTotalClaimCount == 0 ? 0m : GrandTotalPaid / GrandTotalClaimCount;
    public bool HasData => PanelRows.Count > 0;
}
