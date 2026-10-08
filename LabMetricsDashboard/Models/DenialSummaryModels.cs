namespace LabMetricsDashboard.Models;

/// <summary>
/// Denial Summary page filters. Every list is passed to the read SPs as a '|' separated value;
/// with no filter the SPs return the aggregate tables refreshed at claim-file ingest.
/// </summary>
public sealed class DenialSummaryFilters
{
    public List<string> PayerNames { get; set; } = [];
    public List<string> PayerTypes { get; set; } = [];
    public List<string> DenialCodes { get; set; } = [];
    public DateOnly? DenialFrom { get; set; }
    public DateOnly? DenialTo { get; set; }

    /// <summary>Denial List only: keeps the rows whose codes include every code searched (@DenialCodeSearch).</summary>
    public string? DenialCodeSearch { get; set; }

    public bool HasFilters =>
        PayerNames.Count > 0 || PayerTypes.Count > 0 || DenialCodes.Count > 0
        || DenialFrom.HasValue || DenialTo.HasValue || !string.IsNullOrWhiteSpace(DenialCodeSearch);

    public void Normalize()
    {
        PayerNames = Clean(PayerNames);
        PayerTypes = Clean(PayerTypes);
        DenialCodes = Clean(DenialCodes);
        DenialCodeSearch = string.IsNullOrWhiteSpace(DenialCodeSearch) ? null : DenialCodeSearch.Trim();
    }

    private static List<string> Clean(List<string>? values) =>
        (values ?? [])
            .Where(v => !string.IsNullOrWhiteSpace(v))
            .Select(v => v.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
}

/// <summary>
/// One row x period cell of the Monthly / Weekly Denial Analysis
/// (usp_GetAnP_DenialMonthly / usp_GetAnP_DenialWeekly).
/// </summary>
public sealed record DenialPeriodRow(
    string RowType,
    string PayerName,
    string DenialCode,
    int PayerRank,
    int CodeRank,
    string PeriodType,
    string PeriodKey,
    int? PeriodYear,
    DateTime? PeriodStart,
    DateTime? PeriodEnd,
    string PeriodLabel,
    int ClaimCount,
    decimal TotalInsuranceBalance,
    int SortOrder,
    int PeriodOrder,
    string IndexLabel = "",
    string RowLabel = "",
    decimal CoveragePct = 0m);

/// <summary>
/// Denial Summary tiles (usp_GetAnP_DenialSummaryTiles): every denied claim with a balance,
/// whatever its Denial Date.
/// </summary>
public sealed record DenialSummaryTiles(
    int DeniedClaims,
    decimal InsuranceBalance,
    int DenialCodes,
    int Insurances,
    int UndatedGroups,
    DateTime? LoadedThrough,
    DateTime? RefreshedAt)
{
    public static readonly DenialSummaryTiles Empty = new(0, 0m, 0, 0, 0, null, null);
}

/// <summary>A column of the Monthly / Weekly pivot, in SP PeriodOrder.</summary>
public sealed record DenialPeriodColumn(
    string PeriodType,
    string PeriodKey,
    int? PeriodYear,
    string PeriodLabel,
    int PeriodOrder);

/// <summary>A pivot row (payer, top-3 denial code or grand total) with its cells keyed by PeriodKey.</summary>
public sealed record DenialPeriodPivotRow(
    string RowType,
    string PayerName,
    string DenialCode,
    int PayerRank,
    int CodeRank,
    int SortOrder,
    IReadOnlyDictionary<string, DenialPeriodRow> Cells,
    string IndexLabel = "",
    string RowLabel = "");

/// <summary>
/// Monthly / Weekly result reshaped for display only: columns and rows come straight from the
/// SP's PeriodOrder / SortOrder, every value is an SP cell.
/// </summary>
public sealed class DenialPeriodResult
{
    public static readonly DenialPeriodResult Empty = new([], [], []);

    public DenialPeriodResult(
        IReadOnlyList<DenialPeriodRow> raw,
        IReadOnlyList<DenialPeriodColumn> columns,
        IReadOnlyList<DenialPeriodPivotRow> rows)
    {
        Raw = raw;
        Columns = columns;
        Rows = rows;
    }

    public IReadOnlyList<DenialPeriodRow> Raw { get; }
    public IReadOnlyList<DenialPeriodColumn> Columns { get; }
    public IReadOnlyList<DenialPeriodPivotRow> Rows { get; }

    public DenialPeriodPivotRow? GrandTotal => Rows.FirstOrDefault(r => r.RowType == "T");

    public static DenialPeriodResult From(IReadOnlyList<DenialPeriodRow> raw)
    {
        if (raw.Count == 0) return Empty;

        var columns = raw
            .GroupBy(r => r.PeriodKey)
            .Select(g => g.First())
            .OrderBy(r => r.PeriodOrder)
            .Select(r => new DenialPeriodColumn(r.PeriodType, r.PeriodKey, r.PeriodYear, r.PeriodLabel, r.PeriodOrder))
            .ToList();

        var rows = raw
            .GroupBy(r => r.SortOrder)
            .OrderBy(g => g.Key)
            .Select(g =>
            {
                var first = g.First();
                return new DenialPeriodPivotRow(
                    first.RowType, first.PayerName, first.DenialCode, first.PayerRank, first.CodeRank, first.SortOrder,
                    g.ToDictionary(r => r.PeriodKey, StringComparer.Ordinal), first.IndexLabel, first.RowLabel);
            })
            .ToList();

        return new DenialPeriodResult(raw, columns, rows);
    }
}

/// <summary>Denial List row (usp_GetAnP_DenialList): D denial code, I insurance, T grand total.</summary>
public sealed record DenialListRow(
    string RowType,
    string DenialCode,
    string PayerName,
    int CodeRank,
    int PayerRank,
    int ClaimCount,
    decimal TotalInsuranceBalance,
    int SortOrder);

/// <summary>Denial List - Plan Type row (usp_GetAnP_DenialPlanType): D plan type, T grand total.</summary>
public sealed record DenialPlanTypeRow(
    string RowType,
    string PayerType,
    int ClaimCount,
    decimal TotalInsuranceBalance,
    int SortOrder);

/// <summary>Filter dropdown values and the denial date range (usp_GetAnP_DenialFilterOptions).</summary>
public sealed record DenialSummaryFilterOptions(
    IReadOnlyList<string> PayerNames,
    IReadOnlyList<string> PayerTypes,
    IReadOnlyList<string> DenialCodes,
    DateTime? MinDenialDate,
    DateTime? MaxDenialDate,
    DateTime? RefreshedAt)
{
    public static readonly DenialSummaryFilterOptions Empty = new([], [], [], null, null, null);
}
